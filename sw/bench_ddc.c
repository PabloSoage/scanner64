/* --------------------------------------------------------------------------
 * bench_ddc.c - The same DDC in C, bit-exact with model/ddc_model.py.
 *
 * WHY IT EXISTS
 *
 * sw/bench_cpu.py measures the Python interpreter, not the CPU. Measured on
 * the KV260's Cortex-A53: 1.3 kSPS and a shortfall of x77731 to sustain
 * 100 MSPS. That number says nothing about ARM silicon.
 *
 * And there is something worse, which only showed up when measuring with the
 * board's INA260: Python is no good for measuring POWER either. Four cores
 * flat out raise consumption by 0.14 W over idle, because the interpreter
 * spends its time branching and touching memory instead of doing arithmetic.
 * For a comparison whose result is "channels per watt", that is a false
 * denominator.
 *
 * EXACTNESS
 *
 * This file reproduces ddc_model.py's arithmetic operation by operation, and
 * is validated against the SAME golden vectors as the RTL (tb/vectors/). All
 * three implementations -- model, RTL and C -- answer to the same referee.
 *
 * Two details the exactness depends on:
 *
 *   - Right-shifting a negative. In Python `>>` rounds down. In C it is
 *     implementation-defined, but gcc and clang implement it as an ARITHMETIC
 *     shift, which does the same thing. This code relies on that; with a
 *     compiler that did not, --verify would fail and you would know.
 *   - The integrators' wraparound overflow is INTENTIONAL, the same as in the
 *     RTL. wrap36() emulates it. Saturating there breaks the filter.
 *
 * USAGE
 *
 *     bench_ddc --verify [vector_dir]       check against the golden vectors
 *     bench_ddc --bench N_CH N_SAMPLES [--gen]
 *
 * With --gen, generating the stimulus counts INSIDE the measurement. That is
 * what METODOLOGIA.md lays down: every platform pays to produce its own
 * samples, because in the PL the generator is separate hardware that does not
 * steal a single cycle from the DDC, whereas on a CPU it competes for the same
 * units. Measuring with and without, the cost of generating comes out by
 * difference.
 *
 * BUILD
 *
 *     cc -O3 -march=native -o bench_ddc bench_ddc.c -lm
 *
 * On the KV260's A53, -march=native resolves to armv8-a+crc.
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

/* ---- Design parameters. They must match ddc_model.py -------------------- */
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

/* ---- Fixed-width arithmetic --------------------------------------------- */

/* Truncates to 36 bits in two's complement, with WRAPAROUND overflow.
 * The CIC depends on this: the integrators overflow and the combs undo it.
 * Shifting left 28 and right 28 with sign extends bit 35. */
static inline int64_t wrap36(int64_t v)
{
    return (int64_t)((uint64_t)v << (64 - CIC_W)) >> (64 - CIC_W);
}

/* Truncates to 18 bits, for the already-normalised output. */
static inline int32_t wrap18(int64_t v)
{
    return (int32_t)((uint32_t)v << (32 - OUT_W)) >> (32 - OUT_W);
}

/* Saturates to 18 bits. Here you DO have to saturate: a wraparound in the
 * mixer produces clicks in the signal. */
static inline int32_t sat18(int64_t v)
{
    const int64_t lo = -(1LL << (MIX_W - 1));
    const int64_t hi =  (1LL << (MIX_W - 1)) - 1;
    return (int32_t)(v < lo ? lo : (v > hi ? hi : v));
}

/* ---- One channel's state ------------------------------------------------- */
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

