#!/usr/bin/env python3
"""
Genera los ficheros que consume el RTL y su testbench, a partir del modelo
bit-exacto de ddc_model.py.

Salidas:
    rtl/sin_lut.mem        LUT de coseno para $readmemh (BRAM del NCO)
    tb/vectors/stim.hex    muestras de entrada, IN_W bits, hex con signo
    tb/vectors/gold_i.hex  salida I esperada, OUT_W bits
    tb/vectors/gold_q.hex  salida Q esperada, OUT_W bits
    tb/vectors/params.vh   parametros y la palabra de sintonia usada

Como el testbench compara contra estos vectores, si el RTL esta bien
transcrito la simulacion pasa sin ajustar nada. Si falla, el RTL difiere
del modelo — y el modelo esta verificado (ver ddc_model.py).

Uso:
    py gen_vectors.py
"""

import math
import os

from ddc_model import (
    DDCChannel, SIN_LUT, tuning_word,
    IN_W, OUT_W, PHASE_W, LUT_ADDR_W, LUT_W, MIX_W,
    CIC_N, CIC_R, CIC_M, CIC_W, CIC_GROWTH,
)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = os.path.join(ROOT, "rtl")
VEC = os.path.join(ROOT, "tb", "vectors")

# Escenario de prueba: dos tonos, uno dentro del canal y otro fuera.
FS      = 100_000_000.0
F_TUNE  =  10_000_000.0     # canal sintonizado
F_IN    =  10_000_000.0     # tono en banda
F_OUT   =  15_000_000.0     # tono fuera de banda (debe quedar rechazado)
AMP_IN  = 0.40
AMP_OUT = 0.40
N_OUT   = 48                # muestras de salida a comprobar
N_IN    = N_OUT * CIC_R


def twos_hex(value, bits):
    """Entero con signo -> hex de `bits` bits, sin prefijo."""
    return f"{value & ((1 << bits) - 1):0{(bits + 3) // 4}x}"


def write_lines(path, lines, header=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n") as fh:
        if header:
            for h in header:
                fh.write(f"// {h}\n")
        fh.write("\n".join(lines))
        fh.write("\n")
    print(f"  {os.path.relpath(path, ROOT):28} {len(lines):5d} lineas")


def main():
    print("Generando ficheros para el RTL desde el modelo verificado")
    print()

    # --- LUT del NCO ---------------------------------------------------
    write_lines(
        os.path.join(RTL, "sin_lut.mem"),
        [twos_hex(v, LUT_W) for v in SIN_LUT],
    )

    # --- Estimulo: suma de los dos tonos -------------------------------
    peak = (1 << (IN_W - 1)) - 1
    stim = []
    for k in range(N_IN):
        s = (AMP_IN * peak * math.sin(2 * math.pi * F_IN * k / FS)
             + AMP_OUT * peak * math.sin(2 * math.pi * F_OUT * k / FS))
        # Saturar por si la suma se pasa de fondo de escala.
        stim.append(max(-peak - 1, min(peak, int(round(s)))))

    write_lines(os.path.join(VEC, "stim.hex"),
                [twos_hex(v, IN_W) for v in stim])

    # --- Salida esperada, del modelo bit-exacto ------------------------
    ch = DDCChannel(F_TUNE, FS)
    gold = [y for y in (ch.push(x) for x in stim) if y is not None]

    write_lines(os.path.join(VEC, "gold_i.hex"),
                [twos_hex(i, OUT_W) for i, _ in gold])
    write_lines(os.path.join(VEC, "gold_q.hex"),
                [twos_hex(q, OUT_W) for _, q in gold])

    # --- Parametros para el testbench ----------------------------------
    ftw = tuning_word(F_TUNE, FS)
    params = [
        "// Generado por model/gen_vectors.py — no editar a mano.",
        "",
        f"localparam integer P_IN_W       = {IN_W};",
        f"localparam integer P_OUT_W      = {OUT_W};",
        f"localparam integer P_PHASE_W    = {PHASE_W};",
        f"localparam integer P_LUT_ADDR_W = {LUT_ADDR_W};",
        f"localparam integer P_LUT_W      = {LUT_W};",
        f"localparam integer P_MIX_W      = {MIX_W};",
        f"localparam integer P_CIC_N      = {CIC_N};",
        f"localparam integer P_CIC_R      = {CIC_R};",
        f"localparam integer P_CIC_M      = {CIC_M};",
        f"localparam integer P_CIC_W      = {CIC_W};",
        f"localparam integer P_CIC_GROWTH = {CIC_GROWTH};",
        "",
        f"localparam [P_PHASE_W-1:0] P_FTW = {PHASE_W}'h{ftw:08x};  // {F_TUNE/1e6:.3f} MHz @ {FS/1e6:.0f} MSPS",
        f"localparam integer P_N_STIM = {len(stim)};",
        f"localparam integer P_N_GOLD = {len(gold)};",
    ]
    write_lines(os.path.join(VEC, "params.vh"), params)

    # --- Resumen -------------------------------------------------------
    from ddc_model import power_db
    steady = gold[8:]
    p = sum(power_db(i, q) for i, q in steady) / len(steady)
    esperado = 20 * math.log10(AMP_IN / 2)
    print()
    print(f"  Escenario: tono en banda {F_IN/1e6:.0f} MHz (A={AMP_IN}) + "
          f"tono fuera {F_OUT/1e6:.0f} MHz (A={AMP_OUT})")
    print(f"  Potencia medida en el canal: {p:.2f} dBFS "
          f"(teorica solo con el tono en banda: {esperado:.2f} dBFS)")
    if abs(p - esperado) < 1.0:
        print("  -> el tono fuera de banda queda rechazado. Vectores validos.")
    else:
        print("  -> AVISO: el tono fuera de banda no esta suficientemente rechazado")


if __name__ == "__main__":
    main()
