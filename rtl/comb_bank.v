// ---------------------------------------------------------------------------
// comb_bank.v - CIC combs, multiplexed between several units.
//
// WHY THIS MODULE EXISTS
//
// The CIC integrators run at the input rate, but the combs run at the
// DECIMATED rate: with R=64 they work one cycle in 64 and sit idle 98 % of the
// time. Replicating them per channel, the way cic_decim does, wastes 216 LUTs
// and 360 FFs per channel, measured on the KV260.
//
// Here there is ONE set of combs serving N_UNIT units in turns. A "unit" is an
// I or Q chain, so one channel consumes two.
//
// HOW IT WORKS
//
// Every channel decimates on the same cycle, because they share the input
// stream and the counter. So on the `start` pulse the N_UNIT samples are
// captured all at once and then processed one at a time, over the following
// N_UNIT cycles. Since decimation repeats every R cycles, you need
// N_UNIT + 1 < R for the round to finish before the next one: with R=64 the
// safe default is 32 units, that is, 16 channels per bank.
//
// Each unit's state lives in an array indexed by turn. MEASURED on the KV260,
// N_UNIT=32: 2034 LUTs and 7001 FFs per bank, that is 127 LUTs and 438 FFs per
// channel, against the 216 LUTs and 360 FFs per channel the replicated combs
// cost. The bulk of those 2034 LUTs are NOT the adders (4 subtractions of
// 36 bits, ~144 LUTs) but the 32:1 multiplexers that read the array by index.
//
// That is why the state is not forced into LUTRAM: distributed memory comes
// out of the same LUT budget and the saving would be negative. Leaving it in
// flip-flops, which are plentiful (234 k on the chip), is the right call here.
//
// THE ROUND RUNS IN TWO STAGES, and that is not a whim.
//
// The first version did read-compute-write in a single cycle, and the result
// was a critical path running from the turn counter all the way to the power
// meter DSPs, with 84 % of the delay in WIRING: 5.148 ns of routing against
// 0.951 ns of logic. The 32:1 multiplexers force the signal to cross half the
// chip. Post-route, the design topped out at 144 MHz.
//
// Splitting the round in two isolates the array read into its own stage, and
// the mux no longer shares a cycle with the subtraction or with whatever comes
// after it:
//
//     stage A   reads unit u's state and registers it
//     stage B   subtracts, writes the new state and emits the sample
//
// There is no collision hazard: on any cycle stage A reads unit u and stage B
// writes u-1, which are different. Each unit is touched once per round. The
// cost is one more cycle of latency and a round of N_UNIT+1 cycles instead of
// N_UNIT, so now you need N_UNIT+1 < R.
//
// The next avenue, should the area ever need to come down, is to put the state
// in BRAM and go to three stages. Not done.
//
// EQUIVALENCE WITH cic_decim
//
// With input d for unit u, and its state cv[] / cp[], one round does:
//
//     prev[0]   = d                 prev[j] = cv[j-1]  for j >= 1
//     cv_new[j] = prev[j] - cp[j]   cp_new[j] = prev[j]
//     output    = cv_new[N-1]
//
// which is exactly what the comb block of cic_decim does, except the
// "previous" value comes from memory instead of a register. The last stage is
// not stored: it is the output.
//
// What DOES change is WHEN each unit comes out: unit u comes out u cycles
// after the decimation, not all of them at once. The values are bit-identical;
// they are only reordered in time.
//
// Requires N >= 2 and N_UNIT + 1 < R.
// ---------------------------------------------------------------------------

