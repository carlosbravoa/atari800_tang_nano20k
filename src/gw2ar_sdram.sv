// GW2AR-18 embedded 32-bit SDRAM controller
// 64 Mbit (8 MB): 4 banks × 2048 rows × 256 columns × 32 bits
// Designed for 27–29 MHz operation; all standard SDRAM timing met with margin.
//
// Address mapping (25-bit byte address from Atari core):
//   [1:0]  = byte lane select (for DQM)
//   [9:2]  = column [7:0]
//   [20:10]= row [10:0]
//   [22:21]= bank [1:0]
//   [24:23]= ignored (>8 MB)
//
// ROM addresses used by address_decoder.vhdl (low_memory=0, XL/XE mode):
//   BASIC ROM  0x700000-0x701FFF  (bank 3, row 1024, cols 0-511)
//   OS ROM     0x704000-0x707FFF  (bank 3, row 1040, cols 0-1023)

module gw2ar_sdram (
    input  wire        clk,        // system clock
    input  wire        reset_n,

    // ── Atari core / ROM-loader interface (time-shared) ──────────────────────
    input  wire        req,
    output reg         req_complete,
    input  wire        read_en,
    input  wire        write_en,
    input  wire [24:0] addr,       // byte address
    output reg  [31:0] rdata,      // read data (to core)
    input  wire [31:0] wdata,      // write data (from core / loader)
    input  wire [3:0]  wmask,      // 4-bit write mask (active high)
    input  wire        refresh,    // refresh request from core

    // ── GW2AR-18 embedded SDRAM pins ─────────────────────────────────────────
    output wire        O_sdram_clk,
    output reg         O_sdram_cke,
    output reg         O_sdram_cs_n,
    output reg         O_sdram_ras_n,
    output reg         O_sdram_cas_n,
    output reg         O_sdram_wen_n,
    output reg  [1:0]  O_sdram_ba,
    output reg  [10:0] O_sdram_addr,
    output reg  [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq,

    output reg         sdram_ready = 1'b0  // high after SDRAM init completes
);

// SDRAM clock = system clock (same domain; at 27 MHz timing is very relaxed)
// Inverted physical clock to create 180-degree phase shift
assign O_sdram_clk = ~clk;

// ── DQ tri-state ──────────────────────────────────────────────────────────────
reg  [31:0] dq_out;
reg         dq_en;
assign IO_sdram_dq = dq_en ? dq_out : 32'bz;

// ── SDRAM commands ────────────────────────────────────────────────────────────
// {CS_N, RAS_N, CAS_N, WE_N}
localparam CMD_INHIBIT   = 4'b1111;
localparam CMD_NOP       = 4'b0111;
localparam CMD_ACTIVE    = 4'b0011;
localparam CMD_READ      = 4'b0101;
localparam CMD_WRITE     = 4'b0100;
localparam CMD_PRECHARGE = 4'b0010;
localparam CMD_AUTO_REF  = 4'b0001;
localparam CMD_LOAD_MODE = 4'b0000;

// Mode register: CAS=2, Burst=1, Sequential
localparam [10:0] MODE_REG = 11'b000_0_010_0_000;

// ── State machine ─────────────────────────────────────────────────────────────
typedef enum logic [3:0] {
    S_INIT,      // power-on delay (200 µs at 27 MHz ≈ 5400 cycles)
    S_IPRE,      // init: PRECHARGE ALL
    S_IREF,      // init: 8× AUTO REFRESH
    S_IMRS,      // init: LOAD MODE REGISTER
    S_IDLE,
    S_ACT,       // ACTIVATE row
    S_RD,        // READ command
    S_RD_W1,     // CAS latency 1
    S_RD_DONE,   // capture data
    S_WR,        // WRITE command + complete
    S_REF        // AUTO REFRESH from idle
} state_t;

state_t       state = S_INIT;
reg [13:0]    cnt = 14'd5400;        // general wait counter
reg [3:0]     ref_cnt = 4'd8;    // init-refresh repetition counter
reg [1:0]     cur_bank;
reg [10:0]    cur_row;
reg [7:0]     cur_col;
reg [3:0]     cur_dqm;
reg           cur_write;

// Registered read data capture
reg [31:0]    dq_capture;
reg           refresh_r;
reg           refresh_pending;

task set_cmd;
    input [3:0] cmd;
    {O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} = cmd;
endtask



always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state           <= S_INIT;
        cnt             <= 14'd5400;   // 200 µs at 27 MHz
        ref_cnt         <= 4'd8;
        O_sdram_cke     <= 1'b1;
        dq_en           <= 1'b0;
        req_complete    <= 1'b0;
        sdram_ready     <= 1'b0;
        set_cmd(CMD_INHIBIT);
        O_sdram_ba      <= 2'b0;
        O_sdram_addr    <= 11'b0;
        O_sdram_dqm     <= 4'b1111;
        refresh_r       <= 1'b0;
        refresh_pending <= 1'b0;
    end else begin
        req_complete <= 1'b0;
        dq_en        <= 1'b0;
        set_cmd(CMD_NOP);

        refresh_r <= refresh;
        if (refresh && !refresh_r) begin
            refresh_pending <= 1'b1;
        end else if (state == S_IDLE && cnt == 0 && refresh_pending) begin
            refresh_pending <= 1'b0;
        end

        case (state)
            // ── Initialisation ────────────────────────────────────────────────
            S_INIT: begin
                if (cnt == 0) begin
                    state <= S_IPRE;
                end else begin
                    cnt <= cnt - 1;
                end
            end

            S_IPRE: begin
                // PRECHARGE ALL (A10=1)
                set_cmd(CMD_PRECHARGE);
                O_sdram_addr <= 11'b10000000000;  // A10=1 (Precharge All)
                O_sdram_ba   <= 2'b00;
                cnt          <= 14'd2;
                state        <= S_IREF;
            end

            S_IREF: begin
                if (cnt != 0) begin
                    cnt <= cnt - 1;  // finish tRP wait or tRFC wait
                end else if (ref_cnt != 0) begin
                    set_cmd(CMD_AUTO_REF);
                    ref_cnt <= ref_cnt - 1;
                    cnt     <= 14'd6;
                end else begin
                    state <= S_IMRS;
                end
            end

            S_IMRS: begin
                // Load mode register
                set_cmd(CMD_LOAD_MODE);
                O_sdram_ba   <= 2'b00;
                O_sdram_addr <= MODE_REG;
                cnt          <= 14'd2;
                state        <= S_IDLE;
                sdram_ready  <= 1'b1;
            end

            // ── Idle: wait for request or refresh ────────────────────────────
            S_IDLE: begin
                if (cnt != 0) begin
                    cnt <= cnt - 1;
                // Refresh has priority over reads/writes (matches MiSTer sdram_statemachine
                // behaviour) to prevent refresh starvation under heavy ANTIC DMA load.
                end else if (refresh_pending) begin
                    set_cmd(CMD_AUTO_REF);
                    cnt   <= 14'd6;
                    state <= S_REF;
                end else if (req) begin
                    // Latch address fields
                    cur_bank  <= addr[22:21];
                    cur_row   <= addr[20:10];
                    cur_col   <= addr[9:2];
                    cur_dqm   <= ~wmask;
                    cur_write <= write_en;
                    // ACTIVATE
                    set_cmd(CMD_ACTIVE);
                    O_sdram_ba   <= addr[22:21];
                    O_sdram_addr <= addr[20:10];
                    state        <= S_ACT;
                end
            end

            // ── Activate: wait tRCD (1 cycle sufficient @ 27 MHz ≥ 37 ns) ───
            S_ACT: begin
                if (cur_write) begin
                    set_cmd(CMD_WRITE);
                    O_sdram_ba   <= cur_bank;
                    O_sdram_addr <= {3'b100, cur_col};  // A10=1 (Auto-precharge enabled)
                    O_sdram_dqm  <= cur_dqm;
                    dq_out       <= wdata;
                    dq_en        <= 1'b1;
                    state        <= S_WR;
                end else begin
                    set_cmd(CMD_READ);
                    O_sdram_ba   <= cur_bank;
                    O_sdram_addr <= {3'b100, cur_col};  // A10=1 (Auto-precharge enabled)
                    O_sdram_dqm  <= 4'b0000;
                    state        <= S_RD;
                end
            end

            // ── Read: CAS latency wait (CL=2) ────────────────────────────────
            S_RD: begin
                state <= S_RD_W1;  // 1st latency cycle
            end

            S_RD_W1: begin
                state <= S_RD_DONE;  // 2nd latency cycle: data valid next edge
            end

            S_RD_DONE: begin
                rdata        <= IO_sdram_dq;
                req_complete <= 1'b1;
                cnt          <= 14'd2;   // tRP for auto-precharge row close
                state        <= S_IDLE;
            end

            // ── Write complete ────────────────────────────────────────────────
            S_WR: begin
                dq_en        <= 1'b0;
                O_sdram_dqm  <= 4'b1111;
                req_complete <= 1'b1;
                cnt          <= 14'd3;   // tWR + tRP
                state        <= S_IDLE;
            end

            // ── Refresh ───────────────────────────────────────────────────────
            S_REF: begin
                if (cnt != 0) cnt <= cnt - 1;
                else          state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
