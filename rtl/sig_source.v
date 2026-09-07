// ---------------------------------------------------------------------------
// sig_source.v — Generador de senal de prueba dentro de la PL.
//
// Sin ADC no hay antena, asi que la "antena" la generamos aqui: dos tonos
// configurables mas ruido pseudoaleatorio. Sirve para:
//
//   · validar el escaner sin ningun hardware externo;
//   · alimentarlo a la MAXIMA tasa que aguante el reloj de la PL, que es
//     precisamente lo que ninguna CPU puede sostener;
//   · medir el rechazo fuera de banda con dos tonos de amplitud conocida.
//
// El ruido sale de un LFSR de 32 bits (polinomio x^32+x^22+x^2+x+1). No es
// ruido gaussiano, pero para comprobar suelo de ruido y rango dinamico sobra.
// ---------------------------------------------------------------------------

`default_nettype none

module sig_source #(
    parameter integer OUT_W      = 16,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      en,

    input  wire [PHASE_W-1:0]        ftw_a,      // tono A
    input  wire [PHASE_W-1:0]        ftw_b,      // tono B
    input  wire [3:0]                shift_a,    // atenuacion: amplitud >> shift
    input  wire [3:0]                shift_b,
    input  wire [3:0]                shift_n,    // nivel de ruido
    input  wire                      noise_en,

    output reg                       out_valid,
    output reg  signed [OUT_W-1:0]   out_data
);

    // ---- Dos NCO -----------------------------------------------------------
    wire signed [LUT_W-1:0] cos_a, sin_a, cos_b, sin_b;

    nco #(.PHASE_W(PHASE_W), .LUT_ADDR_W(LUT_ADDR_W),
          .LUT_W(LUT_W), .LUT_FILE(LUT_FILE)) u_a (
        .clk(clk), .rst_n(rst_n), .en(en), .ftw(ftw_a),
        .cos_o(cos_a), .sin_o(sin_a)
    );

    nco #(.PHASE_W(PHASE_W), .LUT_ADDR_W(LUT_ADDR_W),
          .LUT_W(LUT_W), .LUT_FILE(LUT_FILE)) u_b (
        .clk(clk), .rst_n(rst_n), .en(en), .ftw(ftw_b),
        .cos_o(cos_b), .sin_o(sin_b)
    );

    // ---- LFSR de ruido -----------------------------------------------------
    reg [31:0] lfsr;
    wire fb = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];

    always @(posedge clk) begin
        if (!rst_n)      lfsr <= 32'hACE1_2345;   // cualquier semilla no nula
        else if (en)     lfsr <= {lfsr[30:0], fb};
    end

    wire signed [LUT_W-1:0] noise = noise_en ? $signed(lfsr[LUT_W-1:0])
                                             : {LUT_W{1'b0}};

    // ---- Suma con saturacion ----------------------------------------------
    localparam signed [OUT_W-1:0] OUT_MAX =  (1 <<< (OUT_W-1)) - 1;
    localparam signed [OUT_W-1:0] OUT_MIN = -(1 <<< (OUT_W-1));

    wire signed [LUT_W+1:0] sum = (sin_a >>> shift_a)
                                + (sin_b >>> shift_b)
                                + (noise >>> shift_n);

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= {OUT_W{1'b0}};
        end else begin
            out_valid <= en;
            out_data  <= (sum > OUT_MAX) ? OUT_MAX :
                         (sum < OUT_MIN) ? OUT_MIN : sum[OUT_W-1:0];
        end
    end

endmodule

`default_nettype wire
