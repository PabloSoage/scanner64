#!/usr/bin/env python3
"""
Bit-exact model of a DDC (Digital Down-Converter) channel.

This file is THE REFERENCE for the design. The RTL in rtl/ is a direct
transcription of what is here, and the testbenches in tb/ use the vectors
gen_vectors.py produces from this model.

Per-channel chain:

    x[n] (real, 16 b)
       |
       +--> complex mixer  <-- NCO (32-bit phase accumulator + LUT)
       |
       +--> CIC decimator (N=3 stages, R=64, M=1), I and Q separately
       |
       +--> normalisation (>> 18) and I/Q output

Everything in Python integers emulating fixed-width two's complement
arithmetic, so the result is IDENTICAL to the hardware's.

Usage:
    py ddc_model.py          # runs the self-test
"""

import math

# ---------------------------------------------------------------------------
# Design parameters. They must match the RTL `localparam`s.
# ---------------------------------------------------------------------------

IN_W       = 16      # input sample width
PHASE_W    = 32      # width of the NCO phase accumulator
LUT_ADDR_W = 10      # phase bits that address the LUT -> 1024 entries
LUT_W      = 16      # width of the sine/cosine samples
MIX_W      = 18      # width at the mixer output
CIC_N      = 3       # CIC stages
CIC_R      = 64      # decimation factor
CIC_M      = 1       # comb differential delay

# CIC bit growth: N * log2(R*M) = 3 * 6 = 18 bits.
CIC_GROWTH = CIC_N * int(math.log2(CIC_R * CIC_M))
CIC_W      = MIX_W + CIC_GROWTH          # 36-bit internal accumulator
OUT_W      = 18                          # output width after normalisation


# ---------------------------------------------------------------------------
# Fixed-width arithmetic helpers
# ---------------------------------------------------------------------------

def wrap(value, bits):
    """Truncate to `bits` in two's complement, with wraparound overflow.

    The CIC depends on this behaviour: the integrators overflow naturally and
    the combs undo it, as long as the width is sufficient. Emulating this
    wrongly is the classic mistake when porting a CIC to fixed point.
    """
    mask = (1 << bits) - 1
    value &= mask
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def saturate(value, bits):
    """Saturate to `bits` in two's complement (for the mixer, which must not
    wrap: a wraparound there produces clicks in the signal)."""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return lo if value < lo else hi if value > hi else value


# ---------------------------------------------------------------------------
# NCO
# ---------------------------------------------------------------------------

def build_sin_lut():
    """Cosine LUT of 2^LUT_ADDR_W entries, with LUT_W signed bits.

    In the RTL this is a BRAM initialised from the .mem file gen_vectors.py
    writes, so the values are exactly these.
    """
    n = 1 << LUT_ADDR_W
    peak = (1 << (LUT_W - 1)) - 1          # 32767
    return [int(round(peak * math.cos(2.0 * math.pi * i / n))) for i in range(n)]


SIN_LUT = build_sin_lut()


def tuning_word(f_hz, fs_hz):
    """NCO tuning word for a given frequency."""
    return int(round((f_hz / fs_hz) * (1 << PHASE_W))) & ((1 << PHASE_W) - 1)


class NCO:
    """Phase accumulator + LUT. Returns (cos, sin) of LUT_W bits."""

    def __init__(self, ftw, phase0=0):
        self.ftw = ftw & ((1 << PHASE_W) - 1)
        self.phase = phase0 & ((1 << PHASE_W) - 1)

    def step(self):
        # The top LUT_ADDR_W bits of the phase address the LUT.
        addr = self.phase >> (PHASE_W - LUT_ADDR_W)
        cos_v = SIN_LUT[addr]
        # sin(x) = cos(x - pi/2)  ->  shift by a quarter table.
        sin_v = SIN_LUT[(addr - (1 << (LUT_ADDR_W - 2))) & ((1 << LUT_ADDR_W) - 1)]
        self.phase = (self.phase + self.ftw) & ((1 << PHASE_W) - 1)
        return cos_v, sin_v


# ---------------------------------------------------------------------------
# CIC decimator
# ---------------------------------------------------------------------------

