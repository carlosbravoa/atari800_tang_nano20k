// Gowin rPLL: 27 MHz → 216 MHz (CLKOUT) + 12 MHz (CLKOUTD, ÷18)
//
// FOUT = FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1) = 27*8/1 = 216 MHz
// VCO  = 27*8*4 = 864 MHz (valid range 500–1250 MHz ✓)
// CLKOUTD = CLKOUT / DYN_SDIV_SEL = 216 / 18 = 12 MHz ✓  (18 is even, required)
// 216 MHz feeds a CLKDIV÷4 in tang_top to produce clk_core = 54 MHz.
// 12 MHz is routed to the USB HID host (replaces rpll_12m which used a full PLL).
// Using a single PLL for both clocks stays within the GW2AR-18's 2-PLL limit.

module rpll_108m (
    input  wire clk_in,
    output wire clk_108m,   // 216 MHz — feeds CLKDIV÷4 → 54 MHz core clock
    output wire clk_12m,    // 12 MHz  — USB HID host
    output wire locked
);

wire clkoutp_nc, clkoutd3_nc;
wire gnd = 1'b0;

rPLL rpll_inst (
    .CLKIN    (clk_in),
    .CLKFB    (gnd),
    .RESET    (gnd),
    .RESET_P  (gnd),
    .FBDSEL   ({gnd,gnd,gnd,gnd,gnd,gnd}),
    .IDSEL    ({gnd,gnd,gnd,gnd,gnd,gnd}),
    .ODSEL    ({gnd,gnd,gnd,gnd,gnd,gnd}),
    .PSDA     ({gnd,gnd,gnd,gnd}),
    .DUTYDA   ({gnd,gnd,gnd,gnd}),
    .FDLY     ({gnd,gnd,gnd,gnd}),
    .LOCK     (locked),
    .CLKOUT   (clk_108m),
    .CLKOUTP  (clkoutp_nc),
    .CLKOUTD  (clk_12m),
    .CLKOUTD3 (clkoutd3_nc)
);

defparam rpll_inst.FCLKIN          = "27";
defparam rpll_inst.DYN_IDIV_SEL    = "false";
defparam rpll_inst.IDIV_SEL        = 0;      // divide input by 1
defparam rpll_inst.DYN_FBDIV_SEL   = "false";
defparam rpll_inst.FBDIV_SEL       = 3;      // 27*4 = 108 MHz → CLKDIV/4 = clk_core 27 MHz
defparam rpll_inst.DYN_ODIV_SEL    = "false";
defparam rpll_inst.ODIV_SEL        = 8;      // VCO = 108*8 = 864 MHz (in range)
defparam rpll_inst.PSDA_SEL        = "0000";
defparam rpll_inst.DYN_DA_EN       = "true";
defparam rpll_inst.DUTYDA_SEL      = "1000";
defparam rpll_inst.CLKOUT_FT_DIR   = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR  = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL       = "internal";
defparam rpll_inst.CLKOUT_BYPASS   = "false";
defparam rpll_inst.CLKOUTP_BYPASS  = "false";
defparam rpll_inst.CLKOUTD_BYPASS  = "false";
defparam rpll_inst.DYN_SDIV_SEL    = 18;     // CLKOUTD = 216/18 = 12 MHz (even ✓)
defparam rpll_inst.CLKOUTD_SRC     = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC    = "CLKOUT";
defparam rpll_inst.DEVICE          = "GW2AR-18C";

endmodule
