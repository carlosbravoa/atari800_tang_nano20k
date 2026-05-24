// Gowin rPLL: 27 MHz → 371.25 MHz (HDMI TMDS 5x clock for 720p @ 74.25 MHz pixel clock)
//
// Formula: FOUT = FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1) = 27*55/4 = 371.25 MHz
// VCO  = FOUT*ODIV_SEL = 371.25*2 = 742.5 MHz  (500–1250 MHz ✓)
// CLKIN must be on pin 4 (LPLL1_T_in) — same constraint as rpll_135m.

module rpll_371m (
    input  wire clk_in,
    output wire clk_371m,
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
    .CLKOUT   (clk_371m),
    .CLKOUTP  (clkoutp_nc),
    .CLKOUTD  (clkoutd_nc),
    .CLKOUTD3 (clkoutd3_nc)
);

defparam rpll_inst.FCLKIN          = "27";
defparam rpll_inst.DYN_IDIV_SEL    = "false";
defparam rpll_inst.IDIV_SEL        = 3;     // divide input by 4
defparam rpll_inst.DYN_FBDIV_SEL   = "false";
defparam rpll_inst.FBDIV_SEL       = 54;    // multiply by 55
defparam rpll_inst.DYN_ODIV_SEL    = "false";
defparam rpll_inst.ODIV_SEL        = 2;     // VCO/2 = 742.5/2 = 371.25 MHz
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
defparam rpll_inst.DYN_SDIV_SEL    = 2;
defparam rpll_inst.CLKOUTD_SRC     = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC    = "CLKOUT";
defparam rpll_inst.DEVICE          = "GW2AR-18C";

endmodule
