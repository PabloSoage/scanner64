/* --------------------------------------------------------------------------
 * bench_ddc.c — El mismo DDC en C, bit-exacto con model/ddc_model.py.
 *
 * POR QUE EXISTE
 *
 * sw/bench_cpu.py mide el interprete de Python, no la CPU. Medido en los
 * Cortex-A53 de la KV260: 1.3 kSPS y un deficit de x77731 para sostener
 * 100 MSPS. Ese numero no dice nada sobre el silicio de ARM.
 *
 * Y hay algo peor, que solo se vio al medir con el INA260 de la placa:
 * Python tampoco sirve para medir POTENCIA. Cuatro cores a tope suben el
 * consumo 0.14 W sobre reposo, porque el interprete se pasa el tiempo
 * saltando y tocando memoria en vez de haciendo aritmetica. Para una
 * comparativa cuyo resultado es "canales por vatio", eso es un denominador
 * falso.
 *
 * EXACTITUD
 *
 * Este fichero reproduce la aritmetica de ddc_model.py operacion a operacion,
 * y se valida contra los MISMOS vectores dorados que el RTL (tb/vectors/).
 * Las tres implementaciones -- modelo, RTL y C -- tienen el mismo arbitro.
 *
 * Dos detalles de los que depende la exactitud:
 *
 *   - El desplazamiento a la derecha de un negativo. En Python `>>` redondea
 *     hacia abajo. En C es "implementation-defined", pero gcc y clang lo
 *     implementan como desplazamiento ARITMETICO, que hace lo mismo. Este
 *     codigo cuenta con ello; con un compilador que no lo cumpla, --verify
 *     fallaria y se sabria.
 *   - El desbordamiento envolvente de los integradores es INTENCIONADO, igual
 *     que en el RTL. wrap36() lo emula. Saturar ahi rompe el filtro.
 *
 * USO
 *
 *     bench_ddc --verify [dir_vectores]     comprueba contra los dorados
 *     bench_ddc --bench N_CH N_MUESTRAS [--gen]
 *
 * Con --gen, la generacion del estimulo entra DENTRO de la medida. Es lo que
 * fija METODOLOGIA.md: cada plataforma paga por producir sus propias muestras,
 * porque en la PL el generador es hardware aparte que no roba un solo ciclo al
 * DDC, mientras que en una CPU compite por las mismas unidades. Midiendo con y
 * sin, el coste de generar sale por diferencia.
 *
 * COMPILAR
 *
 *     cc -O3 -march=native -o bench_ddc bench_ddc.c -lm
 *
 * En los A53 de la KV260, -march=native se resuelve a armv8-a+crc.
 * -------------------------------------------------------------------------- */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>

/* ---- Parametros del diseno. Deben coincidir con ddc_model.py ------------- */
#define IN_W        16
#define PHASE_W     32
#define LUT_ADDR_W  10
#define LUT_W       16
#define MIX_W       18
#define CIC_N        3
#define CIC_R       64
#define CIC_GROWTH  18                   /* N * log2(R*M) = 3*6 */
#define CIC_W       (MIX_W + CIC_GROWTH) /* 36 */
#define OUT_W       18

#define LUT_SIZE    (1 << LUT_ADDR_W)    /* 1024 */
#define LUT_QUARTER (1 << (LUT_ADDR_W - 2))

static int32_t LUT[LUT_SIZE];

/* ---- Aritmetica de ancho fijo ------------------------------------------- */

/* Trunca a 36 bits en complemento a dos, con desbordamiento ENVOLVENTE.
 * El CIC depende de esto: los integradores desbordan y los peines lo deshacen.
 * Desplazar 28 a la izquierda y 28 a la derecha con signo extiende el bit 35. */
static inline int64_t wrap36(int64_t v)
{
    return (int64_t)((uint64_t)v << (64 - CIC_W)) >> (64 - CIC_W);
}

/* Trunca a 18 bits, para la salida ya normalizada. */
static inline int32_t wrap18(int64_t v)
{
    return (int32_t)((uint32_t)v << (32 - OUT_W)) >> (32 - OUT_W);
}

/* Satura a 18 bits. Aqui SI hay que saturar: una envolvente en el mezclador
 * genera chasquidos en la senal. */
static inline int32_t sat18(int64_t v)
{
    const int64_t lo = -(1LL << (MIX_W - 1));
    const int64_t hi =  (1LL << (MIX_W - 1)) - 1;
    return (int32_t)(v < lo ? lo : (v > hi ? hi : v));
}

