// sd_rom_loader.sv — loads OS.ROM and BASIC.ROM from SD card into SDRAM
// Wraps sd_card + fat_reader; exposes the same req/complete/write_en/addr/wdata
// interface as rom_loader so tang_top needs only minor changes.
//
// SDRAM byte addresses (matches address_decoder.vhdl, low_memory=0, XL/XE):
//   OS ROM    0x704000  (16 KB, fat_reader streams first, is_basic=0)
//   BASIC ROM 0x700000  ( 8 KB, fat_reader streams second, is_basic=1)

module sd_rom_loader (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sdram_ready,   // SDRAM init complete

    output wire        done,          // both ROMs written to SDRAM
    output wire        dbg_sd_ready,  // SD card init done (diagnostic)

    // SDRAM write port (32-bit writes, matches rom_loader interface)
    output reg         req,
    input  wire        complete,
    output wire        write_en,
    output reg  [24:0] addr,
    output reg  [31:0] wdata,

    // SD card SPI
    output wire        spi_clk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n
);

localparam [24:0] OS_BASE    = 25'h704000;
localparam [24:0] BASIC_BASE = 25'h700000;

// ── Internal wires ────────────────────────────────────────────────────────────
wire        sd_ready, sd_err;
wire        fr_sd_req;
wire [31:0] fr_sd_lba;
wire        sd_rd_valid, sd_rd_done;
wire [7:0]  sd_rd_byte;

wire        fr_byte_valid;
wire [7:0]  fr_byte_data;
wire        fr_is_basic;
wire        fr_done, fr_error;

reg         fr_start;

// ── sd_card ───────────────────────────────────────────────────────────────────
sd_card sd_i (
    .clk      (clk),
    .rst_n    (reset_n),
    .ready    (sd_ready),
    .error    (sd_err),
    .rd_req   (fr_sd_req),
    .rd_lba   (fr_sd_lba),
    .rd_valid (sd_rd_valid),
    .rd_byte  (sd_rd_byte),
    .rd_done  (sd_rd_done),
    .spi_clk  (spi_clk),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .spi_cs_n (spi_cs_n)
);

// ── fat_reader ────────────────────────────────────────────────────────────────
fat_reader fr_i (
    .clk       (clk),
    .rst_n     (reset_n),
    .start     (fr_start),
    .done      (fr_done),
    .error     (fr_error),
    .byte_valid(fr_byte_valid),
    .byte_data (fr_byte_data),
    .is_basic  (fr_is_basic),
    .sd_req    (fr_sd_req),
    .sd_lba    (fr_sd_lba),
    .sd_valid  (sd_rd_valid),
    .sd_byte   (sd_rd_byte),
    .sd_done   (sd_rd_done),
    .sd_error  (sd_err)
);

// ── State machine ─────────────────────────────────────────────────────────────
typedef enum logic [2:0] {
    S_INIT, S_START, S_LOAD, S_WRITE, S_DONE
} st_t;
st_t st;

reg [1:0]  byte_idx;   // byte position within current 32-bit word (0..3)
reg [23:0] word_buf;   // bytes 0-2 of the in-progress word (LSByte first)
reg        saw_basic;  // latched when is_basic first goes high

assign done         = (st == S_DONE);
assign write_en     = req;
assign dbg_sd_ready = sd_ready;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        st        <= S_INIT;
        fr_start  <= 1'b0;
        req       <= 1'b0;
        addr      <= 25'd0;
        wdata     <= 32'd0;
        byte_idx  <= 2'd0;
        word_buf  <= 24'd0;
        saw_basic <= 1'b0;
    end else begin
        fr_start <= 1'b0;   // default: no pulse

        case (st)

        S_INIT:
            if (sdram_ready && sd_ready) begin
                fr_start  <= 1'b1;
                addr      <= OS_BASE;
                byte_idx  <= 2'd0;
                saw_basic <= 1'b0;
                st        <= S_START;
            end

        S_START:
            // fat_reader accepted the start pulse; begin receiving bytes
            st <= S_LOAD;

        S_LOAD: begin
            if (fr_done) begin
                st <= S_DONE;
            end else if (fr_byte_valid) begin
                // Detect OS→BASIC transition. fat_reader guarantees this occurs
                // on a word boundary (both ROMs are multiples of 4 bytes), so
                // byte_idx is always 0 here — no partial-word cleanup needed.
                if (fr_is_basic && !saw_basic) begin
                    saw_basic <= 1'b1;
                    addr      <= BASIC_BASE;
                end

                case (byte_idx)
                    2'd0: word_buf[ 7: 0] <= fr_byte_data;
                    2'd1: word_buf[15: 8] <= fr_byte_data;
                    2'd2: word_buf[23:16] <= fr_byte_data;
                    2'd3: begin
                        // Word complete: byte3 in [31:24], byte0 in [7:0]
                        wdata <= {fr_byte_data, word_buf[23:16],
                                  word_buf[15:8], word_buf[7:0]};
                        req   <= 1'b1;
                        st    <= S_WRITE;
                    end
                endcase
                byte_idx <= byte_idx + 2'd1;   // wraps 3→0 naturally
            end
        end

        S_WRITE:
            if (complete) begin
                req  <= 1'b0;
                addr <= addr + 25'd4;
                st   <= S_LOAD;
            end

        S_DONE:
            req <= 1'b0;

        default: st <= S_INIT;
        endcase
    end
end

endmodule
