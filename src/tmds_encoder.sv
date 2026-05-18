// TMDS 8b/10b encoder per DVI 1.0 spec §2.1.2
// Single-cycle registered output.  c0/c1 carry sync (hs/vs) for blue channel;
// tie them to 0 for green and red channels.

module tmds_encoder (
    input  wire       clk,
    input  wire [7:0] d,    // pixel byte
    input  wire       de,   // display enable (1 = pixel, 0 = blanking)
    input  wire       c0,   // hs (blue channel) or 0
    input  wire       c1,   // vs (blue channel) or 0
    output reg  [9:0] q
);

// Population count for 8 bits
function automatic [3:0] cnt8;
    input [7:0] v;
    cnt8 = v[0]+v[1]+v[2]+v[3]+v[4]+v[5]+v[6]+v[7];
endfunction

// Transition-minimised word (9 bits: [8]=encoding type, [7:0]=data)
wire use_xnor = (cnt8(d) > 4) || (cnt8(d) == 4 && !d[0]);

wire [8:0] q_m;
assign q_m[0] = d[0];
assign q_m[1] = use_xnor ? ~(q_m[0] ^ d[1]) : (q_m[0] ^ d[1]);
assign q_m[2] = use_xnor ? ~(q_m[1] ^ d[2]) : (q_m[1] ^ d[2]);
assign q_m[3] = use_xnor ? ~(q_m[2] ^ d[3]) : (q_m[2] ^ d[3]);
assign q_m[4] = use_xnor ? ~(q_m[3] ^ d[4]) : (q_m[3] ^ d[4]);
assign q_m[5] = use_xnor ? ~(q_m[4] ^ d[5]) : (q_m[4] ^ d[5]);
assign q_m[6] = use_xnor ? ~(q_m[5] ^ d[6]) : (q_m[5] ^ d[6]);
assign q_m[7] = use_xnor ? ~(q_m[6] ^ d[7]) : (q_m[6] ^ d[7]);
assign q_m[8] = !use_xnor;   // 1 = XOR, 0 = XNOR

wire [3:0] n1_qm = cnt8(q_m[7:0]);
wire [3:0] n0_qm = 4'd8 - n1_qm;

reg signed [4:0] cnt; // running disparity

always_ff @(posedge clk) begin
    if (!de) begin
        // Control tokens — also reset disparity
        cnt <= '0;
        case ({c1, c0})
            2'b00: q <= 10'b1101010100;
            2'b01: q <= 10'b0010101011;
            2'b10: q <= 10'b0101010100;
            2'b11: q <= 10'b1010101011;
        endcase
    end else begin
        if (cnt == 0 || n1_qm == n0_qm) begin
            // No bias yet or balanced word: output based on encoding type
            q[9] <= ~q_m[8];
            q[8] <=  q_m[8];
            if (q_m[8]) begin
                q[7:0] <=  q_m[7:0];
                cnt    <= cnt + ($signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm}));
            end else begin
                q[7:0] <= ~q_m[7:0];
                cnt    <= cnt - ($signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm}));
            end
        end else if ((cnt > 0 && n1_qm > n0_qm) || (cnt < 0 && n0_qm > n1_qm)) begin
            // Invert to reduce disparity
            q      <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt    <= cnt + {3'b0, q_m[8], 1'b0}
                          - ($signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm}));
        end else begin
            // No invert needed
            q      <= {1'b0, q_m[8], q_m[7:0]};
            cnt    <= cnt + ($signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm}))
                          - {3'b0, ~q_m[8], 1'b0};
        end
    end
end

endmodule
