/* --------------------------------------------------------------------------
 * scanner_ctl.c — Habla con scanner_axi desde Linux, por /dev/mem.
 *
 * El escaner vive en la PL con una interfaz AXI4-Lite. Este programa mapea sus
 * registros y permite configurarlo, arrancarlo y leer las potencias. Sin DMA:
 * el estimulo lo genera sig_source DENTRO de la PL, asi que para validar el
 * diseno en silicio no hace falta mover datos, solo leer resultados.
 *
 * Necesita root, porque /dev/mem lo necesita.
 *
 *     sudo ./scanner_ctl info
 *     sudo ./scanner_ctl test          <-- la prueba que importa
 *     sudo ./scanner_ctl run 4000000
 *     sudo ./scanner_ctl dump
 *
 * La direccion base por defecto es 0xA0000000, que es donde el
 * M_AXI_HPM0_FPD del ZynqMP mapea el primer periferico de la PL. Si tu
 * bitstream la puso en otro sitio se pasa por argumento:
 *
 *     sudo ./scanner_ctl --base 0xA0010000 info
 *
 * QUE PRUEBA `test`
 *
 * Es la prueba T5 del testbench, pero en hardware: sintoniza unos canales
 * sobre los dos tonos que genera sig_source y otros sobre banda vacia, y
 * comprueba que los primeros miden mucha mas potencia que los segundos. Si eso
 * sale, el escaner escanea de verdad, no solo en simulacion.
 *
 * Y ademas comprueba que NO SE PIERDE NI UNA MUESTRA: el contador de muestras
 * de la PL tiene que cuadrar exactamente con el de salidas por CIC_R. Una CPU
 * no puede prometer eso; la PL si, por construccion.
 * -------------------------------------------------------------------------- */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <math.h>
#include <time.h>

/* ---- Mapa de registros, en offsets de byte (ver rtl/scanner_axi.v) ------- */
#define R_ID        0x00
#define R_CTRL      0x04
#define R_SRC_FTWA  0x08
#define R_SRC_FTWB  0x0C
#define R_SRC_SH    0x10
#define R_CFG_CH    0x14
#define R_CFG_FTW   0x18
#define R_PWR_LEN   0x1C
#define R_RD_CH     0x20
#define R_PWR_LO    0x24
#define R_PWR_HI    0x28
#define R_READY     0x2C
#define R_SMP_LO    0x30
#define R_SMP_HI    0x34
#define R_OUT_CNT   0x38
#define R_NCH       0x3C
#define R_TAP_I     0x40
#define R_TAP_Q     0x44

#define CTRL_RUN     (1u << 0)
#define CTRL_SRC_EN  (1u << 1)
#define CTRL_NOISE   (1u << 2)
#define CTRL_CLEAR   (1u << 3)

#define MAGIC       0x5CA44E64u
#define MAP_SIZE    0x1000
#define FS          100000000.0
#define CIC_R       64

/* Los tonos que sig_source pone por defecto (ver scanner_axi.v). */
#define F_TONE_A    10000000.0
#define F_TONE_B    15000000.0

static volatile uint32_t *regs;

static inline void   wr(int off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t rd(int off)           { return regs[off / 4]; }

static uint32_t tuning_word(double f_hz)
{
    return (uint32_t)llround((f_hz / FS) * 4294967296.0);
}

static uint64_t read_pwr(int ch)
{
    wr(R_RD_CH, (uint32_t)ch);
    (void)rd(R_RD_CH);                       /* barrera: que la escritura cale */
    uint32_t lo = rd(R_PWR_LO);
    uint32_t hi = rd(R_PWR_HI);
    return ((uint64_t)hi << 32) | lo;
}

static void set_channel(int ch, double f_hz)
{
    wr(R_CFG_CH, (uint32_t)ch);
    wr(R_CFG_FTW, tuning_word(f_hz));        /* escribir aqui dispara cfg_we */
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int map_regs(unsigned long base)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem (¿sudo?)"); return -1; }
    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, (off_t)base);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); return -1; }
    regs = (volatile uint32_t *)p;
    return 0;
}

static int check_id(void)
{
    uint32_t id = rd(R_ID);
    if (id != MAGIC) {
        fprintf(stderr,
            "ID = 0x%08X, esperaba 0x%08X.\n"
            "  · ¿esta cargado el bitstream?  sudo fpgautil -b scanner64.bit.bin -f Full\n"
            "  · ¿es la direccion base correcta?  prueba --base\n", id, MAGIC);
        return -1;
    }
    return 0;
}

