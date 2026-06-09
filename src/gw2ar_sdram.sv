// gw2ar_sdram — adapter that presents the Atari core/arbiter interface
// (req / req_complete / read_en / write_en / addr / rdata / wdata / wmask / refresh)
// on top of the low-latency NESTang controller (`sdram_nestang`, ~5-cycle access).
//
// Replaces the previous ~20-cycle closed-page controller + read cache. The ports and
// behaviour (req held until a 1-cycle req_complete pulse; refresh latched and serviced
// when idle) match the old module, so tang_top / the arbiter are unchanged.
//
// Address geometry is identical (byte[1:0]/col[9:2]/row[20:10]/bank[22:21]); addr[24:23]
// are ignored (>8 MB), as before. The cache is dropped — at ~5-cycle access every read is
// a direct SDRAM access well within the Atari bus window.

module gw2ar_sdram (
    input  wire        clk,       // bus/interface clock (clk_core) — req/req_complete handshake
    input  wire        clk_mem,   // controller clock (clk_mem, 2x clk_core, synchronous)
    input  wire        reset_n,

    // Atari core / ROM-loader interface (time-shared via the arbiter)
    input  wire        req,
    output reg         req_complete,
    input  wire        read_en,
    input  wire        write_en,
    input  wire        burst,        // 1 with read_en: BL8 burst read (8 words)
    input  wire [24:0] addr,
    output reg  [31:0] rdata,
    output wire [255:0] burst_rdata,  // 8-word burst read result
    input  wire [31:0] wdata,
    input  wire [3:0]  wmask,
    input  wire        refresh,

    // GW2AR-18 embedded SDRAM pins
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_wen_n,
    output wire [1:0]  O_sdram_ba,
    output wire [10:0] O_sdram_addr,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq,

    output reg         sdram_ready = 1'b0
);

// SDRAM clock = inverted controller clock (180-degree phase).
wire clk_sdram = ~clk_mem;

// ── NESTang controller ────────────────────────────────────────────────────────
wire [31:0] n_dout32;
wire        n_data_ready;
wire        n_busy;

reg  r_rd = 1'b0, r_wr = 1'b0, r_ref = 1'b0;

sdram_nestang #(.FREQ(57_375_000)) u_sdram (
    .SDRAM_DQ   (IO_sdram_dq),
    .SDRAM_A    (O_sdram_addr),
    .SDRAM_BA   (O_sdram_ba),
    .SDRAM_nCS  (O_sdram_cs_n),
    .SDRAM_nWE  (O_sdram_wen_n),
    .SDRAM_nRAS (O_sdram_ras_n),
    .SDRAM_nCAS (O_sdram_cas_n),
    .SDRAM_CLK  (O_sdram_clk),
    .SDRAM_CKE  (O_sdram_cke),
    .SDRAM_DQM  (O_sdram_dqm),

    .clk        (clk_mem),
    .clk_sdram  (clk_sdram),
    .resetn     (reset_n),
    .rd         (r_rd),
    .wr         (r_wr),
    .burst      (burst),
    .burst_dout (burst_rdata),
    .refresh    (r_ref),
    .addr       (addr[22:0]),
    .din        (wdata),
    .wmask      (wmask),
    .dout32     (n_dout32),
    .data_ready (n_data_ready),
    .busy       (n_busy)
);

// ── Handshake adapter FSM ──────────────────────────────────────────────────────
localparam [1:0] A_IDLE = 2'd0, A_ACCESS = 2'd1, A_REFRESH = 2'd2, A_DONE = 2'd3;
reg [1:0] ast = A_IDLE;
reg       busy_d = 1'b1;           // delayed busy for falling-edge detect
reg       init_done = 1'b0;
reg       refresh_pending = 1'b0;
reg       refresh_d = 1'b0;

wire busy_fell = busy_d & ~n_busy;

always @(posedge clk_mem or negedge reset_n) begin
    if (!reset_n) begin
        ast             <= A_IDLE;
        r_rd            <= 1'b0;
        r_wr            <= 1'b0;
        r_ref           <= 1'b0;
        req_complete    <= 1'b0;
        rdata           <= 32'd0;
        busy_d          <= 1'b1;
        init_done       <= 1'b0;
        sdram_ready     <= 1'b0;
        refresh_pending <= 1'b0;
        refresh_d       <= 1'b0;
    end else begin
        r_rd  <= 1'b0;
        r_wr  <= 1'b0;
        r_ref <= 1'b0;
        // req_complete is NOT a per-cycle pulse anymore: it is a level driven in A_DONE
        // and held until the clk_core arbiter drops req (4-phase handshake across the
        // clk_core↔clk_mem boundary).  Do not clear it blindly here.
        busy_d <= n_busy;

        // latch refresh requests (rising edge), service when idle
        refresh_d <= refresh;
        if (refresh && !refresh_d) refresh_pending <= 1'b1;

        // controller init finishes the first time busy drops (after CONFIG)
        if (!init_done && busy_fell) begin
            init_done   <= 1'b1;
            sdram_ready <= 1'b1;
        end

        case (ast)
            A_IDLE: if (init_done && !n_busy) begin
                if (req && (read_en || write_en)) begin
                    r_rd <= read_en;
                    r_wr <= write_en;
                    ast  <= A_ACCESS;
                end else if (refresh_pending) begin
                    r_ref           <= 1'b1;
                    refresh_pending <= 1'b0;
                    ast             <= A_REFRESH;
                end
            end

            A_ACCESS: begin
                if (n_data_ready) rdata <= n_dout32;   // capture read data (1 cyc before busy falls)
                if (busy_fell) ast <= A_DONE;
            end

            // Hold req_complete high until the arbiter drops req (it forces req low for one
            // clk_core cycle via SA_WAIT), then return to idle.  This is the handshake
            // boundary that lets clk_core reliably catch completion across the 2:1 crossing.
            A_DONE: begin
                req_complete <= 1'b1;
                if (!req) begin
                    req_complete <= 1'b0;
                    ast          <= A_IDLE;
                end
            end

            A_REFRESH: if (busy_fell) ast <= A_IDLE;
        endcase
    end
end

endmodule
