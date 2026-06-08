// scale720p.sv — Atari video → 256-byte ping-pong line buffers → 720p HDMI output
//
// ============================================================================
// CRITICAL WARNING: DO NOT REVERT TO A FULL FRAME BUFFER!
// This module MUST use a ping-pong LINE buffer design (two 256-byte buffers).
// Reverting to a full frame buffer causes critical latency degradation, violates
// memory constraints, and breaks zero-latency hardware upscaling.
// 
// Design Architecture:
// 1. Port A (Write): Atari clk_core (27 MHz) domain, writes to the active write buffer.
// 2. Port B (Read): HDMI clk_pixel (74.25 MHz) domain, reads from the opposite buffer.
// 3. Collision Avoidance: We must NEVER read and write the same buffer simultaneously.
//    - Atari writes current line N into the active write buffer.
//    - HDMI reads the completed previous line N-1 from the opposite buffer.
//    - Write buffer swaps at the falling edge of de_in (end of Atari line).
//    - Read buffer swaps at the end of the 3-line repeat group (hx == H_TOTAL-1 && line_rep_cnt == 2).
//    - Introducing a 1-line vertical read delay (starts reading at vy >= 5) prevents overlap.
// 4. Genlock Alignment: Resets hx/vy read sequencers on the falling edge of the
//    synchronized VSync (vs_in_sync_fall) to vertically lock the HDMI raster to the core.
// ============================================================================

`default_nettype none
`timescale 1ns/1ps


module scale720p (
    // Atari core domain
    input  wire       clk_core,
    input  wire       rst_n,
    input  wire [7:0] r_in, g_in, b_in,
    input  wire       hs_in,
    input  wire       vs_in,
    input  wire       de_in,
    input  wire       pixce,

    // HDMI domain
    input  wire       clk_pixel,       // 74.25 MHz
    output reg  [7:0] r_out, g_out, b_out,
    output reg        hs_out, vs_out, de_out,

    // OSD coordinates
    output wire [7:0] osd_x,
    output wire [7:0] osd_y
);

// ── 720p timing (CEA-861 VIC 4) ───────────────────────────────────────────────
localparam H_ACTIVE = 11'd1280;
localparam H_FP     = 11'd110;
localparam H_SYNC   = 11'd40;
localparam H_BP     = 11'd242;
localparam H_TOTAL  = 11'd1672;

// Source-column read offset: slides the 352-col read window right over the (wider)
// captured Atari line to centre the active picture within the pillarbox (skips
// excess left overscan, reveals the cut-off right border). +N = picture moves left.
localparam [8:0] H_SRC_OFFSET = 9'd12;

localparam V_ACTIVE = 10'd720;
localparam V_FP     = 10'd5;
localparam V_SYNC   = 10'd5;
localparam V_BP     = 10'd20;
localparam V_TOTAL  = 10'd750;

// ── Write side (clk_core, 27 MHz) ─────────────────────────────────────────────
// pixce (VIDEO_PIXCE) fires at 2x colour-clock rate. Divide by 2 so we capture
// one sample per colour clock — ~188 unique pixels/line fit within 256 columns.
// ── Write side (clk_core, 27 MHz) ─────────────────────────────────────────────
// Sample on every pixce pulse to capture all 320 unique pixels.
reg [8:0] wr_col;
reg       wr_de_r, wr_vs_r;
reg [3:0] wr_buf_idx;       // 16-line FIFO (free BSRAM for the Stage-1 writer test)
reg       wr_line_toggle;

