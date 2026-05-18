// spi_master.sv — byte-at-a-time SPI master (mode 0: CPOL=0, CPHA=0, MSB first)
//
// Speed = clk / (2 * DIV).  Two presets selected at runtime via fast:
//   fast=0: INIT_DIV → must be ≤400 kHz during SD card init
//   fast=1: FAST_DIV → higher speed after SD init completes
//
// At 27 MHz: INIT_DIV=34 → ~397 kHz;  FAST_DIV=4 → ~3.375 MHz
//
// Protocol timing (8 bits, SPI mode 0):
//   MOSI is set to tx_byte[7] before the first rising edge.
//   On each rising edge: MISO is sampled into rx_byte (MSB first).
//   On each falling edge (except last): MOSI is updated for the next bit.
//   done pulses for 1 cycle when all 8 bits have been exchanged.

module spi_master #(
    parameter INIT_DIV = 34,
    parameter FAST_DIV = 4
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       fast,       // 0=init speed, 1=fast speed
    input  wire       start,      // 1-cycle pulse: begin byte transfer
    input  wire [7:0] tx_byte,    // byte to transmit
    output reg  [7:0] rx_byte,    // byte received (valid when done=1)
    output reg        done,       // 1-cycle pulse: transfer complete
    output wire       busy,       // 1 while transfer in progress

    output reg        spi_clk,
    output reg        spi_mosi,
    input  wire       spi_miso
);

localparam DIV_BITS = $clog2(INIT_DIV + 1);
localparam [DIV_BITS-1:0] HDIV_INIT = DIV_BITS'(INIT_DIV - 1);
localparam [DIV_BITS-1:0] HDIV_FAST = DIV_BITS'(FAST_DIV - 1);

wire [DIV_BITS-1:0] hdiv = fast ? HDIV_FAST : HDIV_INIT;

reg [DIV_BITS-1:0] div;
reg [3:0]          edge_cnt;  // counts SPI clock edges 0..15 (8 rising + 8 falling)
reg [7:0]          tx_sr;
reg [7:0]          rx_sr;
reg                active;

assign busy = active;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        spi_clk  <= 1'b0;
        spi_mosi <= 1'b1;
        rx_byte  <= 8'hFF;
        done     <= 1'b0;
        active   <= 1'b0;
        div      <= '0;
        edge_cnt <= 4'd0;
        tx_sr    <= 8'hFF;
        rx_sr    <= 8'h00;
    end else begin
        done <= 1'b0;

        if (!active) begin
            if (start) begin
                active   <= 1'b1;
                tx_sr    <= tx_byte;
                spi_mosi <= tx_byte[7];   // MSB pre-loaded before first rising edge
                spi_clk  <= 1'b0;
                edge_cnt <= 4'd0;
                div      <= '0;
            end
        end else begin
            if (div == hdiv) begin
                div      <= '0;
                edge_cnt <= edge_cnt + 4'd1;

                if (!spi_clk) begin
                    // Rising edge: sample MISO (MSB first, so bit 7 arrives first)
                    spi_clk <= 1'b1;
                    rx_sr   <= {rx_sr[6:0], spi_miso};
                end else begin
                    // Falling edge: shift MOSI or end transfer
                    spi_clk <= 1'b0;
                    if (edge_cnt == 4'd15) begin
                        // 8th falling edge — all bits exchanged
                        active   <= 1'b0;
                        done     <= 1'b1;
                        rx_byte  <= rx_sr;    // rx_sr fully populated after 8 rising edges
                        spi_mosi <= 1'b1;
                    end else begin
                        // Shift TX left; new MSB is the next bit to send
                        // (tx_sr[6] reads the OLD value, which is the correct next bit)
                        tx_sr    <= {tx_sr[6:0], 1'b1};
                        spi_mosi <= tx_sr[6];
                    end
                end
            end else begin
                div <= div + 1'b1;
            end
        end
    end
end

endmodule