/* Processes one sample. Returns 1 and writes (oi,oq) when there is output. */
static inline int ddc_push(ddc_ch *c, int32_t x, int32_t *oi, int32_t *oq)
{
    /* --- NCO: the top LUT_ADDR_W bits of the phase address the table ----- */
    uint32_t addr = c->phase >> (PHASE_W - LUT_ADDR_W);
    int32_t cosv = LUT[addr];
    /* sin(a) = cos(a - pi/2): a quarter table backwards. */
    int32_t sinv = LUT[(addr - LUT_QUARTER) & (LUT_SIZE - 1)];
    c->phase += c->ftw;                       /* wraps on its own, it is uint32 */

    /* --- Mixer. The >> (LUT_W-1) undoes the LUT scaling ------------------ */
    int32_t mi = sat18(((int64_t)x * cosv) >> (LUT_W - 1));
    int32_t mq = sat18(((int64_t)(-x) * sinv) >> (LUT_W - 1));

    /* --- Integrators: REGISTERED cascade, every stage uses the PREVIOUS
     *     value of the one before it. If they were chained within the same
     *     step the result would be different, and it would not match the
     *     RTL. ------------------------------------------------------------- */
    int64_t i0 = wrap36(c->integ_i[0] + mi);
    int64_t i1 = wrap36(c->integ_i[1] + c->integ_i[0]);
    int64_t i2 = wrap36(c->integ_i[2] + c->integ_i[1]);
    c->integ_i[0] = i0; c->integ_i[1] = i1; c->integ_i[2] = i2;

    int64_t q0 = wrap36(c->integ_q[0] + mq);
    int64_t q1 = wrap36(c->integ_q[1] + c->integ_q[0]);
    int64_t q2 = wrap36(c->integ_q[2] + c->integ_q[1]);
    c->integ_q[0] = q0; c->integ_q[1] = q1; c->integ_q[2] = q2;

    /* --- Decimation ------------------------------------------------------- */
    if (++c->count < CIC_R) return 0;
    c->count = 0;

    /* --- Combs, also a registered cascade --------------------------------- */
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

    /* --- Normalisation: the CIC gain is exactly 2^CIC_GROWTH -------------- */
    *oi = wrap18(c->cval_i[CIC_N - 1] >> CIC_GROWTH);
    *oq = wrap18(c->cval_q[CIC_N - 1] >> CIC_GROWTH);
    return 1;
}

/* ---- Loading .hex files -------------------------------------------------- */

/* Reads a $readmemh .hex: one hex value per line, no prefix, interpreted as a
 * signed integer of `bits` bits. */
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

/* ---- Stimulus generator -------------------------------------------------- *
 * The same scenario as model/gen_vectors.py: two tones summed and saturated.
 * It has to be the SAME algorithm on all three platforms or you end up
 * measuring libm instead of the generator. */
/* M_PI is not standard C (it is a POSIX extension that -std=c99 hides), so it
 * is defined here and does not depend on the compiler or the libc. */
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

/* ---- Verification against the golden vectors ---------------------------- */

/* ---- Generator, the SAME one as sig_source.v ---------------------------- *
 *
 * This used to call libm's sin(), which contradicted its own comment three
 * lines above: the FPGA generates with an NCO and a LUT, not with libm.
 * Measuring libm and calling it "the cost of generating" inflated the serial
 * part of the experiment -- in Python, generation ate 90 of 130 seconds -- and
 * on top of that produced DIFFERENT samples from the ones the FPGA sees.
 *
 * With the NCO it is three operations per sample and the stimulus is
 * bit-identical to the PL's, so CPU and FPGA process exactly the same signal.
 * That makes the result comparable, not merely similar.
 *
 * Mind the leading zero: sig_source.v has one cycle of latency in its output
 * register, so its first sample is zero and everything else is shifted by one.
 * It is reproduced here so both platforms see the same sequence. */
typedef struct {
    uint32_t pa, pb, ftwa, ftwb;
    int      sha, shb;
    int      first;
} siggen;

static void siggen_init(siggen *g)
{
    memset(g, 0, sizeof(*g));
    g->ftwa = tuning_word(F_IN,  FS);
    g->ftwb = tuning_word(F_OUT, FS);
    g->sha  = 2;                     /* SRC_SH = 0x022: both tones at 1/4 */
    g->shb  = 2;
    g->first = 1;
}

static inline int32_t nco_sin(uint32_t phase)
{
    uint32_t addr = phase >> (PHASE_W - LUT_ADDR_W);
    return LUT[(addr - LUT_QUARTER) & (LUT_SIZE - 1)];
}

/* Picks up where it left off: there is one single stream, cut into blocks. */
static void siggen_run(siggen *g, int32_t *dst, int n)
{
    const int32_t hi =  (1 << (IN_W - 1)) - 1;
    const int32_t lo = -(1 << (IN_W - 1));
    int i = 0;
    if (g->first) { dst[0] = 0; g->first = 0; i = 1; }
    for (; i < n; i++) {
        int32_t sa = nco_sin(g->pa);
        int32_t sb = nco_sin(g->pb);
        g->pa += g->ftwa;
        g->pb += g->ftwb;
        int32_t s = (sa >> g->sha) + (sb >> g->shb);
        dst[i] = s > hi ? hi : (s < lo ? lo : s);
    }
}


