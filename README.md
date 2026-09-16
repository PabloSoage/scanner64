# scanner64 — a real-time multichannel DDC bank for the KV260's PL

A bank of **N DDC channels** (digital down-converters) watching N frequencies
**simultaneously**, sample by sample, without dropping one.

Every channel has its own tuning word, so the frequencies are arbitrary — not a fixed grid like
an FFT filter bank. To watch the 16 PMR446 channels plus a handful of amateur frequencies at the
same time, that is exactly what you need.

It is not a toy demo. It runs on real silicon on an AMD Kria KV260, and the numbers below were
measured there.

---

## What it does, measured on the board

| | |
|---|---|
| **Throughput** | **100.05 MSPS**, one sample per clock cycle, which is `pl_clk0` exactly |
| **Samples lost** | **none.** 200,733,580 in, 3,136,463 outputs against 3,136,462 expected — the +1 is the pipeline |
| **Arithmetic** | **bit-exact against the Python model**, on all four channels, including the empty ones whose output is 1 and 2 LSB |
| **Discrimination** | **59.7 dB** between channels sitting on a tone and channels tuned to empty band, with 16 channels |
| **Power** | **8.38 mW per channel**, measured with the board's INA260 |
| **Fmax** | **169.9 MHz** post-route on the `-2LV` part |

The same four Cortex-A53 sitting next to the PL, running the same arithmetic in C, manage
**1.58 MSPS** with 16 channels. That is the comparison that matters, because it is the same chip
and the same power budget.

---

## Why this is not a job for a CPU

Worth saying precisely, because the brochure version (*"the FPGA is faster"*) is false: a desktop
PC with AVX-512 has **more** raw GOPS than a ZU5EV's PL. The real argument is a different one.

| | CPU | KV260 PL |
|---|---|---|
| Cost of adding a channel | **More time** per sample | **A fixed slice of area**, the time does not change |
| Sustained rate | Depends on the load | **One sample per cycle, always** |
| Latency | Variable (scheduler, caches, interrupts) | **Fixed and known** |
| Samples lost | Inevitable if you overrun | **Impossible by construction** |

And here is what that costs in energy, all three platforms running **the same bit-exact code on
the same stimulus**:

| platform | M channel-samples/s | power | **M cs/s per watt** | what the power number covers |
|---|---|---|---|---|
| 4× Cortex-A53 (Kria) | 158 | — | — | |
| **Kria PL, 64 ch @ 100 MSPS** | **6,400** | 0.535 W | **11,963** | PL logic only, INA260 delta |
| **Kria, whole board** | **6,400** | 4.30 W | **1,488** | the entire board, A53s included |
| 1× Tesla V100 | 9,379 | ~70 W over idle | 134 | the card, via `nvidia-smi` |
| 4× Tesla V100 | 38,359 | ~280 W over idle | 137 | the cards |
| 2× Xeon Platinum 8171M (52 cores) | 11,232 | ~300 W over idle | 37 | the whole machine, at the wall |

**The measurement boundaries are not the same**, and that matters more than the ratio. Even taken
at its most unfavourable — whole board against card-only and wall-minus-idle — the Kria is 11×
the GPUs and 40× the Xeons.

Two results here are worth saying out loud because they cut against the intuition:

- **The Xeons beat a single V100** (11,232 against 9,379). The GPU is not badly programmed: this
  filter is about the worst thing you can hand a GPU. 64-bit integers, emulated at double cost on
  SM70; a serial dependency chain per thread with nothing to overlap; 69 registers per thread
  holding occupancy at 46 %. Tensor cores are no use at all — not for precision reasons, but
  because the CIC integrators **overflow on purpose** and floating point saturates instead of
  wrapping.
- **Multi-GPU scaling is perfect and pointless.** 9,379 / 9,528 / 9,590 M **per GPU** with 1, 2
  and 4. The channels are independent and each GPU has its own copy of the stream, so **NVLink and
  NCCL contribute nothing here**.
- **The FPGA loses on raw throughput, and that is why it wins.** 6,400 against the Xeons' 11,232.
  What flips the sign is the denominator: two orders of magnitude less power.

Measure it yourself: `sw/bench_ddc.c` is the same DDC in C and runs on anything;
`sw/bench_ddc.cu` is the CUDA version; `sw/bench_cpu.py` is the Python one, which measures the
interpreter and is kept only for scale.

---

## What is verified, and how