/* Vuelca los 32 registros en crudo. Para cuando algo no cuadra y hay que ver
 * el patron entero en vez de adivinar. */
static void cmd_raw(void)
{
    static const char *nm[19] = {
        "ID","CTRL","SRC_FTWA","SRC_FTWB","SRC_SH","CFG_CH","CFG_FTW",
        "PWR_LEN","RD_CH","PWR_LO","PWR_HI","READY","SMP_LO","SMP_HI",
        "OUT_CNT","NCH","TAP_I","TAP_Q","TAP_CNT" };
    printf("\n  off   idx  nombre       valor\n");
    for (int i = 0; i < 20; i++) {
        uint32_t v = rd(i * 4);
        printf("  0x%02X   %2d  %-11s 0x%08X  %u\n",
               i * 4, i, i < 19 ? nm[i] : "-", v, v);
    }
    /* Lecturas repetidas del mismo registro: si cambian, el problema es de
     * handshake y no de decodificado de direccion. */
    printf("\n  ID  leido 4 veces: ");
    for (int i = 0; i < 4; i++) printf("0x%08X ", rd(R_ID));
    printf("\n  NCH leido 4 veces: ");
    for (int i = 0; i < 4; i++) printf("0x%08X ", rd(R_NCH));
    printf("\n\n");
}

/* Escribe y vuelve a leer, para separar tres cosas que desde fuera parecen
 * la misma: si las escrituras llegan, si las lecturas devuelven, y si el
 * escaner procesa. Cada paso descarta una hipotesis. */
static void cmd_probe(void)
{
    printf("\n1) escribir y releer un registro RW\n");
    wr(R_SRC_FTWA, 0xDEADBEEFu);
    uint32_t a = rd(R_SRC_FTWA);
    printf("   SRC_FTWA <- 0xDEADBEEF, leido 0x%08X   %s\n",
           a, a == 0xDEADBEEFu ? "ESCRITURA Y LECTURA OK" : "NO CUADRA");

    wr(R_PWR_LEN, 1234);
    uint32_t b = rd(R_PWR_LEN);
    printf("   PWR_LEN  <- 1234,       leido %u          %s\n",
           b, b == 1234 ? "OK" : "NO CUADRA");

    printf("\n2) constante de solo lectura\n");
    printf("   NCH  = %u   (deberia ser 16)\n", rd(R_NCH));
    printf("   ID   = 0x%08X\n", rd(R_ID));

    printf("\n3) arrancar el escaner y ver si el contador avanza\n");
    wr(R_CTRL, CTRL_RUN);
    uint32_t c1 = rd(R_CTRL);
    printf("   CTRL <- 0x1 (run), leido 0x%08X\n", c1);
    wr(R_CTRL, CTRL_RUN | CTRL_SRC_EN);
    uint32_t c2 = rd(R_CTRL);
    printf("   CTRL <- 0x3 (run+src), leido 0x%08X\n", c2);

    uint32_t s0 = rd(R_SMP_LO);
    usleep(200000);
    uint32_t s1 = rd(R_SMP_LO);
    printf("   SMP_LO: %u -> %u   (delta %u en 0.2 s)\n", s0, s1, s1 - s0);
    if (s1 != s0) {
        printf("   -> EL ESCANER PROCESA. La PL funciona.\n");
        printf("      tasa observada: %.2f MSPS\n", (s1 - s0) / 0.2 / 1e6);
    } else {
        printf("   -> el contador no avanza: o no arranca el generador o las\n");
        printf("      escrituras a CTRL no llegan.\n");
    }
    printf("   OUT_CNT = %u\n", rd(R_OUT_CNT));
    wr(R_CTRL, CTRL_RUN);
    printf("\n");
}

/* Mapa completo del decodificador. Cuando SOLO algunos registros leen bien no
 * sirve de nada seguir deduciendo: hay que separar dos causas que desde fuera
 * producen exactamente el mismo sintoma.
 *
 *   DIRECCION : el decodificador no responde a ese offset y cae en el default.
 *   SECUENCIA : el handshake devuelve el dato de la lectura ANTERIOR, asi que
 *               el valor depende de en que orden se lea, no de donde.
 *
 * Lo que sabemos hasta ahora es que leen bien 0x00 (ID), 0x10 (SRC_SH) y 0x30
 * (SMP_LO) --los tres multiplos de 16-- y que el resto devuelve cero. Leer las
 * mismas 64 palabras hacia delante, hacia atras y dos veces seguidas decide
 * entre las dos causas en una sola pasada. */
