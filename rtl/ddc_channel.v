// ---------------------------------------------------------------------------
// ddc_channel.v — Un canal completo de conversion a banda base.
//
//   x[n] --> [retardo] --> (x) --> CIC I --> >> --> I
//                           ^
//                        NCO cos/sin
//                           v
//            [retardo] --> (x) --> CIC Q --> >> --> Q
//
// Coste por canal, MEDIDO por sintesis out-of-context
// (Vivado 2026.1, xck26-sfvc784-2LV-c, un solo canal):
//   3 DSP48E2     la estimacion inicial de 2 se quedaba corta
//   1 BRAM tile   2x RAMB18E2: la LUT del NCO, hoy SIN compartir
//   600 CLB LUT   los acumuladores del CIC, que no usan DSP
//   677 FF
//   Fmax 220 MHz  post-sintesis con T=10 ns. Optimista: aun sin rutar.
//
// El recurso critico NO son los multiplicadores. Techos en el ZU5EV:
//   por DSP   1248 / 3   = 416 canales
//   por LUT   117120/600 = 195 canales
//   por BRAM  144 / 1    = 144 canales   <-- el muro real
//
// Compartir la LUT del NCO entre canales es lo unico que mueve ese techo.
//
// Desde la separacion en piezas, esto es ddc_front (NCO + mezclador +
// integradores) mas dos comb_chain y la normalizacion. En un banco de muchos
// canales conviene NO usar este modulo, sino ddc_front + comb_bank, que
// comparte los peines entre canales. Ver el README.
//
// Verificado: tb_ddc_channel compara contra los vectores dorados de
// model/ddc_model.py. 0 discrepancias.
// ---------------------------------------------------------------------------

`default_nettype none

module ddc_channel #(
    parameter integer IN_W       = 16,
    parameter integer OUT_W      = 18,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter integer CIC_GROWTH = 18,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [PHASE_W-1:0]         ftw,        // palabra de sintonia
    input  wire                       in_valid,
    input  wire signed [IN_W-1:0]     in_data,
    output wire                       out_valid,
    output wire signed [OUT_W-1:0]    out_i,
    output wire signed [OUT_W-1:0]    out_q
);

    // ---- Parte a tasa de entrada: NCO, mezclador e integradores -----------
    wire                    dec_now;
    wire signed [CIC_W-1:0] tap_i, tap_q;

    ddc_front #(
        .IN_W (IN_W), .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W (LUT_W), .MIX_W (MIX_W), .CIC_N (CIC_N), .CIC_R (CIC_R),
        .CIC_W (CIC_W), .LUT_FILE (LUT_FILE)
    ) u_front (
        .clk (clk), .rst_n (rst_n), .ftw (ftw),
        .in_valid (in_valid), .in_data (in_data),
        .dec_now (dec_now), .tap_i (tap_i), .tap_q (tap_q)
    );

    // ---- Peines propios, a la tasa diezmada --------------------------------
    wire                    cic_valid_i, cic_valid_q;
    wire signed [CIC_W-1:0] cic_i, cic_q;

    comb_chain #(.N (CIC_N), .ACC_W (CIC_W)) u_comb_i (
        .clk (clk), .rst_n (rst_n),
        .dec_now (dec_now), .din (tap_i),
        .out_valid (cic_valid_i), .out_data (cic_i)
    );

    comb_chain #(.N (CIC_N), .ACC_W (CIC_W)) u_comb_q (
        .clk (clk), .rst_n (rst_n),
        .dec_now (dec_now), .din (tap_q),
        .out_valid (cic_valid_q), .out_data (cic_q)
    );

    // ---- Normalizacion -----------------------------------------------------
    // La ganancia del CIC es (R*M)^N = 2^CIC_GROWTH exactos, asi que basta un
    // desplazamiento aritmetico. Nada de divisiones.
    assign out_valid = cic_valid_i;
    assign out_i     = cic_i[CIC_GROWTH +: OUT_W];
    assign out_q     = cic_q[CIC_GROWTH +: OUT_W];

endmodule

`default_nettype wire
