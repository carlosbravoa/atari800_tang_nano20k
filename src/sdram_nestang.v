// sdram_nestang.v — low-latency SDRAM controller for the Tang Nano 20K embedded SDRAM.
//
// Adapted from nand2mario's NESTang controller (../sdram-tang-nano-20k/src/sdram.v),
// MIT/BSD. Changes from the original:
//   - 32-bit masked write: `din` is 32-bit and `wmask[3:0]` selects bytes (DQM = ~wmask),
//     instead of the original byte-only write (the Atari core does byte writes, but the
//     firmware/iosys does 32-bit masked writes, so we need the full path).
//   - module renamed `sdram_nestang`.
// Everything else (the ~5-cycle access state machine, init, refresh) is unchanged.
//
// Address geometry (matches our embedded SDRAM and the previous controller):
//   byte = addr[1:0], col = addr[9:2], row = addr[20:10], bank = addr[22:21].

module sdram_nestang
#(
    parameter         FREQ = 54_000_000,
    parameter         DATA_WIDTH = 32,
    parameter         ROW_WIDTH  = 11,   // 2K rows
    parameter         COL_WIDTH  = 8,    // 256 words/row
    parameter         BANK_WIDTH = 2,    // 4 banks

    // Cycle counts. Valid for any clock up to ~66.7 MHz; at lower clocks each
    // cycle is longer so these stay safely above the SDRAM's ns minimums.
    parameter [3:0]   CAS  = 4'd2,
    parameter [3:0]   T_WR = 4'd2,
    parameter [3:0]   T_MRD= 4'd2,
    parameter [3:0]   T_RP = 4'd1,
    parameter [3:0]   T_RCD= 4'd1,
    parameter [3:0]   T_RC = 4'd4
)
(
    // SDRAM pins
    inout [DATA_WIDTH-1:0]      SDRAM_DQ,
    output reg [ROW_WIDTH-1:0]  SDRAM_A,
    output reg [BANK_WIDTH-1:0] SDRAM_BA,
    output            SDRAM_nCS,
    output reg        SDRAM_nWE,
    output reg        SDRAM_nRAS,
    output reg        SDRAM_nCAS,
    output            SDRAM_CLK,
    output            SDRAM_CKE,
    output reg  [3:0] SDRAM_DQM,

    // Logic side
    input             clk,
    input             clk_sdram,    // phase shifted from clk (180-degrees)
    input             resetn,
    input             rd,           // read command pulse
    input             wr,           // write command pulse
    input             burst,        // 1 with rd: BL8 page-mode burst read (8 words)
    input             refresh,      // auto-refresh command pulse
    input      [22:0] addr,         // byte address, latched at rd/wr pulse
    input      [31:0] din,          // 32-bit write data, latched at wr pulse
    input      [3:0]  wmask,        // active-high byte write mask
    output [DATA_WIDTH-1:0] dout32, // 32-bit read data (valid at data_ready)
    output reg [255:0] burst_dout,  // 8-word burst read data (valid at busy fall)
    output reg        data_ready,   // pulses when read data is valid
    output reg        busy          // 1: controller busy / not ready for next command
);
localparam [3:0] BLEN = 4'd4;       // burst length (words). BL4 keeps the non-preemptible
                                    // burst short enough that ANTIC never misses its bus window.

