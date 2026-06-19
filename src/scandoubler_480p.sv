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
    parameter integer V_PIC_TOP   = 33,    // first active output line ((786-720)/2; tune on HW)
    parameter bit     SYNC_ACTIVE_LOW = 1'b0
)(
    // Atari source (clk_core)
    input  wire        clk_core,
    input  wire        rst_n,
    input  wire [7:0]  colour_in,   // GTIA colour code (VIDEO_B when palette=0)
    input  wire        de_in,       // active video (= ~VIDEO_BLANK)
    input  wire        sof_in,      // VIDEO_START_OF_FIELD
    input  wire        pixce,       // VIDEO_PIXCE pixel strobe

    // HDMI (clk_pix = 57.375 MHz = 2*clk_core; 720-line mode)
    input  wire        clk_pix,
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
localparam [10:0] H_ACT = 11'd1056, H_TOT = 11'd1216;      // HBP = 1216-1056-16-80 = 64
localparam [10:0] H_SYNC_S = 11'd1072, H_SYNC_E = 11'd1152;// HFP=16, HSync=80
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
reg [7:0]  wrow;
wire [11:0] waddr = {wrow[2:0], wcol};   // 8 slots x 512 cols
reg        we;
reg [7:0]  wdata;

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        de_d <= 1'b0; sof_d <= 1'b0; wcol <= 9'd0; wrow <= 8'd0; we <= 1'b0; wdata <= 8'd0;
    end else begin
        de_d <= de_in; sof_d <= sof_in;
        we   <= 1'b0;
        if (sof_rise) begin
            wrow <= 8'd0; wcol <= 9'd0;
        end else if (de_fall) begin
            if (wrow != SRC_LINES-1) wrow <= wrow + 8'd1;
            wcol <= 9'd0;
        end else if (pixce && de_in) begin
            if (wcol < SRC_COLS) begin
                wdata <= colour_in;
                we    <= 1'b1;
                wcol  <= wcol + 9'd1;
            end
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
// (x/3 = floor(x*21846/65536)) keeps src_col/src_row clean combinational functions of hx/vy
// (no counter/pipeline alignment headaches), exactly as the /2 shift did at 480p.
wire [10:0] pic_x   = hx - PIC_X0;             // 0..1055 within picture
wire [26:0] mul_h   = pic_x * 16'd21846;
wire [8:0]  src_col = mul_h[24:16];            // /3 -> 0..351
wire [9:0]  vy_rel  = vy - V_TOP;
wire [25:0] mul_v   = vy_rel * 16'd21846;
wire [7:0]  src_row = mul_v[23:16];            // /3 -> 0..239
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

// ── Output pipeline: raddr(T) -> code_q(T+1) -> r_out(T+2); sync needs 2 stages too. ──
wire hs_lvl = (hx >= H_SYNC_S) && (hx < H_SYNC_E);
wire vs_lvl = (vy < V_SYNC);
wire de_s0  = in_hact && in_vact;
reg de_s1, hs_s1, vs_s1, pic_s1;
always_ff @(posedge clk_pix) begin
    de_s1 <= de_s0;  hs_s1 <= hs_lvl;  vs_s1 <= vs_lvl;  pic_s1 <= in_pic;
end

always_ff @(posedge clk_pix) begin
    de_out <= de_s1;
    hs_out <= SYNC_ACTIVE_LOW ? ~hs_s1 : hs_s1;
    vs_out <= SYNC_ACTIVE_LOW ? ~vs_s1 : vs_s1;
    if (de_s1 && pic_s1) begin
        r_out <= pr; g_out <= pg; b_out <= pb;
    end else begin
        r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;   // pillarbox / blanking
    end
end

endmodule

`default_nettype wire
