// scandoubler_480p — Phase A of the low-latency line-buffer plan
// (docs/mcu_offload_and_linebuffer_spec.md, §VIDEO).
//
// Replaces the SDRAM frame buffer (fb_writer + fb_reader) with a genlocked
// scandoubler: the Atari video is captured into a small 4-line BSRAM ring (clk_core)
// and read out as a standard 480p59.94 raster (clk_pix = 27 MHz) with an exact 2x2
// upscale + pillarbox. Latency is ~1-2 scanlines instead of ~1 frame, and no SDRAM
// is touched. The picture stores the raw 8-bit GTIA colour code (core generic
// palette=0 -> code on VIDEO_B) and the Altirra palette LUT (gtia_palette) is applied
// on READOUT — tiny buffer, full colour fidelity.
//
// Genlock: the 480p read raster free-runs (so HDMI timing is always standard) but its
// vertical counter is SNAPPED to top-of-frame on each Atari VIDEO_START_OF_FIELD (CDC
// to clk_pix). Atari 59.92 Hz vs 480p nominal 59.94 differ ~0.03% -> the snap is a
// sub-line nudge in vblank. The 4-line ring absorbs the read/write skew.
//
// Output interface matches fb_reader (r/g/b/hs/vs/de + osd_x/osd_y) so the downstream
// OSD-mix + hdmi_audio_out path is unchanged (set hdmi VIDEO_ID_CODE=2).
//
// HARDWARE-TUNABLE (verify on silicon — see spec §VIDEO "Verify"):
//   - VSNAP        : genlock snap line (vertical picture position / read-vs-write lead)
//   - H_PIC_OFFSET : horizontal picture centring in the pillarbox
//   - SYNC_ACTIVE_LOW : 480p is negative sync per CEA; flip if a display disagrees.

`default_nettype none
`timescale 1ns/1ps

module scandoubler_480p #(
    parameter integer SRC_COLS   = 352,   // Atari active pixels captured per line
    parameter integer SRC_LINES  = 240,   // Atari active lines captured per field
    parameter integer H_PIC_OFFSET = 8,   // left pillarbox: (720 - 2*352)/2 = 8
    parameter integer VSNAP      = 510,    // read vy snapped here on Atari start-of-field
    // CEA 480p is negative sync, BUT hdmi_audio_out's frame-reset logic detects vs/de
    // active-HIGH (as the proven 720p path does). Default active-high so that reset
    // alignment works; if a strict display rejects positive-polarity 480p, set this 1
    // AND invert hs/vs on the path to hdmi.sv (not the reset path). See spec §VIDEO.
    parameter bit     SYNC_ACTIVE_LOW = 1'b0
)(
    // Atari source (clk_core)
    input  wire        clk_core,
    input  wire        rst_n,
    input  wire [7:0]  colour_in,   // GTIA colour code (VIDEO_B when palette=0)
    input  wire        de_in,       // active video (= ~VIDEO_BLANK)
    input  wire        sof_in,      // VIDEO_START_OF_FIELD (1-pixce-wide-ish frame marker)
    input  wire        pixce,       // VIDEO_PIXCE pixel strobe

    // HDMI (clk_pix = 27 MHz)
    input  wire        clk_pix,
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out,
    output wire [7:0]  osd_x,
    output wire [7:0]  osd_y
);

// ── 480p59.94 timing, matched to hdmi.sv VIDEO_ID_CODE=2 (858x525, active 720x480) ──
// cx/cy origin (0,0) = first active pixel (hdmi_audio_out pulses reset there).
localparam [10:0] H_ACT = 11'd720,  H_TOT = 11'd858;
localparam [10:0] H_SYNC_S = 11'd736, H_SYNC_E = 11'd798;   // HFP=16, HSync=62
localparam [9:0]  V_ACT = 10'd480,  V_TOT = 10'd525;
localparam [9:0]  V_SYNC_S = 10'd489, V_SYNC_E = 10'd495;   // VFP=9, VSync=6
// Picture window (704 wide centred): cols H_PIC_OFFSET .. H_PIC_OFFSET+2*SRC_COLS
localparam [10:0] PIC_X0 = 11'(H_PIC_OFFSET);
localparam [10:0] PIC_X1 = 11'(H_PIC_OFFSET + 2*SRC_COLS);
localparam [9:0]  VSNAP_L = 10'(VSNAP);

