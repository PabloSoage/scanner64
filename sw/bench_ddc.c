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

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <sched.h>

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

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* ---- Verificacion contra los vectores dorados --------------------------- */

/* ---- Generador, el MISMO que sig_source.v ------------------------------- *
 *
 * Antes esto llamaba a sin() de libm, lo cual contradecia su propio comentario:
 * la FPGA genera con un NCO y una LUT, no con libm. Medir libm y llamarlo
 * "coste de generacion" inflaba la parte serie del experimento --en Python la
 * generacion se comia 90 de 130 segundos-- y ademas producia muestras
 * DISTINTAS de las que ve la FPGA.
 *
 * Con el NCO son tres operaciones por muestra y el estimulo es bit-identico al
 * de la PL, asi que CPU y FPGA procesan exactamente la misma señal. Eso hace
 * comparable el resultado, no solo parecido.
 *
 * Ojo al cero inicial: sig_source.v tiene un ciclo de latencia en su registro
 * de salida, asi que su primera muestra es cero y el resto va desplazado uno.
 * Se reproduce para que las dos plataformas vean la misma secuencia. */
typedef struct {
    uint32_t pa, pb, ftwa, ftwb;
    int      sha, shb;
    int      primera;
} siggen;

static void siggen_init(siggen *g)
{
    memset(g, 0, sizeof(*g));
    g->ftwa = tuning_word(F_IN,  FS);
    g->ftwb = tuning_word(F_OUT, FS);
    g->sha  = 2;                     /* SRC_SH = 0x022: los dos tonos a 1/4 */
    g->shb  = 2;
    g->primera = 1;
}

static inline int32_t nco_sin(uint32_t phase)
{
    uint32_t addr = phase >> (PHASE_W - LUT_ADDR_W);
    return LUT[(addr - LUT_QUARTER) & (LUT_SIZE - 1)];
}

/* Continua donde lo dejo: el flujo es uno solo, troceado en bloques. */
static void siggen_run(siggen *g, int32_t *dst, int n)
{
    const int32_t hi =  (1 << (IN_W - 1)) - 1;
    const int32_t lo = -(1 << (IN_W - 1));
    int i = 0;
    if (g->primera) { dst[0] = 0; g->primera = 0; i = 1; }
    for (; i < n; i++) {
        int32_t sa = nco_sin(g->pa);
        int32_t sb = nco_sin(g->pb);
        g->pa += g->ftwa;
        g->pb += g->ftwb;
        int32_t s = (sa >> g->sha) + (sb >> g->shb);
        dst[i] = s > hi ? hi : (s < lo ? lo : s);
    }
}


/* El de siempre, para --bench: un flujo entero de una vez, desde cero. */
static void gen_stim(int32_t *dst, int n)
{
    siggen g;
    siggen_init(&g);
    siggen_run(&g, dst, n);
}

/* ---- Reparto por hilos --------------------------------------------------- *
 *
 * Un solo flujo de entrada --hay UNA antena-- y los canales repartidos entre
 * hilos. Cada hilo lee el mismo bloque y toca solo sus canales, asi que no hay
 * escritura compartida y no hace falta ningun cerrojo en el camino caliente.
 *
 * La generacion se mide APARTE. Con eso salen los dos modelos de un solo tiro:
 *
 *     en serie    total = generacion + proceso     (un nucleo hace las dos)
 *     solapado    total = max(generacion, proceso) (un hilo dedicado genera)
 *
 * Dar el tiempo de generacion por separado evita tener que elegir uno de los
 * dos y permite defender cualquiera de los dos en la memoria. */
typedef struct {
    int       id;
    int       ch_lo, ch_hi;          /* [lo, hi) canales de este hilo */
    ddc_ch   *ch;
    int32_t **blk;                   /* puntero al bloque vigente */
    int      *blk_n;
    int      *sigue;
    pthread_barrier_t *b_ini, *b_fin;
    int64_t   sink;
    double    t_trabajo;
    int       pin;
    int       cpu;                   /* donde acabo corriendo de verdad */
    int       con_gen;               /* si no, no hacen falta barreras */
    long long n_blk;
} worker;

/* Fija el hilo al i-esimo procesador PERMITIDO, no al i-esimo del sistema.
 * Asi compone bien con numactl y taskset: si te dan media maquina, se reparte
 * dentro de esa media en vez de pelearse con la mascara. */
static void fijar_al_permitido(int idx)
{
    cpu_set_t mask, uno;
    if (sched_getaffinity(0, sizeof(mask), &mask) != 0) return;
    int n = CPU_COUNT(&mask), k = 0;
    if (n <= 0) return;
    for (int c = 0; c < CPU_SETSIZE; c++) {
        if (!CPU_ISSET(c, &mask)) continue;
        if (k == idx % n) {
            CPU_ZERO(&uno);
            CPU_SET(c, &uno);
            pthread_setaffinity_np(pthread_self(), sizeof(uno), &uno);
            return;
        }
        k++;
    }
}

