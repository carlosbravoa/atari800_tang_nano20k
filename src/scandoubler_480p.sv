// scandoubler_480p — Phase A of the low-latency line-buffer plan
// (docs/mcu_offload_and_linebuffer_spec.md, §VIDEO).
//
// Replaces the SDRAM frame buffer (fb_writer + fb_reader) with a genlocked scandoubler:
// the Atari video is captured into a small N-line BSRAM ring (clk_core) and read out as
// a standard 480p59.94 raster (clk_pix = 27 MHz) with an exact 2x2 upscale + pillarbox.
// Latency is ~a few scanlines instead of ~1 frame, and no SDRAM is touched. The picture
// stores the raw 8-bit GTIA colour code (core generic palette=0) and the Altirra palette
// LUT (gtia_palette) is applied on READOUT — tiny buffer, full colour fidelity.
//
// GENLOCK (fixed 2026-06-19 after the "rolling + intermittent black" hardware result):
// the Atari VIDEO_START_OF_FIELD is the SOLE vertical frame reference. The output vertical
// counter `vy` resets to 0 on each SOF (synced to clk_pix, applied at a line boundary), and
// VSYNC is emitted at the very top (vy 0..V_SYNC-1). There is NO competing free-wrap (a
// large safety wrap only guards a dropped SOF). This makes the output VSYNC period exactly
// the Atari field period (steady -> the display locks; no roll). The earlier version
// free-wrapped at 525 AND snapped to a mid-count value -> two frame references fighting ->
// the rolling/blanking we saw.
//
// Output interface matches fb_reader (r/g/b/hs/vs/de + osd_x/osd_y) so the OSD-mix +
// hdmi_audio_out path is unchanged (hdmi VIDEO_ID_CODE=2). hdmi_audio_out aligns its
// internal cx/cy by pulsing reset at the first active pixel after VSYNC, so VS/DE are
// kept active-HIGH here.
//
// HARDWARE-TUNABLE (see docs/PHASE_AB_TESTING.md):
//   V_PIC_TOP   : first active output line (vertical picture position AND read-vs-write
//                 lead — must keep the read trailing the write within RING_LINES lines).
//   H_PIC_OFFSET: horizontal picture centring in the pillarbox.
//   SYNC_ACTIVE_LOW : 480p is nominally negative sync; default high (the image locked at
//                 high in testing). If a strict display needs negative, also invert on the
//                 path to hdmi.sv (not the reset-detect path).

`default_nettype none
`timescale 1ns/1ps

module scandoubler_480p #(
    parameter integer SRC_COLS    = 352,   // Atari active pixels captured per line
    parameter integer SRC_LINES   = 240,   // Atari active lines captured per field
    parameter integer H_PIC_OFFSET = 0,    // left margin: 3*352 = 1056 = full active (no pillarbox)
    parameter integer V_PIC_TOP   = 57,    // first active output line; HW-tuned centre on the reference panel
                                           // (also gives the read-vs-write lead that clears the 8-line
                                           // bottom-at-top wrap). Theoretical centre is 33; 57 is real.
    parameter bit     SYNC_ACTIVE_LOW = 1'b0
)(
    // Atari source (clk_core)
    input  wire        clk_core,
    input  wire        rst_n,
    input  wire [7:0]  colour_in,   // GTIA colour code (VIDEO_B when palette=0)
    input  wire        de_in,       // active video (= ~VIDEO_BLANK)
    input  wire        sof_in,      // VIDEO_START_OF_FIELD
    input  wire        pixce,       // VIDEO_PIXCE pixel strobe

    // SIO activity flags (sys_clk domain; 2-FF synced to clk_core inside). Drawn as small
    // blocks into the captured Atari picture on the clk_core CAPTURE side — deliberately NOT
    // on the clk_pix/TMDS readout path (that approach has no HDMI timing margin).
    input  wire        sio_act_in,  // disk data streaming  (mirrors LED2)
    input  wire        sio_cmd_in,  // SIO command frame    (mirrors LED4)

    // HDMI (clk_pix = 57.375 MHz = 2*clk_core; 720-line mode)
    input  wire        clk_pix,
    input  wire [1:0]  scanline_level,  // 0=off, 1=25%, 2=50%, 3=75% brightness of the dim line
    input  wire [7:0]  h_offset,        // front porch 0..80 -> horizontal picture position
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out,
    output wire [7:0]  osd_x,
    output wire [7:0]  osd_y
);

