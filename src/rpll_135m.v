// Gowin rPLL wrapper: 27 MHz → 135 MHz for HDMI OSER10 (5× pixel clock)
// FOUT = FIN * (FBDIV_SEL+2) / ((IDIV_SEL+1) * ODIV_SEL)
//      = 27  * (18+2)       / ((0+1)          * 4       ) = 135 MHz
// VCO  = 27  * 20 / 1 = 540 MHz  (in-range for GW2AR-18: 400–900 MHz)

module rpll_135m (
    input  wire clk_in,
    output wire clk_135m,
    output wire locked
);

rPLL #(
    .FCLKIN         ("27"),
    .IDIV_SEL       (0),
    .FBDIV_SEL      (18),
    .ODIV_SEL       (4),
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
    .CLKOUT  (clk_135m),
    .CLKOUTP (),
    .CLKOUTD (),
    .CLKOUTD3()
);

endmodule
