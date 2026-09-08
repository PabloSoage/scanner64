// ---------------------------------------------------------------------------
// tb_scanner_top.v — Testbench autocomprobante del BANCO de canales.
//
// El testbench del canal (tb_ddc_channel) prueba la aritmetica. Este prueba lo
// que solo aparece al juntar N canales, que es donde estan los fallos que el
// otro no puede ver:
//
//   T1  cfg_we escribe la sintonia en el canal indicado, y SOLO en ese.
//   T2  los N canales producen a la vez y cada uno da lo suyo: ninguno se pisa
//       con otro pese a compartir clk, rst y el flujo de entrada.
//   T3  el mux de tap_ch devuelve el canal seleccionado.
//   T4  el medidor de potencia acumula, congela y reinicia; rd_ch lee bien.
//   T5  el escaner DISCRIMINA: los canales sobre un tono miden potencia alta y
//       los sintonizados al vacio, baja. Es la prueba de que esto sirve.
//   T6  cfg_clear reinicia los acumuladores.
//
// Vectores dorados de model/gen_vectors_bank.py, sacados del mismo modelo
// bit-exacto que valida el canal suelto.
//
// Ejecutar con XSim:
//     xvlog -sv -i vectors ../rtl/nco.v ../rtl/cic_decim.v \
//                          ../rtl/ddc_channel.v ../rtl/scanner_top.v \
//                          ../tb/tb_scanner_top.v
//     xelab tb_scanner_top -s tb_bank
//     xsim tb_bank -runall
//
// Ejecutar con iverilog:
//     iverilog -g2012 -o tb_bank.vvp -I vectors \
//         tb/tb_scanner_top.v rtl/nco.v rtl/cic_decim.v rtl/ddc_channel.v \
//         rtl/scanner_top.v
//     vvp tb_bank.vvp
//
// El .mem de la LUT y el directorio vectors/ tienen que estar en el directorio
// de trabajo del simulador: el $readmemh usa rutas relativas a el.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tb_scanner_top;

    `include "params.vh"          // generado por model/gen_vectors.py
    `include "params_bank.vh"     // generado por model/gen_vectors_bank.py

    localparam integer SKIP  = 8;                  // transitorio del CIC
    localparam integer CH_W  = $clog2(PB_N_CH);
    localparam integer DISCR = 1000;               // margen minimo de T5, veces

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;         // 100 MHz

    // ---- Vectores ----------------------------------------------------------
    reg signed [P_IN_W-1:0]  stim     [0:PB_N_STIM-1];
    reg        [P_PHASE_W-1:0] ftw_v  [0:PB_N_CH-1];
    reg signed [P_OUT_W-1:0] gold_i   [0:PB_N_CH*PB_N_GOLD-1];
    reg signed [P_OUT_W-1:0] gold_q   [0:PB_N_CH*PB_N_GOLD-1];
    reg        [PB_PWR_W-1:0] gold_pwr[0:PB_N_CH-1];

    initial begin
        $readmemh("vectors/stim.hex",        stim);
        $readmemh("vectors/bank_ftw.hex",    ftw_v);
        $readmemh("vectors/bank_gold_i.hex", gold_i);
        $readmemh("vectors/bank_gold_q.hex", gold_q);
        $readmemh("vectors/bank_pwr.hex",    gold_pwr);
    end

    // ---- Unidad bajo prueba ------------------------------------------------
    reg                       in_valid = 1'b0;
    reg signed [P_IN_W-1:0]   in_data  = {P_IN_W{1'b0}};

    reg                       cfg_we      = 1'b0;
    reg  [CH_W-1:0]           cfg_ch      = {CH_W{1'b0}};
    reg  [P_PHASE_W-1:0]      cfg_ftw     = {P_PHASE_W{1'b0}};
    reg  [31:0]               cfg_pwr_len = PB_PWR_LEN;
    reg                       cfg_clear   = 1'b0;

    reg  [CH_W-1:0]           rd_ch  = {CH_W{1'b0}};
    reg  [CH_W-1:0]           tap_ch = {CH_W{1'b0}};

    wire [PB_PWR_W-1:0]       rd_pwr;
    wire [PB_N_CH-1:0]        pwr_ready;
    wire                      tap_valid;
    wire signed [P_OUT_W-1:0] tap_i, tap_q;

    scanner_top #(
        .N_CH (PB_N_CH),
        .IN_W (P_IN_W), .OUT_W (P_OUT_W), .PHASE_W (P_PHASE_W),
        .LUT_ADDR_W (P_LUT_ADDR_W), .LUT_W (P_LUT_W), .MIX_W (P_MIX_W),
        .CIC_N (P_CIC_N), .CIC_R (P_CIC_R), .CIC_W (P_CIC_W),
        .CIC_GROWTH (P_CIC_GROWTH), .PWR_W (PB_PWR_W),
        .LUT_FILE ("sin_lut.mem")
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .in_valid (in_valid), .in_data (in_data),
        .cfg_we (cfg_we), .cfg_ch (cfg_ch), .cfg_ftw (cfg_ftw),
        .cfg_pwr_len (cfg_pwr_len), .cfg_clear (cfg_clear),
        .rd_ch (rd_ch), .rd_pwr (rd_pwr), .pwr_ready (pwr_ready),
        .tap_ch (tap_ch), .tap_valid (tap_valid),
        .tap_i (tap_i), .tap_q (tap_q)
    );

    // ---- Contadores de error, uno por prueba -------------------------------
    integer e_cfg    = 0;   // T1
    integer e_out    = 0;   // T2, en regimen
    integer e_trans  = 0;   // T2, durante el transitorio (informativo)
    integer e_tap    = 0;   // T3
    integer e_pwr    = 0;   // T4
    integer e_discr  = 0;   // T5
    integer e_clear  = 0;   // T6
    integer checked  = 0;

    // ---- T2: comparacion de los N canales, muestra a muestra ---------------
    // Con los peines compartidos los canales YA NO salen en el mismo ciclo:
    // cada uno sale en su turno dentro de la ronda. Asi que cada canal lleva
    // su propio contador de salidas y se compara cuando sube SU ch_valid.
    integer oi_ch [0:PB_N_CH-1];
    integer oi = 0;
    integer c;

    initial for (c = 0; c < PB_N_CH; c = c + 1) oi_ch[c] = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            for (c = 0; c < PB_N_CH; c = c + 1) begin
                if (dut.ch_valid[c]) begin
                    if (oi_ch[c] < PB_N_GOLD) begin
                        if (dut.ch_i[c] !== gold_i[c*PB_N_GOLD + oi_ch[c]] ||
                            dut.ch_q[c] !== gold_q[c*PB_N_GOLD + oi_ch[c]]) begin
                            if (oi_ch[c] >= SKIP) begin
                                e_out = e_out + 1;
                                if (e_out <= 10)
                                    $display("  T2 ch%0d [%0d] esperado I=%0d Q=%0d   rtl I=%0d Q=%0d",
                                             c, oi_ch[c],
                                             gold_i[c*PB_N_GOLD + oi_ch[c]],
                                             gold_q[c*PB_N_GOLD + oi_ch[c]],
                                             dut.ch_i[c], dut.ch_q[c]);
                            end else begin
                                e_trans = e_trans + 1;
                            end
                        end
                        if (oi_ch[c] >= SKIP) checked = checked + 1;
                    end
                    oi_ch[c] = oi_ch[c] + 1;
                    if (c == 0) oi = oi_ch[0];
                end
            end
        end
    end

    // ---- Secuencia principal -----------------------------------------------
    integer si, k;
    reg [PB_PWR_W-1:0] pwr_rd [0:PB_N_CH-1];

    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // --- T1: escribir una sintonia distinta en cada canal ---------------
        for (k = 0; k < PB_N_CH; k = k + 1) begin
            cfg_we  <= 1'b1;
            cfg_ch  <= k[CH_W-1:0];
            cfg_ftw <= ftw_v[k];
            @(posedge clk);
        end
        cfg_we <= 1'b0;
        @(posedge clk);

        for (k = 0; k < PB_N_CH; k = k + 1)
            if (dut.ftw[k] !== ftw_v[k]) begin
                e_cfg = e_cfg + 1;
                $display("  T1 ch%0d sintonia esperada %08x, leida %08x",
                         k, ftw_v[k], dut.ftw[k]);
            end

        // --- T2: meter el estimulo -----------------------------------------
        for (si = 0; si < PB_N_STIM; si = si + 1) begin
            in_valid <= 1'b1;
            in_data  <= stim[si];
            @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (200) @(posedge clk);   // vaciar el pipeline

        // --- T3: el mux de tap_ch ------------------------------------------
        // Con in_valid a cero las salidas quedan congeladas, asi que se puede
        // barrer tap_ch y comparar contra el canal correspondiente.
        for (k = 0; k < PB_N_CH; k = k + 1) begin
            tap_ch = k[CH_W-1:0];
            #1;
            if (tap_i !== dut.ch_i[k] || tap_q !== dut.ch_q[k]) begin
                e_tap = e_tap + 1;
                $display("  T3 tap_ch=%0d devuelve I=%0d Q=%0d, el canal tiene I=%0d Q=%0d",
                         k, tap_i, tap_q, dut.ch_i[k], dut.ch_q[k]);
            end
        end

        // --- T4: potencia por canal ----------------------------------------
        for (k = 0; k < PB_N_CH; k = k + 1) begin
            rd_ch = k[CH_W-1:0];
            #1;
            pwr_rd[k] = rd_pwr;
            if (rd_pwr !== gold_pwr[k]) begin
                e_pwr = e_pwr + 1;
                $display("  T4 ch%0d potencia esperada %0d, leida %0d",
                         k, gold_pwr[k], rd_pwr);
            end
            if (pwr_ready[k] !== 1'b1) begin
                e_pwr = e_pwr + 1;
                $display("  T4 ch%0d pwr_ready sigue a 0 tras %0d ventanas completas",
                         k, PB_N_GOLD / PB_PWR_LEN);
            end
        end

        // --- T5: discriminacion --------------------------------------------
        // Canales 0 y 1 estan sobre un tono; 2 y 3, sobre banda vacia.
        for (k = 0; k < 2; k = k + 1) begin
            for (c = 2; c < PB_N_CH; c = c + 1) begin
                if (pwr_rd[k] < pwr_rd[c] * DISCR) begin
                    e_discr = e_discr + 1;
                    $display("  T5 el canal %0d (con tono, %0d) no supera en %0dx al canal %0d (vacio, %0d)",
                             k, pwr_rd[k], DISCR, c, pwr_rd[c]);
                end
            end
        end

        // --- T6: cfg_clear --------------------------------------------------
        cfg_clear <= 1'b1;
        @(posedge clk);
        cfg_clear <= 1'b0;
        @(posedge clk);
        #1;
        if (pwr_ready !== {PB_N_CH{1'b0}}) begin
            e_clear = e_clear + 1;
            $display("  T6 pwr_ready no se limpia con cfg_clear: %b", pwr_ready);
        end
        for (k = 0; k < PB_N_CH; k = k + 1) begin
            rd_ch = k[CH_W-1:0];
            #1;
            if (rd_pwr !== {PB_PWR_W{1'b0}}) begin
                e_clear = e_clear + 1;
                $display("  T6 ch%0d rd_pwr no se limpia con cfg_clear: %0d", k, rd_pwr);
            end
        end

        report_and_finish;
    end

    // ---- Informe -----------------------------------------------------------
    integer total;
    task report_and_finish;
        begin
            total = e_cfg + e_out + e_tap + e_pwr + e_discr + e_clear;
            $display("");
            $display("tb_scanner_top   (%0d canales, %0d salidas por canal)", PB_N_CH, PB_N_GOLD);
            $display("  salidas producidas : %0d", oi);
            $display("  comparadas         : %0d  (%0d canales x %0d muestras en regimen)",
                     checked, PB_N_CH, PB_N_GOLD - SKIP);
            $display("");
            $display("  T1 sintonias           : %0d fallos", e_cfg);
            $display("  T2 canales sin pisarse : %0d fallos", e_out);
            $display("  T3 mux de tap_ch       : %0d fallos", e_tap);
            $display("  T4 medidor de potencia : %0d fallos", e_pwr);
            $display("  T5 discriminacion      : %0d fallos", e_discr);
            $display("  T6 cfg_clear           : %0d fallos", e_clear);
            if (e_trans != 0)
                $display("  (transitorio del CIC, no computa: %0d diferencias)", e_trans);
            $display("");
            if (checked < PB_N_CH * 16)
                $display("RESULTADO: FALLA — muy pocas salidas comparadas (%0d).", checked);
            else if (total == 0)
                $display("RESULTADO: PASA");
            else
                $display("RESULTADO: FALLA — %0d fallos en total", total);
            $display("");
            $finish;
        end
    endtask

endmodule

`default_nettype wire
