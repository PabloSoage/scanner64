// ---------------------------------------------------------------------------
// nco.v - Numerically controlled oscillator.
//
// Phase accumulator + cosine LUT in dual-port BRAM. The sine comes out of the
// same table, addressed a quarter turn back, which saves half a BRAM.
//
// Direct transcription of the NCO class in model/ddc_model.py. If you change
// something here, change it there too and regenerate the vectors.
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
    input  wire                      en,        // advance the phase
    input  wire [PHASE_W-1:0]        ftw,       // frequency tuning word
    output reg  signed [LUT_W-1:0]   cos_o,
    output reg  signed [LUT_W-1:0]   sin_o
);

    localparam integer LUT_DEPTH   = 1 << LUT_ADDR_W;
    localparam integer QUARTER     = 1 << (LUT_ADDR_W - 2);

    // Cosine ROM. Inferred as a dual-port BRAM.
    (* rom_style = "block" *)
    reg signed [LUT_W-1:0] lut [0:LUT_DEPTH-1];
    initial $readmemh(LUT_FILE, lut);

    reg [PHASE_W-1:0] phase;

    wire [LUT_ADDR_W-1:0] addr_cos = phase[PHASE_W-1 -: LUT_ADDR_W];
    // sin(x) = cos(x - pi/2)  ->  subtract a quarter table (wraps naturally)
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