class CICDecimator:
    """CIC with N stages, decimation R, differential delay M.

    Integrators at the high rate, combs at the low rate. The DC gain is
    (R*M)^N, which here is exactly 2^18, so normalising is a plain arithmetic
    right shift.

    REGISTERED (pipelined) STRUCTURE, not combinational.
    ---------------------------------------------------
    Each stage uses the PREVIOUS value of the one before it, not the one just
    computed. That is, there is a register between stages.

    The textbook version chains the stages combinationally within the same
    cycle. Mathematically it comes to the same thing (same transfer function,
    only the latency changes), but in hardware it creates a carry chain of
    N * ACC_W bits that will not close timing at high frequencies: three
    36-bit adders in series in a single cycle.

    The model emulates the registered structure so that it is CYCLE FOR CYCLE
    the same as the RTL. If the model used the combinational version, the test
    vectors would not match the hardware and there would be no way to know
    whether the fault was in the RTL or in the model.
    """

    def __init__(self):
        self.integ = [0] * CIC_N
        self.comb_prev = [0] * CIC_N
        self.comb_val = [0] * CIC_N
        self.count = 0
        self.snapshot = 0

    def push(self, x):
        """Feed in one sample. Returns the decimated output or None."""
        # --- Integrators: REGISTERED cascade --------------------------------
        nxt = [0] * CIC_N
        nxt[0] = wrap(self.integ[0] + x, CIC_W)
        for i in range(1, CIC_N):
            nxt[i] = wrap(self.integ[i] + self.integ[i - 1], CIC_W)
        self.integ = nxt

        # --- Decimation -----------------------------------------------------
        self.count += 1
        if self.count < CIC_R:
            return None
        self.count = 0

        # --- Combs: REGISTERED cascade, at the output rate -------------------
        # With M=1 the comb delay is one decimated sample.
        src = self.integ[CIC_N - 1]
        nv = [0] * CIC_N
        nv[0] = wrap(src - self.comb_prev[0], CIC_W)
        for j in range(1, CIC_N):
            nv[j] = wrap(self.comb_val[j - 1] - self.comb_prev[j], CIC_W)

        self.comb_prev[0] = src
        for j in range(1, CIC_N):
            self.comb_prev[j] = self.comb_val[j - 1]
        self.comb_val = nv

        return self.comb_val[CIC_N - 1]


# ---------------------------------------------------------------------------
# Complete DDC channel
# ---------------------------------------------------------------------------

class DDCChannel:
    """One channel: NCO + complex mixer + two CICs + normalisation."""

    def __init__(self, f_hz, fs_hz, phase0=0):
        self.nco = NCO(tuning_word(f_hz, fs_hz), phase0)
        self.cic_i = CICDecimator()
        self.cic_q = CICDecimator()

    def push(self, x):
        """Feed in one real sample of IN_W bits.

        Returns (I, Q) of OUT_W bits when there is an output, or None.
        """
        cos_v, sin_v = self.nco.step()

        # Mixer: x[n] * e^(-j*w*n).  The shift by LUT_W-1 undoes the LUT
        # scaling (32767 ~ 1.0).
        mix_i = saturate((x * cos_v) >> (LUT_W - 1), MIX_W)
        mix_q = saturate((-x * sin_v) >> (LUT_W - 1), MIX_W)

        yi = self.cic_i.push(mix_i)
        yq = self.cic_q.push(mix_q)
        if yi is None:
            return None

        # Normalisation: the CIC gain is exactly 2^CIC_GROWTH.
        return (wrap(yi >> CIC_GROWTH, OUT_W), wrap(yq >> CIC_GROWTH, OUT_W))


def power_db(i, q):
    """Channel power in dBFS, referred to the INPUT full scale.

    It is referred to the input and not to the output because that is what
    matters in a scanner: "how much signal is there relative to what saturates
    the ADC". The output has OUT_W bits and the input IN_W, so there are
    OUT_W-IN_W bits of headroom: a signal at input full scale does NOT saturate
    the output.
    """
    mag2 = i * i + q * q
    if mag2 == 0:
        return -999.0
    full = float((1 << (IN_W - 1)) - 1) ** 2
    return 10.0 * math.log10(mag2 / full)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _tone(n, f_hz, fs_hz, amp=0.5, phase=0.0):
    """Generate n real samples of a tone, quantised to IN_W bits."""
    peak = (1 << (IN_W - 1)) - 1
    return [int(round(amp * peak * math.sin(2 * math.pi * f_hz * k / fs_hz + phase)))
            for k in range(n)]


