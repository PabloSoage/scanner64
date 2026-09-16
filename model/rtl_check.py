#!/usr/bin/env python3
"""
Checks the RTL without a Verilog simulator.

This was written when the machine had no simulator at all, so the RTL could not
be run. It is the most honest substitute: a Python transcription of the
SEMANTICS of the Verilog exactly as written -- with non-blocking assignments,
that is, every read uses the register value from BEFORE the edge -- compared
against the golden vectors in tb/vectors/.

There is a simulator now (the testbenches in tb/ run under XSim and pass), but
this check is still worth keeping, because the direction of the transcription
is what makes it independent:
  ddc_model.py  was written first, and the RTL came out of it.
  rtl_check.py  is written by READING the RTL, and compared against the
                vectors.

If the two agree, the chance of a transcription error drops a lot.
What this does NOT check: synthesis, timing closure, resource usage, and
anything that depends on how the tools actually behave. For that, run
tb/tb_ddc_channel.v under Vivado or iverilog.

Usage:
    py rtl_check.py
"""

import os

from ddc_model import (
    IN_W, OUT_W, PHASE_W, LUT_ADDR_W, LUT_W, MIX_W,
    CIC_N, CIC_R, CIC_W, CIC_GROWTH,
    SIN_LUT, wrap, saturate,
)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VEC = os.path.join(ROOT, "tb", "vectors")


def read_hex(path, bits):
    """Reads a $readmemh-style file and returns signed integers."""
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.split("//")[0].strip()
            if line:
                out.append(wrap(int(line, 16), bits))
    return out


# ---------------------------------------------------------------------------
# Transcription of rtl/nco.v
# ---------------------------------------------------------------------------

class RtlNco:
    """nco.v - phase accumulator + dual-port LUT.

    Note: in the RTL cos_o/sin_o are REGISTERS, so they come out one cycle
    after the phase that generated them.
    """

    QUARTER = 1 << (LUT_ADDR_W - 2)
    PMASK = (1 << PHASE_W) - 1
    AMASK = (1 << LUT_ADDR_W) - 1

    def __init__(self, ftw):
        self.ftw = ftw & self.PMASK
        self.phase = 0
        self.cos_o = 0
        self.sin_o = 0

    def tick(self, en=True):
        if not en:
            return
        addr_cos = self.phase >> (PHASE_W - LUT_ADDR_W)
        addr_sin = (addr_cos - self.QUARTER) & self.AMASK
        # Non-blocking: computed with the previous value of phase.
        self.cos_o = SIN_LUT[addr_cos]
        self.sin_o = SIN_LUT[addr_sin]
        self.phase = (self.phase + self.ftw) & self.PMASK


# ---------------------------------------------------------------------------
# Transcription of rtl/cic_decim.v
# ---------------------------------------------------------------------------

class RtlCic:
    """cic_decim.v - registered cascades, wraparound overflow."""

    def __init__(self):
        self.integ = [0] * CIC_N
        self.cnt = 0
        self.comb_prev = [0] * CIC_N
        self.comb_val = [0] * CIC_N
        self.out_valid = False
        self.out_data = 0

    def tick(self, in_valid, in_data):
        # ---- combinational ----
        integ_last_next = wrap(self.integ[CIC_N-1] + self.integ[CIC_N-2], CIC_W)
        decim_now = in_valid and (self.cnt == CIC_R - 1)

        # ---- sequential: everything computed from the PREVIOUS values ----
        new_integ = list(self.integ)
        new_cnt = self.cnt
        if in_valid:
            new_integ[0] = wrap(self.integ[0] + in_data, CIC_W)
            for i in range(1, CIC_N):
                new_integ[i] = wrap(self.integ[i] + self.integ[i-1], CIC_W)
            new_cnt = 0 if decim_now else self.cnt + 1

        new_prev = list(self.comb_prev)
        new_val = list(self.comb_val)
        new_out_valid = False
        new_out_data = self.out_data

        if decim_now:
            new_val[0] = wrap(integ_last_next - self.comb_prev[0], CIC_W)
            new_prev[0] = integ_last_next
            for j in range(1, CIC_N):
                new_val[j] = wrap(self.comb_val[j-1] - self.comb_prev[j], CIC_W)
                new_prev[j] = self.comb_val[j-1]
            new_out_data = wrap(self.comb_val[CIC_N-2] - self.comb_prev[CIC_N-1], CIC_W)
            new_out_valid = True

        self.integ, self.cnt = new_integ, new_cnt
        self.comb_prev, self.comb_val = new_prev, new_val
        self.out_valid, self.out_data = new_out_valid, new_out_data