/* ---- Estado de un canal -------------------------------------------------- */
typedef struct {
    uint32_t phase, ftw;
    int64_t  integ_i[CIC_N], integ_q[CIC_N];
    int64_t  cprev_i[CIC_N], cval_i[CIC_N];
    int64_t  cprev_q[CIC_N], cval_q[CIC_N];
    int32_t  count;
} ddc_ch;

static void ddc_init(ddc_ch *c, uint32_t ftw)
{
    memset(c, 0, sizeof(*c));
    c->ftw = ftw;
}

static uint32_t tuning_word(double f_hz, double fs_hz)
{
    double t = (f_hz / fs_hz) * 4294967296.0;   /* 2^32 */
    return (uint32_t)llround(t);
}

/* Procesa una muestra. Devuelve 1 y escribe (oi,oq) cuando hay salida. */
static inline int ddc_push(ddc_ch *c, int32_t x, int32_t *oi, int32_t *oq)
{
    /* --- NCO: los LUT_ADDR_W bits altos de la fase direccionan la tabla --- */
    uint32_t addr = c->phase >> (PHASE_W - LUT_ADDR_W);
    int32_t cosv = LUT[addr];
    /* sin(a) = cos(a - pi/2): un cuarto de tabla hacia atras. */
    int32_t sinv = LUT[(addr - LUT_QUARTER) & (LUT_SIZE - 1)];
    c->phase += c->ftw;                       /* envuelve solo, es uint32 */

    /* --- Mezclador. El >> (LUT_W-1) deshace la escala de la LUT ---------- */
    int32_t mi = sat18(((int64_t)x * cosv) >> (LUT_W - 1));
    int32_t mq = sat18(((int64_t)(-x) * sinv) >> (LUT_W - 1));

    /* --- Integradores: cascada REGISTRADA, cada etapa usa el valor PREVIO
     *     de la anterior. Si se encadenaran en el mismo paso el resultado
     *     seria otro, y no cuadraria con el RTL. ---------------------------- */
    int64_t i0 = wrap36(c->integ_i[0] + mi);
    int64_t i1 = wrap36(c->integ_i[1] + c->integ_i[0]);
    int64_t i2 = wrap36(c->integ_i[2] + c->integ_i[1]);
    c->integ_i[0] = i0; c->integ_i[1] = i1; c->integ_i[2] = i2;

    int64_t q0 = wrap36(c->integ_q[0] + mq);
    int64_t q1 = wrap36(c->integ_q[1] + c->integ_q[0]);
    int64_t q2 = wrap36(c->integ_q[2] + c->integ_q[1]);
    c->integ_q[0] = q0; c->integ_q[1] = q1; c->integ_q[2] = q2;

    /* --- Diezmado --------------------------------------------------------- */
    if (++c->count < CIC_R) return 0;
    c->count = 0;

    /* --- Peines, tambien en cascada registrada ---------------------------- */
    int64_t si = c->integ_i[CIC_N - 1];
    int64_t vi0 = wrap36(si            - c->cprev_i[0]);
    int64_t vi1 = wrap36(c->cval_i[0]  - c->cprev_i[1]);
    int64_t vi2 = wrap36(c->cval_i[1]  - c->cprev_i[2]);
    c->cprev_i[0] = si;
    c->cprev_i[1] = c->cval_i[0];
    c->cprev_i[2] = c->cval_i[1];
    c->cval_i[0] = vi0; c->cval_i[1] = vi1; c->cval_i[2] = vi2;

    int64_t sq = c->integ_q[CIC_N - 1];
    int64_t vq0 = wrap36(sq            - c->cprev_q[0]);
    int64_t vq1 = wrap36(c->cval_q[0]  - c->cprev_q[1]);
    int64_t vq2 = wrap36(c->cval_q[1]  - c->cprev_q[2]);
    c->cprev_q[0] = sq;
    c->cprev_q[1] = c->cval_q[0];
    c->cprev_q[2] = c->cval_q[1];
    c->cval_q[0] = vq0; c->cval_q[1] = vq1; c->cval_q[2] = vq2;

    /* --- Normalizacion: la ganancia del CIC es 2^CIC_GROWTH exactos ------- */
    *oi = wrap18(c->cval_i[CIC_N - 1] >> CIC_GROWTH);
    *oq = wrap18(c->cval_q[CIC_N - 1] >> CIC_GROWTH);
    return 1;
}

