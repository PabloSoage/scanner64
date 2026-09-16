// ---------------------------------------------------------------------------
// scanner_top.v - Bank of N parallel DDC channels, with a power meter.
//
// This is the scanner: N frequencies watched SIMULTANEOUSLY, sample by sample,
// without losing one. Every channel has its own tuning word, so the
// frequencies are arbitrary - not a fixed grid like an FFT filter bank. To
// watch the 16 PMR446 channels plus a few amateur frequencies at the same
// time, it is exactly what you need.
//
// ARCHITECTURE: shared combs
//
// The channel is split into two halves that run at very different rates:
//
//   ddc_front   NCO + mixer + integrators. One sample per cycle, so there is
//               one per channel, and there is no choice about it.
//   comb_bank   the combs. They work 1 cycle in CIC_R, so ONE single set
//               serves UNITS_PER_BANK units in turns. A unit is an I or Q
//               chain: that makes CH_PER_BANK = UNITS_PER_BANK/2 channels per
//               bank.
//
// Replicating the combs per channel cost a measured 216 LUTs and 360 FFs per
// channel, and left the chip ceiling at 144 channels. Sharing them raises it
// to 191.
//
// CONSEQUENCE FOR THE INTERFACE: the channels NO LONGER all come out on the
// same cycle. The channel occupying unit u of its bank comes out u cycles
// after the decimation. The values are bit-identical (tb_comb_bank checks
// that), they are only reordered in time, and ch_valid marks each one where it
// belongs. If you need a simultaneous snapshot of every channel, wait for the
// round to finish: it lasts UNITS_PER_BANK cycles from the decimation.
//
// Why a CPU does not do this:
//   N=64 channels x 100 MSPS x ~18 operations/sample ~= 115 Gop/s sustained,
//   without dropping samples and with bounded latency. The KV260's own four
//   Cortex-A53 deliver on the order of 10-15 real Gop/s. That is a factor of
//   ~10 on the SAME chip. See sw/bench_cpu.py to measure it on your machine.
//
// Register interface: synchronous and simple, on purpose. Wrapping it in
// AXI4-Lite is a Vivado step (Create and Package IP), not something that
// should clutter the DSP core.
// ---------------------------------------------------------------------------

