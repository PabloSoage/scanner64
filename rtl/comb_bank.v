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
// N_UNIT + 1 < R para que la ronda termine antes de la siguiente: con R=64
// el valor seguro por defecto es 32 unidades, o sea 16 canales por banco.
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
// LA RONDA VA EN DOS ETAPAS, y esto no es un capricho.
//
// La primera version hacia leer-calcular-escribir en un solo ciclo, y el
// resultado fue un camino critico que iba del contador de turno hasta los DSP
// del medidor de potencia, con el 84 % del retardo en CABLEADO: 5.148 ns de
// rutado contra 0.951 ns de logica. Los multiplexores 32:1 obligan a la senal
// a cruzar medio chip. Post-rutado el diseno se quedaba en 144 MHz.
//
// Partiendo la ronda en dos, la lectura del array queda aislada en su propia
// etapa y el mux ya no comparte ciclo con la resta ni con lo que venga detras:
//
//     etapa A   lee el estado de la unidad u y lo registra
//     etapa B   resta, escribe el estado nuevo y saca la muestra
//
// No hay riesgo de colision: en cualquier ciclo la etapa A lee la unidad u y
// la B escribe la u-1, que son distintas. Cada unidad se toca una vez por
// ronda. El coste es un ciclo mas de latencia y una ronda de N_UNIT+1 ciclos
// en vez de N_UNIT, asi que ahora hace falta N_UNIT+1 < R.
//
// La siguiente via, si hiciera falta bajar el area, es poner el estado en BRAM
// y pasar a tres etapas. No esta hecho.
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
// Requiere N >= 2 y N_UNIT + 1 < R.
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

    // ---- Etapa A: lectura del estado de la unidad u -----------------------
    // prev[j] es el valor que la etapa j consume: la entrada para la primera,
    // y el valor PREVIO de la etapa anterior para el resto.
    // Estos son los multiplexores caros, y ahora tienen el ciclo para ellos.
    wire signed [ACC_W-1:0] prev_c [0:N-1];
    wire signed [ACC_W-1:0] cp_c   [0:N-1];

    genvar gj;
    generate
        assign prev_c[0] = buf_in[u];
        for (gj = 1; gj < N; gj = gj + 1) begin : gen_prev
            assign prev_c[gj] = cv[gj-1][u];
        end
        for (gj = 0; gj < N; gj = gj + 1) begin : gen_cp
            assign cp_c[gj] = cp[gj][u];
        end
    endgenerate

    reg                    a_valid;
    reg [UW-1:0]           a_unit;
    reg signed [ACC_W-1:0] a_prev [0:N-1];
    reg signed [ACC_W-1:0] a_cp   [0:N-1];

    // ---- Etapa B: la resta, con los operandos ya registrados --------------
    wire signed [ACC_W-1:0] cv_nx [0:N-1];
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin : gen_cvnx
            assign cv_nx[gj] = a_prev[gj] - a_cp[gj];
        end
    endgenerate

    integer k, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            u         <= {UW{1'b0}};
            a_valid   <= 1'b0;
            a_unit    <= {UW{1'b0}};
            out_valid <= 1'b0;
            out_unit  <= {UW{1'b0}};
            out_data  <= {ACC_W{1'b0}};
        end else begin
            a_valid   <= 1'b0;
            out_valid <= 1'b0;

            // --- Etapa A ---------------------------------------------------
            if (start) begin
                for (k = 0; k < N_UNIT; k = k + 1)
                    buf_in[k] <= din_flat[k*ACC_W +: ACC_W];
                busy <= 1'b1;
                u    <= {UW{1'b0}};
            end else if (busy) begin
                a_valid <= 1'b1;
                a_unit  <= u;
                for (j = 0; j < N; j = j + 1) begin
                    a_prev[j] <= prev_c[j];
                    a_cp[j]   <= cp_c[j];
                end

                if (u == N_UNIT[UW-1:0] - 1'b1) begin
                    busy <= 1'b0;
                    u    <= {UW{1'b0}};
                end else begin
                    u <= u + 1'b1;
                end
            end

            // --- Etapa B ---------------------------------------------------
            // Escribe la unidad a_unit, que es la anterior a la que lee A.
            if (a_valid) begin
                for (j = 0; j < N-1; j = j + 1) cv[j][a_unit] <= cv_nx[j];
                for (j = 0; j < N;   j = j + 1) cp[j][a_unit] <= a_prev[j];

                out_data  <= cv_nx[N-1];
                out_unit  <= a_unit;
                out_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
