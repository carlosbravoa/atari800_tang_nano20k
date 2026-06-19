// Gowin rPLL: 114.75 MHz (clk_108m) → 286.875 MHz (HDMI TMDS serialiser clock)
//
// Phase A "720-line" mode: clk_pix = clk_5x/5 = 286.875/5 = 57.375 MHz = 2*clk_core, locked
// to the Atari frame. Output is a custom 1216x786 raster (active 1056x720 = integer 3x of the
// Atari 352x240 frame); 1216*786 = 955776 = 2 * 477888 = exactly two-per-... no: it is exactly
// one Atari frame at the 2x pixel rate (477888 core cycles * 2 = 955776 pixel cycles) -> integer
// lines -> no jitter, 720 lines tall, sharp 3x, full borders.
//
// CASCADED off clk_108m (a PLL output), ×5/2: 114.75 * 5/2 = 286.875 MHz.
// FOUT = FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1) = 114.75*5/2 = 286.875
// VCO  = FCLKIN*(FBDIV_SEL+1)*ODIV_SEL/(IDIV_SEL+1) = 114.75*5*4/2 = 1147.5 MHz (500-1250 ✓)

module rpll_287m (
    input  wire clk_in,        // 114.75 MHz (clk_108m)
    output wire clk_287m,      // 286.875 MHz
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
    .CLKOUT   (clk_287m),
    .CLKOUTP  (clkoutp_nc),
    .CLKOUTD  (clkoutd_nc),
    .CLKOUTD3 (clkoutd3_nc)
);

defparam rpll_inst.FCLKIN          = "114.75";
defparam rpll_inst.DYN_IDIV_SEL    = "false";
defparam rpll_inst.IDIV_SEL        = 1;
defparam rpll_inst.DYN_FBDIV_SEL   = "false";
defparam rpll_inst.FBDIV_SEL       = 4;
defparam rpll_inst.DYN_ODIV_SEL    = "false";
defparam rpll_inst.ODIV_SEL        = 4;
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
