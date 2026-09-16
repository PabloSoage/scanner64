// ---------------------------------------------------------------------------
// comb_chain.v - CIC combs for ONE unit, at the decimated rate.
//
// Split out of cic_decim. This is the "one comb chain per unit" version, the
// simple one, and the one ddc_channel uses when instantiated on its own.
//
// For a bank of many channels there is comb_bank, which does exactly the same
// thing with a single set of combs taking turns between 32 units. Both produce
// bit-identical values; tb_comb_bank checks that.
//
// THE CASCADES ARE REGISTERED, not combinational. Each stage uses the PREVIOUS
// value of the one before it. The textbook version chains them within the same
// cycle, which creates an N*ACC_W-bit carry chain that will not close timing.
// Same transfer function, only the latency changes.
//
// Requires N >= 2.
// ---------------------------------------------------------------------------

`default_nettype none

module comb_chain #(
    parameter integer N     = 3,
    parameter integer ACC_W = 36
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    dec_now,   // decimation pulse
    input  wire signed [ACC_W-1:0] din,       // integrator tap

    output reg                     out_valid,
    output reg  signed [ACC_W-1:0] out_data
);

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
            if (dec_now) begin
                comb_val[0]  <= din - comb_prev[0];
                comb_prev[0] <= din;
                for (j = 1; j < N; j = j + 1) begin
                    comb_val[j]  <= comb_val[j-1] - comb_prev[j];  // PREVIOUS value
                    comb_prev[j] <= comb_val[j-1];
                end
                // Same expression that gets assigned to comb_val[N-1]: the
                // output is the NEW value of the last comb stage.
                out_data  <= comb_val[N-2] - comb_prev[N-1];
                out_valid <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
