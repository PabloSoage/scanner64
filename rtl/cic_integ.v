// ---------------------------------------------------------------------------
// cic_integ.v - Integrator half of the CIC, running at the input rate.
//
// Split out of cic_decim so the two halves of the filter can be handled
// separately, because they run at very different rates:
//
//   - the integrators process ONE SAMPLE PER CYCLE. They live here, and they
//     have to be replicated per channel: there is no way to share them.
//   - the combs process one sample every R cycles. They live in comb_chain
//     (one per unit) or in comb_bank (one shared between many), and that is
//     what lets more channels fit in the same chip.
//
// THE INTEGRATORS' WRAPAROUND OVERFLOW IS INTENTIONAL. They overflow and the
// combs undo it exactly, as long as ACC_W >= IN_W + N*log2(R*M). Adding
// saturation here BREAKS the filter. It is the classic mistake when porting a
// CIC.
//
// Requires N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

module cic_integ #(
    parameter integer IN_W  = 18,
    parameter integer N     = 3,      // stages
    parameter integer R     = 64,     // decimation factor
    parameter integer ACC_W = 36      // = IN_W + N*log2(R*M)
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    in_valid,
    input  wire signed [IN_W-1:0]  in_data,

    // Decimation pulse: on this cycle `tap` carries the sample that counts.
    output wire                    dec_now,
    // The value the last stage WILL have once it has absorbed the current
    // sample. The model reads it on that same cycle, so it has to be
    // anticipated. It is one combinational adder, not a chain.
    output wire signed [ACC_W-1:0] tap
);

    localparam integer CNT_W = $clog2(R);

    wire signed [ACC_W-1:0] in_ext = {{(ACC_W-IN_W){in_data[IN_W-1]}}, in_data};

    reg signed [ACC_W-1:0] integ [0:N-1];
    reg [CNT_W-1:0]        cnt;

    assign tap     = integ[N-1] + integ[N-2];
    assign dec_now = in_valid && (cnt == R[CNT_W-1:0] - 1'b1);

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1)
                integ[i] <= {ACC_W{1'b0}};
            cnt <= {CNT_W{1'b0}};
        end else if (in_valid) begin
            integ[0] <= integ[0] + in_ext;
            for (i = 1; i < N; i = i + 1)
                integ[i] <= integ[i] + integ[i-1];   // PREVIOUS value: registered

            cnt <= dec_now ? {CNT_W{1'b0}} : (cnt + 1'b1);
        end
    end

endmodule

`default_nettype wire