static void cmd_map(void)
{
    uint32_t asc[64], desc[64], twice[64];
    int i, off, n;
    size_t k;

    for (i = 0; i < 64; i++) asc[i] = rd(i * 4);
    for (i = 63; i >= 0; i--) desc[i] = rd(i * 4);
    for (i = 0; i < 64; i++) { (void)rd(i * 4); twice[i] = rd(i * 4); }

    printf("\n1) las mismas 64 palabras, leidas de tres maneras\n");
    printf("   idx  off    ascendente   descendente  leida 2 veces\n");
    for (i = 0; i < 64; i++) {
        if (!asc[i] && !desc[i] && !twice[i]) continue;
        printf("   %3d  0x%02X   0x%08X   0x%08X   0x%08X%s\n",
               i, i * 4, asc[i], desc[i], twice[i],
               (asc[i] == desc[i] && asc[i] == twice[i]) ? "" : "   <-- CAMBIA");
    }
    printf("   (solo salen las que no son cero en alguna pasada)\n");
    printf("   iguales las tres pasadas -> es la DIRECCION\n");
    printf("   alguna CAMBIA            -> es la SECUENCIA (handshake)\n");

    /* Si el decodificador estuviera desplazado, los valores seguirian ahi
     * pero en otro offset. Buscarlos por todo el mapeo lo dice sin ambiguedad:
     * si el valor de reset de SRC_FTWA no aparece en ningun sitio, entonces el
     * registro vale cero de verdad y no es un problema de lectura. */
    printf("\n2) donde aparece cada valor conocido en los 4 KB mapeados\n");
    {
        struct { uint32_t v; const char *q; } look[] = {
            { MAGIC,       "ID 0x5CA44E64"           },
            { 0x1999999Au, "reset de SRC_FTWA"       },
            { 0x26666666u, "reset de SRC_FTWB"       },
            { 0x00000022u, "reset de SRC_SH"         },
            { 0x00000400u, "reset de PWR_LEN (1024)" },
            { 0x00000010u, "N_CH = 16"               },
        };
        for (k = 0; k < sizeof look / sizeof look[0]; k++) {
            printf("   %-24s :", look[k].q);
            n = 0;
            for (off = 0; off < 4096; off += 4)
                if (rd(off) == look[k].v && n < 12) { printf(" 0x%03X", off); n++; }
            printf("%s\n", n ? "" : "  NO APARECE EN NINGUN SITIO");
        }
    }

    /* Y lo mismo por el lado de la escritura: una firma distinta en cada
     * registro RW y luego mirar donde ha caido cada una. */
    printf("\n3) una firma distinta en cada registro RW, y volcado\n");
    {
        static const int rw[] = { 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20 };
        int nrw = (int)(sizeof rw / sizeof rw[0]);
        for (i = 0; i < nrw; i++)
            wr(rw[i], 0xC0DE0000u | ((uint32_t)rw[i] << 4) | 0xAu);
        printf("   escritas:");
        for (i = 0; i < nrw; i++)
            printf(" 0x%02X<-0x%08X", rw[i], 0xC0DE0000u | ((uint32_t)rw[i] << 4) | 0xAu);
        printf("\n   leidas (solo las no nulas):\n");
        for (off = 0; off < 128; off += 4) {
            uint32_t v = rd(off);
            if (v) printf("     0x%02X = 0x%08X\n", off, v);
        }
        printf("   firma en su sitio      -> escritura y lectura OK ahi\n");
        printf("   firma en OTRO offset   -> decodificador desplazado\n");
        printf("   ninguna firma          -> las escrituras no llegan\n");
    }

    /* Dejar el generador como estaba: si no, la siguiente prueba sale rara. */
    wr(R_SRC_FTWA, 0x1999999Au);
    wr(R_SRC_FTWB, 0x26666666u);
    wr(R_SRC_SH,   0x00000022u);
    wr(R_PWR_LEN,  1024u);
    wr(R_CFG_CH,   0u);
    printf("\n");
}