/* ---- Carga de ficheros .hex --------------------------------------------- */

/* Lee un .hex de $readmemh: un valor hex por linea, sin prefijo, y lo
 * interpreta como entero con signo de `bits` bits. */
static int load_hex(const char *path, int bits, int64_t *out, int max)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    int n = 0;
    while (n < max && fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '\n' || *p == '/' || *p == '#') continue;
        uint64_t raw = strtoull(p, NULL, 16);
        uint64_t m = (bits >= 64) ? ~0ULL : ((1ULL << bits) - 1);
        raw &= m;
        int64_t v = (raw & (1ULL << (bits - 1)))
                  ? (int64_t)(raw - (1ULL << bits))
                  : (int64_t)raw;
        out[n++] = v;
    }
    fclose(f);
    return n;
}

static int load_lut(const char *dir)
{
    char path[512];
    int64_t tmp[LUT_SIZE];
    snprintf(path, sizeof(path), "%s/sin_lut.mem", dir);
    int n = load_hex(path, LUT_W, tmp, LUT_SIZE);
    if (n != LUT_SIZE) return -1;
    for (int i = 0; i < LUT_SIZE; i++) LUT[i] = (int32_t)tmp[i];
    return 0;
}

/* ---- Generador de estimulo ---------------------------------------------- *
 * El mismo escenario que model/gen_vectors.py: dos tonos sumados y saturados.
 * Tiene que ser el MISMO algoritmo en las tres plataformas o se acaba midiendo
 * la libm en vez del generador. */
/* M_PI no es C estandar (es una extension de POSIX que -std=c99 esconde),
 * asi que se define aqui y no depende del compilador ni de la libc. */
#define PI_D  3.14159265358979323846

#define FS      100000000.0
#define F_IN     10000000.0
#define F_OUT    15000000.0
#define AMP_IN       0.40
#define AMP_OUT      0.40

