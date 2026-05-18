// sd_card.sv — SPI-mode SD card: init (CMD0/CMD8/ACMD41) + block read (CMD17)
// Assumes SDHC/SDXC (direct LBA addressing). CRC checking disabled.

module sd_card (
    input  wire        clk,
    input  wire        rst_n,

    output reg         ready,       // card init done, ready for rd_req
    output reg         error,       // fatal error (stuck high)

    input  wire        rd_req,      // 1-cycle pulse: read sector rd_lba
    input  wire [31:0] rd_lba,
    output reg         rd_valid,    // 1-cycle pulse: rd_byte is valid
    output reg  [7:0]  rd_byte,
    output reg         rd_done,     // 1-cycle pulse: all 512 bytes delivered

    output wire        spi_clk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output reg         spi_cs_n
);

// ── SPI master ────────────────────────────────────────────────────────────────
reg        spi_fast, spi_start;
reg  [7:0] spi_tx;
wire [7:0] spi_rx;
wire       spi_done, spi_busy;

spi_master #(.INIT_DIV(34), .FAST_DIV(4)) spi_i (
    .clk(clk), .rst_n(rst_n), .fast(spi_fast),
    .start(spi_start), .tx_byte(spi_tx),
    .rx_byte(spi_rx), .done(spi_done), .busy(spi_busy),
    .spi_clk(spi_clk), .spi_mosi(spi_mosi), .spi_miso(spi_miso)
);

// ── States ────────────────────────────────────────────────────────────────────
typedef enum logic [3:0] {
    ST_PWRUP,       // 10 × 0xFF with CS=1
    ST_TX6,         // send 6-byte command (reused for every command)
    ST_C0_POLL,     // poll for CMD0  R1 = 0x01
    ST_C8_POLL,     // poll for CMD8  R1 (any non-0xFF)
    ST_C8_SKIP,     // discard 4 trailing R7 bytes
    ST_C55_POLL,    // poll for CMD55 R1 (ignored)
    ST_C41_POLL,    // poll for CMD41 R1 = 0x00; retry if 0x01
    ST_READY,
    ST_RD_POLL,     // poll for CMD17 R1 = 0x00
    ST_RD_TOKEN,    // poll for data token 0xFE
    ST_RD_DATA,     // stream 512 data bytes
    ST_RD_CRC,      // discard 2 CRC bytes, then rd_done
    ST_ERROR
} st_t;

st_t       st, tx6_next;
reg [2:0]  tx6_idx;
reg [9:0]  byte_cnt;
reg [11:0] retry;
reg [7:0]  cmd [0:5];