/* ---- Ancho del puerto AXI del PS ----------------------------------------
 *
 * El sintoma: solo responden los offsets multiplos de 16 (0x00, 0x10, 0x20,
 * 0x30, 0x40) y el resto lee cero, mientras que las escrituras SI llegan.
 *
 * Eso es exactamente lo que pasa cuando el bus del maestro es de 128 bits y
 * el esclavo solo tiene 32. Cada latido del bus lleva cuatro palabras; el
 * esclavo solo pone la suya en la primera, y la CPU, al leer 0x04, recoge la
 * SEGUNDA palabra de ese latido, que nadie conduce -> cero. Al leer 0x10 ya
 * es otro latido distinto, la CPU recoge la primera palabra, y sale bien.
 * Las escrituras funcionan porque la direccion viaja entera y el esclavo no
 * mira wstrb: se queda con lo que venga en wdata[31:0].
 *
 * Y el ancho de HPM0_FPD NO lo fija el bitstream. Lo fija el PS, en
 * FPD_SLCR.AFI_FS (0xFD615000), y ese registro lo escribe el FSBL a partir
 * del handoff del proyecto. Al cargar con `fpgautil` el PS se queda como lo
 * dejo el arranque de la Kria, que pone los dos puertos a 128 bits. El block
 * design pide 32. De ahi el desajuste.
 *
 *   AFI_FS bits [9:8]   DW_SS0_SEL -> HPM0_FPD
 *          bits [11:10] DW_SS1_SEL -> HPM1_FPD
 *          0 = 32 bits, 1 = 64 bits, 2 = 128 bits
 *
 * `bus` lo lee y lo dice. `bus fix` lo pone a 32 bits y vuelve a volcar los
 * registros para que se vea si era eso. Es lo mismo que haria el FSBL. */

#define FPD_SLCR_AFI_FS  0xFD615000UL

static const char *dw_name(unsigned v)
{
    switch (v & 3u) {
    case 0: return "32 bits";
    case 1: return "64 bits";
    case 2: return "128 bits";
    default: return "reservado";
    }
}

static int cmd_bus(int fix)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *slcr;
    uint32_t v;
    unsigned ss0, ss1;

    if (fd < 0) { perror("/dev/mem"); return 2; }
    slcr = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, (off_t)FPD_SLCR_AFI_FS);
    close(fd);
    if ((void *)slcr == MAP_FAILED) { perror("mmap FPD_SLCR"); return 2; }

    v   = slcr[0];
    ss0 = (v >> 8) & 3u;
    ss1 = (v >> 10) & 3u;
    printf("\nFPD_SLCR.AFI_FS = 0x%08X\n", v);
    printf("  HPM0_FPD : %s   %s\n", dw_name(ss0),
           ss0 == 0 ? "(lo que pide el block design)"
                    : "<-- NO CUADRA, el diseno pide 32 bits");
    printf("  HPM1_FPD : %s   (apagado en este diseno)\n", dw_name(ss1));

    if (ss0 == 0) {
        printf("\n  El ancho ya es el correcto: el fallo es otro.\n\n");
        return 0;
    }
    if (!fix) {
        printf("\n  Para arreglarlo:  sudo scanner_ctl bus fix\n\n");
        return 1;
    }

    /* Solo los cuatro bits del ancho; el resto del registro no se toca. */
    slcr[0] = (v & ~0x00000F00u) | 0x00000000u;
    v = slcr[0];
    printf("\n  escrito. AFI_FS = 0x%08X -> HPM0_FPD %s\n",
           v, dw_name((v >> 8) & 3u));
    if (((v >> 8) & 3u) != 0) {
        printf("  el registro no acepta la escritura (¿XMPU?).\n\n");
        return 1;
    }

    printf("\n  y ahora los registros del escaner:\n");
    cmd_raw();
    return 0;
}

/* El ancho de HPM0_FPD se pierde en CADA arranque: `fpgautil` carga la PL pero
 * no reconfigura el PS, y el arranque de la Kria deja los dos puertos a 128
 * bits. Confirmado en silicio el 14-sep-2026: con 128 bits solo se leian bien
 * los offsets multiplos de 16 y el resto devolvia cero.
 *
 * Por eso se comprueba y se corrige al principio de cada invocacion, en vez de
 * dejarlo a que alguien se acuerde de lanzar `bus fix`. Es exactamente lo que
 * habria hecho el FSBL si la placa arrancara con el handoff de este proyecto. */
