// ---------------------------------------------------------------------------
// tb_ddc_fold.v — El plegado contra el original, muestra a muestra.
//
// ddc_fold multiplexa un juego de NCO, mezclador e integradores entre FOLD
// canales. La unica forma de creerselo es comparar su salida con la de FOLD
// ddc_front independientes, alimentados con la MISMA secuencia y sintonizados
// a las MISMAS frecuencias, y exigir que coincidan bit a bit.
//
// No basta con que se parezcan. Un filtro recursivo multiplexado falla de una
// forma muy concreta --leyendo el estado de un canal antes de escribir el de su
// vuelta anterior-- y eso produce una salida que sigue pareciendo una senal.
// Por eso la comparacion es de igualdad exacta sobre cada salida diezmada.
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

    // Cuatro sintonias repartidas por la banda, como en un escaner real.
    reg [PHASE_W-1:0] ftw [0:FOLD-1];
    initial begin
        ftw[0] = 32'h1999_999A;   // 10,0 MHz a 100 MSPS
        ftw[1] = 32'h2666_6666;   // 15,0
        ftw[2] = 32'h0CCC_CCCD;   //  5,0
        ftw[3] = 32'h3851_EB85;   // 22,0
    end

    // ---- El original: FOLD canales independientes --------------------------
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

    // ---- El plegado --------------------------------------------------------
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

    // ---- Colas de salida, una por canal ------------------------------------
    // El plegado emite las ranuras en orden dentro de cada ronda y el original
    // las emite a la vez, asi que no se pueden comparar en el mismo ciclo: hay
    // que encolar por canal y comparar en orden de llegada.
    integer ref_n [0:FOLD-1];
    integer fol_n [0:FOLD-1];
    reg signed [CIC_W-1:0] ref_qi [0:FOLD-1][0:511];
    reg signed [CIC_W-1:0] ref_qq [0:FOLD-1][0:511];

    integer errores;
    integer comparadas;

    // UNA VARIABLE DE BUCLE POR BLOQUE. Compartir `i` entre el `always` que
    // encola y el `initial` que configura costo una tarde: el always corre en
    // cada flanco y deja i = FOLD, asi que el initial leia ftw[4] --fuera de
    // rango, X-- y escribia siempre en la ranura 0. Las fases no avanzaban,
    // sin() salia 0 y las cuatro ranuras daban lo mismo. Parecia un fallo del
    // plegado y era del banco de pruebas.
    integer i;      // solo el bloque de encolado
    integer j;      // solo el initial

    // Estimulo: dos tonos sumados, como sig_source.
    function signed [IN_W-1:0] estimulo(input integer n);
        real s;
        begin
            s = 13000.0 * $sin(2.0 * 3.14159265358979 * 10.0e6 * n / 100.0e6)
              +  9000.0 * $sin(2.0 * 3.14159265358979 * 15.0e6 * n / 100.0e6);
            estimulo = $rtoi(s);
        end
    endfunction

    // Encolar lo que saca el original.
    //
    // BLOQUEANTE a proposito. Con asignacion no bloqueante, la cola se escribe
    // al final del ciclo y el bloque de comparacion, que lee la misma posicion
    // en ese mismo ciclo, se encuentra el valor viejo -- o una X si todavia no
    // se habia escrito nunca. Esto no es un banco de pruebas de hardware: es
    // contabilidad del propio testbench, y ahi lo que hace falta es que el
    // efecto sea inmediato. Solo este bloque escribe estas variables, asi que
    // no hay carrera con nadie.
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

    // Comparar lo que saca el plegado contra la cola de su canal.
    always @(posedge clk) begin
        if (rst_n && f_out_valid) begin
            comparadas = comparadas + 1;
            if (f_tap_i !== ref_qi[f_out_slot][fol_n[f_out_slot] % 512] ||
                f_tap_q !== ref_qq[f_out_slot][fol_n[f_out_slot] % 512]) begin
                if (errores < 8)
                    $display("  ranura %0d salida %0d:  plegado (%0d, %0d)  original (%0d, %0d)",
                             f_out_slot, fol_n[f_out_slot], f_tap_i, f_tap_q,
                             ref_qi[f_out_slot][fol_n[f_out_slot] % 512],
                             ref_qq[f_out_slot][fol_n[f_out_slot] % 512]);
                errores = errores + 1;
            end
            fol_n[f_out_slot] = fol_n[f_out_slot] + 1;
        end
    end

    integer n;
    initial begin
        errores = 0;
        comparadas = 0;
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

        // Sintonizar el plegado igual que el original.
        for (j = 0; j < FOLD; j = j + 1) begin
            @(posedge clk);
            f_cfg_we   <= 1'b1;
            f_cfg_slot <= j[SLOT_W-1:0];
            f_cfg_ftw  <= ftw[j];
        end
        @(posedge clk);
        f_cfg_we <= 1'b0;
        repeat (2) @(posedge clk);

        // Una muestra cada FOLD ciclos: el plegado necesita ese hueco, y el
        // original la recibe en el mismo ciclo para que las secuencias por
        // canal sean identicas.
        for (n = 0; n < NSAMP; n = n + 1) begin
            @(posedge clk);
            ref_data  <= estimulo(n);
            ref_valid <= 1'b1;
            f_data    <= estimulo(n);
            f_valid   <= 1'b1;
            @(posedge clk);
            ref_valid <= 1'b0;
            f_valid   <= 1'b0;
            repeat (FOLD - 1) @(posedge clk);
        end

        // Que salga lo que quede en la tuberia.
        repeat (4 * FOLD + 20) @(posedge clk);

        $display("");
        $display("tb_ddc_fold — FOLD=%0d, %0d muestras", FOLD, NSAMP);
        for (j = 0; j < FOLD; j = j + 1)
            $display("  ranura %0d: original %0d salidas, plegado %0d",
                     j, ref_n[j], fol_n[j]);
        $display("  comparaciones : %0d", comparadas);
        $display("  discrepancias : %0d", errores);
        $display("");
        if (errores == 0 && comparadas > 100)
            $display("RESULTADO: PASA — el plegado da lo mismo que %0d canales sueltos.", FOLD);
        else if (comparadas <= 100)
            $display("RESULTADO: INCONCLUSO — solo %0d comparaciones.", comparadas);
        else
            $display("RESULTADO: FALLA — %0d discrepancias.", errores);
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
