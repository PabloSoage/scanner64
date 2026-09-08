// ---------------------------------------------------------------------------
// comb_chain.v — Peines del CIC para UNA unidad, a la tasa diezmada.
//
// Extraido de cic_decim. Es la version "una cadena de peines por unidad", que
// es la sencilla y la que usa ddc_channel cuando se instancia suelto.
//
// Para un banco de muchos canales existe comb_bank, que hace exactamente lo
// mismo pero con un solo juego de peines por turnos entre 32 unidades. Los dos
// producen los mismos valores bit a bit; lo comprueba tb_comb_bank.
//
// LAS CASCADAS SON REGISTRADAS, no combinatorias. Cada etapa usa el valor
// PREVIO de la anterior. La version "de libro" las encadena dentro del mismo
// ciclo, lo que crea una cadena de acarreo de N*ACC_W bits que no cierra
// tiempos. Misma funcion de transferencia, solo cambia la latencia.
//
// Requiere N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

module comb_chain #(
    parameter integer N     = 3,
    parameter integer ACC_W = 36
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    dec_now,   // pulso de diezmado
    input  wire signed [ACC_W-1:0] din,       // tap del integrador

    output reg                     out_valid,
    output reg  signed [ACC_W-1:0] out_data
);

    reg signed [ACC_W-1:0] comb_prev [0:N-1];
    reg signed [ACC_W-1:0] comb_val  [0:N-1];

    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (j = 0; j < N; j = j + 1) begin
                comb_prev[j] <= {ACC_W{1'b0}};
                comb_val[j]  <= {ACC_W{1'b0}};
            end
            out_valid <= 1'b0;
            out_data  <= {ACC_W{1'b0}};
        end else begin
            out_valid <= 1'b0;
            if (dec_now) begin
                comb_val[0]  <= din - comb_prev[0];
                comb_prev[0] <= din;
                for (j = 1; j < N; j = j + 1) begin
                    comb_val[j]  <= comb_val[j-1] - comb_prev[j];  // valor PREVIO
                    comb_prev[j] <= comb_val[j-1];
                end
                // Misma expresion que se asigna a comb_val[N-1]: la salida es
                // el valor NUEVO de la ultima etapa de peine.
                out_data  <= comb_val[N-2] - comb_prev[N-1];
                out_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