| Item | State | How it was checked |
|---|---|---|
| Algorithm and fixed-point arithmetic | ✅ | `model/ddc_model.py` — 4 tests, all passing |
| RTL semantics | ✅ | `model/rtl_check.py` — 39 samples against golden vectors, **0 mismatches** |
| `ddc_channel` simulation | ✅ | XSim — 40 outputs compared, **0 mismatches** |
| `scanner_top` simulation | ✅ | XSim — 4 channels, 160 comparisons, 6 tests, **0 mismatches** |
| Shared vs replicated combs | ✅ | XSim — 368 comparisons against `cic_decim`, **0 mismatches** |
| Folded vs unfolded front end | ✅ | XSim — 372 comparisons against 4 separate channels, **0 mismatches** |
| AXI4-Lite register map | ✅ | XSim — 19 registers read and written back |
| C implementation | ✅ | `bench_ddc --verify` — against the **same** golden vectors as the RTL |
| Synthesis, timing closure | ✅ | Full implementation for `xck26-sfvc784-2LV-c`, 0 errors |
| **Behaviour in hardware** | ✅ | KV260, 14–15 Sep 2026. See the table at the top |

Every implementation — model, RTL, C and CUDA — answers to the **same referee**: the golden
vectors in `tb/vectors/`, generated from the verified model.

The testbenches were **validated by mutation**. A testbench you have never seen fail tells you
nothing about what it checks. Two bugs were injected into a copy of the RTL — a `tap_ch` mux that
ignores its selection, and a `cfg_we` that always writes channel 0 — and the testbench caught
them: T1 4 failures, T2 160, T3 3, T4 4, T5 4.

---

## Layout

```
scanner64/
├── model/
│   ├── ddc_model.py         Bit-exact model. THE REFERENCE. Self-testing.
│   ├── gen_vectors.py       Generates the NCO LUT and the golden vectors.
│   ├── gen_vectors_bank.py  Golden vectors for the multichannel bank.
│   ├── rtl_check.py         Transcribes the RTL semantics and compares.
│   └── golden_hw.py         Checks what the board measured against the model.
├── rtl/
│   ├── nco.v                Phase accumulator + cosine LUT in BRAM.
│   ├── cic_integ.v          CIC integrators, at the input rate.
│   ├── comb_chain.v         Combs for ONE unit, at the decimated rate.
│   ├── comb_bank.v          Combs shared in turns between 32 units.
│   ├── cic_decim.v          The two halves together: a plain CIC decimator.
│   ├── ddc_front.v          NCO + mixer + integrators. No combs.
│   ├── ddc_fold.v           One front end time-shared between FOLD channels.
│   ├── ddc_channel.v        A complete, self-contained channel.
│   ├── scanner_top.v        N channels + power meter.
│   ├── scanner_axi.v        scanner_top + sig_source behind AXI4-Lite.
│   ├── sig_source.v         Signal generator in the PL (the "antenna", no ADC).
│   └── sin_lut.mem          Generated by gen_vectors.py.
├── tb/                      Seven testbenches; each prints PASS or FAIL.
├── sw/
│   ├── scanner_ctl.c        Drives the board from Linux over /dev/mem.
│   ├── bench_ddc.c          The same DDC in C, multithreaded.
│   ├── bench_ddc.cu         The same DDC in CUDA, integer.
│   ├── bench_cpu.py         The Python version (measures the interpreter).
│   └── d6_fino.sh           Power against channel count, with error bars.
└── syn/
    ├── make_project.tcl     Builds a Vivado project for simulating and reading reports.
    ├── build_kria.tcl       RTL -> KV260 bitstream, block design included.
    ├── ooc_channel.tcl      OOC synthesis of one channel.
    ├── sweep_bank.tcl       N_CH sweep over scanner_top.
    ├── fold_check.tcl       Folding against the original, in area.
    ├── impl_bank.tcl        Full implementation, for the real Fmax.
    ├── sweep_nch.ps1        One bitstream per channel count.
    ├── sweep_fs.ps1         The channels-against-Fs curve.
    └── results/             Reports from the last run.
```

---

## How to use it

### 1. The model, which is the reference

```bash
cd model
py ddc_model.py           # the model's self-test
py gen_vectors.py         # writes sin_lut.mem and tb/vectors/
py gen_vectors_bank.py    # the bank's golden vectors
py rtl_check.py           # checks the RTL semantics against them
```

### 2. Simulate

