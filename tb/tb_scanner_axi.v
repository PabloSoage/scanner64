// ---------------------------------------------------------------------------
// tb_scanner_axi.v - The AXI4-Lite interface testbench.
//
// It exists for one specific reason: on the KV260, reading through /dev/mem,
// ONLY the offsets that were multiples of 16 answered (0x00 ID, 0x10 SRC_SH,
// 0x20 RD_CH, 0x30 SMP_LO, 0x40 TAP_I) and the rest returned zero. Writes did
// get through -- the scanner started -- so the fault was on the read side.
//
// The block design was fine (AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 7), so the
// question is whether the RTL itself reproduces the fault. This testbench acts
// as an AXI4-Lite master and reads all 20 registers. If they all come out
// right here, the problem is outside the module; if the same pattern shows up,
// it is inside.
//
//     xvlog *.v && xelab -debug typical tb_scanner_axi -s a && xsim a -R
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_scanner_axi;

    localparam integer N_CH   = 8;
    localparam integer ADDR_W = 7;
    localparam [31:0]  MAGIC  = 32'h5CA4_4E64;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    reg  [ADDR_W-1:0] awaddr;
    reg               awvalid;
    wire              awready;
    reg  [31:0]       wdata;
    reg  [3:0]        wstrb;
    reg               wvalid;
    wire              wready;
    wire [1:0]        bresp;
    wire              bvalid;
    reg               bready;
    reg  [ADDR_W-1:0] araddr;
    reg               arvalid;
    wire              arready;
    wire [31:0]       rdata;
    wire [1:0]        rresp;
    wire              rvalid;
    reg               rready;

    scanner_axi #(.N_CH (N_CH), .C_S_AXI_ADDR_WIDTH (ADDR_W)) dut (
        .s_axi_aclk (clk), .s_axi_aresetn (rst_n),
        .s_axi_awaddr (awaddr), .s_axi_awprot (3'd0),
        .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb),
        .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arprot (3'd0),
        .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp),
        .s_axi_rvalid (rvalid), .s_axi_rready (rready));

    // ---- AXI4-Lite master --------------------------------------------------
    // The important part: arvalid is held until the slave asserts arready,
    // which is what the protocol demands and what the real interconnect does.

    task axi_read(input [31:0] a, output reg [31:0] d);
    begin
        @(posedge clk);
        araddr  <= a[ADDR_W-1:0];
        arvalid <= 1'b1;
        rready  <= 1'b1;
        begin : ar_hs
            forever begin
                @(posedge clk);
                if (arready) begin
                    arvalid <= 1'b0;
                    disable ar_hs;
                end
            end
        end
        begin : r_hs
            forever begin
                @(posedge clk);
                if (rvalid) begin
                    d = rdata;
                    disable r_hs;
                end
            end
        end
        @(posedge clk);
        rready <= 1'b0;
    end
    endtask

    task axi_write(input [31:0] a, input [31:0] v);
    begin
        @(posedge clk);
        awaddr  <= a[ADDR_W-1:0];
        awvalid <= 1'b1;
        wdata   <= v;
        wstrb   <= 4'hF;
        wvalid  <= 1'b1;
        bready  <= 1'b1;
        begin : aw_hs
            forever begin
                @(posedge clk);
                if (awready && wready) begin
                    awvalid <= 1'b0;
                    wvalid  <= 1'b0;
                    disable aw_hs;
                end
            end
        end
        begin : b_hs
            forever begin
                @(posedge clk);
                if (bvalid) disable b_hs;
            end
        end
        @(posedge clk);
        bready <= 1'b0;
    end
    endtask

    // ---- The test ----------------------------------------------------------
    integer i, errors;
    reg [31:0] v, expected;
    reg [8*12-1:0] nm;

    function [8*12-1:0] reg_name(input integer k);
        case (k)
            0: reg_name = "ID";        1: reg_name = "CTRL";
            2: reg_name = "SRC_FTWA";  3: reg_name = "SRC_FTWB";
            4: reg_name = "SRC_SH";    5: reg_name = "CFG_CH";
            6: reg_name = "CFG_FTW";   7: reg_name = "PWR_LEN";
            8: reg_name = "RD_CH";     9: reg_name = "PWR_LO";
           10: reg_name = "PWR_HI";   11: reg_name = "READY";
           12: reg_name = "SMP_LO";   13: reg_name = "SMP_HI";
           14: reg_name = "OUT_CNT";  15: reg_name = "NCH";
           16: reg_name = "TAP_I";    17: reg_name = "TAP_Q";
           18: reg_name = "TAP_CNT";  default: reg_name = "-";
        endcase
    endfunction

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        errors = 0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("");
        $display("Reading all 19 registers after reset");
        $display("  off  idx  name         read         expected");
        for (i = 0; i < 19; i = i + 1) begin
            axi_read(i * 4, v);
            case (i)
                0:  expected = MAGIC;
                2:  expected = 32'h1999_999A;
                3:  expected = 32'h2666_6666;
                4:  expected = 32'h0000_0022;
                7:  expected = 32'd1024;
                15: expected = N_CH;
                default: expected = 32'd0;      // the rest read zero while stopped
            endcase
            nm = reg_name(i);
            if (v !== expected) begin
                $display("  0x%02h  %2d  %-11s 0x%08h   0x%08h   <-- WRONG",
                         i*4, i, nm, v, expected);
                errors = errors + 1;
            end else begin
                $display("  0x%02h  %2d  %-11s 0x%08h   0x%08h",
                         i*4, i, nm, v, expected);
            end
        end

        $display("");
        $display("Write and read back every RW register");
        for (i = 2; i <= 8; i = i + 1) begin
            axi_write(i * 4, 32'hC0DE0000 | (i << 4) | 8'h0A);
            axi_read (i * 4, v);
            expected = 32'hC0DE0000 | (i << 4) | 8'h0A;
            if (i == 4) expected = {20'd0, expected[11:0]};   // SRC_SH: 12 bits
            nm = reg_name(i);
            if (v !== expected) begin
                $display("  0x%02h  %-11s wrote 0x%08h  read 0x%08h  <-- WRONG",
                         i*4, nm, 32'hC0DE0000 | (i << 4) | 8'h0A, v);
                errors = errors + 1;
            end else begin
                $display("  0x%02h  %-11s written and read back 0x%08h  OK",
                         i*4, nm, v);
            end
        end

        $display("");
        if (errors == 0)
            $display("RESULT: PASS. The RTL decodes all 19 registers correctly.");
        else
            $display("RESULT: FAIL, %0d mismatches. The fault is in the RTL.",
                     errors);
        $display("");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT: the master hung waiting for a handshake.");
        $finish;
    end

endmodule

`default_nettype wire
