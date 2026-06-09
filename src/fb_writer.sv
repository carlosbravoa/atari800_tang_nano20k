// fb_writer — Stage 1 of the frame-buffer plan (docs/frame_buffer_plan.md).
//
// Captures the Atari video stream (clk_core domain) and writes it as packed RGB332
// words into an SDRAM **double frame buffer**, acting as one write-only client of the
// SDRAM arbiter. Nothing reads the buffer yet (that is Stage 2); this stage exists to
// prove the 3rd SDRAM client coexists with the real-time Atari core without disturbing it.
//
// Pixel format matches the scaler line buffer: 8-bit {R[7:5],G[7:5],B[7:6]}. Four pixels
// pack into one 32-bit word (pixel0→byte0 … pixel3→byte3, left-to-right on read-back).
// Layout per buffer: LINES × WORDS_PER_LINE words, contiguous (stride = WORDS_PER_LINE);
// two buffers swap on Atari VSync. A small FIFO decouples pixel capture from SDRAM write
// timing (writes can be delayed a few cycles behind the higher-priority Atari core).

`default_nettype none
`timescale 1ns/1ps

module fb_writer #(
    parameter [24:0]  FB_BASE        = 25'h0060_0000,  // byte base of buffer 0 (well clear of Atari RAM/ROM)
    parameter integer WORDS_PER_LINE = 88,             // 352 px / 4 (actual data)
    parameter integer STRIDE         = 128,            // words/line incl. padding — power-of-2 so
                                                       // each line sits in one 256-col SDRAM row
                                                       // (reader BL8 bursts never cross a row)
    parameter integer LINES          = 240,
    parameter [24:0]  FB_SIZE        = 25'd84480       // bytes per buffer = 240*88*4
)(
    input  wire        clk_core,
    input  wire        rst_n,
    // Atari video (clk_core domain)
    input  wire [7:0]  r_in, g_in, b_in,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire        pixce,
    // SDRAM write client — fbw_req held (with stable addr/data) until fbw_ack pulses
    output wire        fbw_req,
    output wire [24:0] fbw_addr,
    output wire [31:0] fbw_wdata,
    input  wire        fbw_ack
);
    wire [7:0] pix = {r_in[7:5], g_in[7:5], b_in[7:6]};

    reg de_r, vs_r;
    wire de_fall = de_r & ~de_in;
    wire vs_rise = vs_in & ~vs_r;

    reg        buf_sel;        // double-buffer select (toggles per frame)
    reg [1:0]  px_in_word;     // 0..3 — pixel position within the 32-bit word
    reg [31:0] word_acc;       // packing accumulator
    reg [6:0]  col_word;       // 0..WORDS_PER_LINE-1 — word index within the line
    reg [14:0] line_base;      // word index of the current line start (row*WORDS_PER_LINE)
    reg [7:0]  row;            // current source row

    // The just-completed word (valid the cycle px_in_word==3 takes another pixce):
    wire        word_done = pixce && de_in && (px_in_word == 2'd3);
    wire [31:0] word_full = {pix, word_acc[31:8]};               // {p3,p2,p1,p0}
    wire [14:0] word_index = line_base + {8'd0, col_word};
    wire [24:0] word_addr  = FB_BASE + (buf_sel ? FB_SIZE : 25'd0) + ({10'd0, word_index} << 2);

    // ── small write FIFO (depth 4) of {addr[24:0], data[31:0]} ──────────────────
    // Explicit registers (NOT an array) so GowinSynthesis cannot infer a BSRAM block:
    // BSRAM is already 100% used by firmware/scaler, and a block-RAM read would also be
    // registered, breaking the combinational fbw_addr/data. (The ram_style attribute was
    // ignored by the tool, so we force registers structurally.)
    reg  [56:0] f0, f1, f2, f3;
    reg  [1:0]  fifo_wr, fifo_rd;
    reg  [2:0]  fifo_count;
    wire        fifo_full  = (fifo_count == 3'd4);
    wire        fifo_empty = (fifo_count == 3'd0);
    wire        push = word_done && !fifo_full;
    wire        pop  = fbw_ack  && !fifo_empty;

    wire [56:0] head = (fifo_rd == 2'd0) ? f0 :
                       (fifo_rd == 2'd1) ? f1 :
                       (fifo_rd == 2'd2) ? f2 : f3;
    assign fbw_req   = !fifo_empty;
    assign fbw_addr  = head[56:32];
    assign fbw_wdata = head[31:0];

    always_ff @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            de_r<=1'b0; vs_r<=1'b0; buf_sel<=1'b0;
            px_in_word<=2'd0; word_acc<=32'd0; col_word<=7'd0; line_base<=15'd0; row<=8'd0;
            fifo_wr<=2'd0; fifo_rd<=2'd0; fifo_count<=3'd0;
        end else begin
            de_r <= de_in; vs_r <= vs_in;

            // ── pixel capture / packing / addressing ──
            if (vs_rise) begin
                buf_sel    <= 1'b0;   // B4: single shared buffer (lowest latency, slow tear line)
                line_base  <= 15'd0;
                row        <= 8'd0;
                col_word   <= 7'd0;
                px_in_word <= 2'd0;
            end else if (de_fall) begin
                if (row < LINES-1) begin
                    line_base <= line_base + STRIDE[14:0];
                    row       <= row + 8'd1;
                end
                col_word   <= 7'd0;
                px_in_word <= 2'd0;
            end else if (pixce && de_in) begin
                word_acc <= {pix, word_acc[31:8]};
                if (px_in_word == 2'd3) begin
                    px_in_word <= 2'd0;
                    if (col_word < WORDS_PER_LINE-1) col_word <= col_word + 7'd1;
                end else begin
                    px_in_word <= px_in_word + 2'd1;
                end
            end

            // ── FIFO ──
            if (push) begin
                case (fifo_wr)
                    2'd0: f0 <= {word_addr, word_full};
                    2'd1: f1 <= {word_addr, word_full};
                    2'd2: f2 <= {word_addr, word_full};
                    2'd3: f3 <= {word_addr, word_full};
                endcase
                fifo_wr <= fifo_wr + 2'd1;
            end
            if (pop)  fifo_rd <= fifo_rd + 2'd1;
            fifo_count <= fifo_count + (push ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);
        end
    end
endmodule

`default_nettype wire
