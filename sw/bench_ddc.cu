/* --------------------------------------------------------------------------
 * bench_ddc.cu — El mismo DDC en CUDA, bit-exacto con ddc_model.py y con el RTL.
 *
 * POR QUE ENTEROS Y NO TENSOR CORES
 *
 * La tentacion con una V100 es tirar de tensor cores y FP16. Aqui no sirve, y
 * no es cuestion de precision sino de que el filtro DEJA DE FUNCIONAR:
 *
 *   - Los integradores del CIC son acumuladores de 36 bits que DESBORDAN a
 *     proposito, y los peines deshacen ese desbordamiento restando. FP16 tiene
 *     11 bits de mantisa: no puede ni representar el acumulador. FP64 tiene 53,
 *     pero la coma flotante no envuelve, satura, y el filtro se rompe.
 *   - Los tensor cores multiplican matrices. Esto es RECURSIVO EN EL TIEMPO:
 *     cada muestra depende de la anterior. Es justo lo contrario.
 *
 * Asi que va en enteros, que ademas en una V100 no es un castigo: SM70 tiene
 * unidades INT32 SEPARADAS de las FP32, 64 por SM y 80 SMs.
 *
 * DE DONDE SALE EL PARALELISMO
 *
 * De los canales, no de las muestras. Un hilo por canal, y cada hilo recorre
 * el flujo entero en serie -- que es lo que exige la recursion. Con 80 SMs hay
 * sitio para decenas de miles de canales, que es justo el regimen donde una
 * FPGA se queda sin area.
 *
 * El flujo de entrada es UNO SOLO (hay una antena) y lo leen todos los canales.
 * Por eso cada bloque lo trae a memoria compartida una vez y desde ahi lo
 * difunde a sus hilos: si cada hilo fuese a memoria global por su cuenta, se
 * leeria el mismo dato blockDim veces.
 *
 *     nvcc -O3 -arch=sm_70 -o bench_ddc_cu bench_ddc.cu
 * -------------------------------------------------------------------------- */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <ctime>

#define IN_W        16
#define PHASE_W     32
#define LUT_ADDR_W  10
#define LUT_W       16
#define MIX_W       18
#define CIC_N        3
#define CIC_R       64
#define CIC_GROWTH  18
#define CIC_W       (MIX_W + CIC_GROWTH)
#define OUT_W       18
#define LUT_SIZE    (1 << LUT_ADDR_W)
#define LUT_QUARTER (1 << (LUT_ADDR_W - 2))

#define FS       100000000.0
#define F_IN      10000000.0
#define F_OUT     15000000.0

#define CHK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    fprintf(stderr, "%s:%d %s\n", __FILE__, __LINE__, cudaGetErrorString(e)); \
    exit(1); } } while (0)

/* La LUT es pequena (4 kB) y la leen todos los hilos con el mismo patron:
 * memoria constante, que tiene su propia cache difusora. */
__constant__ int32_t d_lut[LUT_SIZE];

/* ---- Aritmetica, identica a la del modelo -------------------------------- */
__device__ __forceinline__ int64_t wrap36(int64_t v)
{
    return (int64_t)((uint64_t)v << (64 - CIC_W)) >> (64 - CIC_W);
}
__device__ __forceinline__ int32_t wrap18(int64_t v)
{
    return (int32_t)((uint32_t)v << (32 - OUT_W)) >> (32 - OUT_W);
}
__device__ __forceinline__ int32_t sat18(int64_t v)
{
    const int64_t lo = -(1LL << (MIX_W - 1));
    const int64_t hi =  (1LL << (MIX_W - 1)) - 1;
    return (int32_t)(v < lo ? lo : (v > hi ? hi : v));
}

/* ---- Estado de un canal. Vive en registros mientras corre el nucleo ------- */
struct chst {
    uint32_t phase, ftw;
    int64_t  ii[CIC_N], iq[CIC_N];
    int64_t  cpi[CIC_N], cvi[CIC_N];
    int64_t  cpq[CIC_N], cvq[CIC_N];
    int32_t  count;
};