static void gen_stim(int32_t *dst, int n)
{
    const double peak = (double)((1 << (IN_W - 1)) - 1);
    const double wi = 2.0 * PI_D * F_IN  / FS;
    const double wo = 2.0 * PI_D * F_OUT / FS;
    for (int k = 0; k < n; k++) {
        double s = AMP_IN * peak * sin(wi * k) + AMP_OUT * peak * sin(wo * k);
        long v = lround(s);
        if (v >  32767) v =  32767;
        if (v < -32768) v = -32768;
        dst[k] = (int32_t)v;
    }
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* ---- Verificacion contra los vectores dorados --------------------------- */

static int cmd_verify(const char *vdir, const char *rtldir)
{
    static int64_t stim[8192], gi[256], gq[256];

    if (load_lut(rtldir) != 0) {
        fprintf(stderr, "no pude leer %s/sin_lut.mem\n", rtldir);
        return 2;
    }
    char p[512];
    snprintf(p, sizeof(p), "%s/stim.hex", vdir);
    int ns = load_hex(p, IN_W, stim, 8192);
    snprintf(p, sizeof(p), "%s/gold_i.hex", vdir);
    int ngi = load_hex(p, OUT_W, gi, 256);
    snprintf(p, sizeof(p), "%s/gold_q.hex", vdir);
    int ngq = load_hex(p, OUT_W, gq, 256);

    if (ns <= 0 || ngi <= 0 || ngi != ngq) {
        fprintf(stderr, "vectores ilegibles en %s (stim=%d gold=%d/%d)\n",
                vdir, ns, ngi, ngq);
        return 2;
    }

    /* La misma palabra de sintonia que params.vh: 10 MHz a 100 MSPS. */
    ddc_ch c;
    ddc_init(&c, tuning_word(F_IN, FS));

    int produced = 0, errors = 0;
    for (int k = 0; k < ns; k++) {
        int32_t oi, oq;
        if (ddc_push(&c, (int32_t)stim[k], &oi, &oq)) {
            if (produced < ngi) {
                if (oi != gi[produced] || oq != gq[produced]) {
                    if (errors < 10)
                        printf("  [%d] esperado I=%lld Q=%lld   C I=%d Q=%d\n",
                               produced, (long long)gi[produced],
                               (long long)gq[produced], oi, oq);
                    errors++;
                }
            }
            produced++;
        }
    }

    printf("\nbench_ddc --verify\n");
    printf("  muestras de entrada : %d\n", ns);
    printf("  salidas producidas  : %d\n", produced);
    printf("  comparadas          : %d\n", produced < ngi ? produced : ngi);
    printf("  discrepancias       : %d\n\n", errors);
    if (errors == 0 && produced >= ngi) {
        printf("RESULTADO: PASA — bit-exacto con el modelo y con el RTL.\n\n");
        return 0;
    }
    printf("RESULTADO: FALLA\n\n");
    return 1;
}

/* ---- Benchmark ----------------------------------------------------------- */

static int cmd_bench(const char *rtldir, int n_ch, int n_samp, int with_gen)
{
    if (load_lut(rtldir) != 0) {
        fprintf(stderr, "no pude leer %s/sin_lut.mem\n", rtldir);
        return 2;
    }

    ddc_ch *ch = malloc((size_t)n_ch * sizeof(ddc_ch));
    int32_t *stim = malloc((size_t)n_samp * sizeof(int32_t));
    if (!ch || !stim) { fprintf(stderr, "sin memoria\n"); return 2; }

    /* Canales repartidos por la banda, como en un escaner real. */
    for (int k = 0; k < n_ch; k++) {
        double f = FS * (0.05 + 0.40 * k / (n_ch > 1 ? n_ch - 1 : 1));
        ddc_init(&ch[k], tuning_word(f, FS));
    }

    /* Si no se mide la generacion, se hace fuera del cronometro. */
    if (!with_gen) gen_stim(stim, n_samp);

    volatile int64_t sink = 0;      /* que el compilador no borre el trabajo */
    double t0 = now_s();

    if (with_gen) gen_stim(stim, n_samp);

    for (int k = 0; k < n_ch; k++) {
        ddc_ch *c = &ch[k];
        for (int i = 0; i < n_samp; i++) {
            int32_t oi, oq;
            if (ddc_push(c, stim[i], &oi, &oq)) sink += oi + oq;
        }
    }
    double dt = now_s() - t0;

    double cm    = (double)n_ch * n_samp;      /* canal-muestras */
    double cms   = cm / dt;
    double sps   = cms / n_ch;                 /* tasa de entrada sostenida */
    double gops  = cms * 18.0 / 1e9;           /* ~18 operaciones por cm */

    printf("\nbench_ddc — %d canales, %d muestras%s\n",
           n_ch, n_samp, with_gen ? "  (generacion INCLUIDA en la medida)" : "");
    printf("  tiempo            : %10.3f s\n", dt);
    printf("  canal-muestras/s  : %10.3f M\n", cms / 1e6);
    printf("  tasa de entrada   : %10.3f MSPS\n", sps / 1e6);
    printf("  ~operaciones/s    : %10.3f Gop/s\n", gops);
    printf("  (checksum %lld)\n", (long long)sink);

    double need = 100e6;
    printf("\n  Para sostener 100 MSPS con %d canales:\n", n_ch);
    if (sps >= need)
        printf("  LLEGA, con un margen de x%.2f\n\n", sps / need);
    else
        printf("  DEFICIT x%.0f\n\n", need / sps);

    free(ch); free(stim);
    return 0;
}

/* ---- main ---------------------------------------------------------------- */

static void usage(const char *p)
{
    fprintf(stderr,
        "uso:\n"
        "  %s --verify [dir_vectores] [dir_rtl]\n"
        "  %s --bench N_CANALES N_MUESTRAS [--gen] [dir_rtl]\n\n"
        "por defecto dir_vectores=../tb/vectors y dir_rtl=../rtl\n", p, p);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 2; }

    if (!strcmp(argv[1], "--verify")) {
        const char *vdir = (argc > 2) ? argv[2] : "../tb/vectors";
        const char *rdir = (argc > 3) ? argv[3] : "../rtl";
        return cmd_verify(vdir, rdir);
    }

    if (!strcmp(argv[1], "--bench")) {
        if (argc < 4) { usage(argv[0]); return 2; }
        int n_ch   = atoi(argv[2]);
        int n_samp = atoi(argv[3]);
        int with_gen = 0;
        const char *rdir = "../rtl";
        for (int i = 4; i < argc; i++) {
            if (!strcmp(argv[i], "--gen")) with_gen = 1;
            else rdir = argv[i];
        }
        if (n_ch < 1 || n_samp < CIC_R) { usage(argv[0]); return 2; }
        return cmd_bench(rdir, n_ch, n_samp, with_gen);
    }

    usage(argv[0]);
    return 2;
}