// Macro-free inline send: set these then the always block fires spi_start
// We use a local wire so we can send in one assignment:
// Pattern in every polling state:
//   if (!spi_busy && !spi_start) begin
//     spi_tx <= 8'hFF; spi_start <= 1;   // clock out a byte
//     if (spi_done) begin ... end         // process the previous byte
//   end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st        <= ST_PWRUP;
        tx6_next  <= ST_C0_POLL;
        ready     <= 1'b0;   error    <= 1'b0;
        spi_cs_n  <= 1'b1;   spi_fast <= 1'b0;
        spi_start <= 1'b0;   spi_tx   <= 8'hFF;
        rd_valid  <= 1'b0;   rd_done  <= 1'b0;  rd_byte <= 8'hFF;
        tx6_idx   <= 3'd0;   byte_cnt <= 10'd0;
        retry     <= 12'd0;
        for (int i = 0; i < 6; i++) cmd[i] <= 8'hFF;
    end else begin
        spi_start <= 1'b0;
        rd_valid  <= 1'b0;
        rd_done   <= 1'b0;

        case (st)

        // ── 10 × 0xFF (CS=1) → 80 init clocks ───────────────────────────────
        ST_PWRUP:
            if (!spi_busy && !spi_start) begin
                if (byte_cnt < 10) begin
                    spi_tx <= 8'hFF; spi_start <= 1'b1;
                    byte_cnt <= byte_cnt + 1;
                end else begin
                    spi_cs_n <= 1'b0;
                    byte_cnt <= 10'd0;
                    // CMD0: GO_IDLE_STATE
                    cmd[0]<=8'h40; cmd[1]<=8'h00; cmd[2]<=8'h00;
                    cmd[3]<=8'h00; cmd[4]<=8'h00; cmd[5]<=8'h95;
                    tx6_idx <= 3'd0; tx6_next <= ST_C0_POLL;
                    st <= ST_TX6;
                end
            end

        // ── Send cmd[0..5], then go to tx6_next ──────────────────────────────
        ST_TX6:
            if (!spi_busy && !spi_start) begin
                if (tx6_idx < 6) begin
                    spi_tx <= cmd[tx6_idx]; spi_start <= 1'b1;
                    tx6_idx <= tx6_idx + 1;
                end else begin
                    retry <= 12'd0;
                    st    <= tx6_next;
                end
            end

        // ── CMD0: expect R1 = 0x01 ────────────────────────────────────────────
        ST_C0_POLL:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if (spi_rx == 8'h01) begin
                        // CMD8: SEND_IF_COND (VHS=1, check=0xAA)
                        cmd[0]<=8'h48; cmd[1]<=8'h00; cmd[2]<=8'h00;
                        cmd[3]<=8'h01; cmd[4]<=8'hAA; cmd[5]<=8'h87;
                        tx6_idx <= 3'd0; tx6_next <= ST_C8_POLL;
                        st <= ST_TX6;
                    end else if (retry > 12'd255) st <= ST_ERROR;
                    else retry <= retry + 1;
                end
            end

        // ── CMD8: grab R1, then skip 4 R7 bytes ──────────────────────────────
        ST_C8_POLL:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if (spi_rx != 8'hFF) begin
                        byte_cnt <= 10'd0; st <= ST_C8_SKIP;
                    end else if (retry > 12'd255) st <= ST_ERROR;
                    else retry <= retry + 1;
                end
            end

        ST_C8_SKIP:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if (byte_cnt < 3) byte_cnt <= byte_cnt + 1;
                    else begin
                        // CMD55: APP_CMD
                        cmd[0]<=8'h77; cmd[1]<=8'h00; cmd[2]<=8'h00;
                        cmd[3]<=8'h00; cmd[4]<=8'h00; cmd[5]<=8'h65;
                        tx6_idx <= 3'd0; tx6_next <= ST_C55_POLL;
                        st <= ST_TX6;
                    end
                end
            end

        // ── CMD55: consume R1, proceed to CMD41 ───────────────────────────────
        ST_C55_POLL:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if (spi_rx != 8'hFF) begin
                        // CMD41: SD_SEND_OP_COND (HCS=1)
                        cmd[0]<=8'h69; cmd[1]<=8'h40; cmd[2]<=8'h00;
                        cmd[3]<=8'h00; cmd[4]<=8'h00; cmd[5]<=8'h77;
                        tx6_idx <= 3'd0; tx6_next <= ST_C41_POLL;
                        st <= ST_TX6;
                    end else if (retry > 12'd255) st <= ST_ERROR;
                    else retry <= retry + 1;
                end
            end

        // ── CMD41: R1=0x00 → done; R1=0x01 → retry CMD55/41 ─────────────────
        ST_C41_POLL:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if      (spi_rx == 8'h00) begin
                        spi_fast <= 1'b1; ready <= 1'b1; st <= ST_READY;
                    end
                    else if (spi_rx == 8'h01) begin
                        if (retry > 12'd4000) st <= ST_ERROR;
                        else begin
                            retry <= retry + 1;
                            cmd[0]<=8'h77; cmd[1]<=8'h00; cmd[2]<=8'h00;
                            cmd[3]<=8'h00; cmd[4]<=8'h00; cmd[5]<=8'h65;
                            tx6_idx <= 3'd0; tx6_next <= ST_C55_POLL;
                            st <= ST_TX6;
                        end
                    end
                    else if (spi_rx != 8'hFF) st <= ST_ERROR;
                end
            end

        // ── Wait for rd_req ───────────────────────────────────────────────────
        ST_READY:
            if (rd_req) begin
                cmd[0] <= 8'h51;
                cmd[1] <= rd_lba[31:24]; cmd[2] <= rd_lba[23:16];
                cmd[3] <= rd_lba[15:8];  cmd[4] <= rd_lba[7:0];
                cmd[5] <= 8'hFF;
                tx6_idx <= 3'd0; tx6_next <= ST_RD_POLL;
                retry <= 12'd0;
                st <= ST_TX6;
            end

        // ── CMD17: poll for R1 = 0x00 ────────────────────────────────────────
        ST_RD_POLL:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if      (spi_rx == 8'h00) begin retry <= 12'd0; st <= ST_RD_TOKEN; end
                    else if (spi_rx != 8'hFF)      st <= ST_ERROR;
                    else if (retry > 12'd255)       st <= ST_ERROR;
                    else                            retry <= retry + 1;
                end
            end

        // ── Poll for data token 0xFE ──────────────────────────────────────────
        ST_RD_TOKEN:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if      (spi_rx == 8'hFE)    begin byte_cnt <= 10'd0; st <= ST_RD_DATA; end
                    else if (retry > 12'd2000)    st <= ST_ERROR;
                    else                          retry <= retry + 1;
                end
            end

        // ── Stream 512 bytes ─────────────────────────────────────────────────
        ST_RD_DATA:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    rd_valid <= 1'b1;
                    rd_byte  <= spi_rx;
                    if (byte_cnt == 10'd511) begin byte_cnt <= 10'd0; st <= ST_RD_CRC; end
                    else                          byte_cnt <= byte_cnt + 1;
                end
            end

        // ── Discard 2 CRC bytes, signal done ─────────────────────────────────
        ST_RD_CRC:
            if (!spi_busy && !spi_start) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1;
                if (spi_done) begin
                    if (byte_cnt < 1) byte_cnt <= byte_cnt + 1;
                    else begin rd_done <= 1'b1; st <= ST_READY; end
                end
            end

        ST_ERROR: error <= 1'b1;
        default:  st <= ST_ERROR;
        endcase
    end
end

endmodule