With **XSim**, from a working directory holding `vectors/` and `sin_lut.mem` (the testbenches
`$readmemh` with paths relative to the simulator's working directory):

```bash
mkdir build && cd build
cp -r ../tb/vectors . && cp ../rtl/sin_lut.mem .
xvlog -sv -i vectors ../rtl/*.v ../tb/*.v
xelab tb_scanner_top -s tb_bank && xsim tb_bank -runall
```

> **Windows warning:** if the working directory has a very long path (~250 characters), `xelab`
> fails with `Failed to compile generated C file`. It is not the design: it is XSim's internal
> gcc. Work from a short path.

The seven testbenches and what each one covers:

| | What it checks |
|---|---|
| `tb_ddc_channel` | the arithmetic of one channel, against the golden vectors |
| `tb_scanner_top` | six tests on the bank: tuning, channels not mixing, the `tap_ch` mux, the power meter, **discrimination**, and `cfg_clear` |
| `tb_comb_bank` | shared combs give bit-identical results to replicated ones |
| `tb_ddc_fold` | the folded front end equals FOLD separate front ends, bit for bit |
| `tb_scanner_fold` | `scanner_top` with FOLD > 1, end to end |
| `tb_scanner_axi` | the 19 AXI4-Lite registers, read and written |
| `tb_sig_source` | dumps the generator's samples, to compare against the model and against C |

Each one prints `RESULT: PASS` or `RESULT: FAIL` with a mismatch count. A testbench you have to
interpret by eye is not a testbench.

> **Check that elaboration succeeded before believing the result.** `xsim` will happily run a
> previously built snapshot if `xelab` failed, and show you a green result from the last time it
> worked. It has happened here, twice.

### 3. Open it in the Vivado GUI

[`syn/make_project.tcl`](syn/make_project.tcl) sets up the whole project — RTL, testbenches,
include path and vectors where XSim looks for them:

```bash
vivado -mode batch -source <repo>/syn/make_project.tcl -tclargs C:/kv/s64
vivado C:/kv/s64/scanner64.xpr
```

Do **not** hit *Run Implementation* there. That project synthesises `scanner_top` out of context
because it is a block, not a chip: its 197 ports do not fit in the XCK26's 189 pins and the placer
fails with `[Place 30-58] IO placement is infeasible`. The bitstream is built by
`syn/build_kria.tcl`, which wraps it in AXI4-Lite and hangs it off the PS.

### 4. Build the bitstream and put it on the board

```bash
vivado -mode batch -source <repo>/syn/build_kria.tcl -tclargs C:/kv/bit 16
```

That produces the block design (Zynq UltraScale+ MPSoC → AXI4-Lite → `scanner_axi`), synthesises,
implements and writes the bitstream. **No AXI DMA is needed**: `sig_source` generates the stimulus
inside the PL and the powers are read through registers, so validating the design moves no data.

On the board:

```bash
sudo fpgautil -b scanner64.bit.bin -f Full
cd sw && gcc -O2 -o scanner_ctl scanner_ctl.c -lm
sudo ./scanner_ctl info
sudo ./scanner_ctl test          # the test that matters: discrimination in hardware
sudo ./scanner_ctl run 200000000 # and the one that proves nothing is dropped
sudo ./scanner_ctl golden        # exact points on the signal, to check against the model
```

One thing worth looking at in the output of `test`: channels tuned to the **same** frequency
report the same power **down to the last digit**. Those are fully independent DDC chains, sharing
nothing but the input stream. Not "close" — identical. That is what deterministic fixed-point
arithmetic in hardware looks like, and it is why the same design can be checked bit for bit
against a Python model.

---

## The trap that cost a day: `FPD_SLCR.AFI_FS`

Worth its own section, because nothing in the Vivado flow warns you and the symptom looks like a
design bug.

With the bitstream loaded, `ID` read back perfectly and `NCH` read **0** with 16 channels
synthesised. Three other registers with non-zero reset values also read 0. Writes got through —
the scanner started. Six hypotheses were eliminated in order (reset values, AXI handshake, address
bit 3, the RTL, the block design, the wrong bitstream), and all six were wrong.

Only the offsets that were **multiples of 16** read correctly. That is the signature of a 128-bit
master talking to a 32-bit slave: each bus beat carries four words, the slave only drives the
first, and reading `0x04` picks up the second word of that beat, which nobody drives.

```
FPD_SLCR.AFI_FS (0xFD615000) = 0x00000A00
   bits [9:8]   DW_SS0_SEL = 0b10 -> HPM0_FPD at 128 bits
   bits [11:10] DW_SS1_SEL = 0b10 -> HPM1_FPD at 128 bits
```

**The width of the PS's AXI port is not set by the bitstream.** It is set by that register, which
the FSBL writes from the project handoff. Loading with `fpgautil` leaves the PS exactly as the
standard Kria boot left it, which puts both masters at 128 bits. The block design asks for 32.

Writing zero to bits [11:8] fixes all 19 registers at once, with no recompile and no reboot. **And
it is lost on every boot and every PL reload**, so `scanner_ctl` checks and corrects it at the
start of every invocation rather than leaving it to somebody remembering.

What to take from it: **a mechanical rule beats an elegant theory.** The six hypotheses were
reasonable explanations built on eight or nine data points, and all of them were false. What
cracked it was reading the same addresses in three different orders and searching the whole 4 KB
map for the known values — a measurement that admits no interpretation. That is what
`scanner_ctl map` does.

---

## Results

### Where the ceiling is, and what folding buys

The integrators process one sample per clock cycle, so if the clock runs faster than the data, one
set can serve several channels:

```
channels per set = floor(Fclk / Fs)
```

That is the trade neither a CPU nor a GPU can offer: **you exchange bandwidth for channels, and
the choice is yours, not the vendor's**. [`rtl/ddc_fold.v`](rtl/ddc_fold.v) implements it with a
`FOLD` parameter.

Measured by OOC synthesis of `scanner_top` on `xck26-sfvc784-2LV-c`, **two N_CH points per FOLD**
so the design's fixed cost (AXI, generator, glue) comes out by difference instead of being smeared
over however many channels there are:

```
marginal = (cost at 64 channels - cost at 16) / 48
```

| FOLD | Fs | LUT/ch | FF/ch | BRAM/ch | DSP/ch | **ceiling** | what binds |
|---|---|---|---|---|---|---|---|
| 1 | 100 MSPS | 484.5 | 582.3 | 1.167 | 3.125 | **123** | BRAM |
| 2 | 50 MSPS | 727.3 | 698.1 | 0.250 | 1.625 | **161** | LUT |
| 4 | 25 MSPS | 480.6 | 665.9 | 0.146 | 0.875 | **243** | LUT |
| 8 | 12.5 MSPS | 327.4 | 650.8 | 0.073 | 0.500 | **357** | LUT |
| 16 | 6.25 MSPS | 263.5 | 641.8 | 0.031 | 0.313 | **364** | FF |

Ceilings against the ZU5EV: 117,120 LUT, 234,240 FF, 144 BRAM tiles, 1,248 DSP.

**Folding by 16 buys a factor of 3, not 16.** That is the headline, and it is the honest one. The
curve saturates because the binding resource **walks**: BRAM at FOLD=1, LUT in the middle, and
flip-flops at the end — and folding does nothing at all for flip-flops, because every channel
still needs its own CIC state whether or not it shares the arithmetic.

**FOLD=2 is worse than no folding at all** in LUTs (727 against 484). Sharing one set between two
channels costs more multiplexing than it saves in arithmetic. The saving only starts paying from
FOLD=4.

The extreme point was synthesised to check the extrapolation rather than trusting it: **256
channels at FOLD=16** gives 67,280 LUT and 164,295 FF, which the marginal model predicts to within
4 registers.

### The real Fmax: 170 MHz

Post-synthesis numbers do not mean much. The full implementation — `syn/impl_bank.tcl`, with place
and route and `HD.CLK_SRC` set so the skew gets modelled — gives the real figure, and chasing it
was instructive:

| N_CH = 16 | Fmax | Critical path |
|---|---|---|
| Post-synthesis | 220.6 MHz | *(not routed: optimistic)* |
| First implementation | **144.2 MHz** | 32:1 mux in the comb bank · **84 % routing** |
| + `comb_bank` in two stages | **154.1 MHz** | Mixer, with fanout 16 · 66 % routing |
| + `max_fanout` on `x_d1` | **167.9 MHz** | Mixer · 60 % logic |
| + mixer in two stages | **169.9 MHz** | **BRAM + DSP · 76 % pure logic** |

**+18 %, and that is where the RTL runs out.** The final path has not one LUT in it: it is the
NCO BRAM's clock-to-out plus the DSP48's internal chain (pre-adder → multiplier → ALU → output),
with 1.3 ns of routing. That is the silicon floor.

Three lessons, in case they help elsewhere:

1. **A path that is 84 % routing is not fixed by optimising logic.** It is fixed by splitting it
   or taking fanout off it.
2. **Vivado merges identical registers.** All 16 channels registered the same `in_data`, so it
   concluded the `x_d1` were one register and left a single signal with fanout 16 crossing the
   chip. `max_fanout` forces replication and each copy gets placed next to its own DSP:
   **+14 MHz from a one-line attribute.**
3. **When the logic percentage goes up, you are going the right way.** Going from 16 % to 76 %
   logic means routing is no longer in charge and what is left is structural.

> **The speed grade is part of the ceiling.** The KV260 carries an **XCK26-SFVC784-2LV-C**, and
> that `2LV` is *low voltage*: the chip runs at 0.72 V instead of 0.85 V to use less power. A plain
> `-2` would give 15–20 % more with this same RTL. Part of the 170 MHz is the silicon, not the
> design — and for a battery-powered platform that is the right trade.

At 170 MHz, 100 MSPS fits comfortably. 200 MSPS does not.

### Power

Measured with the KV260's own INA260 (`hwmon`, microwatt resolution), alternating stopped/running
twelve times per point so the board's thermal drift cancels instead of landing entirely on the
delta, and reporting the standard error alongside the mean:

| N_CH | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|
| dynamic (mW) | 32.8 | 66.8 | 130.7 | 260.5 | 535.4 |
| ± (mW) | 1.4 | 1.9 | 2.5 | 2.6 | 2.5 |

Linear fit: **8.38 mW per channel**, intercept −0.7 mW, errors at 0.5 %.

> **The first INA260 measurement was wrong by 3.5×**, and the reason is worth recording: the script
> started the scanner **without tuning the channels**, so every NCO sat at DC and the design barely
> switched at all. It reported 154 mW at 64 channels against the real 535 mW. A power measurement
> of a DSP block that is not processing anything is a measurement of nothing.

### Transport: no DMA needed

An expensive decision hung on this: to have the FPGA generate and the ARM consume, the samples
have to move from PL to PS. If AXI-Lite has headroom, a FIFO and a few registers will do; if not,
it needs DMA through an HP port, which means a new block design and buffer management.

Measured with `scanner_ctl rate`, which times 32-bit reads against device memory — where every
read is a full round trip across the interconnect, with no cache to absorb it and no pipeline to
overlap it:

- **191 ns per read**, ~5.2 M reads/s
- packing two 16-bit samples per word: a transport ceiling of **~10.5 MSPS**

Against what the four A53 can consume (157.7 M channel-samples/s shared out), that is enough from
16 channels upwards — at 16 channels each needs 9.86 MSPS — and not enough below that. **For the
configuration that matters, a FIFO suffices and no DMA is needed.**

---

## Things that were measured and rejected

This section exists because the negative results took as long as the positive ones and are more
useful to the next person. Each of these looked obviously right and was wrong.

| Idea | Expected | **Measured** | Verdict |
|---|---|---|---|
| Share the NCO LUT between channels | move the BRAM ceiling | +214 LUT/ch, ceiling 144 → 127 | ❌ worse |
| CIC accumulators into the DSPs | free LUTs | −284 LUT/ch but +6 DSP, ceiling 144 → 113 | ⚖️ a trade, kept as an option |
| FOLD=2 | half the area per channel | 727 LUT/ch against 484 with no folding | ❌ worse |
| Guard the `ftw` array with a generate | −32 FF/ch | **0** — Vivado already removed it | ❌ nothing |
| CIC state into distributed RAM | −216 FF/ch | LUT 2,593 → 12,289, FF unchanged | ❌ much worse |
| Narrow the power window counter | −50 FF/ch | −19 FF/ch, **and it closed a silent overflow** | ✅ |
| Share the power meter per bank | — | 2·N_CH DSP → 2·N_BANK. 32 → 2 at 16 channels | ✅ |

Four of those are documented **inside the RTL that they touch**, with their numbers, so the next
person who looks at those 216 bits of accumulator finds out that it has been tried, what happened,
and what it would take to make it work.

The two that paid off are worth a sentence each:

- **The shared power meter** was free because the architecture had already settled it: since
  `comb_bank`, the channels do not come out on the same cycle, so one set of multipliers can serve
  a whole bank. 128 DSPs down to 8 at 64 channels.
- **The narrow window counter** was aimed at flip-flops and hit a bug instead. The accumulator is
  48 bits and each `mag2` can reach 2³⁵, so it holds exactly 2¹³ = 8192 samples and not one more.
  With the 32-bit counter that was there, asking for a 100,000-sample window was perfectly
  possible: the accumulator overflowed silently and the power you read back was garbage that looked
  like data. The narrow counter makes that **impossible to ask for**.

Two lessons about the tools, which is really what all of these are about:

**Memory inference is fragile in a way you cannot see in the RTL.** `comb_bank` infers distributed
RAM without trouble because it reads one position per cycle. `ddc_fold` will not infer it under any
circumstances because the CIC cascade reads three. The two pieces of code look extremely alike; the
results in silicon have nothing to do with each other.

**A parallel reset condemns an array to flip-flops** — RAMs have no reset input — but the converse
does not hold: a reset will *not* keep a dead array alive, because dead-code analysis works
backwards from the outputs and a reset is not an output.

---

## Design parameters

| Parameter | Value | Note |
|---|---|---|
| `IN_W` | 16 b | Input sample |
| `OUT_W` | 18 b | I/Q output, 2 bits of headroom over the input |
| `PHASE_W` | 32 b | Tuning resolution: 0.023 Hz at 100 MSPS |
| `LUT_ADDR_W` | 10 b | 1024 entries; phase truncation noise ≈ −60 dBc |
| `CIC_N` | 3 | Stages |
| `CIC_R` | 64 | Decimation → 1.5625 MSPS per channel at 100 MSPS |
| `CIC_W` | 36 b | = `MIX_W` + N·log₂(R·M) = 18 + 18 |
| `FOLD` | 1 | Channels per set of NCO, mixer and integrators |
| `UNITS_PER_BANK` | 32 | I/Q chains per comb bank; must satisfy `UNITS_PER_BANK + 1 < CIC_R` |

Bandwidth per channel ≈ 780 kHz. Enough for narrowband FM, PMR446, AM and SSB.

### Two CIC traps, both documented in the code

1. **The integrators' overflow is intentional.** They overflow and the combs undo it exactly, as
   long as `ACC_W ≥ IN_W + N·log₂(R·M)`. Putting saturation there **breaks the filter**. It is the
   classic mistake when porting a CIC.
2. **The cascades are registered, not combinational.** The textbook version chains the stages
   within one cycle, which creates a 3×36-bit carry chain that will not close timing. Same transfer
   function, only the latency changes. The model emulates the registered version precisely so it is
   cycle-for-cycle identical to the hardware.

---

## Known limitations

- **No CIC droop compensation.** A 3-stage CIC attenuates towards the band edge (~3 dB in the top
  20 %). For measuring power it does not matter; for demodulating you need a compensating FIR. It
  is not there.
- **The comb state survives a warm reset.** `comb_bank` initialises its state through `initial`,
  that is, from the bitstream, because resetting the array would force Vivado to put 7001
  flip-flops there. After an `rst_n` the filter drags its previous state along for a few rounds. If
  that matters, flush the bank with N rounds of zeros before trusting the output. This is why
  `scanner_ctl golden` uses the TAP registers and not the first power window.
- **`pwr_done` never returns to 0** except through reset or `cfg_clear`, so `pwr_ready` means
  *"there has been at least one measurement"*, not *"there is a new one"*. For a scanner that polls
  periodically you probably want the latter. A design decision, not a bug.
- **The `sig_source` noise is an LFSR**, not Gaussian. Good for noise floor and dynamic range, not
  for measuring noise figure.
- **Folding requires `Fs ≤ Fclk/FOLD`.** Feed it faster and it drops samples. That would be
  invisible — a decimated output with missing samples still looks like a signal — so the hardware
  reports it: `fold_overrun` sticks high the first time it happens, and it is readable in the
  `STATUS` register.

---

## Reuse

The block does not depend on any particular hardware. The input is a stream of samples with a
`valid`, wherever it comes from:

- From `sig_source.v`, inside the PL itself, with nothing external.
- From a USB SDR (a HackRF, say), pushing samples into the PL.
- From an ADC on the KV260's IAS1 interface.

It started life as the digital front end of an SDR receiver, but a DDC bank is equally good for
vibrometry, sonar, instrumentation, or any problem where you have to watch N narrow bands inside a
wide one without losing samples.

---

## Licence

Apache License 2.0 — see [LICENSE](LICENSE).

The algorithms are public domain: the CIC is Hogenauer's (1981) and the NCO/DDS is older. What the
licence covers is this implementation, its reference model and its documentation.

### How to cite

```bibtex
@software{soage_scanner64,
  author  = {Soage Rodas, Pablo},
  title   = {scanner64: a real-time multichannel DDC bank for the Kria KV260},
  year    = {2026},
  url     = {https://github.com/PabloSoage/scanner64}
}
```
