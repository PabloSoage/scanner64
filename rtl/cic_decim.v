// ---------------------------------------------------------------------------
// cic_decim.v — Decimador CIC (Cascaded Integrator-Comb).
//
// N etapas integradoras a la tasa alta, diezmado por R, N peines a la tasa
// baja. No usa NI UN multiplicador: solo sumadores y registros. Eso es lo que
// permite meter decenas de canales en la PL.
//
// Dos cosas que hay que respetar o el filtro deja de funcionar:
//
// 1. EL DESBORDAMIENTO ENVOLVENTE DE LOS INTEGRADORES ES INTENCIONADO.
//    Los integradores desbordan y los peines lo deshacen exactamente, siempre
//    que ACC_W >= IN_W + N*log2(R*M). Poner saturacion aqui ROMPE el filtro.
//    Es el error clasico al portar un CIC a punto fijo.
//
// 2. LAS CASCADAS SON REGISTRADAS, no combinatorias.
//    Cada etapa usa el valor PREVIO de la anterior. La version "de libro"
//    encadena las etapas dentro del mismo ciclo, lo que crea una cadena de
//    acarreo de N*ACC_W bits que no cierra tiempos. Misma funcion de
//    transferencia, solo cambia la latencia.
//
// Equivalente ciclo a ciclo a CICDecimator de model/ddc_model.py.
// Requiere N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

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
    output reg                        out_valid,
    output reg  signed [ACC_W-1:0]    out_data
);

    localparam integer CNT_W = $clog2(R);

    initial begin
        if (N < 2) begin
            $display("cic_decim: N debe ser >= 2");
            $finish;
        end
    end

    wire signed [ACC_W-1:0] in_ext = {{(ACC_W-IN_W){in_data[IN_W-1]}}, in_data};

    // ---- Integradores, a la tasa de entrada --------------------------------
    reg signed [ACC_W-1:0] integ [0:N-1];
    reg [CNT_W-1:0]        cnt;

    // Valor que tendra la ultima etapa TRAS absorber la muestra actual. El
    // modelo lo lee en el mismo ciclo, asi que hay que anticiparlo. Es un solo
    // sumador combinatorio, no una cadena.
    wire signed [ACC_W-1:0] integ_last_next = integ[N-1] + integ[N-2];

    wire decim_now = in_valid && (cnt == R[CNT_W-1:0] - 1'b1);

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1)
                integ[i] <= {ACC_W{1'b0}};
            cnt <= {CNT_W{1'b0}};
        end else if (in_valid) begin
            integ[0] <= integ[0] + in_ext;
            for (i = 1; i < N; i = i + 1)
                integ[i] <= integ[i] + integ[i-1];   // valor PREVIO: registrado

            cnt <= decim_now ? {CNT_W{1'b0}} : (cnt + 1'b1);
        end
    end

    // ---- Peines, a la tasa diezmada ----------------------------------------
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
            if (decim_now) begin
                comb_val[0]  <= integ_last_next - comb_prev[0];
                comb_prev[0] <= integ_last_next;
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
