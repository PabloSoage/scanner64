#!/usr/bin/env python3
"""Predice la medida determinista de `scanner_ctl golden` y la compara.

`golden` mide LA PRIMERA ventana de 4096 salidas desde el reset: los NCO a fase
cero, los CIC a cero. Eso es reproducible ciclo a ciclo, asi que el modelo tiene
que dar el mismo numero y no solo uno parecido.

El unico grado de libertad es el retardo del pipeline de `sig_source`: el NCO
del canal avanza con `in_valid`, asi que va unos ciclos por detras del tono que
genera la PL. Se barre, y el retardo correcto se reconoce solo porque hace
caer el error de todos los canales a la vez.

    python golden_hw.py  P0 P1 P2 P3     <- las cuatro potencias que dio la Kria
"""

import sys
import ddc_model as m

FS      = 100e6
PWR_LEN = 4096
FREQS   = [10.0e6, 15.0e6, 22.2e6, 3.3e6]


class SigSource:
    """sig_source.v: dos NCO sumados con desplazamiento, saturado a IN_W."""

    def __init__(self, f_a, f_b, sh_a=2, sh_b=2):
        self.a = m.NCO(m.tuning_word(f_a, FS))
        self.b = m.NCO(m.tuning_word(f_b, FS))
        self.sh_a, self.sh_b = sh_a, sh_b

    def step(self):
        _, sa = self.a.step()
        _, sb = self.b.step()
        return m.saturate((sa >> self.sh_a) + (sb >> self.sh_b), m.IN_W)


def primera_ventana(retardo):
    """Potencia de la primera ventana de cada canal, desde el reset."""
    src = SigSource(FREQS[0], FREQS[1])
    for _ in range(retardo):
        src.step()
    canales = [m.DDCChannel(f, FS) for f in FREQS]
    acc = [0] * len(FREQS)
    n = 0
    while n < PWR_LEN:
        x = src.step()
        salida = False
        for k, ch in enumerate(canales):
            r = ch.push(x)
            if r is not None:
                salida = True
                acc[k] += r[0] * r[0] + r[1] * r[1]
        if salida:
            n += 1
    return acc


def main():
    hw = [int(a) for a in sys.argv[1:5]] if len(sys.argv) >= 5 else None

    print()
    if hw is None:
        print("  Prediccion del modelo (sin datos de la Kria que comparar)")
        print("  Lanza en la placa:  sudo scanner_ctl golden")
        print()
        print("  retardo    ch0 10 MHz         ch1 15 MHz         "
              "ch2 22.2 MHz   ch3 3.3 MHz")
        for d in range(8):
            a = primera_ventana(d)
            print("     %d      %16d   %16d   %12d   %11d"
                  % (d, a[0], a[1], a[2], a[3]))
        print()
        return 0

    print("  retardo   err ch0     err ch1     err ch2     err ch3    peor")
    mejor, mejor_d, mejor_a = 1e9, None, None
    for d in range(8):
        a = primera_ventana(d)
        errs = [abs(a[k] - hw[k]) / float(hw[k]) * 100.0 if hw[k] else 0.0
                for k in range(4)]
        peor = max(errs)
        if peor < mejor:
            mejor, mejor_d, mejor_a = peor, d, a
        print("     %d     %8.4f %%  %8.4f %%  %8.4f %%  %8.4f %%  %8.4f %%"
              % (d, errs[0], errs[1], errs[2], errs[3], peor))

    print()
    print("  Mejor retardo: %d ciclos" % mejor_d)
    print()
    print("  canal   modelo             Kria               diferencia")
    exactos = 0
    for k in range(4):
        d = mejor_a[k] - hw[k]
        if d == 0:
            exactos += 1
        print("   %3d    %16d   %16d   %+12d %s"
              % (k, mejor_a[k], hw[k], d, "EXACTO" if d == 0 else ""))
    print()
    if exactos == 4:
        print("  BIT A BIT: el silicio calcula exactamente lo que dice el modelo.")
        return 0
    print("  %d de 4 canales exactos, peor error %.4f %%." % (exactos, mejor))
    return 0 if mejor < 0.5 else 1


if __name__ == "__main__":
    sys.exit(main())
