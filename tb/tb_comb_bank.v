// ---------------------------------------------------------------------------
// tb_comb_bank.v - Equivalence between replicated and shared combs.
//
// It does not compare against golden vectors but against the already-verified
// RTL itself: it instantiates N_UNIT cic_decim (the reference, which passes
// tb_ddc_channel) and one comb_bank fed with the same data, and checks they
// produce exactly the same thing.
//
// This is the test that has to pass for the multiplexing to be legitimate: the
// values have to be bit-identical. The only thing allowed to change is WHEN
// each unit comes out.
//
// Each unit gets a DIFFERENT sequence, so that any state crossing between
// units is immediately obvious.
//
// Run with XSim:
//     xvlog -sv -i vectors ../rtl/cic_decim.v ../rtl/comb_bank.v \
//                          ../tb/tb_comb_bank.v
//     xelab tb_comb_bank -s tb_cb
//     xsim tb_cb -runall
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tb_comb_bank;

    localparam integer N_UNIT = 8;      // units to compare
    localparam integer IN_W   = 18;     // = MIX_W, the mixer output
    localparam integer N      = 3;
    localparam integer R      = 64;
    localparam integer ACC_W  = 36;
    localparam integer UW     = $clog2(N_UNIT);
    localparam integer N_STIM = 3072;
    localparam integer SETTLE = 2;      // initial rounds that get ignored

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg signed [IN_W-1:0] stim [0:N_STIM-1];

    // ---- Reference: N_UNIT independent cic_decim ---------------------------
    reg                     in_valid = 1'b0;
    reg signed [IN_W-1:0]   in_data [0:N_UNIT-1];

    wire [N_UNIT-1:0]        ref_valid;
    wire signed [ACC_W-1:0]  ref_data  [0:N_UNIT-1];
    wire signed [ACC_W-1:0]  ref_ilast [0:N_UNIT-1];

    wire [N_UNIT*ACC_W-1:0] din_flat;

    genvar g;
    generate
        for (g = 0; g < N_UNIT; g = g + 1) begin : gen_ref
            cic_decim #(.IN_W(IN_W), .N(N), .R(R), .ACC_W(ACC_W)) u_cic (
                .clk (clk), .rst_n (rst_n),
                .in_valid (in_valid), .in_data (in_data[g]),
                .out_valid (ref_valid[g]), .out_data (ref_data[g])
            );
            // The value the cic hands to its combs. That is what the shared
            // bank has to receive.
            assign ref_ilast[g] = gen_ref[g].u_cic.tap;
            assign din_flat[g*ACC_W +: ACC_W] = ref_ilast[g];
        end
    endgenerate

    wire start = gen_ref[0].u_cic.dec_now;

    // ---- Unit under test: a single set of combs ----------------------------
    wire                     bank_valid;
    wire [UW-1:0]            bank_unit;
    wire signed [ACC_W-1:0]  bank_data;

    comb_bank #(.N_UNIT(N_UNIT), .N(N), .ACC_W(ACC_W)) dut (
        .clk (clk), .rst_n (rst_n),
        .start (start), .din_flat (din_flat),
        .out_valid (bank_valid), .out_unit (bank_unit), .out_data (bank_data)
    );

    // ---- Capturing the reference -------------------------------------------
    reg signed [ACC_W-1:0] ref_hold [0:N_UNIT-1];
    reg [31:0]             ref_round [0:N_UNIT-1];
    reg [31:0]             round = 32'd0;

    integer c;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (c = 0; c < N_UNIT; c = c + 1) begin
                ref_hold[c]  <= {ACC_W{1'b0}};
                ref_round[c] <= 32'd0;
            end
            round <= 32'd0;
        end else begin
            if (start) round <= round + 1;
            for (c = 0; c < N_UNIT; c = c + 1)
                if (ref_valid[c]) begin
                    ref_hold[c]  <= ref_data[c];
                    ref_round[c] <= round;
                end
        end
    end

    // ---- Comparison, one cycle later so ref_hold is already in place -------
    reg                     bv_d = 1'b0;
    reg [UW-1:0]            bu_d = {UW{1'b0}};
    reg signed [ACC_W-1:0]  bd_d = {ACC_W{1'b0}};

    integer errors  = 0;
    integer checked = 0;
    integer per_unit [0:N_UNIT-1];

    initial for (c = 0; c < N_UNIT; c = c + 1) per_unit[c] = 0;

    always @(posedge clk) begin
        bv_d <= bank_valid;
        bu_d <= bank_unit;
        bd_d <= bank_data;

        if (rst_n && bv_d && round > SETTLE) begin
            checked = checked + 1;
            per_unit[bu_d] = per_unit[bu_d] + 1;
            if (bd_d !== ref_hold[bu_d]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  unit %0d round %0d: reference %0d, bank %0d",
                             bu_d, round, ref_hold[bu_d], bd_d);
            end
        end
    end

    // ---- Stimulus: a different sequence per unit ---------------------------
    integer si, k;
    initial begin
        $readmemh("vectors/stim.hex", stim);
        for (k = 0; k < N_UNIT; k = k + 1) in_data[k] = {IN_W{1'b0}};

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        for (si = 0; si < N_STIM; si = si + 1) begin
            in_valid <= 1'b1;
            for (k = 0; k < N_UNIT; k = k + 1)
                in_data[k] <= stim[(si + k*37) % N_STIM];
            @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (200) @(posedge clk);

        report_and_finish;
    end

    integer min_per_unit;
    task report_and_finish;
        begin
            min_per_unit = per_unit[0];
            for (c = 1; c < N_UNIT; c = c + 1)
                if (per_unit[c] < min_per_unit) min_per_unit = per_unit[c];
            $display("");
            $display("tb_comb_bank   (%0d units on a single set of combs)", N_UNIT);
            $display("  decimation rounds : %0d", round);
            $display("  compared          : %0d", checked);
            $display("  per unit (min)    : %0d", min_per_unit);
            $display("  mismatches        : %0d", errors);
            $display("");
            if (min_per_unit < 8)
                $display("RESULT: FAIL - some unit was barely compared (%0d).", min_per_unit);
            else if (errors == 0)
                $display("RESULT: PASS - the shared combs give the same thing, bit for bit.");
            else
                $display("RESULT: FAIL - %0d mismatches", errors);
            $display("");
            $finish;
        end
    endtask

endmodule

`default_nettype wire