/* La tajada de un hilo sobre el bloque vigente. Vive aparte porque la usan los
 * dos: los hilos lanzados y el principal, que tambien es un trabajador. */
static void trabajar_bloque(worker *w)
{
    double t0 = now_s();
    w->cpu = sched_getcpu();
    const int32_t *x = *w->blk;
    int n = *w->blk_n;
    for (int k = w->ch_lo; k < w->ch_hi; k++) {
        ddc_ch *c = &w->ch[k];
        int64_t s = 0;
        for (int i = 0; i < n; i++) {
            int32_t oi, oq;
            if (ddc_push(c, x[i], &oi, &oq)) s += oi + oq;
        }
        w->sink += s;
    }
    w->t_trabajo += now_s() - t0;
}

static void *worker_main(void *arg)
{
    worker *w = (worker *)arg;
    if (w->pin) fijar_al_permitido(w->id);

    /* SIN GENERACION NO HAY BARRERAS. El bufer no cambia en toda la tanda y
     * cada hilo toca solo sus canales, asi que nadie tiene que esperar a nadie.
     *
     * Y esperar sale carisimo a escala: con una barrera por bloque, cada bloque
     * cuesta el MAXIMO de los 104 hilos, no la media. Medido en los Xeon con
     * 104 hilos: los tiempos por hilo se reparten entre 2,5 y 5,2 s con la masa
     * en 3,6 --ruido del sistema, no NUMA ni hyperthreading-- y muestreando esa
     * cola 104 veces por bloque el maximo se dispara. El rendimiento caia de
     * 9.352 M canal-muestras/s con 52 hilos a 3.586 M con 104. Eso medía el
     * rezagado, no la maquina. */
    if (!w->con_gen) {
        for (long long b = 0; b < w->n_blk; b++) trabajar_bloque(w);
        return NULL;
    }

    for (;;) {
        pthread_barrier_wait(w->b_ini);
        if (!*w->sigue) break;
        trabajar_bloque(w);
        pthread_barrier_wait(w->b_fin);
    }
    return NULL;
}

