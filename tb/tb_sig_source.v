// ---------------------------------------------------------------------------
// tb_sig_source.v - Dumps `sig_source` samples so they can be compared against
// the Python model.
//
// It exists because when checking the hardware against the model, the two
// channels with a tone matched to the bit and the two empty ones were off by
// 1 LSB on a value of 2. The suspicion was that the Python stimulus was not
// identical to the RTL one, and here it showed: `sig_source` emits ONE ZERO
// before the first good sample, because of its output register. That is,
// rtl[n] = model[n-1].
//
// That zero enters the CIC and advances the channel's NCO. It does not affect
// a channel with a tone -- its output is 4096 and the zero is lost in the
// average -- but for an empty channel it changes the result by 1 LSB, which
// there is everything.
//
// With the zero modelled, all four channels match the board exactly.
//
//     xvlog nco.v sig_source.v tb_sig_source.v
//     xelab tb_sig_source -s sigsim && xsim sigsim -R
//
// Leaves sig_rtl.txt with 300 samples, one per line.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
module tb_sig_source;
    reg clk = 0; reg rst_n = 0; reg en = 0;
    always #5 clk = ~clk;
    wire v; wire signed [15:0] d;
    integer f, n;
    sig_source #(.OUT_W(16)) u (
        .clk(clk), .rst_n(rst_n), .en(en),
        .ftw_a(32'h1999999A), .ftw_b(32'h26666666),
        .shift_a(4'd2), .shift_b(4'd2), .shift_n(4'd0), .noise_en(1'b0),
        .out_valid(v), .out_data(d));
    initial begin
        f = $fopen("sig_rtl.txt", "w");
        repeat (4) @(posedge clk);
        rst_n = 1; @(posedge clk); en = 1;
        n = 0;
        while (n < 300) begin
            @(posedge clk);
            if (v) begin $fwrite(f, "%0d\n", d); n = n + 1; end
        end
        $fclose(f); $finish;
    end
endmodule
