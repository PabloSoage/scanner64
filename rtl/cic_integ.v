// ---------------------------------------------------------------------------
// cic_integ.v — Parte integradora del CIC, a la tasa de entrada.
//
// Extraido de cic_decim para poder separar las dos mitades del filtro, que
// corren a tasas muy distintas:
//
//   - los integradores procesan UNA MUESTRA POR CICLO. Van aqui, y hay que
//     replicarlos por canal: no hay forma de compartirlos.
//   - los peines procesan una muestra cada R ciclos. Van en comb_chain (uno
//     por unidad) o en comb_bank (uno compartido entre muchas), que es lo que
//     permite meter mas canales en el mismo chip.
//
// EL DESBORDAMIENTO ENVOLVENTE DE LOS INTEGRADORES ES INTENCIONADO. Desbordan
// y los peines lo deshacen exactamente, siempre que ACC_W >= IN_W + N*log2(R*M).
// Poner saturacion aqui ROMPE el filtro. Es el error clasico al portar un CIC.
//
// Requiere N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

module cic_integ #(
    parameter integer IN_W  = 18,
    parameter integer N     = 3,      // etapas
    parameter integer R     = 64,     // factor de diezmado
    parameter integer ACC_W = 36      // = IN_W + N*log2(R*M)
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    in_valid,
    input  wire signed [IN_W-1:0]  in_data,

    // Pulso de diezmado: en este ciclo `tap` lleva la muestra que toca.
    output wire                    dec_now,
    // Valor que tendra la ultima etapa TRAS absorber la muestra actual. El
    // modelo lo lee en el mismo ciclo, asi que hay que anticiparlo. Es un solo
    // sumador combinatorio, no una cadena.
    output wire signed [ACC_W-1:0] tap
);

    localparam integer CNT_W = $clog2(R);

    wire signed [ACC_W-1:0] in_ext = {{(ACC_W-IN_W){in_data[IN_W-1]}}, in_data};

    reg signed [ACC_W-1:0] integ [0:N-1];
    reg [CNT_W-1:0]        cnt;

    assign tap     = integ[N-1] + integ[N-2];
    assign dec_now = in_valid && (cnt == R[CNT_W-1:0] - 1'b1);

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

            cnt <= dec_now ? {CNT_W{1'b0}} : (cnt + 1'b1);
        end
    end

endmodule

`default_nettype wire