/* The usual one, for --bench: a whole stream in one go, from scratch. */
static void gen_stim(int32_t *dst, int n)
{
    siggen g;
    siggen_init(&g);
    siggen_run(&g, dst, n);
}

/* ---- Splitting the work across threads ---------------------------------- *
 *
 * One single input stream -- there is ONE antenna -- and the channels shared
 * out between threads. Every thread reads the same block and touches only its
 * own channels, so there is no shared writing and no lock is needed anywhere
 * on the hot path.
 *
 * Generation is measured SEPARATELY. That gives both models in one shot:
 *
 *     serial      total = generation + processing   (one core does both)
 *     overlapped  total = max(generation, processing) (a dedicated generator
 *                                                      thread)
 *
 * Giving the generation time separately avoids having to pick one of the two
 * and lets either be defended in the write-up. */
typedef struct {
    int       id;
    int       ch_lo, ch_hi;          /* [lo, hi) channels for this thread */
    ddc_ch   *ch;
    int32_t **blk;                   /* pointer to the current block */
    int      *blk_n;
    int      *keep_going;
    pthread_barrier_t *b_ini, *b_fin;
    int64_t   sink;
    double    t_work;
    int       pin;
    int       cpu;                   /* where it actually ended up running */
    int       with_gen;              /* if not, no barriers are needed */
    long long n_blk;
} worker;

/* Pins the thread to the i-th ALLOWED processor, not the i-th in the system.
 * That way it composes properly with numactl and taskset: if you are given
 * half the machine, the work is shared out inside that half instead of
 * fighting the mask. */
static void pin_to_allowed(int idx)
{
    cpu_set_t mask, one;
    if (sched_getaffinity(0, sizeof(mask), &mask) != 0) return;
    int n = CPU_COUNT(&mask), k = 0;
    if (n <= 0) return;
    for (int c = 0; c < CPU_SETSIZE; c++) {
        if (!CPU_ISSET(c, &mask)) continue;
        if (k == idx % n) {
            CPU_ZERO(&one);
            CPU_SET(c, &one);
            pthread_setaffinity_np(pthread_self(), sizeof(one), &one);
            return;
        }
        k++;
    }
}

/* One thread's slice of the current block. It lives on its own because both
 * use it: the spawned threads and the main one, which is also a worker. */
static void work_block(worker *w)
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
    w->t_work += now_s() - t0;
}

static void *worker_main(void *arg)
{
    worker *w = (worker *)arg;
    if (w->pin) pin_to_allowed(w->id);

    /* WITHOUT GENERATION THERE ARE NO BARRIERS. The buffer does not change for
     * the whole run and every thread touches only its own channels, so nobody
     * has to wait for anybody.
     *
     * And waiting gets ruinously expensive at scale: with one barrier per
     * block, every block costs the MAXIMUM of the 104 threads, not the mean.
     * Measured on the Xeons with 104 threads: the per-thread times spread
     * between 2.5 and 5.2 s with the mass at 3.6 -- system noise, not NUMA and
     * not hyperthreading -- and sampling that tail 104 times per block sends
     * the maximum through the roof. Throughput fell from 9,352 M
     * channel-samples/s with 52 threads to 3,586 M with 104. That was
     * measuring the straggler, not the machine. */
    if (!w->with_gen) {
        for (long long b = 0; b < w->n_blk; b++) work_block(w);
        return NULL;
    }

    for (;;) {
        pthread_barrier_wait(w->b_ini);
        if (!*w->keep_going) break;
        work_block(w);
        pthread_barrier_wait(w->b_fin);
    }
    return NULL;
}