`default_nettype none

module scanner_top #(
    parameter integer N_CH       = 16,   // parallel channels
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
    parameter integer PWR_W      = 48,   // width of the power accumulator
    // Units (I or Q chains) per comb bank. It has to be even and smaller than
    // CIC_R, so the round finishes before the next decimation.
    parameter integer UNITS_PER_BANK = 32,
    // Channels per set of NCO, mixer and integrators. With 1, every channel
    // has its own, which is the design validated in silicon. With more, they
    // are time-multiplexed: it can be floor(Fclk/Fs), and the less bandwidth
    // you need, the more channels fit in the same area.
    parameter integer FOLD       = 1,
    parameter         LUT_FILE   = "sin_lut.mem"
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // --- Input sample stream (from the ADC or from sig_source) -------------
    input  wire                        in_valid,
    input  wire signed [IN_W-1:0]      in_data,

    // --- Configuration -----------------------------------------------------
    input  wire                        cfg_we,      // writes ftw into cfg_ch
    input  wire [$clog2(N_CH)-1:0]     cfg_ch,
    input  wire [PHASE_W-1:0]          cfg_ftw,
    input  wire [31:0]                 cfg_pwr_len, // samples per measurement
    input  wire                        cfg_clear,   // resets the accumulators

    // --- Power readout ------------------------------------------------------
    input  wire [$clog2(N_CH)-1:0]     rd_ch,
    output wire [PWR_W-1:0]            rd_pwr,
    output wire [N_CH-1:0]             pwr_ready,   // measurement done, per channel

    // --- Raw I/Q samples of the selected channel (for a DMA dump) ----------
    input  wire [$clog2(N_CH)-1:0]     tap_ch,
    output wire                        tap_valid,
    output wire signed [OUT_W-1:0]     tap_i,
    output wire signed [OUT_W-1:0]     tap_q,

    // With FOLD > 1 the scanner requires Fs <= Fclk/FOLD. If samples arrive
    // faster it drops them, and silently the output would still look like a
    // signal. This bit sticks high the first time it happens.
    output wire                        fold_overrun
);

    localparam integer N_SET   = (N_CH + FOLD - 1) / FOLD;
    localparam integer SLOT_W  = (FOLD > 1) ? $clog2(FOLD) : 1;
    localparam integer CH_PER_BANK = UNITS_PER_BANK / 2;
    localparam integer N_BANK      = (N_CH + CH_PER_BANK - 1) / CH_PER_BANK;
    localparam integer UW          = $clog2(UNITS_PER_BANK);

    // ---- Tuning registers, one per channel ---------------------------------
    //
    // With FOLD > 1 this array is written and nobody reads it: the tuning goes
    // straight into its ddc_fold slot, which stores it already. It is left as
    // it is on purpose. I tried wrapping it in a generate so it only existed
    // with FOLD = 1, thinking the reset was keeping it alive, and measured at
    // the 256-channel point the saving was ZERO registers: Vivado was already
    // removing it. Dead-code analysis works backwards from the outputs, and a
    // reset is not an output.
    //
    // A generate that saves nothing only complicates the module and forces the
    // testbench to chase the hierarchical path. A comment costs less.
    reg [PHASE_W-1:0] ftw [0:N_CH-1];

    genvar g, f;
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < N_CH; k = k + 1)
                ftw[k] <= {PHASE_W{1'b0}};
        end else if (cfg_we) begin
            ftw[cfg_ch] <= cfg_ftw;
        end
    end

    // ---- Channel front ends, at the input rate -----------------------------
    //
    // TWO PATHS, AND NOT OUT OF INDECISION.
    //
    // With FOLD = 1, N_CH independent front ends are instantiated: that is the
    // design validated bit by bit against the model and measured in silicon,
    // and it does not get touched. With FOLD > 1, N_SET folded sets are
    // instantiated, each serving FOLD channels by time multiplexing.
    //
    // Keeping the FOLD = 1 path intact costs one generate branch and stops a
    // new experiment from dragging along with it the one thing we already know
    // works on the board. Same criterion as with CIC_USE_DSP.
    wire [N_CH-1:0]         fr_dec;
    wire signed [CIC_W-1:0] fr_tap_i [0:N_CH-1];
    wire signed [CIC_W-1:0] fr_tap_q [0:N_CH-1];
    wire                    fold_done;

    generate
    if (FOLD <= 1) begin : gen_plain
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
        assign fold_done    = 1'b0;
        assign fold_overrun = 1'b0;   // with no folding there is no round to invade
    end else begin : gen_folded
        for (g = 0; g < N_SET; g = g + 1) begin : gen_set
            wire                    s_ov;
            wire [SLOT_W-1:0]       s_os;
            wire signed [CIC_W-1:0] s_ti, s_tq;
            wire                    s_ovr;
            wire                    s_cfg = cfg_we && ((cfg_ch / FOLD) == g);

            ddc_fold #(
                .FOLD (FOLD), .IN_W (IN_W), .PHASE_W (PHASE_W),
                .LUT_ADDR_W (LUT_ADDR_W), .LUT_W (LUT_W), .MIX_W (MIX_W),
                .CIC_N (CIC_N), .CIC_R (CIC_R), .CIC_W (CIC_W),
                .LUT_FILE (LUT_FILE)
            ) u_fold (
                .clk (clk), .rst_n (rst_n),
                .cfg_we (s_cfg), .cfg_slot (cfg_ch[SLOT_W-1:0]),
                .cfg_ftw (cfg_ftw),
                .in_valid (in_valid), .in_data (in_data), .ready (),
                .out_valid (s_ov), .out_slot (s_os),
                .tap_i (s_ti), .tap_q (s_tq), .overrun (s_ovr)
            );

            // CAPTURE. The comb bank wants all its units at once, but the
            // folded set emits them one per cycle. These registers hold the
            // whole round so that din_flat is stable on the start pulse, which
            // is the only instant the bank looks at it.
            reg signed [CIC_W-1:0] cap_i [0:FOLD-1];
            reg signed [CIC_W-1:0] cap_q [0:FOLD-1];
            integer c;
            always @(posedge clk) begin
                if (!rst_n) begin
                    for (c = 0; c < FOLD; c = c + 1) begin
                        cap_i[c] <= {CIC_W{1'b0}};
                        cap_q[c] <= {CIC_W{1'b0}};
                    end
                end else if (s_ov) begin
                    cap_i[s_os] <= s_ti;
                    cap_q[s_os] <= s_tq;
                end
            end

            for (f = 0; f < FOLD; f = f + 1) begin : gen_expose
                if (g*FOLD + f < N_CH) begin : gen_live
                    assign fr_tap_i[g*FOLD + f] = cap_i[f];
                    assign fr_tap_q[g*FOLD + f] = cap_q[f];
                    assign fr_dec  [g*FOLD + f] = 1'b0;   // not used here
                end
            end
        end
        // Every set sees the same in_valid and comes out of the same reset, so
        // they decimate on the same round. The round is complete when set 0
        // emits its last slot.
        assign fold_done = gen_set[0].s_ov &&
                           (gen_set[0].s_os == (FOLD[SLOT_W-1:0] - 1'b1));

        // It only takes ONE set losing a sample for the sweep to stop being
        // trustworthy, so they are all merged into a single bit.
        wire [N_SET-1:0] ovr_bits;
        for (g = 0; g < N_SET; g = g + 1) begin : gen_ovr
            assign ovr_bits[g] = gen_set[g].s_ovr;
        end
        assign fold_overrun = |ovr_bits;
    end
    endgenerate

    // With FOLD = 1 every front end shares in_valid, their dec_now lands on
    // the same cycle and the one from channel 0 is enough. With folding you
    // have to wait for the whole round to be captured, so the pulse arrives
    // one cycle later.
    reg fold_done_d;
    always @(posedge clk) begin
        if (!rst_n) fold_done_d <= 1'b0;
        else        fold_done_d <= fold_done;
    end
    wire dec_pulse = (FOLD <= 1) ? fr_dec[0] : fold_done_d;

    // ---- Shared comb banks -------------------------------------------------
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
                    // Even unit -> channel's I branch; odd -> Q branch.
                    assign din_flat[u*CIC_W +: CIC_W] =
                        (u % 2 == 0) ? fr_tap_i[CIDX] : fr_tap_q[CIDX];
                end else begin : gen_spare
                    // Gap in the last bank when N_CH does not fill its quota.
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

    // ---- Realignment: from (bank, unit) to (channel, I/Q) ------------------
    // The normalisation is the same shift ddc_channel did: the CIC gain is
    // exactly (R*M)^N = 2^CIC_GROWTH.
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
                            // The Q branch arrives right behind the I one, so
                            // by now both are here: the pair gets published.
                            ch_i[ci]     <= i_hold[ci];
                            ch_q[ci]     <= dd[CIC_GROWTH +: OUT_W];
                            ch_valid[ci] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    // ---- Power meter, ONE PER BANK -----------------------------------------
    //
    // There used to be one per channel: two multipliers each, 2*N_CH DSP48.
    // With 16 channels that was 32 DSPs out of the design's 80 -- more than
    // the front ends took.
    //
    // And it was wasted on something the architecture had already settled back
    // in B7: the channels do NOT come out at the same time any more.
    // comb_bank emits them one at a time, so within a bank it publishes at
    // most one channel per cycle. A single set of multipliers serves every
    // channel in the bank.
    //
    //     2*N_CH DSP  ->  2*N_BANK DSP
    //
    // With 16 channels and one bank: 32 -> 2. With 64 and four banks: 128 -> 8.
    //
    // The state is still per channel -- accumulator, counter and frozen value
    // -- but those are registers, not multipliers, and they are precisely what
    // cannot be shared. It is read and written on the same cycle, so there is
    // no pipeline hazard: the bank's next publication is at least two cycles
    // away, because the I branch has to go through first.
    localparam integer CHB_W = (CH_PER_BANK > 1) ? $clog2(CH_PER_BANK) : 1;

    // WIDTH OF THE WINDOW COUNTER, and this is not a choice about saving but
    // about correctness. Each mag2 is at most 2*(2^(OUT_W-1))^2 = 2^35 with
    // OUT_W=18, so the PWR_W=48-bit accumulator holds
    //
    //     2^48 / 2^35 = 2^13 = 8192 samples
    //
    // and not one more. With the 32-bit counter that used to be here, asking
    // for a window of 100,000 samples was perfectly possible: the accumulator
    // overflowed silently and the power read back was garbage that looked like
    // data. The narrow counter MAKES THAT IMPOSSIBLE to ask for, and saves 19
    // registers per channel into the bargain.
    localparam integer PWR_CNT_W = PWR_W - 2*OUT_W + 1;         // 13 with 48/18
    localparam [PWR_CNT_W-1:0] PWR_LEN_MAX = {PWR_CNT_W{1'b1}};

    // The requested window, clipped to what the accumulator can sustain.
    wire [PWR_CNT_W-1:0] pwr_len_eff =
        (cfg_pwr_len > {{(32-PWR_CNT_W){1'b0}}, PWR_LEN_MAX})
            ? PWR_LEN_MAX : cfg_pwr_len[PWR_CNT_W-1:0];

    // A PACKED vector, not an array of wires. Indexing an unpacked array with
    // a variable inside a continuous assign is slippery ground and here it
    // returned X; with a part select on a flat vector there is no ambiguity.
    wire [N_BANK*PWR_W-1:0] pwr_flat;

    genvar pb, pc;
    generate
        for (pb = 0; pb < N_BANK; pb = pb + 1) begin : gen_pwr
            // Which channel of this bank is publishing, if any. The Q branch
            // comes behind the I one, so the pair is complete on the odd unit,
            // which is the same instant the realignment publishes it.
            wire [UW-1:0]    u_now = bk_unit[pb];
            wire [CHB_W-1:0] k_now = u_now[UW-1:1];
            wire             pub   = bk_valid[pb] && u_now[0] &&
                                     ((pb*CH_PER_BANK + (u_now >> 1)) < N_CH);

            reg                    pw_v;
            reg [CHB_W-1:0]        pw_k;
            reg signed [OUT_W-1:0] pw_i, pw_q;

            always @(posedge clk) begin
                if (!rst_n) begin
                    pw_v <= 1'b0;
                    pw_k <= {CHB_W{1'b0}};
                    pw_i <= {OUT_W{1'b0}};
                    pw_q <= {OUT_W{1'b0}};
                end else begin
                    pw_v <= pub;
                    if (pub) begin
                        pw_k <= k_now;
                        pw_i <= i_hold[pb*CH_PER_BANK + (u_now >> 1)];
                        pw_q <= bk_data[pb][CIC_GROWTH +: OUT_W];
                    end
                end
            end

            // The bank's only two multipliers.
            wire signed [2*OUT_W-1:0] mag2 = pw_i*pw_i + pw_q*pw_q;

            reg [PWR_W-1:0]       acc  [0:CH_PER_BANK-1];
            reg [PWR_CNT_W-1:0]   cnt  [0:CH_PER_BANK-1];
            reg [PWR_W-1:0]       hold [0:CH_PER_BANK-1];
            reg [CH_PER_BANK-1:0] done;

            integer kk;
            always @(posedge clk) begin
                if (!rst_n || cfg_clear) begin
                    for (kk = 0; kk < CH_PER_BANK; kk = kk + 1) begin
                        acc[kk]  <= {PWR_W{1'b0}};
                        cnt[kk]  <= {PWR_CNT_W{1'b0}};
                        hold[kk] <= {PWR_W{1'b0}};
                    end
                    done <= {CH_PER_BANK{1'b0}};
                end else if (pw_v) begin
                    if (cnt[pw_k] + 1'b1 >= pwr_len_eff) begin
                        // Window complete: the value is frozen and it restarts.
                        hold[pw_k] <= acc[pw_k] + mag2;
                        acc[pw_k]  <= {PWR_W{1'b0}};
                        cnt[pw_k]  <= {PWR_CNT_W{1'b0}};
                        done[pw_k] <= 1'b1;
                    end else begin
                        acc[pw_k] <= acc[pw_k] + mag2;
                        cnt[pw_k] <= cnt[pw_k] + 1'b1;
                    end
                end
            end

            // Modulo, not a part select: rd_ch has $clog2(N_CH) bits, which
            // with few channels are FEWER than CHB_W, and rd_ch[CHB_W-1:0] on
            // a narrower signal returns X. It cost a testbench in red.
            assign pwr_flat[pb*PWR_W +: PWR_W] = hold[rd_ch % CH_PER_BANK];

            for (pc = 0; pc < CH_PER_BANK; pc = pc + 1) begin : gen_rdy
                if (pb*CH_PER_BANK + pc < N_CH) begin : gen_live
                    assign pwr_ready[pb*CH_PER_BANK + pc] = done[pc];
                end
            end
        end
    endgenerate

    wire [31:0] rd_bank = (N_BANK > 1) ? (rd_ch / CH_PER_BANK) : 32'd0;
    assign rd_pwr = pwr_flat[rd_bank*PWR_W +: PWR_W];

    assign tap_valid = ch_valid[tap_ch];
    assign tap_i     = ch_i[tap_ch];
    assign tap_q     = ch_q[tap_ch];

endmodule

`default_nettype wire