// 8-line ring buffer (slot = line mod 8) — read may trail write by up to 7 lines.
localparam integer RING_LINES = 8;

// ── Custom frequency-locked "720-line" timing, matched to hdmi.sv VIDEO_ID_CODE=4 patched
// to 1216x786 (active 1056x720). 1216*786 = 955776 = 2*477888 = exactly one Atari frame at
// the 2x pixel rate (clk_pix = 2*clk_core) -> genlocked, integer lines, no jitter. Active is
// integer 3x of the Atari 352x240 frame. ──
localparam [10:0] H_ACT = 11'd1056, H_TOT = 11'd1216;
// Fixed HSYNC (porch position has no effect on DE-positioned panels). HFP=40, HSync=80, HBP=40.
localparam [10:0] H_SYNC_S = 11'd1096, H_SYNC_E = 11'd1176;
// h_offset is the CAPTURE start offset (skip this many leading active pixels per line), which
// pans WHICH part of the Atari line we show — moves the picture without resizing. Bigger
// h_offset shows columns further right in the source = picture moves LEFT on screen.
// 2-FF sync into clk_core (slow config; a rare 1-frame transient while adjusting is harmless).
reg [7:0] h_off_s1, h_off_core;
always_ff @(posedge clk_core) begin h_off_s1 <= h_offset; h_off_core <= h_off_s1; end

// ── SIO activity indicator (capture side, clk_core) ──────────────────────────────
// 2-FF sync the two slow (~19 ms) sys_clk activity flags into clk_core, then draw two small
// lettered blocks at the BOTTOM-LEFT of the SOURCE picture: "D" = disk data streaming
// (green), "S" = SIO command frame (white), each a filled 7×9 block with a 5×7 black glyph.
// Substituting the captured colour code costs only comparators + a tiny font ROM on wdata's
// D input — all in the timing-rich 28.6875 MHz domain, nowhere near the HDMI serializer.
reg sio_act_s1, sio_act_core, sio_cmd_s1, sio_cmd_core;
always_ff @(posedge clk_core) begin
    sio_act_s1 <= sio_act_in;  sio_act_core <= sio_act_s1;
    sio_cmd_s1 <= sio_cmd_in;  sio_cmd_core <= sio_cmd_s1;
end
localparam [7:0] SIO_Y0  = 8'd226, SIO_Y1  = 8'd234;   // shared 9-row band (rows 0..239)
localparam [8:0] DBLK_X0 = 9'd8,   DBLK_X1 = 9'd14;    // "D" block, 7 cols (cols 0..351)
localparam [8:0] SBLK_X0 = 9'd18,  SBLK_X1 = 9'd24;    // "S" block, 7 cols
localparam [7:0] SIO_COL_DATA = 8'hCA;                 // green (#6bde42)
localparam [7:0] SIO_COL_CMD  = 8'h0F;                 // white (#ffffff)
localparam [7:0] SIO_COL_INK  = 8'h00;                 // letter ink (black)
// 5×7 glyphs, row 0 = top; bit 4 = leftmost column.
function automatic [4:0] glyph_D(input [2:0] r);
    case (r)
        3'd0: glyph_D = 5'b11110; 3'd1: glyph_D = 5'b10001; 3'd2: glyph_D = 5'b10001;
        3'd3: glyph_D = 5'b10001; 3'd4: glyph_D = 5'b10001; 3'd5: glyph_D = 5'b10001;
        default: glyph_D = 5'b11110;
    endcase
