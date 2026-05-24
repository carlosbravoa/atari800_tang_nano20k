// scale720p.sv — Atari video → 256×240 frame buffer → 720p HDMI output
//
// Write side (clk_core = 27 MHz, Atari domain):
//   Captures active Atari pixels into a 256×256×8-bit frame buffer (RGB332).
//   pixce = VIDEO_PIXCE = colour_clock_2x enable (fires every 4 sys_clk).
//   First 256 pixels of each active line are stored.
//
// Read side (clk_pixel = 74.25 MHz, HDMI domain):
//   Generates 1280×720@60 Hz timing (CEA-861 Video ID Code 4).
//   Integer 5× H and 3× V scale maps 256×240 → 1280×720 (exact fill, no borders).
//
// Pipeline: 2 clk_pixel latency (BRAM read + RGB expansion) → de/hs/vs delayed
// to match, so outputs are always aligned.

`default_nettype none
`timescale 1ns/1ps

module scale720p (
    // Atari core domain
    input  wire        clk_core,
    input  wire        rst_n,
    input  wire [7:0]  r_in, g_in, b_in,
    input  wire        hs_in,       // GTIA HSYNC (active high)
    input  wire        vs_in,       // GTIA VSYNC (active high)
    input  wire        de_in,       // active-high display enable (~VIDEO_BLANK)
    input  wire        pixce,       // VIDEO_PIXCE = colour_clock_2x enable

    // HDMI domain
    input  wire        clk_pixel,   // 74.25 MHz
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out,

    // OSD coordinates output
    output wire [7:0]  osd_x,
    output wire [7:0]  osd_y
);

// ── 720p timing (CEA-861 VIC 4: 1280×720@60 Hz, 74.25 MHz pixel clock) ─────
localparam H_ACTIVE = 11'd1280;
localparam H_FP     = 11'd110;
localparam H_SYNC   = 11'd40;
localparam H_BP     = 11'd220;
localparam H_TOTAL  = 11'd1650;  // 1280+110+40+220

localparam V_ACTIVE = 10'd720;
localparam V_FP     = 10'd5;
localparam V_SYNC   = 10'd5;
localparam V_BP     = 10'd20;
localparam V_TOTAL  = 10'd750;   // 720+5+5+20

// ── Frame buffer: 256×256×8-bit (RGB332) ─────────────────────────────────────
// 5× H: 256 × 5 = 1280 = H_ACTIVE  (exact integer fill)
// 3× V: 240 × 3 = 720  = V_ACTIVE  (exact integer fill)
// Inference: 65536 × 8 = 524 Kbits → ~29 Gowin BSRAM blocks (42 free)
(* syn_ramstyle="block_ram" *) reg [7:0] fbuf [0:65535];

// ── Write side (clk_core, 27 MHz) ────────────────────────────────────────────
reg [7:0]  wr_col;
reg [7:0]  wr_row;
reg        wr_de_r, wr_vs_r;

wire wr_de_fall = wr_de_r && !de_in;   // end of active line → advance row
wire wr_vs_rise = vs_in  && !wr_vs_r;  // start of vsync → reset row

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        wr_col <= 8'd0; wr_row <= 8'd0;
        wr_de_r <= 1'b0; wr_vs_r <= 1'b0;
    end else begin
        wr_de_r <= de_in;
        wr_vs_r <= vs_in;

        if (wr_vs_rise) begin
            wr_row <= 8'd0;
        end else if (wr_de_fall) begin
            wr_row <= wr_row + 8'd1;
        end

        if (!de_in) begin
            wr_col <= 8'd0;
        end else if (pixce && wr_col != 8'd255) begin
            fbuf[{wr_row, wr_col}] <= {r_in[7:5], g_in[7:5], b_in[7:6]};
            wr_col <= wr_col + 8'd1;
        end else if (pixce && wr_col == 8'd255) begin
            // Last column: write but don't advance (column stays at 255)
            fbuf[{wr_row, wr_col}] <= {r_in[7:5], g_in[7:5], b_in[7:6]};
        end
    end
end

// ── Read side (clk_pixel, 74.25 MHz) ─────────────────────────────────────────
reg [10:0] hx;   // 0..1649
reg [9:0]  vy;   // 0..749

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

// ── Scale counters: integer 5× H, 3× V ───────────────────────────────────────
reg [2:0]  h_rep;    // 0..4 — which sub-pixel within each 5-wide group
reg [7:0]  fb_x;     // 0..255 — frame buffer column

reg [1:0]  v_rep;    // 0..2 — which sub-line within each 3-tall group
reg [7:0]  fb_y;     // 0..239 — frame buffer row

assign osd_x = fb_x;
assign osd_y = fb_y;

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        h_rep <= 3'd0; fb_x <= 8'd0;
        v_rep <= 2'd0; fb_y <= 8'd0;
    end else begin
        // Horizontal scale counter
        if (hx == H_TOTAL - 11'd1) begin
            h_rep <= 3'd0;
            fb_x  <= 8'd0;
        end else if (hx < H_ACTIVE) begin
            if (h_rep == 3'd4) begin
                h_rep <= 3'd0;
                fb_x  <= fb_x + 8'd1;
            end else begin
                h_rep <= h_rep + 3'd1;
            end
        end

        // Vertical scale counter (update at end of each line)
        if (hx == H_TOTAL - 11'd1) begin
            if (vy == V_TOTAL - 10'd1) begin
                v_rep <= 2'd0;
                fb_y  <= 8'd0;
            end else if (vy < V_ACTIVE) begin
                if (v_rep == 2'd2) begin
                    v_rep <= 2'd0;
                    fb_y  <= fb_y + 8'd1;
                end else begin
                    v_rep <= v_rep + 2'd1;
                end
            end
        end
    end
end

// ── Pipeline stage 1: BRAM read + sync latch ─────────────────────────────────
wire [15:0] rd_addr = {fb_y, fb_x};
reg [7:0]   rd_data;
reg         de_p1, hs_p1, vs_p1;

always_ff @(posedge clk_pixel) begin
    rd_data <= fbuf[rd_addr];
    de_p1   <= (hx < H_ACTIVE)                              && (vy < V_ACTIVE);
    hs_p1   <= (hx >= H_ACTIVE + H_FP)                     && (hx < H_ACTIVE + H_FP + H_SYNC);
    vs_p1   <= (vy >= V_ACTIVE + V_FP)                     && (vy < V_ACTIVE + V_FP + V_SYNC);
end

// ── Pipeline stage 2: RGB332 expansion + final output ────────────────────────
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
        hs_out <= 1'b0; vs_out <= 1'b0; de_out <= 1'b0;
    end else begin
        hs_out <= hs_p1;
        vs_out <= vs_p1;
        de_out <= de_p1;
        if (de_p1) begin
            // RGB332 → RGB888: replicate MSBs to fill
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
