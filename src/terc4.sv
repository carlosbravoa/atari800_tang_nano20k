// TERC4 encoder — HDMI data island channel encoding (HDMI 1.3 §5.4.3)
// Maps 4-bit input to 10-bit TMDS-like codeword (DC-balanced, transition minimised).
module terc4 (
    input  wire [3:0] d,
    output reg  [9:0] q
);
always_comb case (d)
    4'h0: q = 10'b1010011100;
    4'h1: q = 10'b1001100011;
    4'h2: q = 10'b1011100100;
    4'h3: q = 10'b1011100010;
    4'h4: q = 10'b0101110001;
    4'h5: q = 10'b0100011110;
    4'h6: q = 10'b0110001110;
    4'h7: q = 10'b0100111100;
    4'h8: q = 10'b1011001100;
    4'h9: q = 10'b0100111001;
    4'ha: q = 10'b0110011100;
    4'hb: q = 10'b1011000110;
    4'hc: q = 10'b1010001110;
    4'hd: q = 10'b1001110001;
    4'he: q = 10'b0101100011;
    4'hf: q = 10'b1011000011;
endcase
endmodule
