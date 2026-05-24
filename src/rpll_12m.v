// Gowin rPLL: 27 MHz → 12 MHz (USB HID host)
//
// Formula (UG286E v2.0.2E): FOUT = FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1) = 27*4/9 = 12 MHz
// VCO  = FCLKIN*(FBDIV_SEL+1)*ODIV_SEL/(IDIV_SEL+1) = 27*4*48/9 = 576 MHz (500-1250 MHz ✓)
// CLKIN must be on pin 4 (LPLL1_T_in) — same as rpll_135m; both PLLs share this clock source.

module rpll_12m (
    input  wire clk_in,
    output wire clk_12m,
    output wire locked
);

wire clkoutp_nc, clkoutd_nc, clkoutd3_nc;
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
    .CLKOUT   (clk_12m),
    .CLKOUTP  (clkoutp_nc),
    .CLKOUTD  (clkoutd_nc),
    .CLKOUTD3 (clkoutd3_nc)
);

defparam rpll_inst.FCLKIN           = "27";
defparam rpll_inst.DYN_IDIV_SEL     = "false";
defparam rpll_inst.IDIV_SEL         = 8;
defparam rpll_inst.DYN_FBDIV_SEL    = "false";
defparam rpll_inst.FBDIV_SEL        = 3;
defparam rpll_inst.DYN_ODIV_SEL     = "false";
defparam rpll_inst.ODIV_SEL         = 48;
defparam rpll_inst.PSDA_SEL         = "0000";
defparam rpll_inst.DYN_DA_EN        = "true";
defparam rpll_inst.DUTYDA_SEL       = "1000";
defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL        = "internal";
defparam rpll_inst.CLKOUT_BYPASS    = "false";
defparam rpll_inst.CLKOUTP_BYPASS   = "false";
defparam rpll_inst.CLKOUTD_BYPASS   = "false";
defparam rpll_inst.DYN_SDIV_SEL     = 2;
defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";
defparam rpll_inst.DEVICE           = "GW2AR-18C";

endmodule
