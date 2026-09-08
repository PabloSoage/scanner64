// ---------------------------------------------------------------------------
// cic_decim.v — Decimador CIC (Cascaded Integrator-Comb).
//
// N etapas integradoras a la tasa alta, diezmado por R, N peines a la tasa
// baja. No usa NI UN multiplicador: solo sumadores y registros. Eso es lo que
// permite meter decenas de canales en la PL.
//
// Desde la separacion en dos piezas, este modulo es solo el pegamento:
//
//     cic_integ   los integradores, a la tasa de entrada. Uno por unidad,
//                 obligatoriamente: procesan una muestra por ciclo.
//     comb_chain  los peines, a la tasa diezmada. Trabajan 1 ciclo de cada R.
//
// Esa asimetria es la que explota comb_bank, que sustituye N comb_chain por un
// solo juego compartido por turnos. Ver el README.
//
// Las dos trampas del CIC estan documentadas donde toca:
//   1. el desbordamiento envolvente intencionado, en cic_integ
//   2. las cascadas registradas y no combinatorias, en comb_chain
//
// Equivalente ciclo a ciclo a CICDecimator de model/ddc_model.py.
// Requiere N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

// Mapeo de la aritmetica: por defecto los sumadores van a CLB. Sintetizando
// con -verilog_define CIC_USE_DSP=1 se mandan a los DSP48, que llevan un
// acumulador de 48 bits sin usar. Cuesta 3 DSP por CIC y ahorra 145 LUT.
//
// No es una mejora, es un INTERCAMBIO: elige segun que recurso te sobre en tu
// diseno. Los numeros medidos estan en el README, seccion "Exprimirla de
// verdad". No cambia la funcion ni un bit, solo donde se implementa.
`ifdef CIC_USE_DSP
(* use_dsp = "logic" *)
`endif
module cic_decim #(
    parameter integer IN_W  = 18,
    parameter integer N     = 3,      // etapas
    parameter integer R     = 64,     // factor de diezmado
    parameter integer ACC_W = 36      // = IN_W + N*log2(R*M)
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       in_valid,
    input  wire signed [IN_W-1:0]     in_data,
    output wire                       out_valid,
    output wire signed [ACC_W-1:0]    out_data
);

    initial begin
        if (N < 2) begin
            $display("cic_decim: N debe ser >= 2");
            $finish;
        end
    end

    wire                    dec_now;
    wire signed [ACC_W-1:0] tap;

    cic_integ #(.IN_W(IN_W), .N(N), .R(R), .ACC_W(ACC_W)) u_integ (
        .clk (clk), .rst_n (rst_n),
        .in_valid (in_valid), .in_data (in_data),
        .dec_now (dec_now), .tap (tap)
    );

    comb_chain #(.N(N), .ACC_W(ACC_W)) u_comb (
        .clk (clk), .rst_n (rst_n),
        .dec_now (dec_now), .din (tap),
        .out_valid (out_valid), .out_data (out_data)
    );

endmodule

`default_nettype wire
