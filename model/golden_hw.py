#!/usr/bin/env python3
"""Contrasta AL BIT las muestras que midio la Kria contra el modelo.

`scanner_ctl golden` devuelve, por canal, una terna (indice, I, Q): la ultima
salida del canal y cual es. Eso fija un punto exacto de la senal sin depender de
donde empiece ninguna ventana de potencia -- que es lo que hacia inservible el
primer intento, porque el estado de los peines no se limpia con un reset en
caliente (ver rtl/comb_bank.v).

Para que el modelo prediga ese punto hay que reproducir dos cosas del hardware
que no son obvias:

  1. `run` a cero deja los integradores a cero y los NCO a fase cero, y el NCO
     de cada canal solo avanza con `in_valid`. Por eso la secuencia es
     reproducible ciclo a ciclo desde la primera muestra.

  2. `sig_source` tiene un ciclo de latencia: su registro de salida emite UN
     CERO antes de la primera muestra buena. Ese cero entra en el CIC y avanza
     el NCO del canal. A los canales con tono les da igual --su salida vale
     4096 y el cero se pierde en el promedio-- pero a los canales vacios les
     cambia el resultado en 1 LSB sobre un valor de 2, que es justo donde se
     nota. Medido con tb/tb_sig_source.v: rtl[n] = modelo[n-1].

El estado sucio de los peines se va en tres rondas, asi que midiendo hacia la
salida ~3000 lo que hay dentro del filtro lo pusieron las muestras de esta
misma tirada, las mismas que ve el modelo.

    python golden_hw.py N0 I0 Q0 N1 I1 Q1 N2 I2 Q2 N3 I3 Q3
"""

import sys
import ddc_model as m

FS    = 100e6
FREQS = [10.0e6, 15.0e6, 22.2e6, 3.3e6]


class SigSource:
    """sig_source.v, con su ciclo de latencia incluido."""

    def __init__(self, f_a, f_b, sh_a=2, sh_b=2):
        self.a = m.NCO(m.tuning_word(f_a, FS))
        self.b = m.NCO(m.tuning_word(f_b, FS))
        self.sh_a, self.sh_b = sh_a, sh_b
        self.primera = True

    def step(self):
        if self.primera:            # el cero del registro de salida
            self.primera = False
            return 0
        _, sa = self.a.step()
        _, sb = self.b.step()
        return m.saturate((sa >> self.sh_a) + (sb >> self.sh_b), m.IN_W)


def salida_n(f_hz, n):
    """La salida numero n (1-based, como la cuenta out_cnt) de ese canal."""
    src = SigSource(FREQS[0], FREQS[1])
    ch = m.DDCChannel(f_hz, FS)
    vistas = 0
    while True:
        r = ch.push(src.step())
        if r is not None:
            vistas += 1
            if vistas == n:
                return r


def main():
    a = [int(x) for x in sys.argv[1:13]]
    if len(a) != 12:
        print(__doc__)
        return 2
    hw = [(a[i * 3], a[i * 3 + 1], a[i * 3 + 2]) for i in range(4)]

    print()
    print("  canal   sintonia     salida n.    modelo (I,Q)      Kria (I,Q)")
    exactos = 0
    for k, (n, i_hw, q_hw) in enumerate(hw):
        i_md, q_md = salida_n(FREQS[k], n)
        bien = (i_md == i_hw and q_md == q_hw)
        exactos += bien
        print("   %3d   %6.1f MHz   %8d   %14s   %14s   %s"
              % (k, FREQS[k] / 1e6, n, "(%d, %d)" % (i_md, q_md),
                 "(%d, %d)" % (i_hw, q_hw), "EXACTO" if bien else "<-- NO CUADRA"))

    print()
    if exactos == 4:
        print("  BIT A BIT: el silicio calcula exactamente lo que dice el modelo,")
        print("  muestra a muestra, tras ~3000 salidas de historia compartida.")
        print("  Y tambien en los canales vacios, donde la salida vale 1 o 2 LSB:")
        print("  ahi no hay margen donde esconder un error de redondeo.")
        return 0
    print("  %d de 4 canales exactos." % exactos)
    return 1


if __name__ == "__main__":
    sys.exit(main())