def _selftest():
    fs = 100_000_000.0          # 100 MSPS
    n_out = 40                  # output samples to evaluate
    n_in = (n_out + 8) * CIC_R  # + margin for the transient
    ok = True

    print(f"DDC model  .  fs={fs/1e6:.0f} MSPS  .  CIC N={CIC_N} R={CIC_R} "
          f"(gain 2^{CIC_GROWTH}, accumulator {CIC_W} b)")
    print()

    # --- Test 1: tone IN the tuned channel -> should appear as DC
    f_ch = 10_000_000.0
    ch = DDCChannel(f_ch, fs)
    outs = [y for y in (ch.push(x) for x in _tone(n_in, f_ch, fs, amp=0.5)) if y]
    steady = outs[8:]           # discard the CIC transient
    p_in = sum(power_db(i, q) for i, q in steady) / len(steady)
    print(f"  [1] In-band tone      f={f_ch/1e6:>6.2f} MHz   power = {p_in:7.2f} dBFS")

    # A real tone of amplitude A, mixed down to baseband, leaves A/2 in the DC
    # term:  sin(w n) * (-sin(w n)) = -1/2 + 1/2 cos(2 w n).
    # With A = 0.5 of full scale, that is 0.25 -> -12.04 dBFS.
    expected = 20 * math.log10(0.5 / 2)
    if abs(p_in - expected) > 1.5:
        print(f"      FAIL: expected ~{expected:.2f} dBFS")
        ok = False

    # --- Test 2: tone OUT of the channel -> should be heavily attenuated
    f_off = 10_000_000.0 + 5_000_000.0      # 5 MHz off; the CIC cuts at ~780 kHz
    ch = DDCChannel(f_ch, fs)
    outs = [y for y in (ch.push(x) for x in _tone(n_in, f_off, fs, amp=0.5)) if y]
    p_out = sum(power_db(i, q) for i, q in outs[8:]) / len(outs[8:])
    rejection = p_in - p_out
    print(f"  [2] Out-of-band tone  f={f_off/1e6:>6.2f} MHz   power = {p_out:7.2f} dBFS"
          f"   (rejection {rejection:.1f} dB)")
    if rejection < 40:
        print(f"      FAIL: insufficient rejection, expected >40 dB")
        ok = False

    # --- Test 3: selectivity, two simultaneous channels on the same input
    f_a, f_b = 10_000_000.0, 12_000_000.0
    sig = [a + b for a, b in zip(_tone(n_in, f_a, fs, 0.4),
                                 _tone(n_in, f_b, fs, 0.4))]
    ch_a, ch_b = DDCChannel(f_a, fs), DDCChannel(f_b, fs)
    oa = [y for y in (ch_a.push(x) for x in sig) if y][8:]
    ob = [y for y in (ch_b.push(x) for x in sig) if y][8:]
    pa = sum(power_db(i, q) for i, q in oa) / len(oa)
    pb = sum(power_db(i, q) for i, q in ob) / len(ob)
    print(f"  [3] Two tones at once, two channels:  "
          f"A({f_a/1e6:.0f} MHz)={pa:.2f} dBFS   B({f_b/1e6:.0f} MHz)={pb:.2f} dBFS")
    if abs(pa - pb) > 1.0:
        print("      FAIL: both channels should measure the same")
        ok = False

    # --- Test 4: no signal -> absolute silence (checks there is no spurious
    #     overflow in the integrators)
    ch = DDCChannel(f_ch, fs)
    outs = [y for y in (ch.push(0) for _ in range(n_in)) if y]
    if any(i or q for i, q in outs):
        print("      FAIL: with a null input the output is not null")
        ok = False
    else:
        print("  [4] Null input -> null output (integrators stable)")

    print()
    print("RESULT:", "OK - the model is correct" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(_selftest())