static void ensure_bus32(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *slcr;
    uint32_t v;

    if (fd < 0) return;
    slcr = (volatile uint32_t *)mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, (off_t)FPD_SLCR_AFI_FS);
    close(fd);
    if ((void *)slcr == MAP_FAILED) return;

    v = slcr[0];
    if (((v >> 8) & 3u) != 0) {
        slcr[0] = v & ~0x00000F00u;
        printf("[AFI_FS 0x%08X -> 0x%08X: HPM0_FPD a 32 bits, "
               "que es lo que pide el diseno]\n", v, slcr[0]);
    }
    munmap((void *)slcr, 0x1000);
}

static void cmd_info(void)
{
    printf("\nscanner_axi en la PL\n");
    printf("  ID           : 0x%08X  (OK)\n", rd(R_ID));
    printf("  canales      : %u\n", rd(R_NCH));
    uint32_t c = rd(R_CTRL);
    printf("  CTRL         : 0x%08X  run=%d src=%d ruido=%d\n",
           c, !!(c & CTRL_RUN), !!(c & CTRL_SRC_EN), !!(c & CTRL_NOISE));
    printf("  generador    : tono A 0x%08X, tono B 0x%08X, shifts 0x%03X\n",
           rd(R_SRC_FTWA), rd(R_SRC_FTWB), rd(R_SRC_SH) & 0xFFF);
    printf("  ventana pwr  : %u muestras\n", rd(R_PWR_LEN));
    uint64_t smp = ((uint64_t)rd(R_SMP_HI) << 32) | rd(R_SMP_LO);
    printf("  muestras     : %llu\n", (unsigned long long)smp);
    printf("  salidas ch0  : %u\n", rd(R_OUT_CNT));
    printf("  pwr_ready    : 0x%08X\n\n", rd(R_READY));
}

static void cmd_dump(void)
{
    int n = (int)rd(R_NCH);
    printf("\n  canal   potencia            dBFS aprox\n");
    for (int k = 0; k < n; k++) {
        uint64_t p = read_pwr(k);
        uint32_t len = rd(R_PWR_LEN);
        double db = -999.0;
        if (p > 0 && len > 0) {
            /* Potencia media por muestra, referida al fondo de escala de
             * ENTRADA, igual que power_db() del modelo. */
            double full = 32767.0 * 32767.0;
            db = 10.0 * log10(((double)p / len) / full);
        }
        printf("   %3d    %18llu   %8.2f\n", k, (unsigned long long)p, db);
    }
    printf("\n");
}

static int cmd_run(unsigned long long target_samples)
{
    wr(R_CTRL, CTRL_RUN);                        /* fuera de reset, parado */
    wr(R_CTRL, CTRL_RUN | CTRL_CLEAR);
    wr(R_CTRL, CTRL_RUN);
    double t0 = now_s();
    wr(R_CTRL, CTRL_RUN | CTRL_SRC_EN);          /* arranca el generador */

    uint64_t smp = 0;
    while (smp < target_samples) {
        usleep(20000);
        smp = ((uint64_t)rd(R_SMP_HI) << 32) | rd(R_SMP_LO);
        if (now_s() - t0 > 30.0) break;
    }
    double dt = now_s() - t0;
    wr(R_CTRL, CTRL_RUN);                        /* para el generador */

    smp = ((uint64_t)rd(R_SMP_HI) << 32) | rd(R_SMP_LO);
    uint32_t out = rd(R_OUT_CNT);

    printf("\n  muestras procesadas : %llu\n", (unsigned long long)smp);
    printf("  salidas del canal 0 : %u\n", out);
    printf("  tiempo              : %.3f s\n", dt);
    printf("  tasa observada      : %.2f MSPS\n", smp / dt / 1e6);

    /* La prueba de que no se ha perdido nada: out_cnt tiene que ser
     * exactamente smp/CIC_R, con un margen de una muestra por el pipeline. */
    long long expect = (long long)(smp / CIC_R);
    long long diff = (long long)out - expect;
    printf("  esperadas smp/%d    : %lld   (diferencia %+lld)\n",
           CIC_R, expect, diff);
    if (diff >= -2 && diff <= 2) {
        printf("  -> NO SE HA PERDIDO NI UNA MUESTRA\n\n");
        return 0;
    }
    printf("  -> DESCUADRE: se han perdido muestras\n\n");
    return 1;
}

