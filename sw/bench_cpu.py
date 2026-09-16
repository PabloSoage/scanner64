#!/usr/bin/env python3
"""
Measures how much THIS CPU can take of the same DSP the PL does.

The point is not to "prove" the FPGA wins. It is to MEASURE where your machine
hits its limit and compare that with what the PL sustains by construction, so
the comparison is a number of your own and not a marketing claim.

Run it in three places and compare:
    1. Your desktop PC
    2. The KV260's own Cortex-A53   <-- the comparison that matters
    3. (the PL is not measured here: it sustains the input rate by design)

Usage:
    py bench_cpu.py                 # 16 channels, 200k samples
    py bench_cpu.py 64 500000       # 64 channels, 500k samples

Honest warning about Python: it is between 30 and 100 times slower than
well-written C with SIMD. The number this script produces is NOT your CPU's
limit: it is your CPU's limit IN PYTHON. For a fair comparison it has to be
written in C with NEON or AVX (that is sw/bench_ddc.c). The qualitative
conclusion (the PL sustains the input rate and the CPU does not) holds, but the
exact factor is not this one. An estimate of the C equivalent is printed at the
end.
"""

import math
import sys
import time

sys.path.insert(0, __file__.rsplit("sw", 1)[0] + "model")

from ddc_model import (                                    # noqa: E402
    DDCChannel, tuning_word, IN_W, CIC_R,
)

FS = 100_000_000.0          # the sample rate the ADC would have


def build_channels(n_ch, fs):
    """n_ch channels spread across the band, like a real scanner."""
    return [DDCChannel(fs * (0.05 + 0.40 * k / max(1, n_ch - 1)), fs)
            for k in range(n_ch)]


def make_input(n):
    """Test signal: two tones, quantised to IN_W bits."""
    peak = (1 << (IN_W - 1)) - 1
    out = []
    for k in range(n):
        v = (0.35 * peak * math.sin(2 * math.pi * 0.10 * k)
             + 0.35 * peak * math.sin(2 * math.pi * 0.23 * k))
        out.append(int(v))
    return out


def main():
    n_ch = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    n_samp = int(sys.argv[2]) if len(sys.argv) > 2 else 200_000

    print(f"CPU benchmark - {n_ch} DDC channels, {n_samp:,} samples")
    print(f"Target: sustain {FS/1e6:.0f} MSPS of input without dropping samples")
    print()

    chans = build_channels(n_ch, FS)
    data = make_input(n_samp)

    t0 = time.perf_counter()
    for x in data:
        for ch in chans:
            ch.push(x)
    dt = time.perf_counter() - t0

    sps = n_samp / dt                       # input samples per second
    ch_sps = sps * n_ch                     # channel-samples per second

    # Operations per sample and channel (conservative count):
    #   NCO 2, mixer 2 mult + 2 shifts, CIC 3 integrators x2 (I,Q) = 6 adds,
    #   combs 3 x2 at 1/R of the rate. Rounded to 18.
    OPS = 18
    gops = ch_sps * OPS / 1e9

    print(f"  time               : {dt:8.2f} s")
    print(f"  input rate         : {sps/1e3:8.1f} kSPS")
    print(f"  channel-samples/s  : {ch_sps/1e6:8.2f} M")
    print(f"  ~operations/s      : {gops:8.3f} Gop/s   (pure Python)")
    print()

    factor = FS / sps
    print(f"  Needed for real time: {FS/1e6:.0f} MSPS")
    print(f"  Achieved            : {sps/1e6:.4f} MSPS")
    print(f"  SHORTFALL           : x{factor:,.0f}")
    print()

    # Estimate of the C equivalent. Interpreted Python is typically between 30x
    # and 100x below C with SIMD for integer loops.
    for speedup, label in ((30, "conservative C"), (100, "C with SIMD")):
        c_sps = sps * speedup
        print(f"  Estimate {label:17}: {c_sps/1e6:8.2f} MSPS  "
              f"-> {'MAKES IT' if c_sps >= FS else f'shortfall x{FS/c_sps:,.0f}'}")

    print()
    print("What the PL does, by construction:")
    print(f"  It processes {n_ch} channels at clock rate, one sample per cycle.")
    print(f"  At 100 MHz that is {100*n_ch/1e3:.1f} G channel-samples/s "
          f"= {100e6*n_ch*OPS/1e9:.0f} Gop/s.")
    print("  Without dropping samples and with fixed latency. It is not that it")
    print("  is faster: it is that the rate DOES NOT DEPEND on how many channels")
    print("  you add, as long as the multipliers fit. Adding a channel costs")
    print("  4 DSP48s, not time.")
    print()
    print("That is the real argument for an FPGA: not raw GOPS - a desktop PC")
    print("with AVX-512 has more - but DETERMINISTIC throughput, bounded")
    print("latency, and scaling by area instead of by time.")


if __name__ == "__main__":
    main()
