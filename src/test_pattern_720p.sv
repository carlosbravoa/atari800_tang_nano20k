// test_pattern_720p.sv — minimal 720p HDMI test pattern (color bars)
// Drives hdmi_audio_out directly; no frame buffer, no Atari core.
// Use to verify the HDMI clock/serialiser path before connecting Atari video.

`default_nettype none
`timescale 1ns/1ps

module test_pattern_720p (
    input  wire        clk_pixel,   // 74.25 MHz
    input  wire        rst_n,       // active-low (should be pll_locked & btn)
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out
);

// ── 720p timing ────────────────────────────────────────────────────────────
localparam H_ACTIVE = 11'd1280;
localparam H_FP     = 11'd110;
localparam H_SYNC   = 11'd40;
localparam H_TOTAL  = 11'd1650;
localparam V_ACTIVE = 10'd720;
localparam V_FP     = 10'd5;
localparam V_SYNC   = 10'd5;
localparam V_TOTAL  = 10'd750;

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

// ── Color bars (8 × 160-pixel columns) ─────────────────────────────────────
wire [2:0] col_bar = (hx < 11'd160)  ? 3'd0 :
                     (hx < 11'd320)  ? 3'd1 :
                     (hx < 11'd480)  ? 3'd2 :
                     (hx < 11'd640)  ? 3'd3 :
                     (hx < 11'd800)  ? 3'd4 :
                     (hx < 11'd960)  ? 3'd5 :
                     (hx < 11'd1120) ? 3'd6 : 3'd7;

// EBU colour bars: white / yellow / cyan / green / magenta / red / blue / black
reg [7:0] br, bg, bb;
always_comb begin
    case (col_bar)
        3'd0: begin br=8'hFF; bg=8'hFF; bb=8'hFF; end  // white
        3'd1: begin br=8'hFF; bg=8'hFF; bb=8'h00; end  // yellow
        3'd2: begin br=8'h00; bg=8'hFF; bb=8'hFF; end  // cyan
        3'd3: begin br=8'h00; bg=8'hFF; bb=8'h00; end  // green
        3'd4: begin br=8'hFF; bg=8'h00; bb=8'hFF; end  // magenta
        3'd5: begin br=8'hFF; bg=8'h00; bb=8'h00; end  // red
        3'd6: begin br=8'h00; bg=8'h00; bb=8'hFF; end  // blue
        3'd7: begin br=8'h00; bg=8'h00; bb=8'h00; end  // black
    endcase
end

// ── Single-cycle registered output ─────────────────────────────────────────
wire act = (hx < H_ACTIVE) && (vy < V_ACTIVE);

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        r_out <= 8'd0; g_out <= 8'd0; b_out <= 8'd0;
        hs_out <= 1'b0; vs_out <= 1'b0; de_out <= 1'b0;
    end else begin
        de_out <= act;
        hs_out <= (hx >= H_ACTIVE + H_FP) && (hx < H_ACTIVE + H_FP + H_SYNC);
        vs_out <= (vy >= V_ACTIVE + V_FP) && (vy < V_ACTIVE + V_FP + V_SYNC);
        r_out  <= act ? br : 8'd0;
        g_out  <= act ? bg : 8'd0;
        b_out  <= act ? bb : 8'd0;
    end
end

endmodule
`default_nettype wire
