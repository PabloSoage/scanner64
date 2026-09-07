#!/usr/bin/env python3
"""
Mide cuanto aguanta ESTA CPU con el mismo DSP que hace la PL.

El objetivo no es "demostrar" que la FPGA gana. Es MEDIR donde esta el limite
de tu maquina y compararlo con lo que la PL sostiene por construccion, para que
la comparacion sea un numero tuyo y no una afirmacion de marketing.

Ejecutalo en tres sitios y compara:
    1. Tu PC de sobremesa
    2. Los Cortex-A53 de la propia KV260   <-- la comparacion que importa
    3. (la PL no se mide aqui: sostiene la tasa de entrada por diseno)

Uso:
    py bench_cpu.py                 # 16 canales, 200k muestras
    py bench_cpu.py 64 500000       # 64 canales, 500k muestras

Aviso honesto sobre Python: es entre 30 y 100 veces mas lento que C bien
escrito con SIMD. El numero que saca este script NO es el limite de tu CPU: es
el limite de tu CPU EN PYTHON. Para una comparacion justa hay que escribirlo en
C con NEON o AVX. La conclusion cualitativa (la PL sostiene la tasa de entrada
y la CPU no) se mantiene, pero el factor exacto no es este. Se indica una
estimacion del equivalente en C al final.
"""

import math
import sys
import time

sys.path.insert(0, __file__.rsplit("sw", 1)[0] + "model")

from ddc_model import (                                    # noqa: E402
    DDCChannel, tuning_word, IN_W, CIC_R,
)

FS = 100_000_000.0          # tasa de muestreo que tendria el ADC


def build_channels(n_ch, fs):
    """n_ch canales repartidos por la banda, como en un escaner real."""
    return [DDCChannel(fs * (0.05 + 0.40 * k / max(1, n_ch - 1)), fs)
            for k in range(n_ch)]


def make_input(n):
    """Senal de prueba: dos tonos, cuantizada a IN_W bits."""
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

    print(f"Benchmark de CPU — {n_ch} canales DDC, {n_samp:,} muestras")
    print(f"Objetivo: sostener {FS/1e6:.0f} MSPS de entrada sin perder muestras")
    print()

    chans = build_channels(n_ch, FS)
    data = make_input(n_samp)

    t0 = time.perf_counter()
    for x in data:
        for ch in chans:
            ch.push(x)
    dt = time.perf_counter() - t0

    sps = n_samp / dt                       # muestras de entrada por segundo
    ch_sps = sps * n_ch                     # canal-muestras por segundo

    # Operaciones por muestra y canal (cuenta conservadora):
    #   NCO 2, mezclador 2 mult + 2 desp, CIC 3 integradores x2 (I,Q) = 6 sumas,
    #   peines 3 x2 a 1/R de la tasa. Redondeamos a 18.
    OPS = 18
    gops = ch_sps * OPS / 1e9

    print(f"  tiempo             : {dt:8.2f} s")
    print(f"  tasa de entrada    : {sps/1e3:8.1f} kSPS")
    print(f"  canal-muestras/s   : {ch_sps/1e6:8.2f} M")
    print(f"  ~operaciones/s     : {gops:8.3f} Gop/s   (Python puro)")
    print()

    factor = FS / sps
    print(f"  Necesario para tiempo real: {FS/1e6:.0f} MSPS")
    print(f"  Conseguido               : {sps/1e6:.4f} MSPS")
    print(f"  DEFICIT                  : x{factor:,.0f}")
    print()

    # Estimacion del equivalente en C. Python interpretado esta tipicamente
    # entre 30x y 100x por debajo de C con SIMD para bucles de enteros.
    for speedup, etiqueta in ((30, "C conservador"), (100, "C con SIMD")):
        c_sps = sps * speedup
        print(f"  Estimacion {etiqueta:16}: {c_sps/1e6:8.2f} MSPS  "
              f"-> {'ALCANZA' if c_sps >= FS else f'deficit x{FS/c_sps:,.0f}'}")

    print()
    print("Lo que hace la PL, por construccion:")
    print(f"  Procesa {n_ch} canales a la tasa del reloj, una muestra por ciclo.")
    print(f"  A 100 MHz eso son {100*n_ch/1e3:.1f} G canal-muestras/s "
          f"= {100e6*n_ch*OPS/1e9:.0f} Gop/s.")
    print("  Sin perder muestras y con latencia fija. No es que sea mas rapida:")
    print("  es que la tasa NO DEPENDE de cuantos canales pongas, mientras")
    print("  quepan multiplicadores. Anadir un canal cuesta 4 DSP48, no tiempo.")
    print()
    print("Ese es el argumento real de una FPGA: no GOPS brutos — un PC de")
    print("sobremesa con AVX-512 tiene mas — sino throughput DETERMINISTA,")
    print("latencia acotada y escalado por area en vez de por tiempo.")


if __name__ == "__main__":
    main()