# ---------------------------------------------------------------------------
# Transcription of rtl/ddc_channel.v
# ---------------------------------------------------------------------------

class RtlDdcChannel:
    """Chains nco + registered mixer + two CICs, the way the RTL does."""

    def __init__(self, ftw):
        self.nco = RtlNco(ftw)
        self.cic_i = RtlCic()
        self.cic_q = RtlCic()
        self.mix_i = 0
        self.mix_q = 0
        self.mix_valid = False
        self.x_d1 = 0          # delay to line up with the NCO register
        self.v_d1 = False

    def tick(self, in_valid, x):
        # Stage 1: NCO (registered) and the sample delay that lines it up.
        cos_v, sin_v = self.nco.cos_o, self.nco.sin_o
        xd, vd = self.x_d1, self.v_d1

        # Stage 2: mixer (registered)
        new_mix_i = saturate((xd * cos_v) >> (LUT_W - 1), MIX_W)
        new_mix_q = saturate((-xd * sin_v) >> (LUT_W - 1), MIX_W)
        new_mix_valid = vd

        # Stage 3: CIC, with what the mixer put out on the previous cycle
        self.cic_i.tick(self.mix_valid, self.mix_i)
        self.cic_q.tick(self.mix_valid, self.mix_q)

        # Advance the registers
        self.nco.tick(in_valid)
        self.x_d1, self.v_d1 = x, in_valid
        self.mix_i, self.mix_q, self.mix_valid = new_mix_i, new_mix_q, new_mix_valid

        if self.cic_i.out_valid:
            return (wrap(self.cic_i.out_data >> CIC_GROWTH, OUT_W),
                    wrap(self.cic_q.out_data >> CIC_GROWTH, OUT_W))
        return None


# ---------------------------------------------------------------------------
# Check against the golden vectors
# ---------------------------------------------------------------------------

def main():
    for f in ("stim.hex", "gold_i.hex", "gold_q.hex", "params.vh"):
        if not os.path.exists(os.path.join(VEC, f)):
            print(f"Vectors missing. Run this first:  py gen_vectors.py")
            return 1

    stim = read_hex(os.path.join(VEC, "stim.hex"), IN_W)
    gold_i = read_hex(os.path.join(VEC, "gold_i.hex"), OUT_W)
    gold_q = read_hex(os.path.join(VEC, "gold_q.hex"), OUT_W)

    # The tuning word is read from params.vh so it is not duplicated.
    ftw = None
    with open(os.path.join(VEC, "params.vh")) as fh:
        for line in fh:
            if "P_FTW" in line and "'h" in line:
                ftw = int(line.split("'h")[1].split(";")[0].strip(), 16)
    if ftw is None:
        print("Could not read P_FTW from params.vh")
        return 1

    print("Checking the RTL semantics against the golden vectors")
    print(f"  stimulus : {len(stim)} samples")
    print(f"  expected : {len(gold_i)} I/Q outputs")
    print(f"  FTW      : 0x{ftw:08x}")
    print()

    ch = RtlDdcChannel(ftw)
    got = []
    for x in stim:
        y = ch.tick(True, x)
        if y is not None:
            got.append(y)

    # The RTL has pipeline latency (NCO + mixer), so it produces fewer outputs,
    # or shifted ones. We look for the shift that lines them up.
    best_shift, best_bad = None, None
    for shift in range(0, 6):
        n = min(len(gold_i), len(got) - shift)
        if n <= 8:
            continue
        bad = sum(1 for k in range(8, n)
                  if got[k + shift] != (gold_i[k], gold_q[k]))
        if best_bad is None or bad < best_bad:
            best_bad, best_shift = bad, shift

    n = min(len(gold_i), len(got) - best_shift)
    compared = n - 8
    print(f"  RTL outputs      : {len(got)}")
    print(f"  pipeline shift   : {best_shift} samples")
    print(f"  compared         : {compared}")
    print(f"  mismatches       : {best_bad}")
    print()

    if best_bad == 0:
        print("RESULT: OK - the RTL semantics agree with the verified model.")
        print()
        print("NOTE: this is NOT a substitute for a simulation. It does not check")
        print("synthesis, timing closure or resource usage. Run tb/tb_ddc_channel.v")
        print("under Vivado (or iverilog) before trusting the design.")
        return 0

    print("RESULT: FAIL - the RTL does not agree with the model.")
    for k in range(8, min(n, 20)):
        g, r = (gold_i[k], gold_q[k]), got[k + best_shift]
        mark = "  " if g == r else "<-"
        print(f"  [{k:3d}] expected I={g[0]:8d} Q={g[1]:8d}   "
              f"rtl I={r[0]:8d} Q={r[1]:8d} {mark}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
