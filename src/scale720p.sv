// scale720p.sv — Atari video → 256×240 frame buffer → 720p HDMI output
//
// Write side (clk_core = 27 MHz):
//   Writes one pixel per VIDEO_PIXCE (colour_clock_2x) pulse during de_in=1.
//   Column wraps at 255; ~350 pulses/line so the last few clamp harmlessly on col 255.
//
// Read side (clk_pixel = 74.25 MHz):
//   Fixed 1280×720@60 Hz raster (CEA-861 VIC 4).
//   5× horizontal: 256×5=1280 px fills H_ACTIVE exactly.
//   3× vertical:   240×3=720 px fills V_ACTIVE exactly.
//   With pixce ÷2, ~188 columns carry actual content; columns 188-255 are black.
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

// ── Frame buffer BRAM: 256×256×8-bit RGB332 ───────────────────────────────────
reg [7:0] fbuf [0:65535];

// BRAM Port A: write-only on clk_core (registered to prevent write glitches)
reg  [15:0] mem_portA_addr;
reg  [7:0]  mem_portA_wdata;
reg         mem_portA_we;

always_ff @(posedge clk_core) begin
    if (mem_portA_we) begin
        fbuf[mem_portA_addr] <= mem_portA_wdata;
    end
end

// BRAM Port B: read-only on clk_pixel
wire  [15:0] mem_portB_addr;
reg   [7:0]  mem_portB_rdata;

always_ff @(posedge clk_pixel) begin
    mem_portB_rdata <= fbuf[mem_portB_addr];
end

// ── Write side (clk_core, 27 MHz) ─────────────────────────────────────────────
// pixce (VIDEO_PIXCE) fires at 2× colour-clock rate.  Divide by 2 so we capture
// one sample per colour clock — ~188 unique pixels/line fit within 256 columns.
reg [7:0] wr_col;
reg [8:0] wr_row;
reg       wr_de_r, wr_vs_r;
reg       pixce_phase;

wire wr_de_fall = wr_de_r && !de_in;
wire wr_vs_rise = vs_in && !wr_vs_r;
wire pixce_1x   = pixce && pixce_phase;   // every other PIXCE pulse

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        wr_col <= 8'd0; wr_row <= 9'd0;
        wr_de_r <= 1'b0; wr_vs_r <= 1'b0;
        pixce_phase <= 1'b0;
    end else begin
        wr_de_r <= de_in;
        wr_vs_r <= vs_in;
        if (pixce) pixce_phase <= ~pixce_phase;

        if (wr_vs_rise)
            wr_row <= 9'd0;
        else if (wr_de_fall)
            wr_row <= wr_row + 9'd1;

        if (!de_in)
            wr_col <= 8'd0;
        else if (pixce_1x) begin
            if (wr_col != 8'd255)
                wr_col <= wr_col + 8'd1;
        end
    end
end

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        mem_portA_addr  <= 16'd0;
        mem_portA_wdata <= 8'd0;
        mem_portA_we    <= 1'b0;
    end else begin
        mem_portA_addr  <= {wr_row[7:0], wr_col};
        mem_portA_wdata <= {r_in[7:5], g_in[7:5], b_in[7:6]};
        mem_portA_we    <= de_in && pixce_1x && (wr_row < 9'd240);
    end
end

// ── Read side (clk_pixel, 74.25 MHz) ──────────────────────────────────────────
reg [10:0] hx;
reg [9:0]  vy;

// Division-free coordinates fb_x (hx / 5) and fb_y (vy / 3)
reg [7:0]  fb_x;
reg [7:0]  fb_y;
reg [2:0]  x_cnt; // 0..4 counter for horizontal 5x scaling
reg [1:0]  y_cnt; // 0..2 counter for vertical 3x scaling

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        hx    <= 11'd0;
        vy    <= 10'd0;
        fb_x  <= 8'd0;
        x_cnt <= 3'd0;
        fb_y  <= 8'd0;
        y_cnt <= 2'd0;
    end else begin
        // Horizontal counter and fb_x
        if (hx == H_TOTAL - 11'd1) begin
            hx    <= 11'd0;
            fb_x  <= 8'd0;
            x_cnt <= 3'd0;
            // Vertical counter and fb_y
            if (vy == V_TOTAL - 10'd1) begin
                vy    <= 10'd0;
                fb_y  <= 8'd0;
                y_cnt <= 2'd0;
            end else begin
                vy <= vy + 10'd1;
                if (vy < V_ACTIVE - 10'd1) begin
                    if (y_cnt == 2'd2) begin
                        y_cnt <= 2'd0;
                        fb_y  <= fb_y + 8'd1;
                    end else begin
                        y_cnt <= y_cnt + 2'd1;
                    end
                end else begin
                    fb_y  <= 8'd0;
                    y_cnt <= 2'd0;
                end
            end
        end else begin
            hx <= hx + 11'd1;
            if (hx < H_ACTIVE - 11'd1) begin
                if (x_cnt == 3'd4) begin
                    x_cnt <= 3'd0;
                    fb_x  <= fb_x + 8'd1;
                end else begin
                    x_cnt <= x_cnt + 3'd1;
                end
            end else begin
                fb_x  <= 8'd0;
                x_cnt <= 3'd0;
            end
        end
    end
end

// ── Stage 0: direct coordinate computation (combinatorial from hx/vy) ─────────
assign osd_x = fb_x;
assign osd_y = fb_y;

wire de_s0 = (hx < H_ACTIVE) && (vy < V_ACTIVE);
wire hs_s0 = (hx >= H_ACTIVE + H_FP) && (hx < H_ACTIVE + H_FP + H_SYNC);
wire vs_s0 = (vy >= V_ACTIVE + V_FP) && (vy < V_ACTIVE + V_FP + V_SYNC);

// ── Stage 1: BRAM read — addr and control signals registered together ──────────
assign mem_portB_addr = {fb_y, fb_x};
reg         de_p1, hs_p1, vs_p1;

always_ff @(posedge clk_pixel) begin
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
            r_out <= {mem_portB_rdata[7:5], mem_portB_rdata[7:5], mem_portB_rdata[7:6]};
            g_out <= {mem_portB_rdata[4:2], mem_portB_rdata[4:2], mem_portB_rdata[4:3]};
            b_out <= {mem_portB_rdata[1:0], mem_portB_rdata[1:0], mem_portB_rdata[1:0], mem_portB_rdata[1:0]};
        end else begin
            r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
        end
    end
end

endmodule
`default_nettype wire
