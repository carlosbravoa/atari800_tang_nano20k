// Gowin rPLL: 27 MHz → 12 MHz for USB HID host (low-speed USB requires 12 MHz)
// FOUT = FIN * (FBDIV_SEL+2) / ((IDIV_SEL+1) * ODIV_SEL)
//      = 27  * (62+2)        / ((2+1)          * 48      ) = 12 MHz
// VCO  = 27  * 64 / 3 = 576 MHz  (in-range for GW2AR-18: 400–900 MHz)

module rpll_12m (
    input  wire clk_in,
    output wire clk_12m,
    output wire locked
);

rPLL #(
    .FCLKIN         ("27"),
    .IDIV_SEL       (2),
    .FBDIV_SEL      (62),
    .ODIV_SEL       (48),
    .DYN_IDIV_SEL   ("false"),
    .DYN_FBDIV_SEL  ("false"),
    .DYN_ODIV_SEL   ("false"),
    .PSDA_SEL       ("0000"),
    .DYN_DA_EN      ("false"),
    .DUTYDA_SEL     ("1000"),
    .CLKOUT_FT_DIR  (1'b1),
    .CLKOUTP_FT_DIR (1'b1),
    .CLKOUT_DLY_STEP(0),
    .CLKOUTP_DLY_STEP(0),
    .CLKFB_SEL      ("internal"),
    .CLKOUT_BYPASS  ("false"),
    .CLKOUTP_BYPASS ("false"),
    .CLKOUTD_BYPASS ("false"),
    .CLKOUTD_SRC    ("CLKOUT"),
    .CLKOUTD3_SRC   ("CLKOUT"),
    .DEVICE         ("GW2AR-18C")
) rpll_inst (
    .CLKIN   (clk_in),
    .CLKFB   (1'b0),
    .FBDSEL  (6'b0),
    .IDSEL   (6'b0),
    .ODSEL   (6'b0),
    .PSDA    (4'b0),
    .DUTYDA  (4'b0),
    .LOCK    (locked),
    .CLKOUT  (clk_12m),
    .CLKOUTP (),
    .CLKOUTD (),
    .CLKOUTD3()
);

endmodule
