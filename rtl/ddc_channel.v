// ---------------------------------------------------------------------------
// ddc_channel.v - One complete down-conversion channel.
//
//   x[n] --> [delay] --> (x) --> CIC I --> >> --> I
//                         ^
//                      NCO cos/sin
//                         v
//            [delay] --> (x) --> CIC Q --> >> --> Q
//
// Cost per channel, MEASURED by out-of-context synthesis
// (Vivado 2026.1, xck26-sfvc784-2LV-c, a single channel):
//   3 DSP48E2     the initial estimate of 2 fell short
//   1 BRAM tile   2x RAMB18E2: the NCO LUT, today NOT shared
//   600 CLB LUT   the CIC accumulators, which do not use DSPs
//   677 FF
//   Fmax 220 MHz  post-synthesis with T=10 ns. Optimistic: not yet routed.
//
// The critical resource is NOT the multipliers. Ceilings on the ZU5EV:
//   by DSP    1248 / 3   = 416 channels
//   by LUT    117120/600 = 195 channels
//   by BRAM   144 / 1    = 144 channels   <-- the real wall
//
// Sharing the NCO LUT between channels is the only thing that moves that
// ceiling.
//
// Since the split into pieces, this is ddc_front (NCO + mixer + integrators)
// plus two comb_chain and the normalisation. In a bank of many channels you
// want NOT to use this module but ddc_front + comb_bank, which shares the
// combs between channels. See the README.
//
// Verified: tb_ddc_channel compares against the golden vectors from
// model/ddc_model.py. 0 mismatches.
// ---------------------------------------------------------------------------

`default_nettype none

module ddc_channel #(
    parameter integer IN_W       = 16,
    parameter integer OUT_W      = 18,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter integer CIC_GROWTH = 18,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [PHASE_W-1:0]         ftw,        // frequency tuning word
    input  wire                       in_valid,
    input  wire signed [IN_W-1:0]     in_data,
    output wire                       out_valid,
    output wire signed [OUT_W-1:0]    out_i,
    output wire signed [OUT_W-1:0]    out_q
);

    // ---- Input-rate part: NCO, mixer and integrators -----------------------
    wire                    dec_now;
    wire signed [CIC_W-1:0] tap_i, tap_q;

    ddc_front #(
        .IN_W (IN_W), .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W (LUT_W), .MIX_W (MIX_W), .CIC_N (CIC_N), .CIC_R (CIC_R),
        .CIC_W (CIC_W), .LUT_FILE (LUT_FILE)
    ) u_front (
        .clk (clk), .rst_n (rst_n), .ftw (ftw),
        .in_valid (in_valid), .in_data (in_data),
        .dec_now (dec_now), .tap_i (tap_i), .tap_q (tap_q)
    );

    // ---- Its own combs, at the decimated rate ------------------------------
    wire                    cic_valid_i, cic_valid_q;
    wire signed [CIC_W-1:0] cic_i, cic_q;

    comb_chain #(.N (CIC_N), .ACC_W (CIC_W)) u_comb_i (
        .clk (clk), .rst_n (rst_n),
        .dec_now (dec_now), .din (tap_i),
        .out_valid (cic_valid_i), .out_data (cic_i)
    );

    comb_chain #(.N (CIC_N), .ACC_W (CIC_W)) u_comb_q (
        .clk (clk), .rst_n (rst_n),
        .dec_now (dec_now), .din (tap_q),
        .out_valid (cic_valid_q), .out_data (cic_q)
    );

    // ---- Normalisation ------------------------------------------------------
    // The CIC gain is exactly (R*M)^N = 2^CIC_GROWTH, so an arithmetic shift
    // is enough. No divisions anywhere.
    assign out_valid = cic_valid_i;
    assign out_i     = cic_i[CIC_GROWTH +: OUT_W];
    assign out_q     = cic_q[CIC_GROWTH +: OUT_W];

endmodule

`default_nettype wire
