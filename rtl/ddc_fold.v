// ---------------------------------------------------------------------------
// ddc_fold.v — Un juego de NCO, mezclador e integradores para FOLD canales.
//
// LA IDEA
//
// Los integradores procesan una muestra por ciclo de reloj. Si el reloj va mas
// rapido que los datos, ese juego esta ocioso la mayor parte del tiempo:
//
//     canales por juego = floor(Fclk / Fs)
//
// A 100 MHz de reloj y 25 MSPS de antena sobran tres de cada cuatro ciclos.
// Plegando, un solo juego atiende cuatro canales y el area por canal se divide
// por cuatro. Es el compromiso que ninguna CPU ni GPU puede ofrecer: aqui el
// ancho de banda se cambia por canales, y la eleccion es del que integra.
//
// Y ataca justo el recurso que limita. Medido en el barrido de N_CH: la BRAM
// es lo primero que se acaba (~143 canales) porque cada canal se lleva un tile
// entero para su ROM de seno. Plegando, FOLD canales comparten UNA ROM.
//
// COMO SE EVITA EL RIESGO DE LA TUBERIA
//
// El peligro de multiplexar un filtro recursivo es leer el estado de un canal
// antes de que se haya escrito el de su vuelta anterior. Aqui no puede pasar,
// por construccion:
//
//   - La fase se lee Y se escribe en la etapa 0, el mismo ciclo.
//   - El estado del CIC se lee Y se escribe en la ultima etapa, el mismo ciclo.
//
// Entre medias la tuberia solo ARRASTRA el numero de ranura. Ningun estado
// queda en vuelo entre su lectura y su escritura, asi que FOLD puede ser
// cualquier valor >= 1 sin necesidad de adelantamiento.
//
//     etapa 0   ranura s: direccion de la ROM desde phase[s], phase[s] += ftw[s]
//     etapa 1   sale el seno y el coseno (la ROM esta registrada)
//     etapa 2   el producto del mezclador
//     etapa 3   desplazamiento y saturacion
//     etapa 4   integradores de la ranura s, y diezmado
//
// EL RESET SI LIMPIA, A DIFERENCIA DE comb_bank
//
// comb_bank deja su estado sin resetear a proposito, para que viva en LUTRAM en
// vez de en 7001 flip-flops. Aqui se hace lo contrario y conviene decir por que:
// el estado son unos 1100 bits con FOLD=4, que no salvan nada, y la alternativa
// ya nos costo una tarde --las primeras salidas tras un reset en caliente eran
// basura y no lo era el diseno--. Correccion por delante de un ahorro que no
// existe.
// ---------------------------------------------------------------------------

