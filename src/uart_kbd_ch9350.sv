// uart_kbd_ch9350.sv — hardware CH9350 keyboard front-end (Stage 1, decoupled from SDRAM)
//
// Purpose: produce the held Atari/HID key state directly in hardware, so the keyboard never
// depends on the PicoRV32 softcore (which runs from SDRAM and competes with the Atari core in the
// SDRAM arbiter). See docs/hw_keyboard_decouple.md for the full rationale.
//
// Taps the same UART RX wire the firmware uses (pin 51 / usb_dp, 115200 8N1). Mirrors:
//   - the half-bit-centered RX sampling of src/simpleuart.v
//   - the CH9350 frame parser in firmware/firmware.c uart_keyboard_poll() (byte-for-byte):
//       frame = 0x57 0xAB <cmd> <len> <data[len]>, data[len-1] = additive checksum of data[0..len-2]
//       keyboard report when (cmd==0x88 || cmd==0x83) and data[0]==0x10:
//         modifier=data[1], (data[2] reserved), key1=data[3], key2=data[4], key3=data[5], key4=data[6]
//   - a 1 s watchdog that clears keys if no valid report arrives (prevents a stuck key)
//
// Single clock domain (sys_clk, 27 MHz). CDC into the core clock is done in tang_top.sv.