/* ---- The measurement ----------------------------------------------------- */
static int cmd_mt(const char *rtldir, int n_ch, long long n_samp, int n_thr,
                  int with_gen, int pin, int csv, int blk_arg, int detail)
{
    if (load_lut(rtldir) != 0) {
        fprintf(stderr, "could not read %s/sin_lut.mem\n", rtldir);
        return 2;
    }
    if (n_thr > n_ch) n_thr = n_ch;      /* a thread with no channels measures nothing */

    /* Block size: between two barriers, every thread has to have plenty of
     * work or the synchronisation eats the measurement.
     *
     * Measured on the Xeons with 104 threads and one channel per thread: with
     * 64 k blocks the threads spent 8.2 s out of 13.8 WAITING -- 59 % -- and
     * throughput fell to a third of the 52-thread figure. With two channels
     * per thread, or with the block doubled, the skew between threads drops
     * from 2x to 2 %.
     *
     * So the block is sized by the work each thread gets: about 250 k
     * channel-samples per block per thread, which at ~4 ns each is on the order
     * of a millisecond. With that the barrier stays below one per cent and
     * there is nothing to remember to tune by hand. */
    int BLK = blk_arg;
    if (BLK <= 0) {
        int ch_per_thread = (n_ch + n_thr - 1) / n_thr;
        BLK = 250000 / (ch_per_thread > 0 ? ch_per_thread : 1);
        if (BLK < 65536)  BLK = 65536;
        if (BLK > 1048576) BLK = 1048576;
    }
    long long n_blk = (n_samp + BLK - 1) / BLK;
    n_samp = n_blk * (long long)BLK;

    ddc_ch  *ch   = calloc((size_t)n_ch, sizeof(ddc_ch));
    int32_t *buf  = malloc((size_t)BLK * sizeof(int32_t));
    worker  *ws   = calloc((size_t)n_thr, sizeof(worker));
    pthread_t *th = calloc((size_t)n_thr, sizeof(pthread_t));
    if (!ch || !buf || !ws || !th) { fprintf(stderr, "out of memory\n"); return 2; }

    /* Channels spread across the band, like a real scanner. */
    for (int k = 0; k < n_ch; k++) {
        double f = FS * (0.05 + 0.40 * k / (n_ch > 1 ? n_ch - 1 : 1));
        ddc_init(&ch[k], tuning_word(f, FS));
    }

    /* The main thread is WORKER 0, not a separate coordinator.
     *
     * The first version spawned n_thr workers and put the main thread into
     * both barriers as well: with 104 threads on 104 logical CPUs that made
     * 105 threads for 104 places. One shared a core with the main thread, took
     * twice as long, and the other 103 waited for it at the barrier. Measured:
     * at 104 threads the worst took 12.77 s and the best 6.02, and throughput
     * collapsed to a third of the 52-thread figure. That was the scheduling
     * mistake, not the machine.
     *
     * So `--threads T` means T compute threads in total, not one more. */
    pthread_barrier_t b_ini, b_fin;
    pthread_barrier_init(&b_ini, NULL, n_thr);
    pthread_barrier_init(&b_fin, NULL, n_thr);

    int32_t *blk_ptr = buf;
    int      blk_n   = BLK;
    int      keep_going = 1;

    for (int t = 0; t < n_thr; t++) {
        ws[t].id    = t;
        ws[t].ch_lo = (int)((long long)n_ch * t       / n_thr);
        ws[t].ch_hi = (int)((long long)n_ch * (t + 1) / n_thr);
        ws[t].ch    = ch;
        ws[t].blk   = &blk_ptr;
        ws[t].blk_n = &blk_n;
        ws[t].keep_going = &keep_going;
        ws[t].b_ini = &b_ini;
        ws[t].b_fin = &b_fin;
        ws[t].pin      = pin;
        ws[t].with_gen = with_gen;
        ws[t].n_blk    = n_blk;
        if (t > 0) pthread_create(&th[t], NULL, worker_main, &ws[t]);
    }
    if (pin) pin_to_allowed(0);                /* the main thread, like the rest */

    siggen g;
    siggen_init(&g);
    siggen_run(&g, buf, BLK);            /* first block, off the clock */

    struct timespec wall0, wall1;
    clock_gettime(CLOCK_REALTIME, &wall0);
    double t_gen = 0.0;
    double t0 = now_s();

    if (!with_gen) {
        /* Barrier-free path: every thread walks the whole run on its own and
         * the main thread does its share. Nobody waits for anybody. */
        for (long long b = 0; b < n_blk; b++) work_block(&ws[0]);
        for (int t = 1; t < n_thr; t++) pthread_join(th[t], NULL);
    } else {
        for (long long b = 0; b < n_blk; b++) {
            pthread_barrier_wait(&b_ini);  /* all start, main thread included */
            work_block(&ws[0]);            /* the main thread does its share */
            pthread_barrier_wait(&b_fin);  /* and here they have all finished */
            if (b + 1 < n_blk) {
                double tg = now_s();
                siggen_run(&g, buf, BLK);  /* the next block */
                t_gen += now_s() - tg;
            }
        }
        keep_going = 0;
        pthread_barrier_wait(&b_ini);      /* wake them so they can leave */
        for (int t = 1; t < n_thr; t++) pthread_join(th[t], NULL);
    }

    double dt = now_s() - t0;
    clock_gettime(CLOCK_REALTIME, &wall1);

    int64_t sink = 0;
    double t_worst = 0.0, t_best = 1e18;
    for (int t = 0; t < n_thr; t++) {
        sink += ws[t].sink;
        if (ws[t].t_work > t_worst) t_worst = ws[t].t_work;
        if (ws[t].t_work < t_best)  t_best  = ws[t].t_work;
    }

    double cm    = (double)n_ch * (double)n_samp;
    double cms   = cm / dt;
    double sps   = cms / n_ch;
    double t_pro = dt - t_gen;
    double overlap = (t_gen > t_pro ? t_gen : t_pro);

    if (csv) {
        /* The absolute timestamps are so the power sampler can trim EXACTLY
         * the right window. Without them the measurement is contaminated by
         * the ramp-up and the tail. */
        printf("n_ch,n_thr,gen,n_samples,seconds,ch_samples_per_s,sustained_sps,"
               "gen_s,proc_s,overlap_s,worst_thread_s,best_thread_s,"
               "t_start_unix,t_end_unix\n");
        printf("%d,%d,%d,%lld,%.6f,%.0f,%.0f,%.6f,%.6f,%.6f,%.6f,%.6f,"
               "%.6f,%.6f\n",
               n_ch, n_thr, with_gen, n_samp, dt, cms, sps,
               t_gen, t_pro, overlap, t_worst, t_best,
               wall0.tv_sec + wall0.tv_nsec * 1e-9,
               wall1.tv_sec + wall1.tv_nsec * 1e-9);
    } else {
        printf("\nbench_ddc mt - %d channels, %d threads, %lld samples%s\n",
               n_ch, n_thr, n_samp, pin ? ", pinned" : "");
        printf("  total time          : %10.3f s\n", dt);
        if (with_gen) {
            printf("    generation        : %10.3f s\n", t_gen);
            printf("    processing        : %10.3f s\n", t_pro);
            printf("    if overlapped     : %10.3f s   (one thread dedicated to generating)\n",
                   overlap);
        }
        printf("  channel-samples/s   : %10.3f M\n", cms / 1e6);
        printf("  sustained rate      : %10.3f MSPS with %d channels\n",
               sps / 1e6, n_ch);
        printf("  spread over threads : worst %.3f s, best %.3f s  (%.1f %% skew)\n",
               t_worst, t_best, t_worst > 0 ? 100.0 * (t_worst - t_best) / t_worst : 0.0);
        /* If one thread takes far longer than another doing the SAME work, the
         * blame lies in where it happened to run. Without seeing the
         * per-CPU breakdown there is no way to tell hyperthreading from NUMA
         * from bad luck. */
        if (detail) {
            printf("  thread  cpu   seconds\n");
            for (int t = 0; t < n_thr; t++)
                printf("  %6d  %3d   %8.3f\n", t, ws[t].cpu, ws[t].t_work);
        }
        printf("  (checksum %lld)\n", (long long)sink);

        double need = 100e6;
        if (sps >= need) printf("\n  100 MSPS: MAKES IT, margin x%.2f\n\n", sps / need);
        else             printf("\n  100 MSPS: SHORTFALL x%.0f\n\n", need / sps);
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
        fprintf(stderr, "could not read %s/sin_lut.mem\n", rtldir);
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
        fprintf(stderr, "unreadable vectors in %s (stim=%d gold=%d/%d)\n",
                vdir, ns, ngi, ngq);
        return 2;
    }

    /* The same tuning word as params.vh: 10 MHz at 100 MSPS. */
    ddc_ch c;
    ddc_init(&c, tuning_word(F_IN, FS));

    int produced = 0, errors = 0;
    for (int k = 0; k < ns; k++) {
        int32_t oi, oq;
        if (ddc_push(&c, (int32_t)stim[k], &oi, &oq)) {
            if (produced < ngi) {
                if (oi != gi[produced] || oq != gq[produced]) {
                    if (errors < 10)
                        printf("  [%d] expected I=%lld Q=%lld   C I=%d Q=%d\n",
                               produced, (long long)gi[produced],
                               (long long)gq[produced], oi, oq);
                    errors++;
                }
            }
            produced++;
        }
    }

    printf("\nbench_ddc --verify\n");
    printf("  input samples      : %d\n", ns);
    printf("  outputs produced   : %d\n", produced);
    printf("  compared           : %d\n", produced < ngi ? produced : ngi);
    printf("  mismatches         : %d\n\n", errors);
    if (errors == 0 && produced >= ngi) {
        printf("RESULT: PASS - bit-exact with the model and with the RTL.\n\n");
        return 0;
    }
    printf("RESULT: FAIL\n\n");
    return 1;
}

