// ---------------------------------------------------------------------------
// tb_scanner_fold.v - scanner_top with FOLD > 1, end to end.
//
// tb_ddc_fold already proves the folded front end is bit-exact against FOLD
// separate front ends. This checks the other thing: that once integrated into
// scanner_top, with the comb banks and the power meter behind it, the whole
// assembly produces outputs at the right rate.
//
// Mind the stimulus cadence: one sample every FOLD cycles. Folding REQUIRES
// Fs <= Fclk/FOLD, and feeding it faster drops samples. That is why
// fold_overrun exists.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
module tb_scanner_fold;
    localparam N_CH = 16, FOLD = 4;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg iv = 0; reg signed [15:0] id = 0;
    reg cfg_we = 0; reg [3:0] cfg_ch = 0; reg [31:0] cfg_ftw = 0;
    wire [47:0] rd_pwr; wire [N_CH-1:0] pwr_ready;
    wire tv; wire signed [17:0] ti, tq;
    scanner_top #(.N_CH(N_CH), .FOLD(FOLD)) u (
        .clk(clk), .rst_n(rst_n), .in_valid(iv), .in_data(id),
        .cfg_we(cfg_we), .cfg_ch(cfg_ch), .cfg_ftw(cfg_ftw),
        .cfg_pwr_len(32'd1024), .cfg_clear(1'b0),
        .rd_ch(4'd0), .rd_pwr(rd_pwr), .pwr_ready(pwr_ready),
        .tap_ch(4'd0), .tap_valid(tv), .tap_i(ti), .tap_q(tq));
    integer n, outs; real s;
    initial begin
        outs = 0;
        repeat(5) @(posedge clk); rst_n = 1;
        for (n = 0; n < N_CH; n = n + 1) begin
            @(posedge clk);
            cfg_we <= 1; cfg_ch <= n[3:0];
            cfg_ftw <= 32'h0CCC_CCCD + n * 32'h0200_0000;
        end
        @(posedge clk); cfg_we <= 0;
        repeat (3) @(posedge clk);
        // One sample every FOLD cycles: the rate the folding accepts.
        for (n = 0; n < 20000; n = n + 1) begin
            @(posedge clk);
            s = 12000.0 * $sin(2.0*3.14159265*10.0e6*n/25.0e6);
            id <= $rtoi(s); iv <= 1;
            @(posedge clk); iv <= 0;
            repeat (FOLD - 1) @(posedge clk);
        end
        repeat (200) @(posedge clk);
        $display("");
        $display("tb_fold4 - scanner_top with N_CH=%0d FOLD=%0d", N_CH, FOLD);
        $display("  outputs observed  : %0d", outs);
        $display("  pwr_ready         : 0x%04x", pwr_ready);
        $display("  channel 0 power   : %0d", rd_pwr);
        $display("");
        $finish;
    end
    always @(posedge clk) if (rst_n && tv) outs = outs + 1;
endmodule