wire wr_de_fall = wr_de_r && !de_in;
wire wr_vs_rise = vs_in && !wr_vs_r;

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        wr_col         <= 9'd0;
        wr_de_r        <= 1'b0;
        wr_vs_r        <= 1'b0;
        wr_buf_idx     <= 4'd0;
        wr_line_toggle <= 1'b0;
    end else begin
        wr_de_r <= de_in;
        wr_vs_r <= vs_in;

        if (wr_vs_rise) begin
            wr_buf_idx     <= 4'd0;
            wr_line_toggle <= 1'b0;
        end else if (wr_de_fall) begin
            wr_buf_idx     <= (wr_buf_idx == 4'd15) ? 4'd0 : wr_buf_idx + 4'd1;
            wr_line_toggle <= ~wr_line_toggle;
        end

        if (!de_in) begin
            wr_col <= 9'd0;
        end else if (pixce) begin
            if (wr_col != 9'd511) wr_col <= wr_col + 9'd1;
        end
    end
end

// ── Clock domain crossing & synchronization ────────────────────────────────────
reg [2:0] vs_in_sync_reg;
reg [2:0] wr_line_toggle_sync_reg;

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        vs_in_sync_reg          <= 3'b111;
        wr_line_toggle_sync_reg <= 3'b000;
    end else begin
        vs_in_sync_reg          <= {vs_in_sync_reg[1:0], vs_in};
        wr_line_toggle_sync_reg <= {wr_line_toggle_sync_reg[1:0], wr_line_toggle};
    end
end

wire vs_in_sync_fall = (vs_in_sync_reg[2] && !vs_in_sync_reg[1]);
wire wr_line_edge    = wr_line_toggle_sync_reg[2] ^ wr_line_toggle_sync_reg[1];

// Genlock vertical sync pending flag (registers end-of-line alignment)
reg vs_pending;
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        vs_pending <= 1'b0;
    end else begin
        if (vs_in_sync_fall) begin
            vs_pending <= 1'b1;
        end else if (hx == H_TOTAL - 11'd1 && vs_pending) begin
            vs_pending <= 1'b0;
        end
    end
end

// Count of source lines the writer has completed this frame, in the read clock
// domain (advanced by the wr_line_toggle edge sync). This is the FIFO write pointer
// as seen by the reader; the reader's rd_line_count must never pass it (underflow).
reg [7:0] wr_line_count;
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        wr_line_count <= 8'd0;
    end else if (vs_in_sync_fall) begin
        wr_line_count <= 8'd0;               // reset at start of frame (genlock)
    end else if (wr_line_edge) begin
        wr_line_count <= wr_line_count + 8'd1;
    end
end

// ── Read side (clk_pixel, 74.25 MHz) ──────────────────────────────────────────
reg [10:0] hx;
reg [9:0]  vy;

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        hx <= 11'd0;
        vy <= 10'd0;
    end else if (hx == H_TOTAL - 11'd1) begin
        hx <= 11'd0;
        if (vs_pending) begin
            vy <= 10'd0;
        end else begin
            vy <= (vy == 10'd1023) ? 10'd0 : vy + 10'd1;
        end
    end else begin
        hx <= hx + 11'd1;
    end
end

// Repetition counters to avoid division logic
reg [1:0] line_rep_cnt;
reg [7:0] rd_row;
reg [7:0] rd_line_count;    // FIFO read pointer: source lines consumed since VSync

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        line_rep_cnt  <= 2'd0;
        rd_row        <= 8'd0;
        rd_line_count <= 8'd0;
    end else if (hx == H_TOTAL - 11'd1) begin
        if (vs_pending) begin
            line_rep_cnt  <= 2'd0;
            rd_row        <= 8'd0;
            rd_line_count <= 8'd0;
        end else if (vy >= 10'd51 && vy < 10'd771) begin
            line_rep_cnt <= (line_rep_cnt == 2'd2) ? 2'd0 : line_rep_cnt + 2'd1;
            if (line_rep_cnt == 2'd2) begin
                rd_row <= rd_row + 8'd1;
                // pop the next source line, but never overtake the writer (underflow clamp).
                // The 32-line FIFO depth absorbs the ~15-line read/write skew at exact speed.
                if (rd_line_count != wr_line_count)
                    rd_line_count <= rd_line_count + 8'd1;
            end
        end else begin
            line_rep_cnt <= 2'd0;
            rd_row       <= 8'd0;
        end
    end
end

wire [3:0] rd_buf_idx = rd_line_count[3:0];    // ring index into the 16-line FIFO

reg [1:0] pix_rep_cnt;
reg [8:0] rd_col;

always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin
        pix_rep_cnt <= 2'd0;
        rd_col      <= 9'd0;
    end else begin
        if (hx >= 11'd112 && hx < 11'd1168) begin
            if (pix_rep_cnt == 2'd2) begin
                pix_rep_cnt <= 2'd0;
                rd_col <= (rd_col == 9'd511) ? 9'd511 : rd_col + 9'd1;
            end else begin
                pix_rep_cnt <= pix_rep_cnt + 2'd1;
            end
        end else begin
            pix_rep_cnt <= 2'd0;
            rd_col      <= 9'd0;
        end
    end
end

// OSD coordinate output mapping
// Centered 256-column OSD inside the 352-column Atari frame (starts at BRAM column 48)
reg [7:0] osd_x_reg;
always_ff @(posedge clk_pixel) begin
    if (rd_col < 9'd48) begin
        osd_x_reg <= 8'd0;
    end else if (rd_col >= 9'd304) begin
        osd_x_reg <= 8'd255;
    end else begin
        osd_x_reg <= rd_col[7:0] - 8'd48;
    end
end
assign osd_x = osd_x_reg;
assign osd_y = rd_row;

// ── Inferred True Dual-Port Block RAM ──────────────────────────────────────────
wire [7:0] rd_data;

scale720p_tdp_ram #(
    .DATA_WIDTH(8),
.ADDR_WIDTH(13) // 32-line FIFO of 512 bytes each
) line_buffer (
    .clk_a (clk_core),
    .we_a  (de_in && pixce), // Sample every pixce pulse
    .addr_a({wr_buf_idx, wr_col}),
    .din_a ({r_in[7:5], g_in[7:5], b_in[7:6]}),
    .dout_a(), // Write-only on Port A

    .clk_b (clk_pixel),
    .we_b  (1'b0),
    .addr_b({rd_buf_idx, rd_col + H_SRC_OFFSET}),
    .din_b (8'd0),
    .dout_b(rd_data)
);

// ── Pipeline Latency Alignment (2 Cycles) ──────────────────────────────────────
// de_out spans the full standard 720p active (1280 wide, hx 0..1279) so the monitor
// sees a normal frame and fills/centres the panel. The 1056-px Atari content is
// pillarboxed centred at hx 112..1167 (cont_s0, same window the rd_col read uses),
// with black borders for the outer 112 px each side.
wire de_s0   = (hx < 11'd1280) && (vy >= 10'd51) && (vy < 10'd771);
wire cont_s0 = (hx >= 11'd112) && (hx < 11'd1168) && (vy >= 10'd51) && (vy < 10'd771);
wire hs_s0 = (hx >= H_ACTIVE + H_FP) && (hx < H_ACTIVE + H_FP + H_SYNC);
wire vs_s0 = (vy < 10'd5);

reg de_p1, hs_p1, vs_p1, cont_p1;
reg de_p2, hs_p2, vs_p2, cont_p2;

always_ff @(posedge clk_pixel) begin
    de_p1 <= de_s0;   hs_p1 <= hs_s0;   vs_p1 <= vs_s0;   cont_p1 <= cont_s0;
    de_p2 <= de_p1;   hs_p2 <= hs_p1;   vs_p2 <= vs_p1;   cont_p2 <= cont_p1;
end

always_comb begin
    hs_out = hs_p2;
    vs_out = vs_p2;
    de_out = de_p2;
    if (de_p2 && cont_p2) begin
        r_out = {rd_data[7:5], rd_data[7:5], rd_data[7:6]};
        g_out = {rd_data[4:2], rd_data[4:2], rd_data[4:3]};
        b_out = {rd_data[1:0], rd_data[1:0], rd_data[1:0], rd_data[1:0]};
    end else begin
        r_out = 8'd0;
        g_out = 8'd0;
        b_out = 8'd0;
    end
end

endmodule

// ── Inferred True Dual-Port Block RAM Module ───────────────────────────────────
module scale720p_tdp_ram #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 9
) (
    input  wire                  clk_a,
    input  wire                  we_a,
    input  wire [ADDR_WIDTH-1:0] addr_a,
    input  wire [DATA_WIDTH-1:0] din_a,
    output reg  [DATA_WIDTH-1:0] dout_a,

    input  wire                  clk_b,
    input  wire                  we_b,
    input  wire [ADDR_WIDTH-1:0] addr_b,
    input  wire [DATA_WIDTH-1:0] din_b,
    output reg  [DATA_WIDTH-1:0] dout_b
);
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] ram [0:(2**ADDR_WIDTH)-1];

    always_ff @(posedge clk_a) begin
        if (we_a) begin
            ram[addr_a] <= din_a;
        end
        dout_a <= ram[addr_a];
    end

    always_ff @(posedge clk_b) begin
        if (we_b) begin
            ram[addr_b] <= din_b;
        end
        dout_b <= ram[addr_b];
    end
endmodule

`default_nettype wire