module uart_kbd_ch9350 #(
    parameter int CLK_HZ     = 27_000_000,
    parameter int BAUD       = 115200,
    parameter int TIMEOUT_MS = 1000          // clear keys after this long with no packet
)(
    input  wire       clk,                   // sys_clk 27 MHz
    input  wire       reset_n,
    input  wire       uart_rx,               // shared pin 51 (usb_dp), raw async input

    output reg  [7:0] kbd_mod,               // held HID modifier bitmap
    output reg  [7:0] kbd_key1,
    output reg  [7:0] kbd_key2,
    output reg  [7:0] kbd_key3,
    output reg  [7:0] kbd_key4
);

    localparam int DIV      = CLK_HZ / BAUD;   // ~234 (matches firmware reg_uart_clkdiv)
    localparam int MS_TICKS = CLK_HZ / 1000;   // 27000 clocks per millisecond

    // ── Input synchronizer (async pin → clk) ─────────────────────────────────
    reg rx_m, rx_s;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) {rx_s, rx_m} <= 2'b11;     // idle line is high
        else          {rx_s, rx_m} <= {rx_m, uart_rx};
    end

    // ── UART RX FSM (mirrors src/simpleuart.v recv path) ─────────────────────
    // state 0: wait for start bit; state 1: wait half a bit to land mid-bit;
    // states 2..9: sample 8 data bits LSB-first; state 10: stop bit, latch byte.
    reg [3:0]  rx_state;
    reg [16:0] rx_divcnt;
    reg [7:0]  rx_pattern;
    reg [7:0]  rx_byte;
    reg        rx_strobe;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_state   <= 4'd0;
            rx_divcnt  <= 17'd0;
            rx_pattern <= 8'd0;
            rx_byte    <= 8'd0;
            rx_strobe  <= 1'b0;
        end else begin
            rx_divcnt <= rx_divcnt + 17'd1;
            rx_strobe <= 1'b0;
            case (rx_state)
                4'd0: begin                              // idle, look for start bit
                    if (!rx_s) rx_state <= 4'd1;
                    rx_divcnt <= 17'd0;
                end
                4'd1: begin                              // center on first data bit
                    if ({rx_divcnt, 1'b0} > DIV) begin   // 2*divcnt > DIV  → divcnt > DIV/2
                        rx_state  <= 4'd2;
                        rx_divcnt <= 17'd0;
                    end
                end
                4'd10: begin                             // stop bit → latch
                    if (rx_divcnt > DIV) begin
                        rx_byte   <= rx_pattern;
                        rx_strobe <= 1'b1;
                        rx_state  <= 4'd0;
                    end
                end
                default: begin                           // states 2..9 sample data bits
                    if (rx_divcnt > DIV) begin
                        rx_pattern <= {rx_s, rx_pattern[7:1]};
                        rx_state   <= rx_state + 4'd1;
                        rx_divcnt  <= 17'd0;
                    end
                end
            endcase
        end
    end

    // ── CH9350 frame parser + held key state + watchdog ──────────────────────
    localparam [2:0] S_IDLE = 3'd0,
                     S_AB   = 3'd1,
                     S_CMD  = 3'd2,
                     S_LEN  = 3'd3,
                     S_DATA = 3'd4;

    reg [2:0]  st;
    reg [7:0]  ch_cmd;
    reg [4:0]  ch_len, ch_idx;
    reg [7:0]  ch_sum;                          // running additive checksum of data[0..len-2]
    reg [7:0]  d0, d1, d3, d4, d5, d6;          // captured report bytes (d2 reserved, ignored)

    reg [16:0] ms_div;
    reg [10:0] ms_cnt;                          // 0..TIMEOUT_MS (<=2047)

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            st       <= S_IDLE;
            ch_cmd   <= 8'd0;
            ch_len   <= 5'd0;
            ch_idx   <= 5'd0;
            ch_sum   <= 8'd0;
            d0<=8'd0; d1<=8'd0; d3<=8'd0; d4<=8'd0; d5<=8'd0; d6<=8'd0;
            kbd_mod<=8'd0; kbd_key1<=8'd0; kbd_key2<=8'd0; kbd_key3<=8'd0; kbd_key4<=8'd0;
            ms_div   <= 17'd0;
            ms_cnt   <= 11'd0;
        end else begin
            // NO key auto-clear: a held key must last as long as it's held. The CH9350
            // transmits only on CHANGE (key-down / key-up), so a held key never refreshes
            // — a watchdog clear would wrongly "release" it after ~1 s. Keys are cleared
            // instead by the actual key-up report (d3..d6 = 0 on release), below. ms_cnt
            // kept (saturating) only as a since-last-packet counter.
            if (ms_div >= MS_TICKS-1) begin
                ms_div <= 17'd0;
                if (ms_cnt < TIMEOUT_MS) ms_cnt <= ms_cnt + 11'd1;
            end else begin
                ms_div <= ms_div + 17'd1;
            end

            // Frame parser, advanced on each received byte. (Key-update / ms_cnt writes below
            // are sequenced after the watchdog block, so a valid report always wins this cycle.)
            if (rx_strobe) begin
                case (st)
                    S_IDLE: if (rx_byte == 8'h57) st <= S_AB;
                    S_AB:   if      (rx_byte == 8'hAB) st <= S_CMD;
                            else if (rx_byte != 8'h57) st <= S_IDLE;   // stay in S_AB on repeated 0x57
                    S_CMD:  begin ch_cmd <= rx_byte; st <= S_LEN; end
                    S_LEN:  begin
                                ch_len <= rx_byte[4:0];
                                ch_idx <= 5'd0;
                                ch_sum <= 8'd0;
                                if (rx_byte >= 8'd1 && rx_byte <= 8'd16) st <= S_DATA;
                                else                                     st <= S_IDLE;
                            end
                    S_DATA: begin
                                if (ch_idx == ch_len - 5'd1) begin
                                    // final byte = checksum
                                    if ((ch_sum == rx_byte || (ch_sum - d0) == rx_byte) &&
                                        (ch_cmd == 8'h88 || ch_cmd == 8'h83) &&
                                        (d0 == 8'h10 || d0 == 8'h11)) begin
                                        kbd_mod  <= d1;
                                        kbd_key1 <= d3;
                                        kbd_key2 <= d4;
                                        kbd_key3 <= d5;
                                        kbd_key4 <= d6;
                                        ms_cnt   <= 11'd0;   // reload watchdog
                                    end
                                    st <= S_IDLE;
                                end else begin
                                    ch_sum <= ch_sum + rx_byte;
                                    case (ch_idx)
                                        5'd0: d0 <= rx_byte;
                                        5'd1: d1 <= rx_byte;
                                        5'd3: d3 <= rx_byte;
                                        5'd4: d4 <= rx_byte;
                                        5'd5: d5 <= rx_byte;
                                        5'd6: d6 <= rx_byte;
                                        default: ;
                                    endcase
                                    ch_idx <= ch_idx + 5'd1;
                                end
                            end
                    default: st <= S_IDLE;
                endcase
            end
        end
    end

endmodule