endfunction
function automatic [4:0] glyph_S(input [2:0] r);
    case (r)
        3'd0: glyph_S = 5'b01110; 3'd1: glyph_S = 5'b10001; 3'd2: glyph_S = 5'b10000;
        3'd3: glyph_S = 5'b01110; 3'd4: glyph_S = 5'b00001; 3'd5: glyph_S = 5'b10001;
        default: glyph_S = 5'b01110;
    endcase
endfunction
localparam [9:0]  V_ACT = 10'd720,  V_SYNC = 10'd6;         // VSync at top (vy 0..5)
localparam [9:0]  V_SAFETY = 10'd800;                       // safety wrap if a SOF is missed (>786)
localparam [10:0] PIC_X0 = 11'(H_PIC_OFFSET);
localparam [10:0] PIC_X1 = 11'(H_PIC_OFFSET + 3*SRC_COLS);  // 3x horizontal
localparam [9:0]  V_TOP  = 10'(V_PIC_TOP);
localparam [9:0]  V_BOT  = 10'(V_PIC_TOP) + V_ACT;

// ───────────────────────────────────────────────────────────────────────────────
// Source capture (clk_core): write the Atari active line into the ring.
// ───────────────────────────────────────────────────────────────────────────────
reg        de_d, sof_d;
wire       de_fall  = de_d  & ~de_in;
wire       sof_rise = sof_in & ~sof_d;

reg [8:0]  wcol;
reg [9:0]  acol;     // active-pixel index within the line (counts skipped pixels too)
reg [7:0]  wrow;
wire [11:0] waddr = {wrow[2:0], wcol};   // 8 slots x 512 cols
reg        we;
reg [7:0]  wdata;