`default_nettype none

module ddc_fold #(
    parameter integer FOLD       = 4,       // canales por juego
    parameter integer IN_W       = 16,
    parameter integer PHASE_W    = 32,
    parameter integer LUT_ADDR_W = 10,
    parameter integer LUT_W      = 16,
    parameter integer MIX_W      = 18,
    parameter integer CIC_N      = 3,
    parameter integer CIC_R      = 64,
    parameter integer CIC_W      = 36,
    parameter         LUT_FILE   = "sin_lut.mem",
    // Derivado de FOLD, pero tiene que vivir en la lista de parametros: un
    // localparam del cuerpo no se puede usar en la lista de puertos.
    parameter integer SLOT_W     = (FOLD > 1) ? $clog2(FOLD) : 1
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // Sintonia, una por ranura.
    input  wire                      cfg_we,
    input  wire [SLOT_W-1:0]         cfg_slot,
    input  wire [PHASE_W-1:0]        cfg_ftw,

    // Una muestra cada FOLD ciclos como mucho: la ronda tarda eso en pasar.
    input  wire                      in_valid,
    input  wire signed [IN_W-1:0]    in_data,
    output wire                      ready,      // puede aceptar otra muestra

    // Salida diezmada, con la ranura a la que pertenece.
    output reg                       out_valid,
    output reg  [SLOT_W-1:0]         out_slot,
    output reg  signed [CIC_W-1:0]   tap_i,
    output reg  signed [CIC_W-1:0]   tap_q,

    // Se pega en alto si llega una muestra mientras la ronda anterior sigue
    // en curso. El plegado EXIGE Fs <= Fclk/FOLD; si se le alimenta mas rapido
    // descarta muestras, y lo haria en silencio. Una salida diezmada con
    // muestras perdidas sigue pareciendo una señal, asi que el unico modo de
    // enterarse es que el propio hardware lo diga.
    output reg                       overrun
);

    localparam integer CNT_W   = $clog2(CIC_R);
    localparam integer QUARTER = 1 << (LUT_ADDR_W - 2);
    localparam integer DEPTH   = 1 << LUT_ADDR_W;

    // ---- La ROM que comparten las FOLD ranuras -----------------------------
    (* rom_style = "block" *)
    reg signed [LUT_W-1:0] lut [0:DEPTH-1];
    initial $readmemh(LUT_FILE, lut);

    // ---- Estado por ranura -------------------------------------------------
    reg [PHASE_W-1:0] phase [0:FOLD-1];
    reg [PHASE_W-1:0] ftw   [0:FOLD-1];
    reg [CNT_W-1:0]   cnt   [0:FOLD-1];
    // Aplanados: [ranura*CIC_N + etapa]
    reg signed [CIC_W-1:0] acc_i [0:FOLD*CIC_N-1];
    reg signed [CIC_W-1:0] acc_q [0:FOLD*CIC_N-1];

    integer k;

    // ---- Control de la ronda -----------------------------------------------
    reg               busy;
    reg [SLOT_W-1:0]  slot;
    reg signed [IN_W-1:0] x_hold;

    assign ready = !busy;

    // ---- Tuberia: valido y ranura arrastrados ------------------------------
    reg              v1, v2, v3, v4;
    reg [SLOT_W-1:0] s1, s2, s3, s4;

    reg signed [LUT_W-1:0] cos_r, sin_r;
    reg signed [IN_W-1:0]  x1;

    reg signed [IN_W+LUT_W-1:0] prod_i_r, prod_q_r;

    localparam signed [MIX_W-1:0] MIX_MAX =  (1 <<< (MIX_W-1)) - 1;
    localparam signed [MIX_W-1:0] MIX_MIN = -(1 <<< (MIX_W-1));

    wire signed [IN_W+LUT_W-1:0] shr_i = prod_i_r >>> (LUT_W-1);
    wire signed [IN_W+LUT_W-1:0] shr_q = prod_q_r >>> (LUT_W-1);

    reg signed [MIX_W-1:0] mix_i, mix_q;

    // Direccion de la ROM para la ranura que se emite en la etapa 0.
    wire [LUT_ADDR_W-1:0] addr_cos = phase[slot][PHASE_W-1 -: LUT_ADDR_W];
    wire [LUT_ADDR_W-1:0] addr_sin = addr_cos - QUARTER[LUT_ADDR_W-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            slot      <= {SLOT_W{1'b0}};
            x_hold    <= {IN_W{1'b0}};
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0;
            s1 <= {SLOT_W{1'b0}}; s2 <= {SLOT_W{1'b0}};
            s3 <= {SLOT_W{1'b0}}; s4 <= {SLOT_W{1'b0}};
            cos_r <= {LUT_W{1'b0}}; sin_r <= {LUT_W{1'b0}};
            x1    <= {IN_W{1'b0}};
            prod_i_r <= {(IN_W+LUT_W){1'b0}};
            prod_q_r <= {(IN_W+LUT_W){1'b0}};
            mix_i <= {MIX_W{1'b0}}; mix_q <= {MIX_W{1'b0}};
            out_valid <= 1'b0;
            out_slot  <= {SLOT_W{1'b0}};
            tap_i <= {CIC_W{1'b0}};
            tap_q <= {CIC_W{1'b0}};
            overrun <= 1'b0;
            for (k = 0; k < FOLD; k = k + 1) begin
                phase[k] <= {PHASE_W{1'b0}};
                ftw[k]   <= {PHASE_W{1'b0}};
                cnt[k]   <= {CNT_W{1'b0}};
            end
            for (k = 0; k < FOLD*CIC_N; k = k + 1) begin
                acc_i[k] <= {CIC_W{1'b0}};
                acc_q[k] <= {CIC_W{1'b0}};
            end
        end else begin
            if (cfg_we) ftw[cfg_slot] <= cfg_ftw;
            if (in_valid && busy) overrun <= 1'b1;

            // --- Etapa 0: arranque de ronda y direccionamiento de la ROM ----
            v1 <= 1'b0;
            if (in_valid && !busy) begin
                busy   <= 1'b1;
                x_hold <= in_data;
                // La ranura 0 se emite ya, con la muestra recien llegada.
                cos_r <= lut[phase[0][PHASE_W-1 -: LUT_ADDR_W]];
                sin_r <= lut[(phase[0][PHASE_W-1 -: LUT_ADDR_W])
                             - QUARTER[LUT_ADDR_W-1:0]];
                phase[0] <= phase[0] + ftw[0];
                x1 <= in_data;
                v1 <= 1'b1;
                s1 <= {SLOT_W{1'b0}};
                slot <= (FOLD > 1) ? {{(SLOT_W-1){1'b0}}, 1'b1} : {SLOT_W{1'b0}};
                if (FOLD == 1) busy <= 1'b0;
            end else if (busy) begin
                cos_r <= lut[addr_cos];
                sin_r <= lut[addr_sin];
                phase[slot] <= phase[slot] + ftw[slot];
                x1 <= x_hold;
                v1 <= 1'b1;
                s1 <= slot;
                if (slot == FOLD[SLOT_W-1:0] - 1'b1) busy <= 1'b0;
                else slot <= slot + 1'b1;
            end

            // --- Etapa 2: el producto ---------------------------------------
            prod_i_r <= x1 *  cos_r;
            prod_q_r <= -x1 * sin_r;
            v2 <= v1;
            s2 <= s1;

            // --- Etapa 3: desplazamiento y saturacion -----------------------
            mix_i <= (shr_i > MIX_MAX) ? MIX_MAX :
                     (shr_i < MIX_MIN) ? MIX_MIN : shr_i[MIX_W-1:0];
            mix_q <= (shr_q > MIX_MAX) ? MIX_MAX :
                     (shr_q < MIX_MIN) ? MIX_MIN : shr_q[MIX_W-1:0];
            v3 <= v2;
            s3 <= s2;

            // --- Etapa 4: integradores de la ranura s3 ----------------------
            // Cascada REGISTRADA: cada etapa usa el valor PREVIO de la
            // anterior. Leer y escribir en el mismo ciclo es lo que hace que no
            // haya riesgo de tuberia con ningun FOLD.
            v4 <= v3;
            s4 <= s3;
            out_valid <= 1'b0;
            if (v3) begin
                acc_i[s3*CIC_N + 0] <= acc_i[s3*CIC_N + 0] + mix_i;
                acc_q[s3*CIC_N + 0] <= acc_q[s3*CIC_N + 0] + mix_q;
                for (k = 1; k < CIC_N; k = k + 1) begin
                    acc_i[s3*CIC_N + k] <= acc_i[s3*CIC_N + k]
                                         + acc_i[s3*CIC_N + k - 1];
                    acc_q[s3*CIC_N + k] <= acc_q[s3*CIC_N + k]
                                         + acc_q[s3*CIC_N + k - 1];
                end

                if (cnt[s3] == CIC_R[CNT_W-1:0] - 1'b1) begin
                    cnt[s3]   <= {CNT_W{1'b0}};
                    out_valid <= 1'b1;
                    out_slot  <= s3;
                    // La salida es el estado NUEVO de la ultima etapa, igual
                    // que en cic_integ: el que acaba de calcularse arriba.
                    tap_i <= acc_i[s3*CIC_N + CIC_N-1]
                           + acc_i[s3*CIC_N + CIC_N-2];
                    tap_q <= acc_q[s3*CIC_N + CIC_N-1]
                           + acc_q[s3*CIC_N + CIC_N-2];
                end else begin
                    cnt[s3] <= cnt[s3] + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
