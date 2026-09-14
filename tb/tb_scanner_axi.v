// ---------------------------------------------------------------------------
// tb_scanner_axi.v — El banco de pruebas del interfaz AXI4-Lite.
//
// Existe por un motivo concreto: en la KV260, leyendo por /dev/mem, SOLO
// respondian los offsets multiplos de 16 (0x00 ID, 0x10 SRC_SH, 0x20 RD_CH,
// 0x30 SMP_LO, 0x40 TAP_I) y el resto devolvia cero. Las escrituras si
// llegaban --el escaner arrancaba-- asi que el fallo estaba en la lectura.
//
// El block design estaba bien (AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 7), asi que
// la pregunta es si el fallo lo reproduce el propio RTL. Este testbench hace de
// maestro AXI4-Lite y lee los 20 registros. Si aqui salen todos bien, el
// problema esta fuera del modulo; si sale el mismo patron, esta dentro.
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

    // ---- Maestro AXI4-Lite -------------------------------------------------
    // Lo importante: arvalid se mantiene hasta que el esclavo da arready, que
    // es lo que exige el protocolo y lo que hace el interconnect de verdad.

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

    // ---- La prueba ---------------------------------------------------------
    integer i, errores;
    reg [31:0] v, esperado;
    reg [8*12-1:0] nm;

    function [8*12-1:0] nombre(input integer k);
        case (k)
            0: nombre = "ID";        1: nombre = "CTRL";
            2: nombre = "SRC_FTWA";  3: nombre = "SRC_FTWB";
            4: nombre = "SRC_SH";    5: nombre = "CFG_CH";
            6: nombre = "CFG_FTW";   7: nombre = "PWR_LEN";
            8: nombre = "RD_CH";     9: nombre = "PWR_LO";
           10: nombre = "PWR_HI";   11: nombre = "READY";
           12: nombre = "SMP_LO";   13: nombre = "SMP_HI";
           14: nombre = "OUT_CNT";  15: nombre = "NCH";
           16: nombre = "TAP_I";    17: nombre = "TAP_Q";
           18: nombre = "TAP_CNT";  default: nombre = "-";
        endcase
    endfunction

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        errores = 0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        $display("");
        $display("Lectura de los 19 registros tras el reset");
        $display("  off  idx  nombre       leido        esperado");
        for (i = 0; i < 19; i = i + 1) begin
            axi_read(i * 4, v);
            case (i)
                0:  esperado = MAGIC;
                2:  esperado = 32'h1999_999A;
                3:  esperado = 32'h2666_6666;
                4:  esperado = 32'h0000_0022;
                7:  esperado = 32'd1024;
                15: esperado = N_CH;
                default: esperado = 32'd0;      // el resto vale cero parado
            endcase
            nm = nombre(i);
            if (v !== esperado) begin
                $display("  0x%02h  %2d  %-11s 0x%08h   0x%08h   <-- MAL",
                         i*4, i, nm, v, esperado);
                errores = errores + 1;
            end else begin
                $display("  0x%02h  %2d  %-11s 0x%08h   0x%08h",
                         i*4, i, nm, v, esperado);
            end
        end

        $display("");
        $display("Escribir y releer cada registro RW");
        for (i = 2; i <= 8; i = i + 1) begin
            axi_write(i * 4, 32'hC0DE0000 | (i << 4) | 8'h0A);
            axi_read (i * 4, v);
            esperado = 32'hC0DE0000 | (i << 4) | 8'h0A;
            if (i == 4) esperado = {20'd0, esperado[11:0]};   // SRC_SH: 12 bits
            nm = nombre(i);
            if (v !== esperado) begin
                $display("  0x%02h  %-11s escrito 0x%08h  leido 0x%08h  <-- MAL",
                         i*4, nm, 32'hC0DE0000 | (i << 4) | 8'h0A, v);
                errores = errores + 1;
            end else begin
                $display("  0x%02h  %-11s escrito y releido 0x%08h  OK",
                         i*4, nm, v);
            end
        end

        $display("");
        if (errores == 0)
            $display("RESULTADO: PASA. El RTL decodifica bien los 19 registros.");
        else
            $display("RESULTADO: FALLA, %0d discrepancias. El fallo esta en el RTL.",
                     errores);
        $display("");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT: el maestro se quedo colgado esperando un handshake.");
        $finish;
    end

endmodule

`default_nettype wire
