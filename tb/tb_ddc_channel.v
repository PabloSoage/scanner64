// ---------------------------------------------------------------------------
// tb_ddc_channel.v — Testbench autocomprobante de un canal DDC.
//
// Compara la salida del RTL contra los vectores dorados generados por
// model/gen_vectors.py a partir del modelo bit-exacto verificado.
//
// No imprime formas de onda para que las mires: imprime PASA o FALLA, con el
// numero de discrepancias. Un testbench que hay que interpretar a ojo no es un
// testbench.
//
// Ejecutar con iverilog:
//     iverilog -g2012 -o tb.vvp -I vectors \
//         tb/tb_ddc_channel.v rtl/nco.v rtl/cic_decim.v rtl/ddc_channel.v
//     vvp tb.vvp
//
// Ejecutar en Vivado: anadir los mismos ficheros como fuentes de simulacion,
// con tb/vectors/ en el include path, y sin olvidar copiar rtl/sin_lut.mem
// al directorio de trabajo del simulador.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tb_ddc_channel;

    `include "params.vh"          // generado por model/gen_vectors.py

    localparam integer SKIP = 8;  // muestras de transitorio del CIC a ignorar

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;         // 100 MHz

    // ---- Vectores ----------------------------------------------------------
    reg signed [P_IN_W-1:0]  stim   [0:P_N_STIM-1];
    reg signed [P_OUT_W-1:0] gold_i [0:P_N_GOLD-1];
    reg signed [P_OUT_W-1:0] gold_q [0:P_N_GOLD-1];

    initial begin
        $readmemh("vectors/stim.hex",   stim);
        $readmemh("vectors/gold_i.hex", gold_i);
        $readmemh("vectors/gold_q.hex", gold_q);
    end

    // ---- Unidad bajo prueba ------------------------------------------------
    reg                      in_valid = 1'b0;
    reg signed [P_IN_W-1:0]  in_data  = {P_IN_W{1'b0}};

    wire                      out_valid;
    wire signed [P_OUT_W-1:0] out_i, out_q;

    ddc_channel #(
        .IN_W (P_IN_W), .OUT_W (P_OUT_W), .PHASE_W (P_PHASE_W),
        .LUT_ADDR_W (P_LUT_ADDR_W), .LUT_W (P_LUT_W), .MIX_W (P_MIX_W),
        .CIC_N (P_CIC_N), .CIC_R (P_CIC_R), .CIC_W (P_CIC_W),
        .CIC_GROWTH (P_CIC_GROWTH), .LUT_FILE ("sin_lut.mem")
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .ftw (P_FTW),
        .in_valid (in_valid), .in_data (in_data),
        .out_valid (out_valid), .out_i (out_i), .out_q (out_q)
    );

    // ---- Estimulo ----------------------------------------------------------
    integer si;
    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        for (si = 0; si < P_N_STIM; si = si + 1) begin
            in_valid <= 1'b1;
            in_data  <= stim[si];
            @(posedge clk);
        end
        in_valid <= 1'b0;

        repeat (200) @(posedge clk);   // vaciar el pipeline
        report_and_finish;
    end

    // ---- Comprobacion ------------------------------------------------------
    integer oi = 0;
    integer errors = 0;
    integer checked = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (oi >= SKIP && oi < P_N_GOLD) begin
                checked = checked + 1;
                if (out_i !== gold_i[oi] || out_q !== gold_q[oi]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("  [%0d] esperado I=%0d Q=%0d   rtl I=%0d Q=%0d",
                                 oi, gold_i[oi], gold_q[oi], out_i, out_q);
                end
            end
            oi = oi + 1;
        end
    end

    task report_and_finish;
        begin
            $display("");
            $display("tb_ddc_channel");
            $display("  salidas producidas : %0d", oi);
            $display("  comparadas         : %0d", checked);
            $display("  discrepancias      : %0d", errors);
            $display("");
            if (checked < 16)
                $display("RESULTADO: FALLA — muy pocas salidas comparadas (%0d).", checked);
            else if (errors == 0)
                $display("RESULTADO: PASA");
            else
                $display("RESULTADO: FALLA");
            $display("");
            $finish;
        end
    endtask

endmodule

`default_nettype wire
