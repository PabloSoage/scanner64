#!/usr/bin/env python3
"""Checks the samples the Kria measured against the model, BIT FOR BIT.

`scanner_ctl golden` returns, per channel, a triple (index, I, Q): the
channel's last output and which one it is. That pins down an exact point on the
signal without depending on where any power window starts -- which is what made
the first attempt useless, because the comb state is not cleared by a warm
reset (see rtl/comb_bank.v).

For the model to predict that point, two things about the hardware that are not
obvious have to be reproduced:

  1. `run` low leaves the integrators at zero and the NCOs at phase zero, and
     each channel's NCO only advances with `in_valid`. That is why the sequence
     is reproducible cycle for cycle from the very first sample.

  2. `sig_source` has one cycle of latency: its output register emits ONE ZERO
     before the first good sample. That zero enters the CIC and advances the
     channel's NCO. It makes no difference to channels with a tone -- their
     output is 4096 and the zero is lost in the average -- but for empty
     channels it changes the result by 1 LSB on a value of 2, which is exactly
     where it shows. Measured with tb/tb_sig_source.v: rtl[n] = model[n-1].

The dirty comb state clears in three rounds, so measuring towards output ~3000,
whatever is inside the filter was put there by the samples of this same run,
the same ones the model sees.

    python3 golden_hw.py N0 I0 Q0 N1 I1 Q1 N2 I2 Q2 N3 I3 Q3
"""

import sys
import ddc_model as m

FS    = 100e6
FREQS = [10.0e6, 15.0e6, 22.2e6, 3.3e6]


class SigSource:
    """sig_source.v, with its cycle of latency included."""

    def __init__(self, f_a, f_b, sh_a=2, sh_b=2):
        self.a = m.NCO(m.tuning_word(f_a, FS))
        self.b = m.NCO(m.tuning_word(f_b, FS))
        self.sh_a, self.sh_b = sh_a, sh_b
        self.first = True

    def step(self):
        if self.first:              # the zero from the output register
            self.first = False
            return 0
        _, sa = self.a.step()
        _, sb = self.b.step()
        return m.saturate((sa >> self.sh_a) + (sb >> self.sh_b), m.IN_W)


def output_n(f_hz, n):
    """Output number n (1-based, the way out_cnt counts) of that channel."""
    src = SigSource(FREQS[0], FREQS[1])
    ch = m.DDCChannel(f_hz, FS)
    seen = 0
    while True:
        r = ch.push(src.step())
        if r is not None:
            seen += 1
            if seen == n:
                return r


def main():
    a = [int(x) for x in sys.argv[1:13]]
    if len(a) != 12:
        print(__doc__)
        return 2
    hw = [(a[i * 3], a[i * 3 + 1], a[i * 3 + 2]) for i in range(4)]

    print()
    print("  channel  tuning       output no.   model (I,Q)       Kria (I,Q)")
    exact = 0
    for k, (n, i_hw, q_hw) in enumerate(hw):
        i_md, q_md = output_n(FREQS[k], n)
        good = (i_md == i_hw and q_md == q_hw)
        exact += good
        print("   %3d   %6.1f MHz   %8d   %14s   %14s   %s"
              % (k, FREQS[k] / 1e6, n, "(%d, %d)" % (i_md, q_md),
                 "(%d, %d)" % (i_hw, q_hw), "EXACT" if good else "<-- MISMATCH"))

    print()
    if exact == 4:
        print("  BIT FOR BIT: the silicon computes exactly what the model says,")
        print("  sample by sample, after ~3000 outputs of shared history.")
        print("  And in the empty channels too, where the output is 1 or 2 LSB:")
        print("  there is no room there to hide a rounding error.")
        return 0
    print("  %d of 4 channels exact." % exact)
    return 1


if __name__ == "__main__":
    sys.exit(main())