// SIO indicator decode (combinational, from the registered wcol/wrow + synced flags).
wire [8:0] dbx = wcol - DBLK_X0;            // 0..6 within "D" block (valid when d_box)
wire [8:0] sbx = wcol - SBLK_X0;            // 0..6 within "S" block
wire [7:0] gby = wrow - SIO_Y0;             // 0..8 within the shared band
wire [2:0] grow = gby[2:0] - 3'd1;          // glyph row 0..6 (valid when gby in 1..7)
wire       d_box = sio_act_core && (wrow >= SIO_Y0) && (wrow <= SIO_Y1) && (wcol >= DBLK_X0) && (wcol <= DBLK_X1);
wire       s_box = sio_cmd_core && (wrow >= SIO_Y0) && (wrow <= SIO_Y1) && (wcol >= SBLK_X0) && (wcol <= SBLK_X1);
wire       in_gy = (gby >= 8'd1) && (gby <= 8'd7);
wire [4:0] drow_bits = glyph_D(grow);
wire [4:0] srow_bits = glyph_S(grow);
wire       d_ink = in_gy && (dbx >= 9'd1) && (dbx <= 9'd5) && drow_bits[3'd5 - dbx[2:0]];
wire       s_ink = in_gy && (sbx >= 9'd1) && (sbx <= 9'd5) && srow_bits[3'd5 - sbx[2:0]];

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        de_d <= 1'b0; sof_d <= 1'b0; wcol <= 9'd0; acol <= 10'd0; wrow <= 8'd0; we <= 1'b0; wdata <= 8'd0;
    end else begin
        de_d <= de_in; sof_d <= sof_in;
        we   <= 1'b0;
        if (sof_rise) begin
            wrow <= 8'd0; wcol <= 9'd0; acol <= 10'd0;
        end else if (de_fall) begin
            if (wrow != SRC_LINES-1) wrow <= wrow + 8'd1;
            wcol <= 9'd0; acol <= 10'd0;
        end else if (pixce && de_in) begin
            // skip the first h_off_core active pixels, then capture SRC_COLS columns
            if ((acol >= {2'b0, h_off_core}) && (wcol < SRC_COLS)) begin
                // Capture-side SIO indicator: inside the "D"/"S" block draw the glyph (ink)
                // over the block colour while its activity flag is set; else the real pixel.
                if (d_box)      wdata <= d_ink ? SIO_COL_INK : SIO_COL_DATA;
                else if (s_box) wdata <= s_ink ? SIO_COL_INK : SIO_COL_CMD;
                else            wdata <= colour_in;
                we    <= 1'b1;
                wcol  <= wcol + 9'd1;
            end
            acol <= acol + 10'd1;
        end
    end
end

// ── CDC: Atari start-of-field -> clk_pix single pulse (toggle/edge, per fb_reader) ──
reg sof_tog = 1'b0;
always_ff @(posedge clk_core) if (sof_rise) sof_tog <= ~sof_tog;
reg [2:0] sof_sync;
always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) sof_sync <= 3'd0;
    else        sof_sync <= {sof_sync[1:0], sof_tog};
end
wire sof_pix = sof_sync[2] ^ sof_sync[1];

// ───────────────────────────────────────────────────────────────────────────────
// Read raster (clk_pix): hx free-runs; vy is reset by the Atari SOF (genlock).
// ───────────────────────────────────────────────────────────────────────────────
// hx free-runs (stable hsync). vy resets to 0 the instant SOF is detected — NOT rounded
// to a line boundary. Rounding to the next boundary added a variable 0..1-line latency
// from the Atari frame start; when SOF drifted near a boundary that latency dithered ±1
// line, shifting the whole picture's read-vs-write alignment (the rapid 1-line jitter).
// Immediate reset gives a constant SOF->vy=0 latency (just the CDC) so the content is
// stable. The vsync then begins mid-line in vblank, which HDMI sinks tolerate.
reg [10:0] hx;
reg [9:0]  vy;
always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin hx <= 11'd0; vy <= 10'd0; end
    else begin
        hx <= (hx == H_TOT - 11'd1) ? 11'd0 : hx + 11'd1;
        if (sof_pix)                       vy <= 10'd0;            // genlock (immediate)
        else if (hx == H_TOT - 11'd1) begin
            if (vy >= V_SAFETY)            vy <= 10'd0;            // safety: dropped SOF
            else                           vy <= vy + 10'd1;
        end
    end
end

wire in_hact = (hx < H_ACT);
wire in_vact = (vy >= V_TOP) && (vy < V_BOT);
wire in_pic  = (hx >= PIC_X0) && (hx < PIC_X1) && in_vact;

// 3x downscale of output position -> source col/line. Divide-by-3 via reciprocal multiply
// (x/3 = floor(x*21846/65536)). The ×21846 constant multiply is a LUT adder tree; at the
// 57.375 MHz pixel clock it is the critical path, so REGISTER its result (src_col/src_row)
// to give the adder tree a full cycle. The output pipeline below gains one matching stage.
wire [10:0] pic_x   = hx - PIC_X0;             // 0..1055 within picture
wire [26:0] mul_h   = pic_x * 16'd21846;
wire [9:0]  vy_rel  = vy - V_TOP;
wire [25:0] mul_v   = vy_rel * 16'd21846;
reg  [8:0]  src_col;                           // /3 -> 0..351 (registered)
reg  [7:0]  src_row;                           // /3 -> 0..239 (registered)
always_ff @(posedge clk_pix) begin
    src_col <= mul_h[24:16];
    src_row <= mul_v[23:16];
end
wire [11:0] raddr   = {src_row[2:0], src_col}; // 8-line ring

// OSD coords: 256-col window centred in 352 src (col 48..303), like fb_reader.
reg [7:0] osd_x_r;
always_ff @(posedge clk_pix) begin
    if      (src_col < 9'd48)   osd_x_r <= 8'd0;
    else if (src_col >= 9'd304) osd_x_r <= 8'd255;
    else                        osd_x_r <= src_col[7:0] - 8'd48;
end
assign osd_x = osd_x_r;
assign osd_y = src_row;

// ── ring buffer (clk_core write / clk_pix read), 8-bit colour code ──
reg [7:0] linebuf [0:RING_LINES*512-1];
always_ff @(posedge clk_core) if (we) linebuf[waddr] <= wdata;
reg [7:0] code_q;
always_ff @(posedge clk_pix) code_q <= linebuf[raddr];   // 1-cycle registered read

// Altirra palette applied on readout (instantiated VHDL LUT, NTSC).
wire [7:0] pr, pg, pb;
gtia_palette palrom (
    .ATARI_COLOUR (code_q),
    .PAL          (1'b0),
    .R_next       (pr),
    .G_next       (pg),
    .B_next       (pb)
);

// Scanlines: v_rep = which of the 3 output lines within this source line (0,1,2), tracked as
// a registered per-line counter — NOT derived from src_row, which would chain a 2nd multiply
// onto clk_pix (dropped the worst-path slack to 0.2ns). Held at 0 before the active region so
// v_rep = (vy - V_TOP) mod 3 during the picture. Dim the bottom line (v_rep==2).
reg [1:0] v_rep;
always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n)              v_rep <= 2'd0;
    else if (sof_pix)        v_rep <= 2'd0;
    else if (hx == H_TOT - 11'd1) begin
        if (vy < V_TOP)         v_rep <= 2'd0;
        else if (v_rep == 2'd2) v_rep <= 2'd0;
        else                    v_rep <= v_rep + 2'd1;
    end
end
wire dim_s0 = (scanline_level != 2'd0) && (v_rep == 2'd2);

// Scanline attenuation of the dim line: 25% = c>>2, 50% = c>>1, 75% = c - c>>2.
function [7:0] atten(input [7:0] c);
    case (scanline_level)
        2'd1:    atten = {2'b00, c[7:2]};        // 25%
        2'd3:    atten = c - {2'b00, c[7:2]};    // 75%
        default: atten = {1'b0,  c[7:1]};        // 50%
    endcase
endfunction
wire [7:0] pr_dim = atten(pr);
wire [7:0] pg_dim = atten(pg);
wire [7:0] pb_dim = atten(pb);

// ── Output pipeline: src_col/row registered(T+1) -> raddr -> code_q(T+2) -> r_out(T+3),
// so sync/de/pic/dim need THREE register stages (s1, s2, output) to align with the pixel. ──
wire hs_lvl = (hx >= H_SYNC_S) && (hx < H_SYNC_E);
wire vs_lvl = (vy < V_SYNC);
wire de_s0  = in_hact && in_vact;
reg de_s1, hs_s1, vs_s1, pic_s1, dim_s1;
reg de_s2, hs_s2, vs_s2, pic_s2, dim_s2;
always_ff @(posedge clk_pix) begin
    de_s1 <= de_s0;  hs_s1 <= hs_lvl;  vs_s1 <= vs_lvl;  pic_s1 <= in_pic;  dim_s1 <= dim_s0;
    de_s2 <= de_s1;  hs_s2 <= hs_s1;   vs_s2 <= vs_s1;   pic_s2 <= pic_s1;  dim_s2 <= dim_s1;
end

always_ff @(posedge clk_pix) begin
    de_out <= de_s2;
    hs_out <= SYNC_ACTIVE_LOW ? ~hs_s2 : hs_s2;
    vs_out <= SYNC_ACTIVE_LOW ? ~vs_s2 : vs_s2;
    if (de_s2 && pic_s2) begin
        r_out <= dim_s2 ? pr_dim : pr;   // scanline attenuation (off/25/50/75%)
        g_out <= dim_s2 ? pg_dim : pg;
        b_out <= dim_s2 ? pb_dim : pb;
    end else begin
        r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;   // pillarbox / blanking
    end
end

endmodule

`default_nettype wire
