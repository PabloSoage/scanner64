// ---------------------------------------------------------------------------
// nco.v — Oscilador controlado numericamente.
//
// Acumulador de fase + LUT de coseno en BRAM de doble puerto. El seno se saca
// de la misma tabla desplazando un cuarto de vuelta, que ahorra media BRAM.
//
// Transcripcion directa de la clase NCO de model/ddc_model.py. Si cambias algo
// aqui, cambialo alli y regenera los vectores.
// ---------------------------------------------------------------------------

`default_nettype none

module nco #(
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      en,        // avanza la fase
    input  wire [PHASE_W-1:0]        ftw,       // palabra de sintonia
    output reg  signed [LUT_W-1:0]   cos_o,
    output reg  signed [LUT_W-1:0]   sin_o
);

    localparam integer LUT_DEPTH   = 1 << LUT_ADDR_W;
    localparam integer QUARTER     = 1 << (LUT_ADDR_W - 2);

    // ROM de coseno. Se infiere como BRAM de doble puerto.
    (* rom_style = "block" *)
    reg signed [LUT_W-1:0] lut [0:LUT_DEPTH-1];
    initial $readmemh(LUT_FILE, lut);

    reg [PHASE_W-1:0] phase;

    wire [LUT_ADDR_W-1:0] addr_cos = phase[PHASE_W-1 -: LUT_ADDR_W];
    // sin(x) = cos(x - pi/2)  ->  restar un cuarto de tabla (envolvente natural)
    wire [LUT_ADDR_W-1:0] addr_sin = addr_cos - QUARTER[LUT_ADDR_W-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            phase <= {PHASE_W{1'b0}};
            cos_o <= {LUT_W{1'b0}};
            sin_o <= {LUT_W{1'b0}};
        end else if (en) begin
            cos_o <= lut[addr_cos];
            sin_o <= lut[addr_sin];
            phase <= phase + ftw;
        end
    end

endmodule

`default_nettype wire
