// ROM loader: copies BASIC and OS ROM images from FPGA BRAM into SDRAM
// before the Atari core is released from reset.
//
// BRAM is initialised at configuration time via $readmemh.
// Hex files are 32-bit words (8 hex digits per line, LSByte first in SDRAM word):
//   tang_nano/rom/basic.hex  — 2048 lines (8 KB)
//   tang_nano/rom/os.hex     — 4096 lines (16 KB)
//
// SDRAM byte addresses (from address_decoder.vhdl, low_memory=0, XL/XE mode):
//   BASIC ROM  0x700000  (8 KB)
//   OS ROM     0x704000  (16 KB)
//
// Usage: assert req repeatedly until complete pulses; the SDRAM mux in
// tang_top switches control to the Atari core once done=1.

module rom_loader (
    input  wire clk,
    input  wire reset_n,
    input  wire sdram_ready,    // SDRAM init complete

    output wire       done,     // ROM loading finished; release core reset

    // SDRAM write port (32-bit writes only)
    output reg        req,
    input  wire       complete,
    output reg        write_en,
    output reg [24:0] addr,
    output reg [31:0] wdata
);

// ── BRAM ROM storage ─────────────────────────────────────────────────────────
// Files are resolved from the impl/<project>/ directory by GowinSynthesis;
// build.tcl copies them there from tang_nano/rom/ before synthesis.
reg [31:0] basic_rom [0:2047];
reg [31:0] os_rom    [0:4095];

initial begin
    $readmemh("basic.hex", basic_rom);
    $readmemh("os.hex",    os_rom);
end

// ── State machine ─────────────────────────────────────────────────────────────
localparam BASIC_BASE = 25'h700000;  // 0x700000
localparam OS_BASE    = 25'h704000;  // 0x704000

typedef enum logic [1:0] {
    S_WAIT,       // wait for SDRAM init
    S_BASIC,      // loading BASIC ROM
    S_OS,         // loading OS ROM
    S_DONE        // finished
} state_t;

state_t    state;
reg [12:0] idx;   // word index within current ROM (max 4095)

assign done     = (state == S_DONE);
assign write_en = (state == S_BASIC || state == S_OS) && !done;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= S_WAIT;
        req   <= 1'b0;
        idx   <= 13'd0;
        addr  <= 25'd0;
        wdata <= 32'd0;
    end else begin
        case (state)
            S_WAIT: begin
                if (sdram_ready) begin
                    state <= S_BASIC;
                    idx   <= 13'd0;
                    addr  <= BASIC_BASE;
                    wdata <= basic_rom[0];
                    req   <= 1'b1;
                end
            end

            S_BASIC: begin
                if (complete) begin
                    if (idx == 13'd2047) begin
                        // Switch to OS ROM
                        state <= S_OS;
                        idx   <= 13'd0;
                        addr  <= OS_BASE;
                        wdata <= os_rom[0];
                    end else begin
                        idx   <= idx + 1;
                        addr  <= BASIC_BASE + {idx + 13'd1, 2'b00}; // word→byte addr
                        wdata <= basic_rom[idx + 1];
                    end
                end
            end

            S_OS: begin
                if (complete) begin
                    if (idx == 13'd4095) begin
                        state <= S_DONE;
                        req   <= 1'b0;
                    end else begin
                        idx   <= idx + 1;
                        addr  <= OS_BASE + {idx + 13'd1, 2'b00};
                        wdata <= os_rom[idx + 1];
                    end
                end
            end

            S_DONE: begin
                req <= 1'b0;
            end

            default: state <= S_WAIT;
        endcase
    end
end

endmodule
