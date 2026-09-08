// ---------------------------------------------------------------------------
// comb_bank.v — Peines del CIC, multiplexados entre varias unidades.
//
// POR QUE EXISTE ESTE MODULO
//
// Los integradores del CIC corren a la tasa de entrada, pero los peines corren
// a la tasa DIEZMADA: con R=64 trabajan un ciclo de cada 64 y estan parados el
// 98 % del tiempo. Replicarlos por canal, como hace cic_decim, desperdicia
// 216 LUT y 360 FF por canal medidos sobre la KV260.
//
// Aqui hay UN solo juego de peines que atiende N_UNIT unidades por turnos. Una
// "unidad" es una cadena I o Q, asi que un canal consume dos.
//
// COMO FUNCIONA
//
// Todos los canales diezman en el mismo ciclo, porque comparten el flujo de
// entrada y el contador. Asi que en el pulso de `start` se capturan de golpe
// las N_UNIT muestras y luego se procesan de una en una, en los N_UNIT ciclos
// siguientes. Como el diezmado se repite cada R ciclos, hace falta
// N_UNIT < R para que la ronda termine antes de la siguiente: con R=64 el
// valor seguro por defecto es 32 unidades, o sea 16 canales por banco.
//
// El estado de cada unidad vive en un array indexado por turno. MEDIDO sobre
// la KV260, N_UNIT=32: 2034 LUT y 7001 FF por banco, o sea 127 LUT y 438 FF
// por canal, frente a los 216 LUT y 360 FF por canal que costaban los peines
// replicados. El grueso de esos 2034 LUT NO son los sumadores (4 restas de
// 36 bits, ~144 LUT) sino los multiplexores 32:1 que leen el array por indice.
//
// Por eso no se fuerza el estado a LUTRAM: la memoria distribuida sale del
// mismo presupuesto de LUT y el ahorro seria negativo. Dejarlo en flip-flops,
// que sobran (234 k en el chip), es lo correcto aqui.
//
// La via para bajar de ahi es poner el estado en BRAM y pipelinear la ronda en
// tres etapas (leer / calcular / escribir): quita los multiplexores enteros a
// cambio de 1-2 RAMB18 por banco. No esta hecho.
//
// EQUIVALENCIA CON cic_decim
//
// Con la entrada d de la unidad u, y su estado cv[] / cp[], una ronda hace:
//
//     prev[0]   = d                 prev[j] = cv[j-1]  para j >= 1
//     cv_new[j] = prev[j] - cp[j]   cp_new[j] = prev[j]
//     salida    = cv_new[N-1]
//
// que es exactamente lo que hace el bloque de peines de cic_decim, solo que
// el valor "previo" viene de memoria en lugar de un registro. La ultima etapa
// no se guarda: es la salida.
//
// Lo que SI cambia es CUANDO sale cada unidad: la unidad u sale u ciclos
// despues del diezmado, no todas a la vez. Los valores son identicos bit a
// bit; solo se reordenan en el tiempo.
//
// Requiere N >= 2 y N_UNIT < R.
// ---------------------------------------------------------------------------

`default_nettype none

module comb_bank #(
    parameter integer N_UNIT = 32,    // unidades atendidas (2 por canal)
    parameter integer N      = 3,     // etapas de peine
    parameter integer ACC_W  = 36
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Pulso de diezmado: hay N_UNIT muestras nuevas en din_flat.
    input  wire                          start,
    input  wire [N_UNIT*ACC_W-1:0]       din_flat,

    // Una salida por ciclo mientras dura la ronda.
    output reg                           out_valid,
    output reg  [$clog2(N_UNIT)-1:0]     out_unit,
    output reg  signed [ACC_W-1:0]       out_data
);

    localparam integer UW = $clog2(N_UNIT);

    // ---- Estado por unidad -------------------------------------------------
    // Lectura asincrona a proposito: asi la ronda cabe en un ciclo por unidad,
    // sin pipeline de memoria. El precio son los multiplexores de lectura.
    reg signed [ACC_W-1:0] buf_in [0:N_UNIT-1];
    reg signed [ACC_W-1:0] cv     [0:N-2][0:N_UNIT-1];  // etapas 0..N-2
    reg signed [ACC_W-1:0] cp     [0:N-1][0:N_UNIT-1];  // etapas 0..N-1

    reg          busy;
    reg [UW-1:0] u;

    // El estado arranca a cero por `initial`, NO por un bucle de reset. Es
    // deliberado: un reset que barre todo el array obliga a Vivado a poner el
    // estado en flip-flops (medido: 7001 FF) en vez de en LUTRAM distribuida.
    // Con `initial` la inicializacion viaja en el bitstream, que es como se
    // inicializa la memoria distribuida en una FPGA de verdad.
    //
    // Consecuencia a tener presente: un reset en caliente NO limpia el estado
    // de los peines. Tras un rst_n el filtro arrastra su estado anterior
    // durante unas cuantas rondas. Si eso importa en tu sistema, vacia el
    // banco metiendo N rondas de ceros antes de fiarte de la salida.
    integer ii, jj;
    initial begin
        for (ii = 0; ii < N_UNIT; ii = ii + 1) begin
            buf_in[ii] = {ACC_W{1'b0}};
            for (jj = 0; jj < N-1; jj = jj + 1) cv[jj][ii] = {ACC_W{1'b0}};
            for (jj = 0; jj < N;   jj = jj + 1) cp[jj][ii] = {ACC_W{1'b0}};
        end
    end

    // ---- Combinatoria de una ronda ----------------------------------------
    // prev[j] es el valor que la etapa j consume: la entrada para la primera,
    // y el valor PREVIO de la etapa anterior para el resto.
    wire signed [ACC_W-1:0] d = buf_in[u];

    wire signed [ACC_W-1:0] prev  [0:N-1];
    wire signed [ACC_W-1:0] cv_nx [0:N-1];

    genvar gj;
    generate
        assign prev[0] = d;
        for (gj = 1; gj < N; gj = gj + 1) begin : gen_prev
            assign prev[gj] = cv[gj-1][u];
        end
        for (gj = 0; gj < N; gj = gj + 1) begin : gen_cvnx
            assign cv_nx[gj] = prev[gj] - cp[gj][u];
        end
    endgenerate

    integer k, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            u         <= {UW{1'b0}};
            out_valid <= 1'b0;
            out_unit  <= {UW{1'b0}};
            out_data  <= {ACC_W{1'b0}};
        end else begin
            out_valid <= 1'b0;

            if (start) begin
                for (k = 0; k < N_UNIT; k = k + 1)
                    buf_in[k] <= din_flat[k*ACC_W +: ACC_W];
                busy <= 1'b1;
                u    <= {UW{1'b0}};
            end else if (busy) begin
                // Turno de la unidad u: actualiza su estado y saca su muestra.
                for (j = 0; j < N-1; j = j + 1) cv[j][u] <= cv_nx[j];
                for (j = 0; j < N;   j = j + 1) cp[j][u] <= prev[j];

                out_data  <= cv_nx[N-1];
                out_unit  <= u;
                out_valid <= 1'b1;

                if (u == N_UNIT[UW-1:0] - 1'b1) begin
                    busy <= 1'b0;
                    u    <= {UW{1'b0}};
                end else begin
                    u <= u + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
