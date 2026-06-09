// fb_reader — B4 of the frame-buffer plan (docs/sdram_cdc_plan.md, frame_buffer_plan.md).
//
// Free-running, standard 720p60 (CEA-861 VIC 4, 1650x750) raster that reads the Atari
// source frame from the SDRAM frame buffer (written by fb_writer) and 3x-upscales it with
// pillarbox. It is asynchronous to the Atari: no genlock. With a SINGLE shared SDRAM buffer
// the reader and writer race → a slow-moving tear line, traded for minimum latency (no
// double-buffer). Output interface matches the old scale720p (r/g/b/hs/vs/de + osd_x/osd_y) so the
// downstream HDMI/OSD path is unchanged.
//
// Two clock domains:
//  - clk_core : SDRAM fetch FSM (a read-only arbiter client) filling a 4-line word cache.
//  - clk_pixel: the 720p raster, reading the cache, 3x H/V upscale + pillarbox.
// The fetcher follows the reader's source row (synced across domains) and stays a few lines
// ahead; the 4-line cache absorbs the skew. Source line = WORDS_PER_LINE 32-bit RGB332 words
// (4 px/word, byte0=leftmost), LINES rows, contiguous from FB_BASE.

`default_nettype none
`timescale 1ns/1ps

module fb_reader #(
    parameter [24:0]  FB_BASE        = 25'h0078_0000,
    parameter integer WORDS_PER_LINE = 88,    // 352 px / 4 (actual data)
    parameter integer STRIDE         = 128,   // words/line incl. padding (must match fb_writer)
    parameter integer LINES          = 240,
    parameter [8:0]   H_SRC_OFFSET   = 9'd12  // centre the picture in the pillarbox
)(
    // SDRAM fetch (clk_core domain) — read-only arbiter client
    input  wire        clk_core,
    input  wire        rst_n,
    output reg         fbr_req,
    output reg  [24:0] fbr_addr,
    input  wire        fbr_ack,          // 1 pulse per completed BL8 burst
    input  wire [255:0] fbr_rdata,       // 8 words from the burst

    // HDMI (clk_pixel domain)
    input  wire        clk_pixel,
    output reg  [7:0]  r_out, g_out, b_out,
    output reg         hs_out, vs_out, de_out,
    output wire [7:0]  osd_x,
    output wire [7:0]  osd_y
);

// ── 720p timing (CEA-861 VIC 4, standard 1650x750 @ 60.00 Hz) ──────────────────
localparam H_ACTIVE = 11'd1280, H_FP = 11'd110, H_SYNC = 11'd40, H_BP = 11'd220;
localparam H_TOTAL  = 11'd1650;
localparam V_ACTIVE = 10'd720,  V_FP = 10'd5,  V_SYNC = 10'd5,  V_BP = 10'd20;
localparam V_TOTAL  = 10'd750;
// Active picture window: 1056 px wide (3*352) centred in 1280 → 112..1167; 720 high → vy 30..749.
localparam [10:0] CONT_X0 = 11'd112, CONT_X1 = 11'd1168;
// Vertical active = after Vsync(5)+VBP(20): vy 25..744, VFP 745..749 (CEA-861 720p).
localparam [9:0]  ACT_Y0  = 10'd25,  ACT_Y1  = 10'd745;

