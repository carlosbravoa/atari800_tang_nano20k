// hdmi_audio_out.sv — Wrapper for Sameer Puri's hdl-util/hdmi transmitter
// Matches original module interface to keep connections in tang_top.sv intact.

`default_nettype none

module hdmi_audio_out #(
    parameter bit DVI_OUTPUT = 1'b0,
    parameter bit NO_DATA_ISLANDS = 1'b0
) (
    input  wire        clk_pix,      // 74.25 MHz
    input  wire        clk_5x,       // 371.25 MHz
    input  wire        rst_n,
    // Video
    input  wire [7:0]  r, g, b,
    input  wire        hs, vs, de,
    // Audio — 16-bit signed PCM
    input  wire [15:0] audio_l, audio_r,
    // TMDS differential outputs
    output wire [2:0]  tmds_p, tmds_n,
    output wire        tmds_clk_p, tmds_clk_n
);

// ── Audio sample mapping ──────────────────────────────────────────────────────
wire [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = audio_l;
assign audio_sample_word[1] = audio_r;

// ── 48 kHz sample tick generator (precise division of 74.25 MHz) ──────────────
reg [13:0] smp_acc;
wire       smp_tick = (smp_acc + 14'd8 >= 14'd12375);
always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n)
        smp_acc <= 14'd0;
    else
        smp_acc <= smp_tick ? (smp_acc + 14'd8 - 14'd12375) : (smp_acc + 14'd8);
end

// ── Reset alignment to the first active pixel of the frame ───────────────────
// This guarantees that the internally generated cx/cy coordinates align
// perfectly with the incoming video stream.
reg waiting_for_frame;
reg hdmi_reset;

always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin
        hdmi_reset        <= 1'b1;
        waiting_for_frame <= 1'b0;
    end else begin
        if (vs) begin
            // We are in VSYNC: get ready to sync on the next active frame start
            waiting_for_frame <= 1'b1;
        end else if (waiting_for_frame && de) begin
            // Pulse reset for 1 cycle at the first active pixel of the frame
            hdmi_reset        <= 1'b1;
            waiting_for_frame <= 1'b0;
        end else begin
            hdmi_reset        <= 1'b0;
        end
    end
end

// ── hdmi core instantiation ──────────────────────────────────────────────────
wire [2:0] tmds_internal;
wire       tmds_clock_internal;

hdmi #(
    .VIDEO_ID_CODE(4),              // 720p60
    .DVI_OUTPUT(DVI_OUTPUT),
    .NO_DATA_ISLANDS(NO_DATA_ISLANDS),
    .VIDEO_REFRESH_RATE(60.0),
    .AUDIO_RATE(48000),
    .AUDIO_BIT_WIDTH(16),
    .START_X(0),
    .START_Y(0)
) hdmi_core (
    .clk_pixel_x5       (clk_5x),
    .clk_pixel          (clk_pix),
    .clk_audio          (smp_tick), // 1-cycle sample clock pulse
    .reset              (hdmi_reset),
    .serializer_reset   (!rst_n),
    .hsync_in           (hs),
    .vsync_in           (vs),
    .rgb                ({r, g, b}),
    .audio_sample_word  (audio_sample_word),
    .tmds               (tmds_internal),
    .tmds_clock         (tmds_clock_internal)
);

// ── Physical differential output drivers ──────────────────────────────────────
TLVDS_OBUF tlvds_d0   (.I(tmds_internal[0]),    .O(tmds_p[0]),    .OB(tmds_n[0]));
TLVDS_OBUF tlvds_d1   (.I(tmds_internal[1]),    .O(tmds_p[1]),    .OB(tmds_n[1]));
TLVDS_OBUF tlvds_d2   (.I(tmds_internal[2]),    .O(tmds_p[2]),    .OB(tmds_n[2]));
TLVDS_OBUF tlvds_clk  (.I(tmds_clock_internal), .O(tmds_clk_p),   .OB(tmds_clk_n));

endmodule

`default_nettype wire
