// ---------------------------------------------------------------------------
// tb_sig_source.v — Vuelca las muestras de `sig_source` para compararlas con
// el modelo de Python.
//
// Existe porque al contrastar el hardware contra el modelo los dos canales con
// tono cuadraban al bit y los dos vacios fallaban por 1 LSB sobre un valor de
// 2. La sospecha era que el estimulo de Python no fuese identico al del RTL, y
// aqui se vio: `sig_source` emite UN CERO antes de la primera muestra buena,
// por el registro de salida. Es decir  rtl[n] = modelo[n-1].
//
// Ese cero entra en el CIC y avanza el NCO del canal. A un canal con tono no le
// afecta --su salida vale 4096 y el cero se pierde en el promedio-- pero a un
// canal vacio le cambia el resultado en 1 LSB, que ahi es todo.
//
// Con el cero modelado, los cuatro canales cuadran exactos contra la placa.
//
//     xvlog nco.v sig_source.v tb_sig_source.v
//     xelab tb_sig_source -s sigsim && xsim sigsim -R
//
// Deja sig_rtl.txt con 300 muestras, una por linea.
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