// ───────────────────────────────────────────────────────────────────────────────
// Read side (clk_pixel): free-running standard raster
// ───────────────────────────────────────────────────────────────────────────────
reg [10:0] hx;
reg [9:0]  vy;
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin hx <= 11'd0; vy <= 10'd0; end
    else if (hx == H_TOTAL - 11'd1) begin
        hx <= 11'd0;
        vy <= (vy == V_TOTAL - 10'd1) ? 10'd0 : vy + 10'd1;
    end else hx <= hx + 11'd1;
end
wire in_v   = (vy >= ACT_Y0) && (vy < ACT_Y1);
wire frame_start = (hx == 11'd0) && (vy == 10'd0);

// 3x vertical: advance source row every 3 output lines within the active region.
reg [1:0] line_rep;
reg [7:0] rd_row;       // 0..LINES-1
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin line_rep <= 2'd0; rd_row <= 8'd0; end
    else if (hx == H_TOTAL - 11'd1) begin
        if (vy == V_TOTAL - 10'd1) begin line_rep <= 2'd0; rd_row <= 8'd0; end
        else if (in_v) begin
            if (line_rep == 2'd2) begin
                line_rep <= 2'd0;
                if (rd_row != LINES-1) rd_row <= rd_row + 8'd1;
            end else line_rep <= line_rep + 2'd1;
        end
    end
end

// 3x horizontal: advance source column every 3 active output pixels.
reg [1:0] pix_rep;
reg [8:0] rd_col;       // 0..351
always_ff @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) begin pix_rep <= 2'd0; rd_col <= 9'd0; end
    else if (hx >= CONT_X0 && hx < CONT_X1) begin
        if (pix_rep == 2'd2) begin
            pix_rep <= 2'd0;
            if (rd_col != 9'd351) rd_col <= rd_col + 9'd1;
        end else pix_rep <= pix_rep + 2'd1;
    end else begin pix_rep <= 2'd0; rd_col <= 9'd0; end
end

// Source column with centring offset → word/byte index into the cache line.
wire [8:0] src_col   = rd_col + H_SRC_OFFSET;          // 0..363 (clamped by cache size)
wire [6:0] rd_word   = src_col[8:2];                   // /4
wire [1:0] rd_byte   = src_col[1:0];

// OSD coords: 256-col window centred in the 352-col source (col 48..303).
reg [7:0] osd_x_reg;
always_ff @(posedge clk_pixel) begin
    if      (rd_col < 9'd48)   osd_x_reg <= 8'd0;
    else if (rd_col >= 9'd304) osd_x_reg <= 8'd255;
    else                       osd_x_reg <= rd_col[7:0] - 8'd48;
end
assign osd_x = osd_x_reg;
assign osd_y = rd_row;

// ── 4-line word cache (clk_core write / clk_pixel read), 32-bit ─────────────────
wire [31:0] cache_rdata;
reg  [31:0] cache_wdata;
reg  [8:0]  cache_waddr;   // {slot[1:0], word[6:0]}
reg         cache_we;
wire [8:0]  cache_raddr = {rd_row[1:0], rd_word};

fb_reader_cache cache (
    .clk_w(clk_core), .we(cache_we), .waddr(cache_waddr), .wdata(cache_wdata),
    .clk_r(clk_pixel), .raddr(cache_raddr), .rdata(cache_rdata)
);

// ───────────────────────────────────────────────────────────────────────────────
// Fetch side (clk_core): keep the cache a few lines ahead of rd_row
// ───────────────────────────────────────────────────────────────────────────────
// CDC: reader row + frame_start into clk_core. rd_row changes slowly (~every 66 us) so a
// 2-FF sample is safe; frame_start is captured as a toggle edge.
reg [1:0] fs_tog_sync; reg fs_seen;
reg        fstoggle = 1'b0;
always_ff @(posedge clk_pixel) if (frame_start) fstoggle <= ~fstoggle;
reg [2:0] fstoggle_sync;
reg [7:0] rdrow_s1, rdrow_s2;
always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin fstoggle_sync <= 3'd0; rdrow_s1 <= 0; rdrow_s2 <= 0; end
    else begin
        fstoggle_sync <= {fstoggle_sync[1:0], fstoggle};
        rdrow_s1 <= rd_row; rdrow_s2 <= rdrow_s1;
    end
end
wire frame_start_core = fstoggle_sync[2] ^ fstoggle_sync[1];

// Fetch each source line as 44 BL2 bursts (88 words / 2). Per burst: issue req, wait one
// fbr_ack, latch the words, then write them to the cache one per cycle. BL2 keeps each
// non-preemptible SDRAM burst short enough that ANTIC never misses its bus window.
reg [7:0]   fetch_row;         // source row being fetched
reg [6:0]   word_base;         // first word of the current burst (0,8,..,80)
reg [14:0]  fetch_rowbase;     // fetch_row * WORDS_PER_LINE
reg         fetching;          // a burst req is in flight
reg         wb_active;         // writing the 8 captured words to the cache
reg [2:0]   wb;
reg [255:0] rdata_lat;
wire signed [9:0] lead = $signed({2'b0, fetch_row}) - $signed({2'b0, rdrow_s2});
// At line start (word_base==0) wait until within 4 lines of the reader; mid-line, continue.
wire start_burst = !fetching && !wb_active && (fetch_row < LINES)
                   && ((word_base != 7'd0) || (lead < 10'sd4));

always_ff @(posedge clk_core or negedge rst_n) begin
    if (!rst_n) begin
        fbr_req <= 1'b0; fbr_addr <= 25'd0; cache_we <= 1'b0;
        fetch_row <= 8'd0; word_base <= 7'd0; fetch_rowbase <= 15'd0;
        fetching <= 1'b0; wb_active <= 1'b0; wb <= 3'd0;
    end else begin
        cache_we <= 1'b0;
        if (frame_start_core) begin
            fetch_row <= 8'd0; word_base <= 7'd0; fetch_rowbase <= 15'd0;
            fetching <= 1'b0; wb_active <= 1'b0; fbr_req <= 1'b0;
        end else if (wb_active) begin
            // write the BL2 captured words (lower 64b of rdata_lat) to the cache, one/cycle
            cache_wdata <= rdata_lat[{wb, 5'b0} +: 32];
            cache_waddr <= {fetch_row[1:0], word_base + {4'd0, wb}};
            cache_we    <= 1'b1;
            if (wb == 3'd1) begin
                wb_active <= 1'b0;
                if (word_base == WORDS_PER_LINE-2) begin   // last burst of the line
                    fetch_row     <= fetch_row + 8'd1;
                    fetch_rowbase <= fetch_rowbase + STRIDE[14:0];
                    word_base     <= 7'd0;
                end else word_base <= word_base + 7'd2;
            end else wb <= wb + 3'd1;
        end else if (fetching) begin
            if (fbr_ack) begin
                rdata_lat <= fbr_rdata;
                fbr_req   <= 1'b0;
                fetching  <= 1'b0;
                wb_active <= 1'b1;
                wb        <= 3'd0;
            end
        end else if (start_burst) begin
            fbr_addr <= FB_BASE + ({10'd0, fetch_rowbase + {8'd0, word_base}} << 2);
            fbr_req  <= 1'b1;
            fetching <= 1'b1;
        end
    end
end

// ── Output pipeline (clk_pixel): align sync/de with the 1-cycle cache read ──────
wire de_s0   = (hx < H_ACTIVE) && in_v;
wire cont_s0 = (hx >= CONT_X0) && (hx < CONT_X1) && in_v;
wire hs_s0   = (hx >= H_ACTIVE + H_FP) && (hx < H_ACTIVE + H_FP + H_SYNC);
wire vs_s0   = (vy < V_SYNC);
// cache_raddr is combinational at clock T; the cache BRAM read is 2 cycles (addr reg +
// output reg) → cache_rdata is valid at T+2.  The byte select and the sync pipeline must
// therefore also be 2 cycles so word, byte, and de/cont all line up (fixes the intra-word
// green ghost from a 1-cycle byte select against a 2-cycle word read).
// cache read (word) + byte select are 1 cycle; align the sync/position pipeline to 1 cycle
// too so word, byte, and de/cont/position all land together (no edge fringe).
reg [1:0] rd_byte_p;
reg de_p1, hs_p1, vs_p1, cont_p1;
always_ff @(posedge clk_pixel) begin
    rd_byte_p <= rd_byte;
    de_p1 <= de_s0; hs_p1 <= hs_s0; vs_p1 <= vs_s0; cont_p1 <= cont_s0;
end
wire [7:0] px = cache_rdata[{rd_byte_p, 3'b000} +: 8];   // select the byte (RGB332)
wire de_p2 = de_p1, hs_p2 = hs_p1, vs_p2 = vs_p1, cont_p2 = cont_p1; // 1-cycle alias
// DIAGNOSTIC: TESTPAT=1 outputs an internal gradient (picture area) + blue pillarbox,
// bypassing the SDRAM/cache path → isolates raster/sync/window from the data path.
// Set TESTPAT=0 once the raster is confirmed.
localparam TESTPAT = 1'b0;
reg [10:0] hx_p2; reg [9:0] vy_p2;
always_ff @(posedge clk_pixel) begin hx_p2 <= hx; vy_p2 <= vy; end // not pipeline-exact; fine for a gradient
always_comb begin
    hs_out = hs_p2; vs_out = vs_p2; de_out = de_p2;
    if (TESTPAT) begin
        if (de_p2 && cont_p2)      begin r_out = hx_p2[9:2]; g_out = vy_p2[8:1]; b_out = 8'd64; end
        else if (de_p2)            begin r_out = 8'd0; g_out = 8'd0; b_out = 8'd128; end // pillarbox = blue
        else                       begin r_out = 8'd0; g_out = 8'd0; b_out = 8'd0;   end
    end else if (de_p2 && cont_p2) begin
        r_out = {px[7:5], px[7:5], px[7:6]};
        g_out = {px[4:2], px[4:2], px[4:3]};
        b_out = {px[1:0], px[1:0], px[1:0], px[1:0]};
    end else begin r_out = 8'd0; g_out = 8'd0; b_out = 8'd0; end
end

endmodule

// ── 4-line x WORDS_PER_LINE word cache (dual-clock, 32-bit) ─────────────────────
module fb_reader_cache (
    input  wire        clk_w,
    input  wire        we,
    input  wire [8:0]  waddr,
    input  wire [31:0] wdata,
    input  wire        clk_r,
    input  wire [8:0]  raddr,
    output reg  [31:0] rdata
);
    (* ram_style = "block" *)
    reg [31:0] mem [0:511];
    always_ff @(posedge clk_w) if (we) mem[waddr] <= wdata;
    always_ff @(posedge clk_r) rdata <= mem[raddr];
endmodule

`default_nettype wire
