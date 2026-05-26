// scale720p.sv — Atari video → 256×240 frame buffer → 720p HDMI output
//
// Write side (clk_core = 27 MHz):
//   Writes one pixel per VIDEO_PIXCE (colour_clock_2x) pulse during de_in=1.
//   Column wraps at 255; ~350 pulses/line so the last few clamp harmlessly on col 255.
//   256 columns × 5× = 1280 = exact integer fill of H_ACTIVE.
//
// Read side (clk_pixel = 74.25 MHz):
//   Fixed 1280×720@60 Hz raster (CEA-861 VIC 4).
//   fb_x = hx/5, fb_y = vy/3  — computed directly, no incremental counters.
//   All signals (DE, HS, VS, pixel data) share identical 2-cycle pipeline latency.

`default_nettype none
`timescale 1ns/1ps

module scale720p (
    // Atari core domain
    input  wire        clk_core,
    input  wire        rst_n,
    input  wire [7:0]  r_in, g_in, b_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire        pixce,

    // HDMI domain
    input  wire        clk_pixel,   // 74.25 MHz
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out,

    // OSD coordinates
    output wire [7:0]  osd_x,
    output wire [7:0]  osd_y
);

// ── 720p timing (CEA-861 VIC 4) ───────────────────────────────────────────────
localparam H_ACTIVE = 11'd1280;
localparam H_FP     = 11'd110;
localparam H_SYNC   = 11'd40;
localparam H_BP     = 11'd220;
localparam H_TOTAL  = 11'd1650;

localparam V_ACTIVE = 10'd720;
localparam V_FP     = 10'd5;
localparam V_SYNC   = 10'd5;
localparam V_BP     = 10'd20;
localparam V_TOTAL  = 10'd750;

// ── Frame buffer: 256×256×8-bit RGB332 ────────────────────────────────────────
(* syn_ramstyle="block_ram" *) reg [7:0] fbuf [0:65535];

// ── Write side (clk_core, 27 MHz) ─────────────────────────────────────────────
reg [7:0] wr_col, wr_row;
reg       wr_de_r, wr_vs_r;

wire wr_de_fall = wr_de_r && !de_in;
wire wr_vs_rise = vs_in && !wr_vs_r;

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        wr_col <= 8'd0; wr_row <= 8'd0;
        wr_de_r <= 1'b0; wr_vs_r <= 1'b0;
    end else begin
        wr_de_r <= de_in;
        wr_vs_r <= vs_in;

        if (wr_vs_rise)
            wr_row <= 8'd0;
        else if (wr_de_fall)
            wr_row <= wr_row + 8'd1;

        if (!de_in)
            wr_col <= 8'd0;
        else if (pixce) begin
            fbuf[{wr_row, wr_col}] <= {r_in[7:5], g_in[7:5], b_in[7:6]};
            if (wr_col != 8'd255)
                wr_col <= wr_col + 8'd1;
        end
    end
end

// ── Read side (clk_pixel, 74.25 MHz) ──────────────────────────────────────────
reg [10:0] hx;
reg [9:0]  vy;

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        hx <= 11'd0; vy <= 10'd0;
    end else if (hx == H_TOTAL - 11'd1) begin
        hx <= 11'd0;
        vy <= (vy == V_TOTAL - 10'd1) ? 10'd0 : vy + 10'd1;
    end else begin
        hx <= hx + 11'd1;
    end
end

// ── Stage 0: direct coordinate computation (combinatorial from hx/vy) ─────────
wire [7:0] fb_x = hx / 5;   // 0..255 (hx 0..1279 during active)
wire [7:0] fb_y = vy / 3;   // 0..239 (vy 0..719 during active)

assign osd_x = fb_x;
assign osd_y = fb_y;

wire de_s0 = (hx < H_ACTIVE) && (vy < V_ACTIVE);
wire hs_s0 = (hx >= H_ACTIVE + H_FP) && (hx < H_ACTIVE + H_FP + H_SYNC);
wire vs_s0 = (vy >= V_ACTIVE + V_FP) && (vy < V_ACTIVE + V_FP + V_SYNC);

// ── Stage 1: BRAM read — addr and control signals registered together ──────────
wire [15:0] rd_addr = {fb_y, fb_x};
reg [7:0]   rd_data;
reg         de_p1, hs_p1, vs_p1;

always_ff @(posedge clk_pixel) begin
    rd_data <= fbuf[rd_addr];
    de_p1   <= de_s0;
    hs_p1   <= hs_s0;
    vs_p1   <= vs_s0;
end

// ── Stage 2: RGB332 expansion + output ────────────────────────────────────────
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
        hs_out <= 1'b0; vs_out <= 1'b0; de_out <= 1'b0;
    end else begin
        hs_out <= hs_p1;
        vs_out <= vs_p1;
        de_out <= de_p1;
        if (de_p1) begin
            r_out <= {rd_data[7:5], rd_data[7:5], rd_data[7:6]};
            g_out <= {rd_data[4:2], rd_data[4:2], rd_data[4:3]};
            b_out <= {rd_data[1:0], rd_data[1:0], rd_data[1:0], rd_data[1:0]};
        end else begin
            r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
        end
    end
end

endmodule
`default_nettype wire
