// ---------------------------------------------------------------------------
// scanner_top.v — Banco de N canales DDC en paralelo, con medidor de potencia.
//
// Esto es el escaner: N frecuencias vigiladas SIMULTANEAMENTE, muestra a
// muestra, sin perder ni una. Cada canal tiene su propia palabra de sintonia,
// asi que las frecuencias son arbitrarias — no una rejilla fija como en un
// banco de filtros por FFT. Para vigilar los 16 canales de PMR446 mas unas
// cuantas frecuencias de aficionado a la vez, es exactamente lo que hace falta.
//
// ARQUITECTURA: peines compartidos
//
// El canal se parte en dos mitades que corren a tasas muy distintas:
//
//   ddc_front   NCO + mezclador + integradores. Una muestra por ciclo, asi
//               que hay uno por canal, obligatoriamente.
//   comb_bank   los peines. Trabajan 1 ciclo de cada CIC_R, asi que UN solo
//               juego atiende UNITS_PER_BANK unidades por turnos. Una unidad
//               es una cadena I o Q: son CH_PER_BANK = UNITS_PER_BANK/2
//               canales por banco.
//
// Replicar los peines por canal costaba 216 LUT y 360 FF por canal medidos, y
// dejaba el techo del chip en 144 canales. Compartiendolos sube a 191.
//
// CONSECUENCIA EN LA INTERFAZ: los canales YA NO salen todos en el mismo
// ciclo. El canal que ocupa la unidad u de su banco sale u ciclos despues del
// diezmado. Los valores son identicos bit a bit (lo comprueba tb_comb_bank),
// solo se reordenan en el tiempo, y ch_valid marca cada uno lo suyo. Si
// necesitas una foto simultanea de todos los canales, espera a que la ronda
// termine: dura UNITS_PER_BANK ciclos desde el diezmado.
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
    // Unidades (cadenas I o Q) por banco de peines. Tiene que ser par y menor
    // que CIC_R, para que la ronda termine antes del siguiente diezmado.
    parameter integer UNITS_PER_BANK = 32,
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

    localparam integer CH_PER_BANK = UNITS_PER_BANK / 2;
    localparam integer N_BANK      = (N_CH + CH_PER_BANK - 1) / CH_PER_BANK;
    localparam integer UW          = $clog2(UNITS_PER_BANK);

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

    // ---- Frentes de canal, a la tasa de entrada ----------------------------
    wire [N_CH-1:0]         fr_dec;
    wire signed [CIC_W-1:0] fr_tap_i [0:N_CH-1];
    wire signed [CIC_W-1:0] fr_tap_q [0:N_CH-1];

    genvar g;
    generate
        for (g = 0; g < N_CH; g = g + 1) begin : gen_front
            ddc_front #(
                .IN_W (IN_W), .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
                .LUT_W (LUT_W), .MIX_W (MIX_W), .CIC_N (CIC_N),
                .CIC_R (CIC_R), .CIC_W (CIC_W), .LUT_FILE (LUT_FILE)
            ) u_front (
                .clk (clk), .rst_n (rst_n),
                .ftw (ftw[g]),
                .in_valid (in_valid), .in_data (in_data),
                .dec_now (fr_dec[g]),
                .tap_i (fr_tap_i[g]), .tap_q (fr_tap_q[g])
            );
        end
    endgenerate

    // Todos los frentes comparten in_valid y arrancan del mismo reset, asi que
    // su dec_now cae en el mismo ciclo. Se toma el del canal 0 como referencia.
    wire dec_pulse = fr_dec[0];

    // ---- Bancos de peines compartidos --------------------------------------
    wire [N_BANK-1:0]        bk_valid;
    wire [UW-1:0]            bk_unit [0:N_BANK-1];
    wire signed [CIC_W-1:0]  bk_data [0:N_BANK-1];

    genvar b, u;
    generate
        for (b = 0; b < N_BANK; b = b + 1) begin : gen_bank
            wire [UNITS_PER_BANK*CIC_W-1:0] din_flat;

            for (u = 0; u < UNITS_PER_BANK; u = u + 1) begin : gen_map
                localparam integer CIDX = b*CH_PER_BANK + (u/2);
                if (CIDX < N_CH) begin : gen_used
                    // Unidad par -> rama I del canal; impar -> rama Q.
                    assign din_flat[u*CIC_W +: CIC_W] =
                        (u % 2 == 0) ? fr_tap_i[CIDX] : fr_tap_q[CIDX];
                end else begin : gen_spare
                    // Hueco del ultimo banco cuando N_CH no llena su cupo.
                    assign din_flat[u*CIC_W +: CIC_W] = {CIC_W{1'b0}};
                end
            end

            comb_bank #(
                .N_UNIT (UNITS_PER_BANK), .N (CIC_N), .ACC_W (CIC_W)
            ) u_comb (
                .clk (clk), .rst_n (rst_n),
                .start (dec_pulse), .din_flat (din_flat),
                .out_valid (bk_valid[b]),
                .out_unit  (bk_unit[b]),
                .out_data  (bk_data[b])
            );
        end
    endgenerate

    // ---- Realineado: de (banco, unidad) a (canal, I/Q) ---------------------
    // La normalizacion es el mismo desplazamiento que hacia ddc_channel: la
    // ganancia del CIC es (R*M)^N = 2^CIC_GROWTH exactos.
    reg signed [OUT_W-1:0] ch_i   [0:N_CH-1];
    reg signed [OUT_W-1:0] ch_q   [0:N_CH-1];
    reg signed [OUT_W-1:0] i_hold [0:N_CH-1];
    reg [N_CH-1:0]         ch_valid;

    integer                bi;
    integer                ci;
    reg [UW-1:0]           uu;
    reg signed [CIC_W-1:0] dd;

    always @(posedge clk) begin
        if (!rst_n) begin
            ch_valid <= {N_CH{1'b0}};
            for (k = 0; k < N_CH; k = k + 1) begin
                ch_i[k]   <= {OUT_W{1'b0}};
                ch_q[k]   <= {OUT_W{1'b0}};
                i_hold[k] <= {OUT_W{1'b0}};
            end
        end else begin
            ch_valid <= {N_CH{1'b0}};
            for (bi = 0; bi < N_BANK; bi = bi + 1) begin
                if (bk_valid[bi]) begin
                    uu = bk_unit[bi];
                    dd = bk_data[bi];
                    ci = bi*CH_PER_BANK + (uu >> 1);
                    if (ci < N_CH) begin
                        if (uu[0] == 1'b0) begin
                            i_hold[ci] <= dd[CIC_GROWTH +: OUT_W];
                        end else begin
                            // La rama Q llega justo detras de la I, asi que
                            // aqui ya estan las dos: se publica el par.
                            ch_i[ci]     <= i_hold[ci];
                            ch_q[ci]     <= dd[CIC_GROWTH +: OUT_W];
                            ch_valid[ci] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    // ---- Medidor de potencia, uno por canal --------------------------------
    reg [PWR_W-1:0]  pwr_acc  [0:N_CH-1];
    reg [31:0]       pwr_cnt  [0:N_CH-1];
    reg [PWR_W-1:0]  pwr_hold [0:N_CH-1];
    reg [N_CH-1:0]   pwr_done;

    generate
        for (g = 0; g < N_CH; g = g + 1) begin : gen_pwr
            // |I|^2 + |Q|^2 acumulado sobre una ventana. Dos multiplicadores
            // mas por canal (2 DSP48).
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
