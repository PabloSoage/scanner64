// ---------------------------------------------------------------------------
// scanner_axi.v — scanner_top + sig_source, con interfaz AXI4-Lite.
//
// Lo que hace falta para meter el escaner en la PL de la KV260 y hablar con el
// desde Linux. Sin DMA: para VALIDAR el diseno en silicio basta con registros.
//
//   sig_source  genera el estimulo DENTRO de la PL, a la tasa del reloj. Es la
//               variante (a) de METODOLOGIA.md: las muestras nacen en la PL y
//               el generador es hardware aparte que no le roba un solo ciclo
//               al DDC. En una CPU generar cuesta la mitad del tiempo; aqui,
//               cero.
//   scanner_top los N canales.
//   AXI4-Lite   configuracion y lectura de potencias.
//
// Los contadores de muestras y de salidas son la prueba de que no se pierde
// nada: a 100 MSPS, smp_cnt tiene que avanzar exactamente un paso por ciclo
// con el generador activo, y out_cnt uno por cada CIC_R muestras. Si la PL
// perdiera una sola muestra, la relacion dejaria de cuadrar.
//
// UN SOLO DOMINIO DE RELOJ. El AXI y el escaner van con el mismo `clk`, que
// sera el pl_clk0 del PS (100 MHz por defecto). No hay cruce de dominios que
// razonar, y 100 MHz entra de sobra en los 170 MHz que cierra el diseno.
//
// MAPA DE REGISTROS (offsets de byte)
//
//   0x00  ID        RO  0x5CA44E64, para comprobar que el bitstream es este
//   0x04  CTRL      RW  [0] run (reset activo bajo del escaner)
//                       [1] src_en      generador en marcha
//                       [2] noise_en    anade ruido del LFSR
//                       [3] clear       pulso: reinicia los acumuladores
//   0x08  SRC_FTWA  RW  palabra de sintonia del tono A del generador
//   0x0C  SRC_FTWB  RW  idem tono B
//   0x10  SRC_SH    RW  [3:0] shift_a  [7:4] shift_b  [11:8] shift_n
//   0x14  CFG_CH    RW  canal al que apunta la siguiente escritura de sintonia
//   0x18  CFG_FTW   RW  escribir aqui carga la sintonia en el canal CFG_CH
//   0x1C  PWR_LEN   RW  muestras por ventana de medida de potencia
//   0x20  RD_CH     RW  canal cuya potencia se lee
//   0x24  PWR_LO    RO  potencia del canal RD_CH, bits 31:0
//   0x28  PWR_HI    RO  bits 47:32
//   0x2C  READY     RO  pwr_ready, un bit por canal (hasta 32)
//   0x30  SMP_LO    RO  muestras entradas al escaner, bits 31:0
//   0x34  SMP_HI    RO  bits 63:32
//   0x38  OUT_CNT   RO  salidas producidas por el canal 0
//   0x3C  NCH       RO  numero de canales sintetizado
//   0x40  TAP_I     RO  ultima muestra I del canal RD_CH (con signo, 18 b)
//   0x44  TAP_Q     RO  ultima muestra Q
//   0x48  TAP_CNT   RO  cuantas muestras I/Q ha soltado ese canal
//   0x4C  STATUS    RO  [0] fold_overrun   [5:1] FOLD sintetizado
//
// Los TAP no sirven para volcar datos --cambian a 1.5 MSPS y AXI-Lite no da
// para tanto-- pero si para ver que hay actividad y que los valores son
// razonables. El volcado continuo es lo que pedira un DMA, mas adelante.
// ---------------------------------------------------------------------------