__device__ __forceinline__ int ddc_push(chst &c, int32_t x, int32_t &oi, int32_t &oq)
{
    uint32_t addr = c.phase >> (PHASE_W - LUT_ADDR_W);
    int32_t cosv = d_lut[addr];
    int32_t sinv = d_lut[(addr - LUT_QUARTER) & (LUT_SIZE - 1)];
    c.phase += c.ftw;

    int32_t mi = sat18(((int64_t)x * cosv) >> (LUT_W - 1));
    int32_t mq = sat18(((int64_t)(-x) * sinv) >> (LUT_W - 1));

    /* Cascada REGISTRADA: cada etapa usa el valor PREVIO de la anterior. */
    int64_t i0 = wrap36(c.ii[0] + mi);
    int64_t i1 = wrap36(c.ii[1] + c.ii[0]);
    int64_t i2 = wrap36(c.ii[2] + c.ii[1]);
    c.ii[0] = i0; c.ii[1] = i1; c.ii[2] = i2;

    int64_t q0 = wrap36(c.iq[0] + mq);
    int64_t q1 = wrap36(c.iq[1] + c.iq[0]);
    int64_t q2 = wrap36(c.iq[2] + c.iq[1]);
    c.iq[0] = q0; c.iq[1] = q1; c.iq[2] = q2;

    if (++c.count < CIC_R) return 0;
    c.count = 0;

    int64_t si = c.ii[CIC_N - 1];
    int64_t vi0 = wrap36(si         - c.cpi[0]);
    int64_t vi1 = wrap36(c.cvi[0]   - c.cpi[1]);
    int64_t vi2 = wrap36(c.cvi[1]   - c.cpi[2]);
    c.cpi[0] = si; c.cpi[1] = c.cvi[0]; c.cpi[2] = c.cvi[1];
    c.cvi[0] = vi0; c.cvi[1] = vi1; c.cvi[2] = vi2;

    int64_t sq = c.iq[CIC_N - 1];
    int64_t vq0 = wrap36(sq         - c.cpq[0]);
    int64_t vq1 = wrap36(c.cvq[0]   - c.cpq[1]);
    int64_t vq2 = wrap36(c.cvq[1]   - c.cpq[2]);
    c.cpq[0] = sq; c.cpq[1] = c.cvq[0]; c.cpq[2] = c.cvq[1];
    c.cvq[0] = vq0; c.cvq[1] = vq1; c.cvq[2] = vq2;

    oi = wrap18(c.cvi[CIC_N - 1] >> CIC_GROWTH);
    oq = wrap18(c.cvq[CIC_N - 1] >> CIC_GROWTH);
    return 1;
}

/* ---- Generacion en la GPU ------------------------------------------------ *
 *
 * En la CPU el NCO es un acumulador de fase y va en serie. En la GPU no hace
 * falta: la fase de la muestra k es (k * ftw) mod 2^32, forma cerrada, asi que
 * generar es EMBARAZOSAMENTE PARALELO. Es una ventaja real de la plataforma y
 * por eso se mide aparte.
 *
 * El cero inicial es el ciclo de latencia del registro de salida de
 * sig_source.v: la muestra 0 es cero y la k viene de la fase (k-1). */
__global__ void gen_kernel(int32_t *dst, long long n, long long base,
                           uint32_t ftwa, uint32_t ftwb, int sha, int shb)
{
    long long k = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (k >= n) return;
    long long g = base + k;
    if (g == 0) { dst[k] = 0; return; }
    uint32_t pa = (uint32_t)((g - 1) * (long long)ftwa);
    uint32_t pb = (uint32_t)((g - 1) * (long long)ftwb);
    int32_t sa = d_lut[((pa >> (PHASE_W - LUT_ADDR_W)) - LUT_QUARTER) & (LUT_SIZE - 1)];
    int32_t sb = d_lut[((pb >> (PHASE_W - LUT_ADDR_W)) - LUT_QUARTER) & (LUT_SIZE - 1)];
    int32_t s = (sa >> sha) + (sb >> shb);
    const int32_t hi =  (1 << (IN_W - 1)) - 1;
    const int32_t lo = -(1 << (IN_W - 1));
    dst[k] = s > hi ? hi : (s < lo ? lo : s);
}

/* ---- El nucleo ----------------------------------------------------------- *
 * Un hilo por canal. El bloque trae el flujo a memoria compartida una vez y
 * desde ahi lo leen sus blockDim hilos. */
template <int SH>
__global__ void ddc_kernel(const int32_t * __restrict__ x, long long n,
                           chst *st, int n_ch, int64_t *sink)
{
    __shared__ int32_t buf[SH];

    int ch = blockIdx.x * blockDim.x + threadIdx.x;
    chst c;
    if (ch < n_ch) c = st[ch];
    int64_t s = 0;

    for (long long base = 0; base < n; base += SH) {
        int m = (int)min((long long)SH, n - base);
        for (int i = threadIdx.x; i < m; i += blockDim.x) buf[i] = x[base + i];
        __syncthreads();
        if (ch < n_ch) {
            for (int i = 0; i < m; i++) {
                int32_t oi, oq;
                if (ddc_push(c, buf[i], oi, oq)) s += oi + oq;
            }
        }
        __syncthreads();
    }
    if (ch < n_ch) { st[ch] = c; sink[ch] = s; }
}