/* ---- Benchmark ----------------------------------------------------------- */

static int cmd_bench(const char *rtldir, int n_ch, int n_samp, int with_gen)
{
    if (load_lut(rtldir) != 0) {
        fprintf(stderr, "could not read %s/sin_lut.mem\n", rtldir);
        return 2;
    }

    ddc_ch *ch = malloc((size_t)n_ch * sizeof(ddc_ch));
    int32_t *stim = malloc((size_t)n_samp * sizeof(int32_t));
    if (!ch || !stim) { fprintf(stderr, "out of memory\n"); return 2; }

    /* Channels spread across the band, like a real scanner. */
    for (int k = 0; k < n_ch; k++) {
        double f = FS * (0.05 + 0.40 * k / (n_ch > 1 ? n_ch - 1 : 1));
        ddc_init(&ch[k], tuning_word(f, FS));
    }

    /* If generation is not being measured, it happens off the clock. */
    if (!with_gen) gen_stim(stim, n_samp);

    volatile int64_t sink = 0;      /* so the compiler cannot delete the work */
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

    double cm    = (double)n_ch * n_samp;      /* channel-samples */
    double cms   = cm / dt;
    double sps   = cms / n_ch;                 /* sustained input rate */
    double gops  = cms * 18.0 / 1e9;           /* ~18 operations per cs */

    printf("\nbench_ddc - %d channels, %d samples%s\n",
           n_ch, n_samp, with_gen ? "  (generation INCLUDED in the measurement)" : "");
    printf("  time              : %10.3f s\n", dt);
    printf("  channel-samples/s : %10.3f M\n", cms / 1e6);
    printf("  input rate        : %10.3f MSPS\n", sps / 1e6);
    printf("  ~operations/s     : %10.3f Gop/s\n", gops);
    printf("  (checksum %lld)\n", (long long)sink);

    double need = 100e6;
    printf("\n  To sustain 100 MSPS with %d channels:\n", n_ch);
    if (sps >= need)
        printf("  MAKES IT, with a margin of x%.2f\n\n", sps / need);
    else
        printf("  SHORTFALL x%.0f\n\n", need / sps);

    free(ch); free(stim);
    return 0;
}

/* ---- main ---------------------------------------------------------------- */

static void usage(const char *p)
{
    fprintf(stderr,
        "usage:\n"
        "  %s --verify [vector_dir] [rtl_dir]\n"
        "  %s --bench N_CHANNELS N_SAMPLES [--gen] [rtl_dir]\n"
        "  %s mt --ch N --threads T --samples M [--gen] [--pin] [--csv] [rtl_dir]\n\n"
        "defaults: vector_dir=../tb/vectors and rtl_dir=../rtl\n", p, p, p);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 2; }

    if (!strcmp(argv[1], "--verify")) {
        const char *vdir = (argc > 2) ? argv[2] : "../tb/vectors";
        const char *rdir = (argc > 3) ? argv[3] : "../rtl";
        return cmd_verify(vdir, rdir);
    }

    /* Dumps the stimulus so it can be compared with the RTL's. The generator
     * has to produce EXACTLY the same thing as sig_source.v, or CPU and FPGA
     * would be processing different signals and the comparison would be
     * worthless:
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
            else if (!strcmp(argv[i], "--detail")) det = 1;
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