`default_nettype none

module scanner_axi #(
    parameter integer N_CH       = 16,
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
    parameter integer PWR_W      = 48,
    parameter integer UNITS_PER_BANK = 32,
    parameter integer FOLD       = 1,
    parameter         LUT_FILE   = "sin_lut.mem",
    parameter integer C_S_AXI_ADDR_WIDTH = 7      // 128 bytes = 32 registros
) (
    // --- AXI4-Lite slave, mismo reloj que el escaner -----------------------
    input  wire                                 s_axi_aclk,
    input  wire                                 s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire [2:0]                           s_axi_awprot,
    input  wire                                 s_axi_awvalid,
    output reg                                  s_axi_awready,

    input  wire [31:0]                          s_axi_wdata,
    input  wire [3:0]                           s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output reg                                  s_axi_wready,

    output reg  [1:0]                           s_axi_bresp,
    output reg                                  s_axi_bvalid,
    input  wire                                 s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire [2:0]                           s_axi_arprot,
    input  wire                                 s_axi_arvalid,
    output reg                                  s_axi_arready,

    output reg  [31:0]                          s_axi_rdata,
    output reg  [1:0]                           s_axi_rresp,
    output reg                                  s_axi_rvalid,
    input  wire                                 s_axi_rready
);

    localparam [31:0] MAGIC_ID = 32'h5CA4_4E64;
    localparam integer CH_W = (N_CH > 1) ? $clog2(N_CH) : 1;

    wire clk   = s_axi_aclk;
    wire rst_n = s_axi_aresetn;

    // ---- Registros de escritura -------------------------------------------
    reg        r_run, r_src_en, r_noise_en;
    reg [31:0] r_ftw_a, r_ftw_b;
    reg [11:0] r_shift;
    reg [31:0] r_cfg_ch, r_cfg_ftw, r_pwr_len, r_rd_ch;
    reg        r_cfg_we, r_clear;      // pulsos de un ciclo

    // ---- Generador dentro de la PL ----------------------------------------
    wire                    src_valid;
    wire signed [IN_W-1:0]  src_data;

    sig_source #(
        .OUT_W (IN_W), .PHASE_W (PHASE_W), .LUT_ADDR_W (LUT_ADDR_W),
        .LUT_W (LUT_W), .LUT_FILE (LUT_FILE)
    ) u_src (
        .clk (clk), .rst_n (rst_n && r_run), .en (r_src_en),
        .ftw_a (r_ftw_a), .ftw_b (r_ftw_b),
        .shift_a (r_shift[3:0]), .shift_b (r_shift[7:4]),
        .shift_n (r_shift[11:8]), .noise_en (r_noise_en),
        .out_valid (src_valid), .out_data (src_data)
    );

    // ---- El escaner --------------------------------------------------------
    wire [PWR_W-1:0]        rd_pwr;
    wire [N_CH-1:0]         pwr_ready;
    wire                    tap_valid;
    wire signed [OUT_W-1:0] tap_i, tap_q;
    wire                    fold_overrun;

    scanner_top #(
        .N_CH (N_CH), .IN_W (IN_W), .OUT_W (OUT_W), .PHASE_W (PHASE_W),
        .LUT_ADDR_W (LUT_ADDR_W), .LUT_W (LUT_W), .MIX_W (MIX_W),
        .CIC_N (CIC_N), .CIC_R (CIC_R), .CIC_W (CIC_W),
        .CIC_GROWTH (CIC_GROWTH), .PWR_W (PWR_W),
        .UNITS_PER_BANK (UNITS_PER_BANK), .FOLD (FOLD), .LUT_FILE (LUT_FILE)
    ) u_scan (
        .clk (clk), .rst_n (rst_n && r_run),
        .in_valid (src_valid), .in_data (src_data),
        .cfg_we (r_cfg_we), .cfg_ch (r_cfg_ch[CH_W-1:0]),
        .cfg_ftw (r_cfg_ftw), .cfg_pwr_len (r_pwr_len), .cfg_clear (r_clear),
        .rd_ch (r_rd_ch[CH_W-1:0]), .rd_pwr (rd_pwr), .pwr_ready (pwr_ready),
        .tap_ch (r_rd_ch[CH_W-1:0]), .tap_valid (tap_valid),
        .tap_i (tap_i), .tap_q (tap_q), .fold_overrun (fold_overrun)
    );

    // ---- Contadores: la prueba de que no se pierde una muestra ------------
    reg [63:0] smp_cnt;
    reg [31:0] out_cnt;
    reg signed [OUT_W-1:0] tap_i_r, tap_q_r;

    always @(posedge clk) begin
        if (!rst_n || !r_run || r_clear) begin
            smp_cnt <= 64'd0;
            out_cnt <= 32'd0;
            tap_i_r <= {OUT_W{1'b0}};
            tap_q_r <= {OUT_W{1'b0}};
        end else begin
            if (src_valid)  smp_cnt <= smp_cnt + 64'd1;
            if (tap_valid) begin
                out_cnt <= out_cnt + 32'd1;
                // Se congela la ultima muestra del canal seleccionado, para
                // poder mirarla por AXI sin necesidad de DMA.
                tap_i_r <= tap_i;
                tap_q_r <= tap_q;
            end
        end
    end

    // ---- AXI4-Lite: escritura ---------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] waddr;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            waddr         <= {C_S_AXI_ADDR_WIDTH{1'b0}};

            r_run      <= 1'b0;
            r_src_en   <= 1'b0;
            r_noise_en <= 1'b0;
            r_ftw_a    <= 32'h1999_999A;   // 10 MHz a 100 MSPS
            r_ftw_b    <= 32'h2666_6666;   // 15 MHz a 100 MSPS
            r_shift    <= 12'h022;         // los dos tonos a 1/4: la suma no satura
            r_cfg_ch   <= 32'd0;
            r_cfg_ftw  <= 32'd0;
            r_pwr_len  <= 32'd1024;
            r_rd_ch    <= 32'd0;
            r_cfg_we   <= 1'b0;
            r_clear    <= 1'b0;
        end else begin
            r_cfg_we <= 1'b0;            // pulsos de un solo ciclo
            r_clear  <= 1'b0;

            // Direccion y dato llegan juntos: se aceptan a la vez.
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                waddr         <= s_axi_awaddr;
            end else begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
            end

            if (s_axi_awready && s_axi_wready) begin
                case (waddr[C_S_AXI_ADDR_WIDTH-1:2])
                    5'h01: begin                       // CTRL
                        r_run      <= s_axi_wdata[0];
                        r_src_en   <= s_axi_wdata[1];
                        r_noise_en <= s_axi_wdata[2];
                        r_clear    <= s_axi_wdata[3];
                    end
                    5'h02: r_ftw_a   <= s_axi_wdata;
                    5'h03: r_ftw_b   <= s_axi_wdata;
                    5'h04: r_shift   <= s_axi_wdata[11:0];
                    5'h05: r_cfg_ch  <= s_axi_wdata;
                    5'h06: begin                       // CFG_FTW: carga y dispara
                        r_cfg_ftw <= s_axi_wdata;
                        r_cfg_we  <= 1'b1;
                    end
                    5'h07: r_pwr_len <= s_axi_wdata;
                    5'h08: r_rd_ch   <= s_axi_wdata;
                    default: ;                        // RO o sin usar
                endcase
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;                // OKAY
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---- AXI4-Lite: lectura ------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] raddr;
    reg [31:0] rmux;

    // pwr_ready puede tener menos de 32 bits: se rellena con ceros. Va por
    // generate porque una replicacion de ancho CERO es ilegal en Verilog, y
    // con N_CH >= 32 eso es lo que saldria.
    wire [31:0] ready_ext;
    generate
        if (N_CH >= 32) assign ready_ext = pwr_ready[31:0];
        else            assign ready_ext = {{(32-N_CH){1'b0}}, pwr_ready};
    endgenerate

    always @(*) begin
        case (raddr[C_S_AXI_ADDR_WIDTH-1:2])
            5'h00: rmux = MAGIC_ID;
            5'h01: rmux = {28'd0, r_clear, r_noise_en, r_src_en, r_run};
            5'h02: rmux = r_ftw_a;
            5'h03: rmux = r_ftw_b;
            5'h04: rmux = {20'd0, r_shift};
            5'h05: rmux = r_cfg_ch;
            5'h06: rmux = r_cfg_ftw;
            5'h07: rmux = r_pwr_len;
            5'h08: rmux = r_rd_ch;
            5'h09: rmux = rd_pwr[31:0];
            5'h0A: rmux = {{(32 - (PWR_W - 32)){1'b0}}, rd_pwr[PWR_W-1:32]};
            5'h0B: rmux = ready_ext;
            5'h0C: rmux = smp_cnt[31:0];
            5'h0D: rmux = smp_cnt[63:32];
            5'h0E: rmux = out_cnt;
            5'h0F: rmux = N_CH;
            5'h10: rmux = {{(32-OUT_W){tap_i_r[OUT_W-1]}}, tap_i_r};
            5'h11: rmux = {{(32-OUT_W){tap_q_r[OUT_W-1]}}, tap_q_r};
            5'h12: rmux = out_cnt;
            // STATUS. El bit de desbordamiento importa mas de lo que su tamaño
            // sugiere: con plegado, alimentar mas rapido de Fs = Fclk/FOLD
            // descarta muestras y la salida sigue pareciendo una señal. Sin
            // este bit, esa perdida es invisible desde software.
            5'h13: rmux = {26'd0, FOLD[4:0], fold_overrun};
            default: rmux = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'd0;
            raddr         <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                raddr         <= s_axi_araddr;
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;                // OKAY
                s_axi_rdata  <= rmux;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
