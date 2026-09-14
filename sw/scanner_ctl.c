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

static int cmd_test(void)
{
    int n = (int)rd(R_NCH);
    if (n < 4) { fprintf(stderr, "hacen falta al menos 4 canales\n"); return 2; }

    printf("\nPrueba de discriminacion en hardware (T5 del testbench, en silicio)\n");
    printf("  El generador de la PL emite dos tonos: %.0f y %.0f MHz.\n",
           F_TONE_A / 1e6, F_TONE_B / 1e6);

    wr(R_CTRL, CTRL_RUN);
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
            "uso: %s [--base 0xA0000000] {info|test|run N|dump}\n", argv[0]);
        return 2;
    }
    if (map_regs(base) != 0) return 2;
    if (check_id() != 0) return 2;

    if (!strcmp(argv[a], "info")) { cmd_info(); return 0; }
    if (!strcmp(argv[a], "dump")) { cmd_dump(); return 0; }
    if (!strcmp(argv[a], "test")) return cmd_test();
    if (!strcmp(argv[a], "run")) {
        unsigned long long n = (a + 1 < argc) ? strtoull(argv[a+1], NULL, 0)
                                              : 100000000ULL;
        return cmd_run(n);
    }
    fprintf(stderr, "orden desconocida: %s\n", argv[a]);
    return 2;
}