/* ---- Anfitrion ----------------------------------------------------------- */
static int32_t h_lut[LUT_SIZE];

static int load_lut(const char *dir)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/sin_lut.mem", dir);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    int n = 0;
    while (n < LUT_SIZE && fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '/' || *p == '\n' || *p == '\r' || *p == 0) continue;
        long v = strtol(p, NULL, 16);
        if (v & (1L << (LUT_W - 1))) v -= (1L << LUT_W);   /* con signo */
        h_lut[n++] = (int32_t)v;
    }
    fclose(f);
    return n == LUT_SIZE ? 0 : -1;
}

static uint32_t tuning_word(double f_hz)
{
    return (uint32_t)llround((f_hz / FS) * 4294967296.0);
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* El mismo generador que la CPU, para comprobar que el de la GPU coincide. */
static void gen_cpu(int32_t *dst, long long n, uint32_t fa, uint32_t fb,
                    int sha, int shb)
{
    uint32_t pa = 0, pb = 0;
    const int32_t hi =  (1 << (IN_W - 1)) - 1;
    const int32_t lo = -(1 << (IN_W - 1));
    for (long long k = 0; k < n; k++) {
        if (k == 0) { dst[0] = 0; continue; }
        int32_t sa = h_lut[((pa >> (PHASE_W - LUT_ADDR_W)) - LUT_QUARTER) & (LUT_SIZE - 1)];
        int32_t sb = h_lut[((pb >> (PHASE_W - LUT_ADDR_W)) - LUT_QUARTER) & (LUT_SIZE - 1)];
        pa += fa; pb += fb;
        int32_t s = (sa >> sha) + (sb >> shb);
        dst[k] = s > hi ? hi : (s < lo ? lo : s);
    }
}

struct gpu_ctx {
    int       dev;
    int       ch_lo, ch_hi;
    int32_t  *d_x;
    chst     *d_st;
    int64_t  *d_sink;
    cudaStream_t stream;
};

int main(int argc, char **argv)
{
    int n_ch = 4096, n_gpu = 1, gen_gpu = 0, verif = 0, csv = 0;
    long long n_samp = 20000000LL;
    const char *rdir = "../rtl";

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--ch")      && i + 1 < argc) n_ch   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--gpus")    && i + 1 < argc) n_gpu  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--samples") && i + 1 < argc) n_samp = atoll(argv[++i]);
        else if (!strcmp(argv[i], "--gen"))    gen_gpu = 1;
        else if (!strcmp(argv[i], "--verify")) verif = 1;
        else if (!strcmp(argv[i], "--csv"))    csv = 1;
        else rdir = argv[i];
    }

    if (load_lut(rdir) != 0) {
        fprintf(stderr, "no pude leer %s/sin_lut.mem\n", rdir);
        return 2;
    }

    int disp = 0;
    CHK(cudaGetDeviceCount(&disp));
    if (n_gpu > disp) n_gpu = disp;
    if (n_gpu < 1) { fprintf(stderr, "sin GPUs\n"); return 2; }

    uint32_t fa = tuning_word(F_IN), fb = tuning_word(F_OUT);
    const int SHBUF = 8192;               /* 32 kB de memoria compartida */

    /* El flujo lo ve ENTERO cada GPU: hay una sola antena y todos los canales
     * miran las mismas muestras. Repartir canales, no muestras. */
    int32_t *h_x = (int32_t *)malloc((size_t)n_samp * sizeof(int32_t));
    if (!h_x) { fprintf(stderr, "sin memoria\n"); return 2; }
    if (!gen_gpu) gen_cpu(h_x, n_samp, fa, fb, 2, 2);

    gpu_ctx *g = (gpu_ctx *)calloc(n_gpu, sizeof(gpu_ctx));
    chst *h_st = (chst *)calloc(n_ch, sizeof(chst));
    for (int k = 0; k < n_ch; k++) {
        double f = FS * (0.05 + 0.40 * k / (n_ch > 1 ? n_ch - 1 : 1));
        h_st[k].ftw = tuning_word(f);
    }

    for (int d = 0; d < n_gpu; d++) {
        g[d].dev   = d;
        g[d].ch_lo = (int)((long long)n_ch * d       / n_gpu);
        g[d].ch_hi = (int)((long long)n_ch * (d + 1) / n_gpu);
        CHK(cudaSetDevice(d));
        CHK(cudaStreamCreate(&g[d].stream));
        CHK(cudaMemcpyToSymbol(d_lut, h_lut, sizeof(h_lut)));
        CHK(cudaMalloc(&g[d].d_x,    (size_t)n_samp * sizeof(int32_t)));
        int nc = g[d].ch_hi - g[d].ch_lo;
        CHK(cudaMalloc(&g[d].d_st,   (size_t)nc * sizeof(chst)));
        CHK(cudaMalloc(&g[d].d_sink, (size_t)nc * sizeof(int64_t)));
        CHK(cudaMemcpy(g[d].d_st, h_st + g[d].ch_lo,
                       (size_t)nc * sizeof(chst), cudaMemcpyHostToDevice));
        if (gen_gpu) {
            int blk = 256;
            gen_kernel<<<(int)((n_samp + blk - 1) / blk), blk>>>(
                g[d].d_x, n_samp, 0, fa, fb, 2, 2);
        } else {
            CHK(cudaMemcpy(g[d].d_x, h_x, (size_t)n_samp * sizeof(int32_t),
                           cudaMemcpyHostToDevice));
        }
    }
    for (int d = 0; d < n_gpu; d++) { CHK(cudaSetDevice(d)); CHK(cudaDeviceSynchronize()); }

    /* Si se genero en la GPU, hay que comprobar que da lo MISMO que la CPU:
     * la forma cerrada de la fase es una optimizacion, no una licencia. */
    if (gen_gpu && verif) {
        int32_t *chk = (int32_t *)malloc((size_t)SHBUF * sizeof(int32_t));
        int32_t *ref = (int32_t *)malloc((size_t)SHBUF * sizeof(int32_t));
        CHK(cudaSetDevice(0));
        CHK(cudaMemcpy(chk, g[0].d_x, SHBUF * sizeof(int32_t), cudaMemcpyDeviceToHost));
        gen_cpu(ref, SHBUF, fa, fb, 2, 2);
        int mal = 0;
        for (int i = 0; i < SHBUF; i++) if (chk[i] != ref[i]) mal++;
        printf("  generador GPU contra CPU: %d discrepancias en %d muestras%s\n",
               mal, SHBUF, mal ? "  <-- MAL" : "  OK");
        free(chk); free(ref);
    }

    /* ---- La medida ------------------------------------------------------- */
    int blk = 128;
    double t0 = now_s();
    for (int d = 0; d < n_gpu; d++) {
        CHK(cudaSetDevice(d));
        int nc = g[d].ch_hi - g[d].ch_lo;
        ddc_kernel<SHBUF><<<(nc + blk - 1) / blk, blk, 0, g[d].stream>>>(
            g[d].d_x, n_samp, g[d].d_st, nc, g[d].d_sink);
    }
    for (int d = 0; d < n_gpu; d++) {
        CHK(cudaSetDevice(d));
        CHK(cudaStreamSynchronize(g[d].stream));
    }
    double dt = now_s() - t0;
    CHK(cudaGetLastError());

    int64_t sink = 0;
    for (int d = 0; d < n_gpu; d++) {
        int nc = g[d].ch_hi - g[d].ch_lo;
        int64_t *hs = (int64_t *)malloc((size_t)nc * sizeof(int64_t));
        CHK(cudaSetDevice(d));
        CHK(cudaMemcpy(hs, g[d].d_sink, (size_t)nc * sizeof(int64_t),
                       cudaMemcpyDeviceToHost));
        for (int k = 0; k < nc; k++) sink += hs[k];
        free(hs);
    }

    double cm  = (double)n_ch * (double)n_samp;
    double cms = cm / dt;
    double sps = cms / n_ch;

    if (csv) {
        printf("n_ch,n_gpu,gen_gpu,n_samples,seconds,ch_samples_per_s,sustained_sps\n");
        printf("%d,%d,%d,%lld,%.6f,%.0f,%.0f\n",
               n_ch, n_gpu, gen_gpu, n_samp, dt, cms, sps);
    } else {
        printf("\nbench_ddc CUDA — %d canales, %d GPU%s, %lld muestras%s\n",
               n_ch, n_gpu, n_gpu > 1 ? "s" : "", n_samp,
               gen_gpu ? "  (generado en la GPU)" : "");
        printf("  tiempo            : %10.3f s\n", dt);
        printf("  canal-muestras/s  : %10.1f M\n", cms / 1e6);
        printf("  tasa sostenida    : %10.3f MSPS con %d canales\n", sps / 1e6, n_ch);
        printf("  (checksum %lld)\n", (long long)sink);
        double need = 100e6;
        if (sps >= need) printf("\n  100 MSPS: LLEGA, margen x%.2f\n\n", sps / need);
        else             printf("\n  100 MSPS: DEFICIT x%.1f\n\n", need / sps);
    }

    for (int d = 0; d < n_gpu; d++) {
        CHK(cudaSetDevice(d));
        cudaFree(g[d].d_x); cudaFree(g[d].d_st); cudaFree(g[d].d_sink);
        cudaStreamDestroy(g[d].stream);
    }
    free(h_x); free(h_st); free(g);
    return 0;
}
