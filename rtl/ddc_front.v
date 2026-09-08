// ---------------------------------------------------------------------------
// ddc_front.v — La parte del canal DDC que corre a la tasa de entrada.
//
//   x[n] --> [retardo] --> (x) --> integradores I --> tap_i
//                           ^
//                        NCO cos/sin
//                           v
//            [retardo] --> (x) --> integradores Q --> tap_q
//
// Es ddc_channel SIN los peines. Existe porque los peines corren a 1/R de esta
// tasa y conviene compartirlos entre canales (comb_bank), en vez de replicar
// uno por unidad.
//
// Quien quiera un canal completo y autonomo tiene ddc_channel, que es esto mas
// dos comb_chain y la normalizacion.
//
// Coste por canal MEDIDO (sintesis OOC, Vivado 2026.1, xck26-sfvc784-2LV-c):
// 486 LUT, 461 FF, 3 DSP48E2 y media BRAM tile, frente a los 703 LUT y 821 FF
// del canal con peines propios.
// ---------------------------------------------------------------------------

`default_nettype none

module ddc_front #(
    parameter integer IN_W       = 16,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [PHASE_W-1:0]        ftw,        // palabra de sintonia
    input  wire                      in_valid,
    input  wire signed [IN_W-1:0]    in_data,

    // Pulso de diezmado y los dos valores que van a los peines.
    output wire                      dec_now,
    output wire signed [CIC_W-1:0]   tap_i,
    output wire signed [CIC_W-1:0]   tap_q
);

    // ---- NCO ---------------------------------------------------------------
    wire signed [LUT_W-1:0] cos_v, sin_v;

    nco #(
        .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W (LUT_W), .LUT_FILE (LUT_FILE)
    ) u_nco (
        .clk (clk), .rst_n (rst_n), .en (in_valid),
        .ftw (ftw), .cos_o (cos_v), .sin_o (sin_v)
    );

    // ---- Retardo de la muestra, para alinearla con la salida del NCO -------
    reg signed [IN_W-1:0] x_d1;
    reg                   v_d1;

    // ---- Mezclador complejo ------------------------------------------------
    // El desplazamiento de LUT_W-1 deshace la escala de la LUT (32767 ~ 1.0).
    // Aqui SI hay que saturar: una envolvente genera chasquidos en la senal.
    localparam signed [MIX_W-1:0] MIX_MAX =  (1 <<< (MIX_W-1)) - 1;
    localparam signed [MIX_W-1:0] MIX_MIN = -(1 <<< (MIX_W-1));

    wire signed [IN_W+LUT_W-1:0] prod_i = x_d1 * cos_v;
    wire signed [IN_W+LUT_W-1:0] prod_q = -x_d1 * sin_v;

    wire signed [IN_W+LUT_W-1:0] shr_i = prod_i >>> (LUT_W-1);
    wire signed [IN_W+LUT_W-1:0] shr_q = prod_q >>> (LUT_W-1);

    reg signed [MIX_W-1:0] mix_i, mix_q;
    reg                    mix_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            x_d1      <= {IN_W{1'b0}};
            v_d1      <= 1'b0;
            mix_i     <= {MIX_W{1'b0}};
            mix_q     <= {MIX_W{1'b0}};
            mix_valid <= 1'b0;
        end else begin
            x_d1 <= in_data;
            v_d1 <= in_valid;

            mix_i <= (shr_i > MIX_MAX) ? MIX_MAX :
                     (shr_i < MIX_MIN) ? MIX_MIN : shr_i[MIX_W-1:0];
            mix_q <= (shr_q > MIX_MAX) ? MIX_MAX :
                     (shr_q < MIX_MIN) ? MIX_MIN : shr_q[MIX_W-1:0];
            mix_valid <= v_d1;
        end
    end

    // ---- Integradores ------------------------------------------------------
    // Los dos comparten in_valid, asi que su dec_now es el mismo. Se toma el
    // de la rama I.
    wire dec_q_unused;

    cic_integ #(.IN_W(MIX_W), .N(CIC_N), .R(CIC_R), .ACC_W(CIC_W)) u_int_i (
        .clk (clk), .rst_n (rst_n),
        .in_valid (mix_valid), .in_data (mix_i),
        .dec_now (dec_now), .tap (tap_i)
    );

    cic_integ #(.IN_W(MIX_W), .N(CIC_N), .R(CIC_R), .ACC_W(CIC_W)) u_int_q (
        .clk (clk), .rst_n (rst_n),
        .in_valid (mix_valid), .in_data (mix_q),
        .dec_now (dec_q_unused), .tap (tap_q)
    );

endmodule

`default_nettype wire
