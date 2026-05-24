// Minimal blink test: counter + PLL.
// sys_clk MUST be on pin 4 (LPLL1_T_in) — pin 10 adds GCLK buffer jitter that prevents PLL lock.
// leds_n[0]=pin16=LPLL2_C_fb and leds_n[5]=pin15=LPLL2_T_fb must NOT be driven.
// This module only drives leds_n[4:1] (pins 20,19,18,17).
module tang_top (
    input  wire        sys_clk,
    input  wire [1:0]  btn_n,
    output wire [4:1]  leds_n
);

// Both PLLs for sys_clk_d distribution to all 4 quadrants.
wire clk_5x,  pll_locked;
wire clk_usb, pll_usb_locked;
rpll_135m pll     (.clk_in(sys_clk), .clk_135m(clk_5x),  .locked(pll_locked));
rpll_12m  pll_usb (.clk_in(sys_clk), .clk_12m (clk_usb), .locked(pll_usb_locked));

// Counter A: sys_clk (27 MHz) — blinks LED3 at ~1.2 s if oscillator is running.
reg [25:0] cnt_sys = 26'h0;
always @(posedge sys_clk) cnt_sys <= cnt_sys + 1'b1;

// Counter B: clk_5x (135 MHz PLL output) — blinks LED based on PLL lock state.
// At 135 MHz locked:  cnt_pll[26] half-cycle = 2^26/135e6 = 0.50 s → ~1.0 s blink
// At ~3.375 MHz (unlocked fallback, CLKIN/8): cnt_pll[26] half-cycle = 19.9 s → ~20 s blink
reg [26:0] cnt_pll = 27'h0;
always @(posedge clk_5x) cnt_pll <= cnt_pll + 1'b1;

// leds_n[4:1] active-low (0=ON, 1=OFF):
// [4] pin20  ~pll_locked  ON = PLL locked
// [3] pin19  ~cnt_pll[26] ~1.0 s blink if PLL locked at 135 MHz; ~20 s if unlocked
// [2] pin18  ~cnt_sys[23] ~0.62 s blink (sys_clk on pin 4 confirm)
// [1] pin17  constant OFF (confirms new bitstream is running)
assign leds_n = {~pll_locked, ~cnt_pll[26], ~cnt_sys[23], 1'b1};

endmodule