static int cmd_test(int n_arg)
{
    /* NCH se puede pasar a mano: si el registro leyera mal, la prueba no
     * tiene por que quedarse bloqueada por eso. */
    int n = n_arg > 0 ? n_arg : (int)rd(R_NCH);
    if (n < 4) { fprintf(stderr, "hacen falta al menos 4 canales\n"); return 2; }

    printf("\nPrueba de discriminacion en hardware (T5 del testbench, en silicio)\n");
    printf("  El generador de la PL emite dos tonos: %.0f y %.0f MHz.\n",
           F_TONE_A / 1e6, F_TONE_B / 1e6);

    wr(R_CTRL, CTRL_RUN);
    /* Programar el generador EXPLICITAMENTE. No fiarse de los valores de
     * reset: cualquier prueba anterior puede haberlos dejado tocados, y
     * entonces esta prueba busca tonos donde no los hay y falla por nada. */
    wr(R_SRC_FTWA, tuning_word(F_TONE_A));
    wr(R_SRC_FTWB, tuning_word(F_TONE_B));
    wr(R_SRC_SH,   0x022);
    wr(R_PWR_LEN, 4096);

    /* Mitad de canales sobre los tonos, mitad sobre banda vacia. */
    double freqs[64];
    int occupied[64];
    for (int k = 0; k < n && k < 64; k++) {
        if (k % 4 == 0)      { freqs[k] = F_TONE_A;            occupied[k] = 1; }
        else if (k % 4 == 1) { freqs[k] = F_TONE_B;            occupied[k] = 1; }
        else if (k % 4 == 2) { freqs[k] = 22000000.0 + k*1e5;  occupied[k] = 0; }
        else                 { freqs[k] =  3000000.0 + k*1e5;  occupied[k] = 0; }
        set_channel(k, freqs[k]);
    }

    wr(R_CTRL, CTRL_RUN | CTRL_CLEAR);
    wr(R_CTRL, CTRL_RUN | CTRL_SRC_EN);
    usleep(300000);                              /* deja llenar varias ventanas */
    wr(R_CTRL, CTRL_RUN);

    double min_occ = 1e300, max_emp = 0.0;
    printf("\n  canal   sintonia      potencia            estado\n");
    for (int k = 0; k < n && k < 64; k++) {
        uint64_t p = read_pwr(k);
        printf("   %3d   %6.1f MHz   %18llu   %s\n",
               k, freqs[k] / 1e6, (unsigned long long)p,
               occupied[k] ? "TONO" : "vacio");
        if (occupied[k]) { if ((double)p < min_occ) min_occ = (double)p; }
        else             { if ((double)p > max_emp) max_emp = (double)p; }
    }

    printf("\n  menor de los ocupados : %.0f\n", min_occ);
    printf("  mayor de los vacios   : %.0f\n", max_emp);
    if (max_emp <= 0.0) max_emp = 1.0;
    double ratio = min_occ / max_emp;
    printf("  margen                : x%.0f  (%.1f dB)\n",
           ratio, 10.0 * log10(ratio));

    uint32_t ready = rd(R_READY);
    printf("  pwr_ready             : 0x%08X\n\n", ready);

    if (ratio > 100.0) {
        printf("RESULTADO: PASA — el escaner discrimina EN HARDWARE.\n\n");
        return 0;
    }
    printf("RESULTADO: FALLA — no hay margen suficiente.\n\n");
    return 1;
}

/* Medida DETERMINISTA, para contrastarla con el modelo al bit.
 *
 * Primer intento: medir la primera ventana de potencia desde el reset. NO
 * FUNCIONA, y la razon esta escrita en rtl/comb_bank.v: el estado de los
 * peines vive en LUTRAM distribuida y se inicializa por `initial`, es decir,
 * con el bitstream. Un reset en caliente NO lo limpia. Los integradores si
 * vuelven a cero, los peines arrastran el estado de la prueba anterior, y las
 * primeras salidas son basura --basura grande, porque el peine resta un estado
 * sin relacion y satura--. Un par de muestras a fondo de escala se comen una
 * ventana de 4096. Es el precio de ahorrarse 7001 flip-flops, y esta asumido.
 *
 * Asi que no se usa la ventana de potencia: se usan los TAP. `tap_i`/`tap_q`
 * congelan la ULTIMA salida del canal seleccionado y `out_cnt` dice cual es.
 * Leer la terna (indice, I, Q) da un punto exacto de la senal, sin depender de
 * donde empiece ninguna ventana:
 *
 *   - `run` a cero deja los integradores a cero y los NCO a fase cero, y el
 *     NCO de cada canal solo avanza con in_valid, asi que la secuencia es
 *     reproducible ciclo a ciclo desde la primera muestra.
 *   - el estado sucio de los peines se va en tres rondas; midiendo a partir de
 *     la salida ~3000, hace rato que lo que hay dentro lo pusieron las
 *     muestras de ESTA tirada, que son las mismas que ve el modelo.
 *   - y no hace falta acertar el numero de salidas: se lee.
 *
 * Un canal por tirada, porque out_cnt cuenta las salidas del canal apuntado
 * por rd_ch. */