`default_nettype none

module comb_bank #(
    parameter integer N_UNIT = 32,    // units served (2 per channel)
    parameter integer N      = 3,     // comb stages
    parameter integer ACC_W  = 36
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Decimation pulse: there are N_UNIT new samples in din_flat.
    input  wire                          start,
    input  wire [N_UNIT*ACC_W-1:0]       din_flat,

    // One output per cycle for as long as the round lasts.
    output reg                           out_valid,
    output reg  [$clog2(N_UNIT)-1:0]     out_unit,
    output reg  signed [ACC_W-1:0]       out_data
);

    localparam integer UW = $clog2(N_UNIT);

    // ---- Per-unit state ----------------------------------------------------
    // Asynchronous read on purpose: that way the round fits in one cycle per
    // unit, with no memory pipeline. The price is the read multiplexers.
    reg signed [ACC_W-1:0] buf_in [0:N_UNIT-1];
    reg signed [ACC_W-1:0] cv     [0:N-2][0:N_UNIT-1];  // stages 0..N-2
    reg signed [ACC_W-1:0] cp     [0:N-1][0:N_UNIT-1];  // stages 0..N-1

    reg          busy;
    reg [UW-1:0] u;

    // The state starts at zero through `initial`, NOT through a reset loop.
    // That is deliberate: a reset that sweeps the whole array forces Vivado to
    // put the state in flip-flops (measured: 7001 FFs) instead of distributed
    // LUTRAM. With `initial` the initialisation travels in the bitstream,
    // which is how distributed memory gets initialised on a real FPGA.
    //
    // A consequence to keep in mind: a warm reset does NOT clear the comb
    // state. After an rst_n the filter drags its previous state along for a
    // few rounds. If that matters in your system, flush the bank by pushing N
    // rounds of zeros through it before trusting the output.
    integer ii, jj;
    initial begin
        for (ii = 0; ii < N_UNIT; ii = ii + 1) begin
            buf_in[ii] = {ACC_W{1'b0}};
            for (jj = 0; jj < N-1; jj = jj + 1) cv[jj][ii] = {ACC_W{1'b0}};
            for (jj = 0; jj < N;   jj = jj + 1) cp[jj][ii] = {ACC_W{1'b0}};
        end
    end

    // ---- Stage A: read unit u's state --------------------------------------
    // prev[j] is the value stage j consumes: the input for the first one, and
    // the PREVIOUS value of the stage before it for the rest.
    // These are the expensive multiplexers, and now they get the cycle to
    // themselves.
    wire signed [ACC_W-1:0] prev_c [0:N-1];
    wire signed [ACC_W-1:0] cp_c   [0:N-1];

    genvar gj;
    generate
        assign prev_c[0] = buf_in[u];
        for (gj = 1; gj < N; gj = gj + 1) begin : gen_prev
            assign prev_c[gj] = cv[gj-1][u];
        end
        for (gj = 0; gj < N; gj = gj + 1) begin : gen_cp
            assign cp_c[gj] = cp[gj][u];
        end
    endgenerate

    reg                    a_valid;
    reg [UW-1:0]           a_unit;
    reg signed [ACC_W-1:0] a_prev [0:N-1];
    reg signed [ACC_W-1:0] a_cp   [0:N-1];

    // ---- Stage B: the subtraction, operands already registered -------------
    wire signed [ACC_W-1:0] cv_nx [0:N-1];
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin : gen_cvnx
            assign cv_nx[gj] = a_prev[gj] - a_cp[gj];
        end
    endgenerate

    integer k, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            u         <= {UW{1'b0}};
            a_valid   <= 1'b0;
            a_unit    <= {UW{1'b0}};
            out_valid <= 1'b0;
            out_unit  <= {UW{1'b0}};
            out_data  <= {ACC_W{1'b0}};
        end else begin
            a_valid   <= 1'b0;
            out_valid <= 1'b0;

            // --- Stage A ---------------------------------------------------
            if (start) begin
                for (k = 0; k < N_UNIT; k = k + 1)
                    buf_in[k] <= din_flat[k*ACC_W +: ACC_W];
                busy <= 1'b1;
                u    <= {UW{1'b0}};
            end else if (busy) begin
                a_valid <= 1'b1;
                a_unit  <= u;
                for (j = 0; j < N; j = j + 1) begin
                    a_prev[j] <= prev_c[j];
                    a_cp[j]   <= cp_c[j];
                end

                if (u == N_UNIT[UW-1:0] - 1'b1) begin
                    busy <= 1'b0;
                    u    <= {UW{1'b0}};
                end else begin
                    u <= u + 1'b1;
                end
            end

            // --- Stage B ---------------------------------------------------
            // Writes unit a_unit, the one before whatever A is reading.
            if (a_valid) begin
                for (j = 0; j < N-1; j = j + 1) cv[j][a_unit] <= cv_nx[j];
                for (j = 0; j < N;   j = j + 1) cp[j][a_unit] <= a_prev[j];

                out_data  <= cv_nx[N-1];
                out_unit  <= a_unit;
                out_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
