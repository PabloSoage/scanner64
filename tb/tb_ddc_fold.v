// ---------------------------------------------------------------------------
// tb_ddc_fold.v - The folded front end against the original, sample by sample.
//
// ddc_fold multiplexes one set of NCO, mixer and integrators between FOLD
// channels. The only way to believe it is to compare its output against FOLD
// independent ddc_front, fed with the SAME sequence and tuned to the SAME
// frequencies, and demand that they match bit for bit.
//
// It is not enough for them to look alike. A multiplexed recursive filter
// fails in a very specific way -- reading one channel's state before the state
// from its previous turn has been written -- and that produces an output that
// still looks like a signal. Which is why the comparison is exact equality on
// every decimated output.
//
//     xvlog nco.v cic_integ.v ddc_front.v ddc_fold.v tb_ddc_fold.v
//     xelab tb_ddc_fold -s f && xsim f -R
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_ddc_fold;

    localparam integer FOLD    = 4;
    localparam integer IN_W    = 16;
    localparam integer PHASE_W = 32;
    localparam integer CIC_W   = 36;
    localparam integer CIC_R   = 64;
    localparam integer SLOT_W  = 2;
    localparam integer NSAMP   = 6000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // Four tunings spread across the band, like a real scanner.
    reg [PHASE_W-1:0] ftw [0:FOLD-1];
    initial begin
        ftw[0] = 32'h1999_999A;   // 10.0 MHz at 100 MSPS
        ftw[1] = 32'h2666_6666;   // 15.0
        ftw[2] = 32'h0CCC_CCCD;   //  5.0
        ftw[3] = 32'h3851_EB85;   // 22.0
    end

    // ---- The original: FOLD independent channels ---------------------------
    reg                    ref_valid;
    reg signed [IN_W-1:0]  ref_data;
    wire                   ref_dec  [0:FOLD-1];
    wire signed [CIC_W-1:0] ref_i   [0:FOLD-1];
    wire signed [CIC_W-1:0] ref_q   [0:FOLD-1];

    genvar g;
    generate
        for (g = 0; g < FOLD; g = g + 1) begin : gen_ref
            ddc_front #(
                .IN_W (IN_W), .PHASE_W (PHASE_W), .CIC_W (CIC_W), .CIC_R (CIC_R)
            ) u (
                .clk (clk), .rst_n (rst_n), .ftw (ftw[g]),
                .in_valid (ref_valid), .in_data (ref_data),
                .dec_now (ref_dec[g]), .tap_i (ref_i[g]), .tap_q (ref_q[g])
            );
        end
    endgenerate

    // ---- The folded one ----------------------------------------------------
    reg                     f_cfg_we;
    reg  [SLOT_W-1:0]       f_cfg_slot;
    reg  [PHASE_W-1:0]      f_cfg_ftw;
    reg                     f_valid;
    reg  signed [IN_W-1:0]  f_data;
    wire                    f_ready;
    wire                    f_out_valid;
    wire [SLOT_W-1:0]       f_out_slot;
    wire signed [CIC_W-1:0] f_tap_i, f_tap_q;

    ddc_fold #(
        .FOLD (FOLD), .IN_W (IN_W), .PHASE_W (PHASE_W),
        .CIC_W (CIC_W), .CIC_R (CIC_R)
    ) u_fold (
        .clk (clk), .rst_n (rst_n),
        .cfg_we (f_cfg_we), .cfg_slot (f_cfg_slot), .cfg_ftw (f_cfg_ftw),
        .in_valid (f_valid), .in_data (f_data), .ready (f_ready),
        .out_valid (f_out_valid), .out_slot (f_out_slot),
        .tap_i (f_tap_i), .tap_q (f_tap_q)
    );

    // ---- Output queues, one per channel ------------------------------------
    // The folded version emits the slots in order within each round and the
    // original emits them all at once, so they cannot be compared on the same
    // cycle: you have to queue per channel and compare in arrival order.
    integer ref_n [0:FOLD-1];
    integer fol_n [0:FOLD-1];
    reg signed [CIC_W-1:0] ref_qi [0:FOLD-1][0:511];
    reg signed [CIC_W-1:0] ref_qq [0:FOLD-1][0:511];

    integer errors;
    integer compared;

    // ONE LOOP VARIABLE PER BLOCK. Sharing `i` between the `always` that
    // queues and the `initial` that configures cost an afternoon: the always
    // runs on every edge and leaves i = FOLD, so the initial was reading
    // ftw[4] -- out of range, X -- and always writing into slot 0. The phases
    // did not advance, sin() came out 0 and all four slots gave the same
    // thing. It looked like a bug in the folding and it was in the testbench.
    integer i;      // the queueing block only
    integer j;      // the initial only

    // Stimulus: two summed tones, like sig_source.
    function signed [IN_W-1:0] stimulus(input integer n);
        real s;
        begin
            s = 13000.0 * $sin(2.0 * 3.14159265358979 * 10.0e6 * n / 100.0e6)
              +  9000.0 * $sin(2.0 * 3.14159265358979 * 15.0e6 * n / 100.0e6);
            stimulus = $rtoi(s);
        end
    endfunction

    // Queue whatever the original puts out.
    //
    // BLOCKING on purpose. With a non-blocking assignment the queue is written
    // at the end of the cycle and the comparison block, which reads the same
    // position on that same cycle, finds the old value -- or an X if it had
    // never been written. This is not a hardware testbench: it is the
    // testbench's own bookkeeping, and there what you need is for the effect to
    // be immediate. Only this block writes these variables, so there is no race
    // with anybody.
    always @(posedge clk) begin
        if (rst_n) begin
            for (i = 0; i < FOLD; i = i + 1) begin
                if (ref_dec[i]) begin
                    ref_qi[i][ref_n[i] % 512] = ref_i[i];
                    ref_qq[i][ref_n[i] % 512] = ref_q[i];
                    ref_n[i] = ref_n[i] + 1;
                end
            end
        end
    end

    // Compare what the folded one puts out against its channel's queue.
    always @(posedge clk) begin
        if (rst_n && f_out_valid) begin
            compared = compared + 1;
            if (f_tap_i !== ref_qi[f_out_slot][fol_n[f_out_slot] % 512] ||
                f_tap_q !== ref_qq[f_out_slot][fol_n[f_out_slot] % 512]) begin
                if (errors < 8)
                    $display("  slot %0d output %0d:  folded (%0d, %0d)  original (%0d, %0d)",
                             f_out_slot, fol_n[f_out_slot], f_tap_i, f_tap_q,
                             ref_qi[f_out_slot][fol_n[f_out_slot] % 512],
                             ref_qq[f_out_slot][fol_n[f_out_slot] % 512]);
                errors = errors + 1;
            end
            fol_n[f_out_slot] = fol_n[f_out_slot] + 1;
        end
    end

    integer n;
    initial begin
        errors = 0;
        compared = 0;
        for (j = 0; j < FOLD; j = j + 1) begin
            ref_n[j] = 0;
            fol_n[j] = 0;
        end
        ref_valid = 1'b0; ref_data = 0;
        f_valid = 1'b0;   f_data = 0;
        f_cfg_we = 1'b0;  f_cfg_slot = 0; f_cfg_ftw = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Tune the folded one the same as the original.
        for (j = 0; j < FOLD; j = j + 1) begin
            @(posedge clk);
            f_cfg_we   <= 1'b1;
            f_cfg_slot <= j[SLOT_W-1:0];
            f_cfg_ftw  <= ftw[j];
        end
        @(posedge clk);
        f_cfg_we <= 1'b0;
        repeat (2) @(posedge clk);

        // One sample every FOLD cycles: the folded one needs that gap, and the
        // original gets it on the same cycle so that the per-channel sequences
        // are identical.
        for (n = 0; n < NSAMP; n = n + 1) begin
            @(posedge clk);
            ref_data  <= stimulus(n);
            ref_valid <= 1'b1;
            f_data    <= stimulus(n);
            f_valid   <= 1'b1;
            @(posedge clk);
            ref_valid <= 1'b0;
            f_valid   <= 1'b0;
            repeat (FOLD - 1) @(posedge clk);
        end

        // Let whatever is left in the pipeline come out.
        repeat (4 * FOLD + 20) @(posedge clk);

        $display("");
        $display("tb_ddc_fold - FOLD=%0d, %0d samples", FOLD, NSAMP);
        for (j = 0; j < FOLD; j = j + 1)
            $display("  slot %0d: original %0d outputs, folded %0d",
                     j, ref_n[j], fol_n[j]);
        $display("  comparisons : %0d", compared);
        $display("  mismatches  : %0d", errors);
        $display("");
        if (errors == 0 && compared > 100)
            $display("RESULT: PASS - the folded version gives the same as %0d separate channels.", FOLD);
        else if (compared <= 100)
            $display("RESULT: INCONCLUSIVE - only %0d comparisons.", compared);
        else
            $display("RESULT: FAIL - %0d mismatches.", errors);
        $display("");
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
