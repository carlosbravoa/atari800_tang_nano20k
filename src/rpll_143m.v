// Gowin rPLL: 114.75 MHz (clk_108m) → 143.4375 MHz (HDMI TMDS serialiser clock)
//
// Phase A frequency-lock: the HDMI pixel clock must be locked to the Atari core clock so
// the 480p output is an integer number of lines per Atari frame (no ±1 jitter). clk_pix =
// clk_5x/5 = 143.4375/5 = 28.6875 MHz = clk_core. Both clk_core and clk_5x therefore derive
// from clk_108m, so the output is genlocked to the machine by construction.
//
// This is a CASCADED PLL: its input is clk_108m (a PLL output), not the 27 MHz crystal —
// 143.4375 MHz is not synthesisable directly from 27 MHz (would need FBDIV_SEL+1=85 > 64),
// but from 114.75 MHz it is a clean 5/4.
//
// Formula (UG286E v2.0.2E): FOUT = FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1) = 114.75*5/4 = 143.4375
// VCO  = FCLKIN*(FBDIV_SEL+1)*ODIV_SEL/(IDIV_SEL+1) = 114.75*5*8/4 = 1147.5 MHz (500-1250 ✓)
//
// DEVICE="GW2AR-18C": "GW2AR-18" triggers EX0206.

module rpll_143m (
    input  wire clk_in,        // 114.75 MHz (clk_108m)
    output wire clk_143m,      // 143.4375 MHz
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
    .CLKOUT   (clk_143m),
    .CLKOUTP  (clkoutp_nc),
    .CLKOUTD  (clkoutd_nc),
    .CLKOUTD3 (clkoutd3_nc)
);

defparam rpll_inst.FCLKIN          = "114.75";
defparam rpll_inst.DYN_IDIV_SEL    = "false";
defparam rpll_inst.IDIV_SEL        = 3;
defparam rpll_inst.DYN_FBDIV_SEL   = "false";
defparam rpll_inst.FBDIV_SEL       = 4;
defparam rpll_inst.DYN_ODIV_SEL    = "false";
defparam rpll_inst.ODIV_SEL        = 8;
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
