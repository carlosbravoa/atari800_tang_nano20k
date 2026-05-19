// hdmi_audio_out.sv — HDMI video + audio data islands
//
// Audio path: 48 kHz stereo PCM, N=6144 CTS=27000 @ 27 MHz pixel clock.
// Two data islands per horizontal blanking, each carrying up to 2 stereo
// sample pairs (SP0=L0, SP1=R0, SP2=L1, SP3=R1).
//
// HDMI 1.3 §5 data island timing per island:
//   8 preamble + 2 leading GB + 32 data + 2 trailing GB = 44 pixels
//
// Both HDMI audio (primary) and GPIO sigma-delta audio (tang_top.sv) coexist.

`default_nettype none

module hdmi_audio_out (
    input  wire        clk_pix,      // 27 MHz
    input  wire        clk_5x,       // 135 MHz
    input  wire        rst_n,
    // Video (active-low syncs from Atari core)
    input  wire [7:0]  r, g, b,
    input  wire        hs, vs, de,
    // Audio — 16-bit signed PCM
    input  wire [15:0] audio_l, audio_r,
    // TMDS differential outputs
    output wire [2:0]  tmds_p, tmds_n,
    output wire        tmds_clk_p, tmds_clk_n
);

// ── TMDS encoding (1-cycle registered output) ─────────────────────────────────
wire [9:0] td_b, td_g, td_r;
tmds_encoder enc_b(.clk(clk_pix),.d(b),.de(de),.c0(hs),.c1(vs),.q(td_b));
tmds_encoder enc_g(.clk(clk_pix),.d(g),.de(de),.c0(1'b0),.c1(1'b0),.q(td_g));
tmds_encoder enc_r(.clk(clk_pix),.d(r),.de(de),.c0(1'b0),.c1(1'b0),.q(td_r));

// CTL token lookup (TMDS-encoded control period, HDMI spec Table 5-7)
function automatic [9:0] ctl;
    input c1, c0;
    case ({c1,c0})
        2'b00: ctl = 10'b1101010100;
        2'b01: ctl = 10'b0010101011;
        2'b10: ctl = 10'b0101010100;
        2'b11: ctl = 10'b1010101011;
    endcase
endfunction

// ── BCH ECC: G(x) = x^8+x^4+x^3+x^2+1 (poly=0x1D), bits fed LSB-first ───────
function automatic [7:0] bch_acc;
    input [7:0] acc, data;
    integer i; reg [7:0] b; reg fb;
    b = acc;
    for (i = 0; i < 8; i = i + 1) begin
        fb = data[i] ^ b[7];
        b  = {b[6:0], 1'b0};
        if (fb) b = b ^ 8'h1D;
    end
    bch_acc = b;
endfunction

// Header BCH (3 header bytes → 1 ECC byte)
function automatic [7:0] hdr_bch;
    input [7:0] hb0, hb1, hb2;
    reg [7:0] x;
    x = bch_acc(8'h00, hb0);
    x = bch_acc(x,    hb1);
    x = bch_acc(x,    hb2);
    hdr_bch = x;
endfunction

// Sub-packet BCH (7 body bytes PB[0..6] → 1 ECC byte)
function automatic [7:0] sp_bch;
    input [55:0] body;  // body[7:0]=PB0 .. body[55:48]=PB6
    integer i; reg [7:0] x;
    x = 8'h00;
    for (i = 0; i < 7; i = i + 1)
        x = bch_acc(x, body[8*i +: 8]);
    sp_bch = x;
endfunction

// ── IEC60958 sub-frame builder: 16-bit PCM, right-justified in 24-bit field ───
// PB[0]={parity,CS=0,U=0,V=0}, PB[1]=0 (padding), PB[2]=smp[7:0], PB[3]=smp[15:8]
// PB[4..6]=0; BCH over PB[0..6].
function automatic [63:0] mksp;
    input [15:0] smp;
    reg [55:0] body; reg p; integer j;
    body = {24'd0, smp[15:8], smp[7:0], 8'h00, 8'h00}; // {PB6..PB0}
    p = 1'b0;
    for (j = 8; j < 32; j = j + 1) p = p ^ body[j]; // parity over PB[1..3]
    body[3] = p;  // PB[0][3] = parity
    mksp = {sp_bch(body), body};
endfunction

// ── ACR sub-packet constant (N=6144=0x001800, CTS=27000=0x006978) ─────────────
// Body: PB0=0, PB1=CTS[19:16]=0, PB2=CTS[15:8]=0x69, PB3=CTS[7:0]=0x78,
//       PB4=N[19:16]=0, PB5=N[15:8]=0x18, PB6=N[7:0]=0x00
// body[55:0] = {PB6,PB5,PB4,PB3,PB2,PB1,PB0} (MSB-first in concat = PB6 highest)
//            = {0x00, 0x18, 0x00, 0x78, 0x69, 0x00, 0x00}
localparam [55:0] ACR_BODY = {8'h00, 8'h18, 8'h00, 8'h78, 8'h69, 8'h00, 8'h00};
// BCH and full 64-bit sp are computed as constants by synthesis (constant folding)

// ── Packet registers (header + 4 sub-packets) ────────────────────────────────
// hdr[31:0]  = {HEC[7:0], HB2[7:0], HB1[7:0], HB0[7:0]}
// sp[k][63:0] = {BCH[7:0], PB6..PB0} (64 bits per sub-packet)
//
// Physical channel mapping at pixel i (0..31), bit index bi = 2*i:
//   ch0 TERC4: {vs,hs, hdr[bi+1] if i<16 else 0, hdr[bi] if i<16 else 0}
//   ch1 TERC4: {sp[1][bi+1], sp[1][bi], sp[0][bi+1], sp[0][bi]}
//   ch2 TERC4: {sp[3][bi+1], sp[3][bi], sp[2][bi+1], sp[2][bi]}
reg [31:0] pkt_hdr;
reg [63:0] pkt_sp [0:3];
reg [4:0]  pkt_idx;

// ── Audio FIFO (8 entries × {R[15:0], L[15:0]}) ──────────────────────────────
reg [31:0] fifo [0:7];
reg [2:0]  wr_ptr, rd_ptr;
reg [3:0]  fifo_cnt;   // 0..8

// 48 kHz tick: accumulator += 16, tick when >= 9000
// (GCD-reduced: 48000/3000=16, 27000000/3000=9000 → exact 48 kHz)
reg [13:0] smp_acc;
wire       smp_tick = (smp_acc + 14'd16 >= 14'd9000);

// ── State machine ─────────────────────────────────────────────────────────────
localparam [2:0] S_ACTIVE = 3'd0,
                 S_CTRL   = 3'd1,
                 S_PRE    = 3'd2,   // 8 pixels: data island preamble
                 S_LGB    = 3'd3,   // 2 pixels: leading guard band + packet load
                 S_DATA   = 3'd4,   // 32 pixels: TERC4 data island
                 S_TGB    = 3'd5;   // 2 pixels: trailing guard band
reg [2:0] state;
reg [5:0] cnt;
reg [1:0] isl_num;   // island counter per blanking (0..1)
reg [9:0] hbl_pos;   // pixel position since de fell
reg       de_r, vs_r;
reg       send_acr;  // set on vs falling edge, cleared after first island

wire de_fell = !de &&  de_r;
wire vs_fell = !vs &&  vs_r;   // vs active-low: fell = sync starts

always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_ACTIVE; cnt <= 6'd0; isl_num <= 2'd0;
        hbl_pos <= 10'd0; de_r <= 1'b1; vs_r <= 1'b1;
        wr_ptr <= 3'd0; rd_ptr <= 3'd0; fifo_cnt <= 4'd0;
        smp_acc <= 14'd0; send_acr <= 1'b1; pkt_idx <= 5'd0;
    end else begin
        de_r <= de;
        vs_r <= vs;

        // 48 kHz sample → FIFO write
        if (smp_tick) begin
            smp_acc <= smp_acc + 14'd16 - 14'd9000;
            if (fifo_cnt < 4'd8) begin
                fifo[wr_ptr] <= {audio_r, audio_l};
                wr_ptr       <= wr_ptr + 3'd1;
                fifo_cnt     <= fifo_cnt + 4'd1;
            end
        end else
            smp_acc <= smp_acc + 14'd16;

        if (vs_fell) send_acr <= 1'b1;

        if (de_fell) hbl_pos <= 10'd0;
        else if (!de) hbl_pos <= hbl_pos + 10'd1;

        if (state == S_DATA)
            pkt_idx <= pkt_idx + 5'd1;

        case (state)
            S_ACTIVE:
                if (de_fell) begin state <= S_CTRL; cnt <= 6'd0; isl_num <= 2'd0; end

            S_CTRL: begin
                if (de && !de_r) begin
                    state <= S_ACTIVE;
                end else begin
                    cnt <= cnt + 6'd1;
                    // Start island after 4 ctrl pixels, ≤2 islands, not too late
                    // in blanking, and something to send
                    if (cnt >= 6'd3 && isl_num < 2'd2 && hbl_pos < 10'd700 &&
                        (send_acr || fifo_cnt >= 4'd1)) begin
                        state <= S_PRE; cnt <= 6'd0;
                    end
                end
            end

            S_PRE:
                if (cnt == 6'd7) begin state <= S_LGB; cnt <= 6'd0; end
                else             cnt <= cnt + 6'd1;

            S_LGB: begin
                cnt <= cnt + 6'd1;
                if (cnt == 6'd1) begin
                    // Final guard-band pixel: load packet
                    pkt_idx <= 5'd0;
                    state   <= S_DATA;
                    cnt     <= 6'd0;
                    if (send_acr) begin
                        send_acr  <= 1'b0;
                        pkt_hdr   <= {hdr_bch(8'h01, 8'h00, 8'h00), 8'h00, 8'h00, 8'h01};
                        pkt_sp[0] <= {sp_bch(ACR_BODY), ACR_BODY};
                        pkt_sp[1] <= {sp_bch(ACR_BODY), ACR_BODY};
                        pkt_sp[2] <= {sp_bch(ACR_BODY), ACR_BODY};
                        pkt_sp[3] <= {sp_bch(ACR_BODY), ACR_BODY};
                    end else begin
                        // Build audio sample packet directly from FIFO
                        // Use fifo_cnt BEFORE decrement to determine HB1 flags
                        pkt_hdr   <= {hdr_bch(8'h02,
                                        (fifo_cnt >= 4'd2) ? 8'h3D : 8'h0D,
                                        8'h01),
                                      8'h01,
                                      (fifo_cnt >= 4'd2) ? 8'h3D : 8'h0D,
                                      8'h02};
                        pkt_sp[0] <= mksp(fifo[rd_ptr][15:0]);
                        pkt_sp[1] <= mksp(fifo[rd_ptr][31:16]);
                        if (fifo_cnt >= 4'd2) begin
                            pkt_sp[2] <= mksp(fifo[rd_ptr + 3'd1][15:0]);
                            pkt_sp[3] <= mksp(fifo[rd_ptr + 3'd1][31:16]);
                            rd_ptr    <= rd_ptr + 3'd2;
                            fifo_cnt  <= fifo_cnt - 4'd2;
                        end else begin
                            pkt_sp[2] <= 64'd0;
                            pkt_sp[3] <= 64'd0;
                            rd_ptr    <= rd_ptr + 3'd1;
                            fifo_cnt  <= fifo_cnt - 4'd1;
                        end
                    end
                end
            end

            S_DATA:
                if (cnt == 6'd31) begin state <= S_TGB; cnt <= 6'd0; end
                else              cnt <= cnt + 6'd1;

            S_TGB: begin
                if (cnt == 6'd1) begin
                    isl_num <= isl_num + 2'd1;
                    state   <= S_CTRL; cnt <= 6'd0;
                end else cnt <= cnt + 6'd1;
            end

            default: state <= S_CTRL;
        endcase
    end
end

// ── TERC4 instances ───────────────────────────────────────────────────────────
wire [5:0] bi = {pkt_idx, 1'b0};   // bit index within 64-bit sub-packet

wire [3:0] ch0_in = {vs, hs,
                     (pkt_idx < 5'd16) ? pkt_hdr[bi+6'd1] : 1'b0,
                     (pkt_idx < 5'd16) ? pkt_hdr[bi      ] : 1'b0};
wire [3:0] ch1_in = {pkt_sp[1][bi+6'd1], pkt_sp[1][bi],
                     pkt_sp[0][bi+6'd1], pkt_sp[0][bi]};
wire [3:0] ch2_in = {pkt_sp[3][bi+6'd1], pkt_sp[3][bi],
                     pkt_sp[2][bi+6'd1], pkt_sp[2][bi]};

wire [9:0] t0, t1, t2, tgb0;
terc4 tc0(.d(ch0_in),        .q(t0));
terc4 tc1(.d(ch1_in),        .q(t1));
terc4 tc2(.d(ch2_in),        .q(t2));
terc4 tg0(.d({vs,hs,2'b11}), .q(tgb0));  // guard-band ch0 = TERC4({vs,hs,1,1})

localparam [9:0] GUARD_CH12 = 10'b0100110011;  // data island guard band ch1/ch2

// ── Output mux (registered; state machine is 1 pixel ahead of OSER output) ───
// 1-cycle latency aligns with tmds_encoder's 1-cycle pipeline in blanking.
// Active video also inherits tmds_encoder delay (pixel appears 1 cycle after input).
reg [9:0] ob, og, or_;

always_ff @(posedge clk_pix) begin
    case (state)
        S_ACTIVE: begin ob <= td_b; og <= td_g;           or_ <= td_r; end
        S_PRE:    begin ob <= td_b; og <= ctl(1'b1,1'b0); or_ <= ctl(1'b1,1'b0); end
        S_LGB,
        S_TGB:    begin ob <= tgb0; og <= GUARD_CH12;     or_ <= GUARD_CH12; end
        S_DATA:   begin ob <= t0;   og <= t1;              or_ <= t2; end
        default:  begin ob <= td_b; og <= td_g;            or_ <= td_r; end
    endcase
end

// ── OSER10 serialisers + ELVDS differential drivers ──────────────────────────
wire [3:0] ser;
genvar i;
generate
    for (i = 0; i < 3; i = i + 1) begin : gen_ser
        wire [9:0] d10 = (i==0) ? ob : (i==1) ? og : or_;
        OSER10 oser(.D0(d10[0]),.D1(d10[1]),.D2(d10[2]),.D3(d10[3]),.D4(d10[4]),
                    .D5(d10[5]),.D6(d10[6]),.D7(d10[7]),.D8(d10[8]),.D9(d10[9]),
                    .FCLK(clk_5x),.PCLK(clk_pix),.RESET(!rst_n),.Q(ser[i]));
        ELVDS_OBUF elvds(.I(ser[i]),.O(tmds_p[i]),.OB(tmds_n[i]));
    end
endgenerate

OSER10 oser_clk(
    .D0(1'b0),.D1(1'b0),.D2(1'b0),.D3(1'b0),.D4(1'b0),
    .D5(1'b1),.D6(1'b1),.D7(1'b1),.D8(1'b1),.D9(1'b1),
    .FCLK(clk_5x),.PCLK(clk_pix),.RESET(!rst_n),.Q(ser[3]));
ELVDS_OBUF elvds_clk(.I(ser[3]),.O(tmds_clk_p),.OB(tmds_clk_n));

endmodule

`default_nettype wire