reg dq_oen;
reg [DATA_WIDTH-1:0] dq_out;
assign SDRAM_DQ = dq_oen ? {DATA_WIDTH{1'bz}} : dq_out;
wire [DATA_WIDTH-1:0] dq_in = SDRAM_DQ;

assign dout32   = dq_in;
assign SDRAM_CLK = clk_sdram;
assign SDRAM_CKE = 1'b1;
assign SDRAM_nCS = 1'b0;

reg [2:0] state;
localparam INIT    = 3'd0;
localparam CONFIG  = 3'd1;
localparam IDLE    = 3'd2;
localparam READ    = 3'd3;
localparam WRITE   = 3'd4;
localparam REFRESH = 3'd5;
localparam BREAD   = 3'd6;   // BL8 page-mode burst read

// RAS# CAS# WE#
localparam CMD_SetModeReg  = 3'b000;
localparam CMD_AutoRefresh = 3'b001;
localparam CMD_PreCharge   = 3'b010;
localparam CMD_BankActivate= 3'b011;
localparam CMD_Write       = 3'b100;
localparam CMD_Read        = 3'b101;
localparam CMD_NOP         = 3'b111;

localparam [2:0] BURST_LEN  = 3'b0;   // burst length 1
localparam       BURST_MODE = 1'b0;   // sequential
localparam [10:0] MODE_REG  = {4'b0, CAS[2:0], BURST_MODE, BURST_LEN};

reg cfg_now;
reg [3:0]  cycle;
// Half-rate BL2 burst: READ commands at odd cycles 1,3 (one per 2 cycles), data captured
// exactly like the upstream single-read path: at the posedge in the middle of each beat's
// driven cycle (cmd on bus cycle k → data on bus cycle k+CAS → capture at its end).
// Full-rate back-to-back reads made the bus transition every cycle with no settle time —
// the only access pattern upstream never uses, and the source of the per-build burst-read
// corruption (green ghost / dropped beats). The gap cycle between beats gives every sample
// a quiet, settled bus; BL2 keeps the non-preemptible burst as short as the original
// (proven) BL4 full-rate burst so ANTIC never misses its bus window. Assumes even CAS.
wire [2:0] beat = (cycle - 4'd2 - CAS) >> 1;   // capture cycles CAS+2,CAS+4 → beats 0,1
reg [31:0] din_buf;
reg [3:0]  wmask_buf;
reg [22:0] addr_buf;

always @(posedge clk) begin
    cycle <= cycle == 4'd15 ? 4'd15 : cycle + 4'd1;
    {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
    casex ({state, cycle})
        {INIT, 4'bxxxx} : if (cfg_now) begin state <= CONFIG; cycle <= 0; end

        {CONFIG, 4'd0} : begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PreCharge;
            SDRAM_A[10] <= 1'b1;
        end
        {CONFIG, T_RP} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AutoRefresh;
        {CONFIG, T_RP+T_RC} : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AutoRefresh;
        {CONFIG, T_RP+T_RC+T_RC} : begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_SetModeReg;
            SDRAM_A[10:0] <= MODE_REG;
        end
        {CONFIG, T_RP+T_RC+T_RC+T_MRD} : begin
            state <= IDLE;
            busy  <= 1'b0;
        end

        {IDLE, 4'bxxxx}: if (rd | wr) begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_BankActivate;
            SDRAM_BA <= addr[ROW_WIDTH+COL_WIDTH+BANK_WIDTH-1+2 : ROW_WIDTH+COL_WIDTH+2];
            SDRAM_A  <= addr[ROW_WIDTH+COL_WIDTH-1+2:COL_WIDTH+2];
            state    <= rd ? (burst ? BREAD : READ) : WRITE;
            addr_buf <= addr;
            if (wr) begin din_buf <= din; wmask_buf <= wmask; end
            cycle <= 4'd1;
            busy  <= 1'b1;
        end else if (refresh) begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AutoRefresh;
            state <= REFRESH;
            cycle <= 4'd1;
            busy  <= 1'b1;
        end

        // read: Active -> (T_RCD) Read+auto-precharge -> (CAS) data_ready
        {READ, T_RCD}: begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_Read;
            SDRAM_A[10]  <= 1'b1;                                  // auto precharge
            SDRAM_A[9:0] <= {1'b0, addr_buf[COL_WIDTH-1+2:2]};
            SDRAM_DQM    <= 4'b0;
        end
        {READ, T_RCD+CAS}:      data_ready <= 1'b1;
        {READ, T_RCD+CAS+4'd1}: begin
            data_ready <= 1'b0;
            busy <= 0;
            state <= IDLE;
        end

        // write: Active -> (T_RCD) Write+auto-precharge (32-bit, DQM=~wmask)
        {WRITE, T_RCD}: begin
            {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_Write;
            SDRAM_A[10]  <= 1'b1;                                  // auto precharge
            SDRAM_A[9:0] <= {1'b0, addr_buf[COL_WIDTH-1+2:2]};
            SDRAM_DQM    <= ~wmask_buf;                            // write only masked bytes
            dq_out       <= din_buf;
            dq_oen       <= 1'b0;
        end
        {WRITE, T_RCD+4'd1}:      dq_oen <= 1'b1;
        {WRITE, T_RCD+T_WR+T_RP}: begin busy <= 0; state <= IDLE; end

        // BL8 page-mode burst read: 8 Reads (no auto-precharge) at col..col+7, then 1 Precharge.
        // Reads issued on cycles 1..8 → data on cycles (1+CAS)..(8+CAS); precharge after.
        {BREAD, 4'bxxxx}: begin
            if (cycle >= 4'd1 && cycle <= 4'd3 && cycle[0]) begin      // cycles 1,3 (BL2)
                {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_Read;
                SDRAM_A[10]  <= 1'b0;                                  // NO auto-precharge
                SDRAM_A[9:0] <= {2'b0, addr_buf[COL_WIDTH-1+2:2] + {5'b0, cycle[3:1]}};
                SDRAM_DQM    <= 4'b0;
            end
            // capture beats at even cycles CAS+2 .. CAS+4 (4,6 for CAS=2)
            if (cycle >= (CAS+4'd2) && cycle <= (CAS+4'd4) && !cycle[0])
                burst_dout[ {beat, 5'b0} +: 32 ] <= dq_in;   // beat*32
            if (cycle == (CAS+4'd5)) begin
                {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PreCharge;
                SDRAM_A[10] <= 1'b1;                                   // precharge all
            end
            if (cycle == (CAS+4'd5+T_RP)) begin
                busy  <= 1'b0;
                state <= IDLE;
            end
        end

        {REFRESH, T_RC}: begin state <= IDLE; busy <= 0; end
    endcase

    if (~resetn) begin
        busy      <= 1'b1;
        dq_oen    <= 1'b1;
        SDRAM_DQM <= 4'b0;
        state     <= INIT;
    end
end

// cfg_now pulse after the 200 us power-on delay
reg [14:0] rst_cnt;
reg rst_done, rst_done_p1;
always @(posedge clk) begin
    rst_done_p1 <= rst_done;
    cfg_now     <= rst_done & ~rst_done_p1;
    if (rst_cnt != FREQ / 1000 * 200 / 1000) begin
        rst_cnt  <= rst_cnt + 15'd1;
        rst_done <= 1'b0;
    end else begin
        rst_done <= 1'b1;
    end
    if (~resetn) begin
        rst_cnt  <= 15'd0;
        rst_done <= 1'b0;
    end
end

endmodule