// ───────────────────────────────────────────────────────────────────────────────
// Source capture (clk_core): write the Atari active line into a 4-line ring.
// ───────────────────────────────────────────────────────────────────────────────
reg        de_d;
wire       de_fall = de_d & ~de_in;
reg        sof_d;
wire       sof_rise = sof_in & ~sof_d;

reg [8:0]  wcol;     // 0..SRC_COLS-1 column within the line
reg [7:0]  wrow;     // 0..SRC_LINES-1 source line
wire [10:0] waddr = {wrow[1:0], wcol};   // 4-line ring: slot = wrow[1:0]
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

// ── CDC: Atari start-of-field -> clk_pix as a single pulse (toggle/edge, per fb_reader) ──
reg sof_tog = 1'b0;
always_ff @(posedge clk_core) if (sof_rise) sof_tog <= ~sof_tog;
reg [2:0] sof_sync;
always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) sof_sync <= 3'd0;
    else        sof_sync <= {sof_sync[1:0], sof_tog};
end
wire sof_pix = sof_sync[2] ^ sof_sync[1];

// ───────────────────────────────────────────────────────────────────────────────
// Read raster (clk_pix): free-running 480p, genlock-snapped each Atari field.
// ───────────────────────────────────────────────────────────────────────────────
reg [10:0] hx;
reg [9:0]  vy;
always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin hx <= 11'd0; vy <= 10'd0; end
    else if (hx == H_TOT - 11'd1) begin
        hx <= 11'd0;
        // Snap the field at line end nearest the Atari SOF; else advance/wrap.
        if (sof_pix)                 vy <= VSNAP_L;
        else if (vy == V_TOT-10'd1)  vy <= 10'd0;
        else                         vy <= vy + 10'd1;
    end else hx <= hx + 11'd1;
end

wire in_hact = (hx < H_ACT);
wire in_vact = (vy < V_ACT);
wire in_pic  = (hx >= PIC_X0) && (hx < PIC_X1) && in_vact;

// 2x downscale of output position -> source col/line
wire [10:0] pic_x   = hx - PIC_X0;             // 0..703 within picture
wire [8:0]  src_col = pic_x[9:1];              // /2  -> 0..351
wire [7:0]  src_row = vy[8:1];                 // /2  -> 0..239
wire [10:0] raddr   = {src_row[1:0], src_col}; // 4-line ring

// OSD coords: 256-col window centred in 352 src (col 48..303), like fb_reader.
reg [7:0] osd_x_r;
always_ff @(posedge clk_pix) begin
    if      (src_col < 9'd48)   osd_x_r <= 8'd0;
    else if (src_col >= 9'd304) osd_x_r <= 8'd255;
    else                        osd_x_r <= src_col[7:0] - 8'd48;
end
assign osd_x = osd_x_r;
assign osd_y = src_row;

// ── 4-line dual-clock ring (clk_core write / clk_pix read), 8-bit colour code ──
reg [7:0] linebuf [0:4*512-1];   // 4 slots x 512 cols (>=352)
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

// ── Output pipeline: data path is raddr(T) -> code_q(T+1) -> r_out(T+2), so the
// sync/de/pic signals need exactly 2 register stages (one s1 flop + the output reg)
// to land with the matching pixel.
wire hs_lvl = (hx >= H_SYNC_S) && (hx < H_SYNC_E);
wire vs_lvl = (vy >= V_SYNC_S) && (vy < V_SYNC_E);
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
