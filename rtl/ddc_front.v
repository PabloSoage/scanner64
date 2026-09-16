// ---------------------------------------------------------------------------
// ddc_front.v - The part of a DDC channel that runs at the input rate.
//
//   x[n] --> [delay] --> (x) --> I integrators --> tap_i
//                         ^
//                      NCO cos/sin
//                         v
//            [delay] --> (x) --> Q integrators --> tap_q
//
// This is ddc_channel WITHOUT the combs. It exists because the combs run at
// 1/R of this rate, and sharing them between channels (comb_bank) beats
// replicating one per unit.
//
// If you want a complete, self-contained channel, use ddc_channel, which is
// this plus two comb_chain and the normalisation.
//
// MEASURED cost per channel (OOC synthesis, Vivado 2026.1,
// xck26-sfvc784-2LV-c): 486 LUTs, 461 FFs, 3 DSP48E2 and half a BRAM tile,
// against the 703 LUTs and 821 FFs of a channel with its own combs.
// ---------------------------------------------------------------------------

`default_nettype none

module ddc_front #(
    parameter integer IN_W       = 16,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [PHASE_W-1:0]        ftw,        // frequency tuning word
    input  wire                      in_valid,
    input  wire signed [IN_W-1:0]    in_data,

    // Decimation pulse and the two values that feed the combs.
    output wire                      dec_now,
    output wire signed [CIC_W-1:0]   tap_i,
    output wire signed [CIC_W-1:0]   tap_q
);

    // ---- NCO ---------------------------------------------------------------
    wire signed [LUT_W-1:0] cos_v, sin_v;

    nco #(
        .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W (LUT_W), .LUT_FILE (LUT_FILE)
    ) u_nco (
        .clk (clk), .rst_n (rst_n), .en (in_valid),
        .ftw (ftw), .cos_o (cos_v), .sin_o (sin_v)
    );

    // ---- Sample delay, to line it up with the NCO output --------------------
    // max_fanout forces Vivado to REPLICATE this register instead of sharing a
    // single one between all channels. They all register the same in_data, so
    // the tool merges them on its own and leaves one signal with a fanout of
    // N_CH crossing the chip to the DSP of every mixer: measured, 66 % of the
    // critical path was routing for that reason. Replicated, each copy gets
    // placed next to its own DSP.
    (* max_fanout = 8 *) reg signed [IN_W-1:0] x_d1;
    (* max_fanout = 8 *) reg                   v_d1;

    // ---- Complex mixer, in two stages ---------------------------------------
    // The shift by LUT_W-1 undoes the LUT scaling (32767 ~ 1.0). At the
    // saturation point you DO have to saturate: wrapping around makes clicks.
    //
    // WHY IT IS SPLIT IN TWO. Doing product, shift and saturation in the same
    // cycle, the path crosses the whole DSP48 chain (pre-adder, multiplier,
    // ALU, output) and the saturation LUTs on top: measured, 10 levels and
    // 3.452 ns of logic, 60 % of the critical path. Registering the product
    // leaves the DSP with its own chain and the saturation with its own.
    //
    // It costs one more cycle of latency in the channel. It costs nothing
    // else: the input and output registers of the DSP48 were already there,
    // unused.
    localparam signed [MIX_W-1:0] MIX_MAX =  (1 <<< (MIX_W-1)) - 1;
    localparam signed [MIX_W-1:0] MIX_MIN = -(1 <<< (MIX_W-1));

    wire signed [IN_W+LUT_W-1:0] prod_i = x_d1 * cos_v;
    wire signed [IN_W+LUT_W-1:0] prod_q = -x_d1 * sin_v;

    // --- Stage 1: the product ------------------------------------------------
    reg signed [IN_W+LUT_W-1:0] prod_i_r, prod_q_r;
    reg                         prod_valid;

    // --- Stage 2: shift and saturation ---------------------------------------
    wire signed [IN_W+LUT_W-1:0] shr_i = prod_i_r >>> (LUT_W-1);
    wire signed [IN_W+LUT_W-1:0] shr_q = prod_q_r >>> (LUT_W-1);

    reg signed [MIX_W-1:0] mix_i, mix_q;
    reg                    mix_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            x_d1       <= {IN_W{1'b0}};
            v_d1       <= 1'b0;
            prod_i_r   <= {(IN_W+LUT_W){1'b0}};
            prod_q_r   <= {(IN_W+LUT_W){1'b0}};
            prod_valid <= 1'b0;
            mix_i      <= {MIX_W{1'b0}};
            mix_q      <= {MIX_W{1'b0}};
            mix_valid  <= 1'b0;
        end else begin
            x_d1 <= in_data;
            v_d1 <= in_valid;

            prod_i_r   <= prod_i;
            prod_q_r   <= prod_q;
            prod_valid <= v_d1;

            mix_i <= (shr_i > MIX_MAX) ? MIX_MAX :
                     (shr_i < MIX_MIN) ? MIX_MIN : shr_i[MIX_W-1:0];
            mix_q <= (shr_q > MIX_MAX) ? MIX_MAX :
                     (shr_q < MIX_MIN) ? MIX_MIN : shr_q[MIX_W-1:0];
            mix_valid <= prod_valid;
        end
    end

    // ---- Integrators --------------------------------------------------------
    // Both share in_valid, so their dec_now is the same. The one from the I
    // branch is the one that gets used.
    wire dec_q_unused;

    cic_integ #(.IN_W(MIX_W), .N(CIC_N), .R(CIC_R), .ACC_W(CIC_W)) u_int_i (
        .clk (clk), .rst_n (rst_n),
        .in_valid (mix_valid), .in_data (mix_i),
        .dec_now (dec_now), .tap (tap_i)
    );

    cic_integ #(.IN_W(MIX_W), .N(CIC_N), .R(CIC_R), .ACC_W(CIC_W)) u_int_q (
        .clk (clk), .rst_n (rst_n),
        .in_valid (mix_valid), .in_data (mix_q),
        .dec_now (dec_q_unused), .tap (tap_q)
    );

endmodule

`default_nettype wire
