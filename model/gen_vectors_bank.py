#!/usr/bin/env python3
"""
Genera los vectores dorados del BANCO de canales (scanner_top), a partir del
mismo modelo bit-exacto que ya valida un canal suelto.

Lo que prueba el banco y no prueba el canal:
    - que N canales con sintonias distintas no se pisen entre si
    - que cfg_we escribe la palabra de sintonia en el canal correcto
    - que el medidor de potencia acumula, congela y reinicia bien
    - que el escaner de verdad DISCRIMINA: los canales sintonizados a un tono
      miden potencia alta y los sintonizados al vacio, baja

Escenario: la entrada lleva dos tonos (10 y 15 MHz). Se sintonizan cuatro
canales, dos sobre los tonos y dos sobre bandas vacias.

Salidas:
    tb/vectors/bank_ftw.hex      N_CH palabras de sintonia
    tb/vectors/bank_gold.hex     I y Q esperados, por bloques de canal
    tb/vectors/bank_pwr.hex      valor esperado de rd_pwr por canal
    tb/vectors/params_bank.vh    parametros del testbench del banco

Reutiliza stim.hex, que genera gen_vectors.py. Ejecuta aquel primero.

Uso:
    py gen_vectors_bank.py
"""

import math
import os

from ddc_model import (
    DDCChannel, tuning_word, power_db,
    IN_W, OUT_W, PHASE_W, CIC_R,
)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VEC = os.path.join(ROOT, "tb", "vectors")

FS = 100_000_000.0

# Tonos presentes en el estimulo (los mismos que genera gen_vectors.py).
F_IN = 10_000_000.0
F_OUT = 15_000_000.0
AMP_IN = 0.40
AMP_OUT = 0.40

# Sintonias del banco. Dos sobre los tonos, dos sobre bandas vacias.
TUNES = [
    (10_000_000.0, "tono A, en banda"),
    (15_000_000.0, "tono B, el que el canal 0 rechaza"),
    (20_000_000.0, "vacio"),
    (5_000_000.0, "vacio"),
]
N_CH = len(TUNES)

PWR_LEN = 16                 # muestras por ventana de medida
N_OUT = 48                   # salidas por canal, como en el canal suelto
N_IN = N_OUT * CIC_R
PWR_W = 48


def twos_hex(value, bits):
    return f"{value & ((1 << bits) - 1):0{(bits + 3) // 4}x}"


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n") as fh:
        fh.write("\n".join(lines))
        fh.write("\n")
    print(f"  {os.path.relpath(path, ROOT):32} {len(lines):6d} lineas")


def make_stim():
    """El mismo estimulo que gen_vectors.py: dos tonos sumados y saturados."""
    peak = (1 << (IN_W - 1)) - 1
    out = []
    for k in range(N_IN):
        s = (AMP_IN * peak * math.sin(2 * math.pi * F_IN * k / FS)
             + AMP_OUT * peak * math.sin(2 * math.pi * F_OUT * k / FS))
        out.append(max(-peak - 1, min(peak, int(round(s)))))
    return out


def expected_power(gold):
    """Replica EXACTAMENTE la aritmetica del medidor de scanner_top.

    El RTL congela en pwr_hold la suma de PWR_LEN muestras y reinicia. Lo que
    se lee al final por rd_pwr es la ultima ventana completa, no el total.
    """
    acc = cnt = hold = 0
    done = False
    for i, q in gold:
        mag2 = i * i + q * q
        if cnt + 1 >= PWR_LEN:
            hold = (acc + mag2) & ((1 << PWR_W) - 1)
            acc = 0
            cnt = 0
            done = True
        else:
            acc += mag2
            cnt += 1
    return hold, done


def main():
    print("Generando vectores del banco desde el modelo verificado")
    print()

    stim = make_stim()

    gold_per_ch = []
    pwr_per_ch = []
    for f_tune, _ in TUNES:
        ch = DDCChannel(f_tune, FS)
        gold = [y for y in (ch.push(x) for x in stim) if y is not None]
        assert len(gold) == N_OUT, f"esperadas {N_OUT} salidas, salieron {len(gold)}"
        gold_per_ch.append(gold)
        hold, done = expected_power(gold)
        assert done, "PWR_LEN mayor que el numero de salidas: no cierra ventana"
        pwr_per_ch.append(hold)

    # --- Sintonias -----------------------------------------------------
    write_lines(os.path.join(VEC, "bank_ftw.hex"),
                [twos_hex(tuning_word(f, FS), PHASE_W) for f, _ in TUNES])

    # --- Vectores dorados, por bloques de canal ------------------------
    # El canal k ocupa [k*N_OUT, (k+1)*N_OUT). Un solo $readmemh en el
    # testbench, porque $readmemh necesita un nombre de fichero constante.
    lines_i, lines_q = [], []
    for gold in gold_per_ch:
        lines_i += [twos_hex(i, OUT_W) for i, _ in gold]
        lines_q += [twos_hex(q, OUT_W) for _, q in gold]
    write_lines(os.path.join(VEC, "bank_gold_i.hex"), lines_i)
    write_lines(os.path.join(VEC, "bank_gold_q.hex"), lines_q)

    # --- Potencia esperada ---------------------------------------------
    write_lines(os.path.join(VEC, "bank_pwr.hex"),
                [twos_hex(p, PWR_W) for p in pwr_per_ch])

    # --- Parametros -----------------------------------------------------
    params = [
        "// Generado por model/gen_vectors_bank.py - no editar a mano.",
        "",
        f"localparam integer PB_N_CH    = {N_CH};",
        f"localparam integer PB_N_STIM  = {len(stim)};",
        f"localparam integer PB_N_GOLD  = {N_OUT};",
        f"localparam integer PB_PWR_LEN = {PWR_LEN};",
        f"localparam integer PB_PWR_W   = {PWR_W};",
    ]
    write_lines(os.path.join(VEC, "params_bank.vh"), params)

    # --- Resumen: comprobar que el escenario discrimina de verdad -------
    print()
    print("  Canal  sintonia      potencia media en regimen   escenario")
    steady_db = []
    for k, (f_tune, nota) in enumerate(TUNES):
        steady = gold_per_ch[k][8:]
        p = sum(power_db(i, q) for i, q in steady) / len(steady)
        steady_db.append(p)
        print(f"    {k}    {f_tune/1e6:5.1f} MHz    {p:9.2f} dBFS            {nota}")

    ocupados = min(steady_db[0], steady_db[1])
    vacios = max(steady_db[2], steady_db[3])
    margen = ocupados - vacios
    print()
    print(f"  Margen entre canales con tono y canales vacios: {margen:.1f} dB")
    if margen > 40.0:
        print("  -> el banco discrimina. Vectores validos.")
    else:
        print("  -> AVISO: margen insuficiente, el test de discriminacion no vale")


if __name__ == "__main__":
    main()
