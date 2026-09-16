// ---------------------------------------------------------------------------
// sig_source.v - Test signal generator inside the PL.
//
// With no ADC there is no antenna, so we generate the "antenna" here: two
// configurable tones plus pseudo-random noise. It is good for:
//
//   . validating the scanner with no external hardware at all;
//   . feeding it at the MAXIMUM rate the PL clock can take, which is exactly
//     what no CPU can sustain;
//   . measuring out-of-band rejection with two tones of known amplitude.
//
// The noise comes from a 32-bit LFSR (polynomial x^32+x^22+x^2+x+1). It is not
// Gaussian noise, but for checking noise floor and dynamic range it is plenty.
// ---------------------------------------------------------------------------

`default_nettype none

module sig_source #(
    parameter integer OUT_W      = 16,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      en,

    input  wire [PHASE_W-1:0]        ftw_a,      // tone A
    input  wire [PHASE_W-1:0]        ftw_b,      // tone B
    input  wire [3:0]                shift_a,    // attenuation: amplitude >> shift
    input  wire [3:0]                shift_b,
    input  wire [3:0]                shift_n,    // noise level
    input  wire                      noise_en,

    output reg                       out_valid,
    output reg  signed [OUT_W-1:0]   out_data
);

    // ---- Two NCOs ----------------------------------------------------------
    wire signed [LUT_W-1:0] cos_a, sin_a, cos_b, sin_b;

    nco #(.PHASE_W(PHASE_W), .LUT_ADDR_W(LUT_ADDR_W),
          .LUT_W(LUT_W), .LUT_FILE(LUT_FILE)) u_a (
        .clk(clk), .rst_n(rst_n), .en(en), .ftw(ftw_a),
        .cos_o(cos_a), .sin_o(sin_a)
    );

    nco #(.PHASE_W(PHASE_W), .LUT_ADDR_W(LUT_ADDR_W),
          .LUT_W(LUT_W), .LUT_FILE(LUT_FILE)) u_b (
        .clk(clk), .rst_n(rst_n), .en(en), .ftw(ftw_b),
        .cos_o(cos_b), .sin_o(sin_b)
    );

    // ---- Noise LFSR --------------------------------------------------------
    reg [31:0] lfsr;
    wire fb = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];

    always @(posedge clk) begin
        if (!rst_n)      lfsr <= 32'hACE1_2345;   // any non-zero seed will do
        else if (en)     lfsr <= {lfsr[30:0], fb};
    end

    wire signed [LUT_W-1:0] noise = noise_en ? $signed(lfsr[LUT_W-1:0])
                                             : {LUT_W{1'b0}};

    // ---- Sum with saturation -----------------------------------------------
    localparam signed [OUT_W-1:0] OUT_MAX =  (1 <<< (OUT_W-1)) - 1;
    localparam signed [OUT_W-1:0] OUT_MIN = -(1 <<< (OUT_W-1));

    wire signed [LUT_W+1:0] sum = (sin_a >>> shift_a)
                                + (sin_b >>> shift_b)
                                + (noise >>> shift_n);

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= {OUT_W{1'b0}};
        end else begin
            out_valid <= en;
            out_data  <= (sum > OUT_MAX) ? OUT_MAX :
                         (sum < OUT_MIN) ? OUT_MIN : sum[OUT_W-1:0];
        end
    end

endmodule

`default_nettype wire
