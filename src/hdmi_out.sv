// HDMI/DVI output for Tang Nano 20K
// Uses Gowin OSER10 (10:1 serialiser) and ELVDS_OBUF (differential driver).
// Pixel clock  = 27 MHz  (clk_pix)
// Serialiser clock = 5 × 27 = 135 MHz (clk_5x)

module hdmi_out (
    input  wire       clk_pix,    // pixel clock (27 MHz)
    input  wire       clk_5x,     // 5 × pixel clock (135 MHz)
    input  wire       rst_n,

    // Video from Atari core
    input  wire [7:0] r, g, b,
    input  wire       hs,         // horizontal sync (active low from core)
    input  wire       vs,         // vertical sync (active low from core)
    input  wire       de,         // display enable (= ~VIDEO_BLANK)

    // TMDS differential outputs
    output wire [2:0] tmds_p,
    output wire [2:0] tmds_n,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n
);

// ── TMDS encoding ─────────────────────────────────────────────────────────────
wire [9:0] tmds_r, tmds_g, tmds_b;

tmds_encoder enc_b (.clk(clk_pix), .d(b), .de(de), .c0(hs), .c1(vs), .q(tmds_b));
tmds_encoder enc_g (.clk(clk_pix), .d(g), .de(de), .c0(1'b0), .c1(1'b0), .q(tmds_g));
tmds_encoder enc_r (.clk(clk_pix), .d(r), .de(de), .c0(1'b0), .c1(1'b0), .q(tmds_r));

// ── Serialisation (OSER10: 10:1, DDR, so FCLK = 5 × PCLK) ───────────────────
wire [3:0] ser_out;   // [0]=B [1]=G [2]=R [3]=CLK

// Data channels
genvar i;
generate
    for (i = 0; i < 3; i++) begin : gen_data
        wire [9:0] tdata = (i==0) ? tmds_b : (i==1) ? tmds_g : tmds_r;
        OSER10 oser_inst (
            .D0(tdata[0]), .D1(tdata[1]), .D2(tdata[2]), .D3(tdata[3]),
            .D4(tdata[4]), .D5(tdata[5]), .D6(tdata[6]), .D7(tdata[7]),
            .D8(tdata[8]), .D9(tdata[9]),
            .FCLK(clk_5x), .PCLK(clk_pix), .RESET(!rst_n),
            .Q(ser_out[i])
        );
        ELVDS_OBUF bufd (
            .I(ser_out[i]),
            .O(tmds_p[i]),
            .OB(tmds_n[i])
        );
    end
endgenerate

// Clock channel: constant 10'b1111100000 → 5 lows then 5 highs at FCLK rate
// = square wave at FCLK/10 = pixel clock frequency
OSER10 oser_clk (
    .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0), .D4(1'b0),
    .D5(1'b1), .D6(1'b1), .D7(1'b1), .D8(1'b1), .D9(1'b1),
    .FCLK(clk_5x), .PCLK(clk_pix), .RESET(!rst_n),
    .Q(ser_out[3])
);
ELVDS_OBUF bufc (
    .I(ser_out[3]),
    .O(tmds_clk_p),
    .OB(tmds_clk_n)
);

endmodule
