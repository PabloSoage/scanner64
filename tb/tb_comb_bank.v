// ---------------------------------------------------------------------------
// tb_comb_bank.v — Equivalencia entre los peines replicados y los compartidos.
//
// No compara contra vectores dorados sino contra el propio RTL ya verificado:
// instancia N_UNIT cic_decim (la referencia, que pasa tb_ddc_channel) y un
// comb_bank alimentado con los mismos datos, y comprueba que sacan
// exactamente lo mismo.
//
// Es la prueba que hay que pasar para que el multiplexado sea legitimo: los
// valores tienen que ser identicos bit a bit. Lo unico que puede cambiar es
// CUANDO sale cada unidad.
//
// Cada unidad recibe una secuencia DISTINTA, para que cualquier cruce de
// estado entre unidades salte a la vista.
//
// Ejecutar con XSim:
//     xvlog -sv -i vectors ../rtl/cic_decim.v ../rtl/comb_bank.v \
//                          ../tb/tb_comb_bank.v
//     xelab tb_comb_bank -s tb_cb
//     xsim tb_cb -runall
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tb_comb_bank;

    localparam integer N_UNIT = 8;      // unidades a comparar
    localparam integer IN_W   = 18;     // = MIX_W, la salida del mezclador
    localparam integer N      = 3;
    localparam integer R      = 64;
    localparam integer ACC_W  = 36;
    localparam integer UW     = $clog2(N_UNIT);
    localparam integer N_STIM = 3072;
    localparam integer SETTLE = 2;      // rondas iniciales que se ignoran

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg signed [IN_W-1:0] stim [0:N_STIM-1];

    // ---- Referencia: N_UNIT cic_decim independientes -----------------------
    reg                     in_valid = 1'b0;
    reg signed [IN_W-1:0]   in_data [0:N_UNIT-1];

    wire [N_UNIT-1:0]        ref_valid;
    wire signed [ACC_W-1:0]  ref_data  [0:N_UNIT-1];
    wire signed [ACC_W-1:0]  ref_ilast [0:N_UNIT-1];

    wire [N_UNIT*ACC_W-1:0] din_flat;

    genvar g;
    generate
        for (g = 0; g < N_UNIT; g = g + 1) begin : gen_ref
            cic_decim #(.IN_W(IN_W), .N(N), .R(R), .ACC_W(ACC_W)) u_cic (
                .clk (clk), .rst_n (rst_n),
                .in_valid (in_valid), .in_data (in_data[g]),
                .out_valid (ref_valid[g]), .out_data (ref_data[g])
            );
            // El valor que el cic entrega a sus peines. Es lo que el banco
            // compartido tiene que recibir.
            assign ref_ilast[g] = gen_ref[g].u_cic.tap;
            assign din_flat[g*ACC_W +: ACC_W] = ref_ilast[g];
        end
    endgenerate

    wire start = gen_ref[0].u_cic.dec_now;

    // ---- Unidad bajo prueba: un solo juego de peines -----------------------
    wire                     bank_valid;
    wire [UW-1:0]            bank_unit;
    wire signed [ACC_W-1:0]  bank_data;

    comb_bank #(.N_UNIT(N_UNIT), .N(N), .ACC_W(ACC_W)) dut (
        .clk (clk), .rst_n (rst_n),
        .start (start), .din_flat (din_flat),
        .out_valid (bank_valid), .out_unit (bank_unit), .out_data (bank_data)
    );

    // ---- Captura de la referencia ------------------------------------------
    reg signed [ACC_W-1:0] ref_hold [0:N_UNIT-1];
    reg [31:0]             ref_round [0:N_UNIT-1];
    reg [31:0]             round = 32'd0;

    integer c;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (c = 0; c < N_UNIT; c = c + 1) begin
                ref_hold[c]  <= {ACC_W{1'b0}};
                ref_round[c] <= 32'd0;
            end
            round <= 32'd0;
        end else begin
            if (start) round <= round + 1;
            for (c = 0; c < N_UNIT; c = c + 1)
                if (ref_valid[c]) begin
                    ref_hold[c]  <= ref_data[c];
                    ref_round[c] <= round;
                end
        end
    end

    // ---- Comparacion, un ciclo despues para que ref_hold ya este puesta ----
    reg                     bv_d = 1'b0;
    reg [UW-1:0]            bu_d = {UW{1'b0}};
    reg signed [ACC_W-1:0]  bd_d = {ACC_W{1'b0}};

    integer errors  = 0;
    integer checked = 0;
    integer per_unit [0:N_UNIT-1];

    initial for (c = 0; c < N_UNIT; c = c + 1) per_unit[c] = 0;

    always @(posedge clk) begin
        bv_d <= bank_valid;
        bu_d <= bank_unit;
        bd_d <= bank_data;

        if (rst_n && bv_d && round > SETTLE) begin
            checked = checked + 1;
            per_unit[bu_d] = per_unit[bu_d] + 1;
            if (bd_d !== ref_hold[bu_d]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  unidad %0d ronda %0d: referencia %0d, banco %0d",
                             bu_d, round, ref_hold[bu_d], bd_d);
            end
        end
    end

    // ---- Estimulo: una secuencia distinta por unidad -----------------------
    integer si, k;
    initial begin
        $readmemh("vectors/stim.hex", stim);
        for (k = 0; k < N_UNIT; k = k + 1) in_data[k] = {IN_W{1'b0}};

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        for (si = 0; si < N_STIM; si = si + 1) begin
            in_valid <= 1'b1;
            for (k = 0; k < N_UNIT; k = k + 1)
                in_data[k] <= stim[(si + k*37) % N_STIM];
            @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (200) @(posedge clk);

        report_and_finish;
    end

    integer min_per_unit;
    task report_and_finish;
        begin
            min_per_unit = per_unit[0];
            for (c = 1; c < N_UNIT; c = c + 1)
                if (per_unit[c] < min_per_unit) min_per_unit = per_unit[c];
            $display("");
            $display("tb_comb_bank   (%0d unidades con un solo juego de peines)", N_UNIT);
            $display("  rondas de diezmado : %0d", round);
            $display("  comparadas         : %0d", checked);
            $display("  por unidad (min)   : %0d", min_per_unit);
            $display("  discrepancias      : %0d", errors);
            $display("");
            if (min_per_unit < 8)
                $display("RESULTADO: FALLA — alguna unidad se comparo muy poco (%0d).", min_per_unit);
            else if (errors == 0)
                $display("RESULTADO: PASA — los peines compartidos dan lo mismo, bit a bit.");
            else
                $display("RESULTADO: FALLA — %0d discrepancias", errors);
            $display("");
            $finish;
        end
    endtask

endmodule

`default_nettype wire
