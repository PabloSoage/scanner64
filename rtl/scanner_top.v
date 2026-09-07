// ---------------------------------------------------------------------------
// scanner_top.v — Banco de N canales DDC en paralelo, con medidor de potencia.
//
// Esto es el escaner: N frecuencias vigiladas SIMULTANEAMENTE, muestra a
// muestra, sin perder ni una. Cada canal tiene su propia palabra de sintonia,
// asi que las frecuencias son arbitrarias — no una rejilla fija como en un
// banco de filtros por FFT. Para vigilar los 16 canales de PMR446 mas unas
// cuantas frecuencias de aficionado a la vez, es exactamente lo que hace falta.
//
// Por que esto no lo hace una CPU:
//   N=64 canales x 100 MSPS x ~18 operaciones/muestra ~= 115 Gop/s sostenidos,
//   sin perder muestras y con latencia acotada. Los cuatro Cortex-A53 de la
//   propia KV260 dan del orden de 10-15 Gop/s reales. Es un factor ~10 en el
//   MISMO chip. Ver sw/bench_cpu.py para medirlo en tu maquina.
//
// Interfaz de registros: sincrona y sencilla, a proposito. Envolverla en
// AXI4-Lite es un paso de Vivado (Create and Package IP), no algo que deba
// ensuciar el nucleo de DSP.
// ---------------------------------------------------------------------------

`default_nettype none

module scanner_top #(
    parameter integer N_CH       = 16,   // canales en paralelo
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
    parameter integer PWR_W      = 48,   // ancho del acumulador de potencia
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // --- Flujo de muestras de entrada (del ADC o de sig_source) ------------
    input  wire                        in_valid,
    input  wire signed [IN_W-1:0]      in_data,

    // --- Configuracion -----------------------------------------------------
    input  wire                        cfg_we,      // escribe ftw en cfg_ch
    input  wire [$clog2(N_CH)-1:0]     cfg_ch,
    input  wire [PHASE_W-1:0]          cfg_ftw,
    input  wire [31:0]                 cfg_pwr_len, // muestras por medida
    input  wire                        cfg_clear,   // reinicia acumuladores

    // --- Lectura de potencias ----------------------------------------------
    input  wire [$clog2(N_CH)-1:0]     rd_ch,
    output wire [PWR_W-1:0]            rd_pwr,
    output wire [N_CH-1:0]             pwr_ready,   // medida completa por canal

    // --- Muestras I/Q en crudo del canal seleccionado (para volcado por DMA)
    input  wire [$clog2(N_CH)-1:0]     tap_ch,
    output wire                        tap_valid,
    output wire signed [OUT_W-1:0]     tap_i,
    output wire signed [OUT_W-1:0]     tap_q
);

    // ---- Registros de sintonia, uno por canal ------------------------------
    reg [PHASE_W-1:0] ftw [0:N_CH-1];

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < N_CH; k = k + 1)
                ftw[k] <= {PHASE_W{1'b0}};
        end else if (cfg_we) begin
            ftw[cfg_ch] <= cfg_ftw;
        end
    end

    // ---- Banco de canales --------------------------------------------------
    wire [N_CH-1:0]        ch_valid;
    wire signed [OUT_W-1:0] ch_i [0:N_CH-1];
    wire signed [OUT_W-1:0] ch_q [0:N_CH-1];

    reg [PWR_W-1:0]  pwr_acc  [0:N_CH-1];
    reg [31:0]       pwr_cnt  [0:N_CH-1];
    reg [PWR_W-1:0]  pwr_hold [0:N_CH-1];
    reg [N_CH-1:0]   pwr_done;

    genvar g;
    generate
        for (g = 0; g < N_CH; g = g + 1) begin : gen_ch

            ddc_channel #(
                .IN_W (IN_W), .OUT_W (OUT_W), .PHASE_W (PHASE_W),
                .LUT_ADDR_W (LUT_ADDR_W), .LUT_W (LUT_W), .MIX_W (MIX_W),
                .CIC_N (CIC_N), .CIC_R (CIC_R), .CIC_W (CIC_W),
                .CIC_GROWTH (CIC_GROWTH), .LUT_FILE (LUT_FILE)
            ) u_ch (
                .clk (clk), .rst_n (rst_n),
                .ftw (ftw[g]),
                .in_valid (in_valid), .in_data (in_data),
                .out_valid (ch_valid[g]),
                .out_i (ch_i[g]), .out_q (ch_q[g])
            );

            // Medidor de potencia: |I|^2 + |Q|^2 acumulado sobre una ventana.
            // Dos multiplicadores mas por canal (2 DSP48).
            wire signed [2*OUT_W-1:0] mag2 = ch_i[g]*ch_i[g] + ch_q[g]*ch_q[g];

            always @(posedge clk) begin
                if (!rst_n || cfg_clear) begin
                    pwr_acc[g]  <= {PWR_W{1'b0}};
                    pwr_cnt[g]  <= 32'd0;
                    pwr_hold[g] <= {PWR_W{1'b0}};
                    pwr_done[g] <= 1'b0;
                end else if (ch_valid[g]) begin
                    if (pwr_cnt[g] + 1 >= cfg_pwr_len) begin
                        // Ventana completa: se congela el valor y se reinicia.
                        pwr_hold[g] <= pwr_acc[g] + mag2;
                        pwr_acc[g]  <= {PWR_W{1'b0}};
                        pwr_cnt[g]  <= 32'd0;
                        pwr_done[g] <= 1'b1;
                    end else begin
                        pwr_acc[g] <= pwr_acc[g] + mag2;
                        pwr_cnt[g] <= pwr_cnt[g] + 1;
                    end
                end
            end
        end
    endgenerate

    assign rd_pwr    = pwr_hold[rd_ch];
    assign pwr_ready = pwr_done;

    assign tap_valid = ch_valid[tap_ch];
    assign tap_i     = ch_i[tap_ch];
    assign tap_q     = ch_q[tap_ch];

endmodule

`default_nettype wire
