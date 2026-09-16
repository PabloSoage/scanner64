// ---------------------------------------------------------------------------
// cic_decim.v - CIC (Cascaded Integrator-Comb) decimator.
//
// N integrator stages at the high rate, decimation by R, N combs at the low
// rate. It uses NOT ONE multiplier: only adders and registers. That is what
// makes it possible to fit dozens of channels in the PL.
//
// Since the split into two pieces, this module is just the glue:
//
//     cic_integ   the integrators, at the input rate. One per unit, and there
//                 is no choice about it: they process one sample per cycle.
//     comb_chain  the combs, at the decimated rate. They work 1 cycle in R.
//
// That asymmetry is what comb_bank exploits, replacing N comb_chain with a
// single set shared in turns. See the README.
//
// The two CIC traps are documented where they belong:
//   1. the intentional wraparound overflow, in cic_integ
//   2. the registered, non-combinational cascades, in comb_chain
//
// Cycle-for-cycle equivalent to CICDecimator in model/ddc_model.py.
// Requires N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

// Arithmetic mapping: by default the adders go to CLBs. Synthesising with
// -verilog_define CIC_USE_DSP=1 sends them to the DSP48s, which carry an
// unused 48-bit accumulator. It costs 3 DSPs per CIC and saves 145 LUTs.
//
// This is not an improvement, it is a TRADE: choose according to which
// resource you have to spare in your design. The measured numbers are in the
// README, section "Pushing it properly". It does not change the function by a
// single bit, only where it is implemented.
`ifdef CIC_USE_DSP
(* use_dsp = "logic" *)
`endif
module cic_decim #(
    parameter integer IN_W  = 18,
    parameter integer N     = 3,      // stages
    parameter integer R     = 64,     // decimation factor
    parameter integer ACC_W = 36      // = IN_W + N*log2(R*M)
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       in_valid,
    input  wire signed [IN_W-1:0]     in_data,
    output wire                       out_valid,
    output wire signed [ACC_W-1:0]    out_data
);

    initial begin
        if (N < 2) begin
            $display("cic_decim: N must be >= 2");
            $finish;
        end
    end

    wire                    dec_now;
    wire signed [ACC_W-1:0] tap;

    cic_integ #(.IN_W(IN_W), .N(N), .R(R), .ACC_W(ACC_W)) u_integ (
        .clk (clk), .rst_n (rst_n),
        .in_valid (in_valid), .in_data (in_data),
        .dec_now (dec_now), .tap (tap)
    );

    comb_chain #(.N(N), .ACC_W(ACC_W)) u_comb (
        .clk (clk), .rst_n (rst_n),
        .dec_now (dec_now), .din (tap),
        .out_valid (out_valid), .out_data (out_data)
    );

endmodule

`default_nettype wire