/* ---- La medida ----------------------------------------------------------- */
static int cmd_mt(const char *rtldir, int n_ch, long long n_samp, int n_thr,
                  int with_gen, int pin, int csv, int blk_arg, int detalle)
{
    if (load_lut(rtldir) != 0) {
        fprintf(stderr, "no pude leer %s/sin_lut.mem\n", rtldir);
        return 2;
    }
    if (n_thr > n_ch) n_thr = n_ch;      /* un hilo sin canales no mide nada */

    /* Tamaño de bloque: entre dos barreras, cada hilo tiene que tener trabajo
     * de sobra o la sincronizacion se come la medida.
     *
     * Medido en los Xeon con 104 hilos y un canal por hilo: con bloques de 64 k
     * los hilos pasaban 8,2 s de 13,8 ESPERANDO --el 59 %-- y el rendimiento
     * caia a un tercio del de 52 hilos. Con dos canales por hilo, o con el
     * bloque al doble, el sesgo entre hilos baja del 2x al 2 %.
     *
     * Asi que el bloque se dimensiona por el trabajo que le toca a cada hilo:
     * unos 250 k canal-muestras por bloque y por hilo, que a ~4 ns cada una
     * son del orden del milisegundo. Con eso la barrera queda por debajo del
     * uno por ciento y no hay que acordarse de ajustarlo a mano. */
    int BLK = blk_arg;
    if (BLK <= 0) {
        int ch_por_hilo = (n_ch + n_thr - 1) / n_thr;
        BLK = 250000 / (ch_por_hilo > 0 ? ch_por_hilo : 1);
        if (BLK < 65536)  BLK = 65536;
        if (BLK > 1048576) BLK = 1048576;
    }
    long long n_blk = (n_samp + BLK - 1) / BLK;
    n_samp = n_blk * (long long)BLK;

    ddc_ch  *ch   = calloc((size_t)n_ch, sizeof(ddc_ch));
    int32_t *buf  = malloc((size_t)BLK * sizeof(int32_t));
    worker  *ws   = calloc((size_t)n_thr, sizeof(worker));
    pthread_t *th = calloc((size_t)n_thr, sizeof(pthread_t));
    if (!ch || !buf || !ws || !th) { fprintf(stderr, "sin memoria\n"); return 2; }

    /* Canales repartidos por la banda, como en un escaner real. */
    for (int k = 0; k < n_ch; k++) {
        double f = FS * (0.05 + 0.40 * k / (n_ch > 1 ? n_ch - 1 : 1));
        ddc_init(&ch[k], tuning_word(f, FS));
    }

    /* El hilo principal es el TRABAJADOR 0, no un coordinador aparte.
     *
     * La primera version lanzaba n_thr trabajadores y ademas metia al
     * principal en las dos barreras: con 104 hilos en 104 CPUs logicas salian
     * 105 hilos para 104 sitios. Uno compartia nucleo con el principal, tardaba
     * el doble, y los otros 103 le esperaban en la barrera. Medido: a 104 hilos
     * el peor tardaba 12,77 s y el mejor 6,02, y el rendimiento se hundia a un
     * tercio del de 52 hilos. Eso era el error de planificacion, no la maquina.
     *
     * Asi `--threads T` son T hilos de calculo en total, ni uno mas. */
    pthread_barrier_t b_ini, b_fin;
    pthread_barrier_init(&b_ini, NULL, n_thr);
    pthread_barrier_init(&b_fin, NULL, n_thr);

    int32_t *blk_ptr = buf;
    int      blk_n   = BLK;
    int      sigue   = 1;

    for (int t = 0; t < n_thr; t++) {
        ws[t].id    = t;
        ws[t].ch_lo = (int)((long long)n_ch * t       / n_thr);
        ws[t].ch_hi = (int)((long long)n_ch * (t + 1) / n_thr);
        ws[t].ch    = ch;
        ws[t].blk   = &blk_ptr;
        ws[t].blk_n = &blk_n;
        ws[t].sigue = &sigue;
        ws[t].b_ini = &b_ini;
        ws[t].b_fin = &b_fin;
        ws[t].pin     = pin;
        ws[t].con_gen = with_gen;
        ws[t].n_blk   = n_blk;
        if (t > 0) pthread_create(&th[t], NULL, worker_main, &ws[t]);
    }
    if (pin) fijar_al_permitido(0);            /* el principal, como el resto */

    siggen g;
    siggen_init(&g);
    siggen_run(&g, buf, BLK);            /* primer bloque, fuera del reloj */

    struct timespec wall0, wall1;
    clock_gettime(CLOCK_REALTIME, &wall0);
    double t_gen = 0.0;
    double t0 = now_s();

    if (!with_gen) {
        /* Camino sin barreras: cada hilo recorre la tanda entera por su cuenta
         * y el principal hace la suya. Nadie espera a nadie. */
        for (long long b = 0; b < n_blk; b++) trabajar_bloque(&ws[0]);
        for (int t = 1; t < n_thr; t++) pthread_join(th[t], NULL);
    } else {
        for (long long b = 0; b < n_blk; b++) {
            pthread_barrier_wait(&b_ini);  /* arrancan todos, el principal incluido */
            trabajar_bloque(&ws[0]);       /* el principal hace su tajada */
            pthread_barrier_wait(&b_fin);  /* y aqui han terminado todos */
            if (b + 1 < n_blk) {
                double tg = now_s();
                siggen_run(&g, buf, BLK);  /* el siguiente bloque */
                t_gen += now_s() - tg;
            }
        }
        sigue = 0;
        pthread_barrier_wait(&b_ini);      /* los despierta para que salgan */
        for (int t = 1; t < n_thr; t++) pthread_join(th[t], NULL);
    }

    double dt = now_s() - t0;
    clock_gettime(CLOCK_REALTIME, &wall1);

    int64_t sink = 0;
    double t_peor = 0.0, t_mejor = 1e18;
    for (int t = 0; t < n_thr; t++) {
        sink += ws[t].sink;
        if (ws[t].t_trabajo > t_peor)  t_peor  = ws[t].t_trabajo;
        if (ws[t].t_trabajo < t_mejor) t_mejor = ws[t].t_trabajo;
    }

    double cm    = (double)n_ch * (double)n_samp;
    double cms   = cm / dt;
    double sps   = cms / n_ch;
    double t_pro = dt - t_gen;
    double solap = (t_gen > t_pro ? t_gen : t_pro);

    if (csv) {
        /* Las marcas de tiempo absolutas son para que el muestreador de
         * potencia recorte EXACTAMENTE la ventana. Sin ellas la medida se
         * contamina con el arranque y con la cola. */
        printf("n_ch,n_thr,gen,n_samples,seconds,ch_samples_per_s,sustained_sps,"
               "gen_s,proc_s,overlap_s,worst_thread_s,best_thread_s,"
               "t_start_unix,t_end_unix\n");
        printf("%d,%d,%d,%lld,%.6f,%.0f,%.0f,%.6f,%.6f,%.6f,%.6f,%.6f,"
               "%.6f,%.6f\n",
               n_ch, n_thr, with_gen, n_samp, dt, cms, sps,
               t_gen, t_pro, solap, t_peor, t_mejor,
               wall0.tv_sec + wall0.tv_nsec * 1e-9,
               wall1.tv_sec + wall1.tv_nsec * 1e-9);
    } else {
        printf("\nbench_ddc mt — %d canales, %d hilos, %lld muestras%s\n",
               n_ch, n_thr, n_samp, pin ? ", fijados" : "");
        printf("  tiempo total        : %10.3f s\n", dt);
        if (with_gen) {
            printf("    generacion        : %10.3f s\n", t_gen);
            printf("    proceso           : %10.3f s\n", t_pro);
            printf("    si se solapan     : %10.3f s   (un hilo dedicado a generar)\n",
                   solap);
        }
        printf("  canal-muestras/s    : %10.3f M\n", cms / 1e6);
        printf("  tasa sostenida      : %10.3f MSPS con %d canales\n",
               sps / 1e6, n_ch);
        printf("  reparto entre hilos : peor %.3f s, mejor %.3f s  (%.1f %% de sesgo)\n",
               t_peor, t_mejor, t_peor > 0 ? 100.0 * (t_peor - t_mejor) / t_peor : 0.0);
        /* Si un hilo tarda mucho mas que otro haciendo el MISMO trabajo, la
         * culpa esta en donde le toco correr. Sin ver el reparto por CPU no
         * hay forma de distinguir hyperthreading de NUMA de mala suerte. */
        if (detalle) {
            printf("  hilo  cpu   segundos\n");
            for (int t = 0; t < n_thr; t++)
                printf("  %4d  %3d   %8.3f\n", t, ws[t].cpu, ws[t].t_trabajo);
        }
        printf("  (checksum %lld)\n", (long long)sink);

        double need = 100e6;
        if (sps >= need) printf("\n  100 MSPS: LLEGA, margen x%.2f\n\n", sps / need);
        else             printf("\n  100 MSPS: DEFICIT x%.0f\n\n", need / sps);
    }

    pthread_barrier_destroy(&b_ini);
    pthread_barrier_destroy(&b_fin);
    free(ch); free(buf); free(ws); free(th);
    return 0;
}

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
        "  %s --bench N_CANALES N_MUESTRAS [--gen] [dir_rtl]\n"
        "  %s mt --ch N --threads T --samples M [--gen] [--pin] [--csv] [dir_rtl]\n\n"
        "por defecto dir_vectores=../tb/vectors y dir_rtl=../rtl\n", p, p, p);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 2; }

    if (!strcmp(argv[1], "--verify")) {
        const char *vdir = (argc > 2) ? argv[2] : "../tb/vectors";
        const char *rdir = (argc > 3) ? argv[3] : "../rtl";
        return cmd_verify(vdir, rdir);
    }

    /* Vuelca el estimulo para compararlo con el del RTL. El generador tiene
     * que dar EXACTAMENTE lo mismo que sig_source.v, o CPU y FPGA estarian
     * procesando señales distintas y la comparativa no valdria:
     *     tb/tb_sig_source.v -> sig_rtl.txt
     *     bench_ddc --stim 300 ../rtl | diff - sig_rtl.txt */
    if (!strcmp(argv[1], "--stim")) {
        int n = (argc > 2) ? atoi(argv[2]) : 300;
        const char *rdir = (argc > 3) ? argv[3] : "../rtl";
        if (n < 1 || load_lut(rdir) != 0) { usage(argv[0]); return 2; }
        int32_t *b = malloc((size_t)n * sizeof(int32_t));
        if (!b) return 2;
        gen_stim(b, n);
        for (int i = 0; i < n; i++) printf("%d\n", b[i]);
        free(b);
        return 0;
    }

    if (!strcmp(argv[1], "mt")) {
        int n_ch = 16, n_thr = 1, gen = 0, pin = 0, csv = 0, blk = 0, det = 0;
        long long n_samp = 10000000LL;
        const char *rdir = "../rtl";
        for (int i = 2; i < argc; i++) {
            if      (!strcmp(argv[i], "--ch")      && i + 1 < argc) n_ch   = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--threads") && i + 1 < argc) n_thr  = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--samples") && i + 1 < argc) n_samp = atoll(argv[++i]);
            else if (!strcmp(argv[i], "--block")   && i + 1 < argc) blk    = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--gen"))  gen = 1;
            else if (!strcmp(argv[i], "--pin"))  pin = 1;
            else if (!strcmp(argv[i], "--csv"))  csv = 1;
            else if (!strcmp(argv[i], "--detalle")) det = 1;
            else rdir = argv[i];
        }
        if (n_ch < 1 || n_thr < 1 || n_samp < 65536) { usage(argv[0]); return 2; }
        return cmd_mt(rdir, n_ch, n_samp, n_thr, gen, pin, csv, blk, det);
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
