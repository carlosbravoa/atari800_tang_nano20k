// First-order sigma-delta DAC — 16-bit signed PCM → 1-bit PDM output.
// At 27 MHz the quantisation noise is shaped above ~13 kHz; a simple RC
// low-pass filter (1 kΩ + 10 nF, Fc ≈ 15.9 kHz) recovers the analogue signal.
//
// Conversion: flip the sign bit to produce unsigned offset-binary,
// then accumulate; the carry is the PDM output.

module sigma_delta_dac (
    input  wire        clk,
    input  wire [15:0] audio_in,   // signed two's-complement
    output reg         dac_out
);

wire [15:0] uin = {~audio_in[15], audio_in[14:0]};
reg  [15:0] acc;

always_ff @(posedge clk)
    {dac_out, acc} <= acc + uin;

endmodule
