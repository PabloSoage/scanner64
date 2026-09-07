// ---------------------------------------------------------------------------
// ddc_channel.v — Un canal completo de conversion a banda base.
//
//   x[n] --> [retardo] --> (x) --> CIC I --> >> --> I
//                           ^
//                        NCO cos/sin
//                           v
//            [retardo] --> (x) --> CIC Q --> >> --> Q
//
// Coste por canal (estimacion para Zynq UltraScale+):
//   2 DSP48E2   (los dos multiplicadores del mezclador)
//   ~1/2 BRAM   (la LUT del NCO, compartible entre canales)
//   ~250 LUT    (los acumuladores del CIC, que no usan DSP)
//
// Con 1248 DSP en el ZU5EV de la KV260, el limite practico no son los
// multiplicadores sino el rutado. 64 canales usan ~128 DSP: un 10 %.
//
// Verificado: model/rtl_check.py compara la semantica de este RTL contra los
// vectores dorados de model/ddc_model.py. 0 discrepancias.
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

    // ---- NCO ---------------------------------------------------------------
    wire signed [LUT_W-1:0] cos_v, sin_v;

    nco #(
        .PHASE_W    (PHASE_W),
        .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W      (LUT_W),
        .LUT_FILE   (LUT_FILE)
    ) u_nco (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (in_valid),
        .ftw   (ftw),
        .cos_o (cos_v),
        .sin_o (sin_v)
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

    // ---- Decimadores CIC ---------------------------------------------------
    wire                    cic_valid_i, cic_valid_q;
    wire signed [CIC_W-1:0] cic_i, cic_q;

    cic_decim #(.IN_W(MIX_W), .N(CIC_N), .R(CIC_R), .ACC_W(CIC_W)) u_cic_i (
        .clk (clk), .rst_n (rst_n),
        .in_valid (mix_valid), .in_data (mix_i),
        .out_valid (cic_valid_i), .out_data (cic_i)
    );

    cic_decim #(.IN_W(MIX_W), .N(CIC_N), .R(CIC_R), .ACC_W(CIC_W)) u_cic_q (
        .clk (clk), .rst_n (rst_n),
        .in_valid (mix_valid), .in_data (mix_q),
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