static int cmd_golden(void)
{
    static const double freqs[4] = { F_TONE_A, F_TONE_B, 22200000.0, 3300000.0 };
    uint32_t cnt[4];
    int32_t  ti[4], tq[4];
    int k;

    if ((int)rd(R_NCH) < 4) { fprintf(stderr, "hacen falta 4 canales\n"); return 2; }

    for (k = 0; k < 4; k++) {
        wr(R_CTRL, 0);                          /* reset: integradores y NCO */
        usleep(1000);
        wr(R_CTRL, CTRL_RUN);                   /* fuera de reset, parado */

        wr(R_SRC_FTWA, tuning_word(F_TONE_A));
        wr(R_SRC_FTWB, tuning_word(F_TONE_B));
        wr(R_SRC_SH,   0x022);
        wr(R_PWR_LEN,  4096);
        set_channel(k, freqs[k]);               /* la sintonia va DESPUES de run */
        wr(R_RD_CH, (uint32_t)k);               /* tap_ch sigue a rd_ch */

        wr(R_CTRL, CTRL_RUN | CTRL_SRC_EN);     /* arranca la secuencia */
        usleep(2000);                           /* ~200k muestras, ~3000 salidas */
        wr(R_CTRL, CTRL_RUN);                   /* congela el tap */

        cnt[k] = rd(R_OUT_CNT);
        ti[k]  = (int32_t)rd(R_TAP_I);
        tq[k]  = (int32_t)rd(R_TAP_Q);
    }

    printf("\nPuntos exactos de la senal, uno por canal\n\n");
    printf("  canal   sintonia      salida n.      I          Q\n");
    for (k = 0; k < 4; k++)
        printf("   %3d   %6.1f MHz   %9u   %8d   %8d\n",
               k, freqs[k] / 1e6, cnt[k], ti[k], tq[k]);

    printf("\n  Contrastalo con el modelo:\n\n    python golden_hw.py");
    for (k = 0; k < 4; k++)
        printf(" %u %d %d", cnt[k], ti[k], tq[k]);
    printf("\n\n");
    return 0;
}

int main(int argc, char **argv)
{
    unsigned long base = 0xA0000000UL;
    int a = 1;
    if (argc > 2 && !strcmp(argv[1], "--base")) {
        base = strtoul(argv[2], NULL, 0);
        a = 3;
    }
    if (a >= argc) {
        fprintf(stderr,
            "uso: %s [--base 0xA0000000] {info|raw|probe|map|bus [fix]|test [N]|golden|run N|dump}\n", argv[0]);
        return 2;
    }
    ensure_bus32();
    if (map_regs(base) != 0) return 2;
    if (check_id() != 0) return 2;

    if (!strcmp(argv[a], "info")) { cmd_info(); return 0; }
    if (!strcmp(argv[a], "dump")) { cmd_dump(); return 0; }
    if (!strcmp(argv[a], "golden")) return cmd_golden();
    if (!strcmp(argv[a], "raw"))   { cmd_raw();   return 0; }
    if (!strcmp(argv[a], "probe")) { cmd_probe(); return 0; }
    if (!strcmp(argv[a], "map"))   { cmd_map();   return 0; }
    if (!strcmp(argv[a], "bus"))
        return cmd_bus((a + 1 < argc) && !strcmp(argv[a+1], "fix"));
    if (!strcmp(argv[a], "test")) {
        int nc = (a + 1 < argc) ? atoi(argv[a+1]) : 0;
        return cmd_test(nc);
    }
    if (!strcmp(argv[a], "run")) {
        unsigned long long n = (a + 1 < argc) ? strtoull(argv[a+1], NULL, 0)
                                              : 100000000ULL;
        return cmd_run(n);
    }
    fprintf(stderr, "orden desconocida: %s\n", argv[a]);
    return 2;
}
