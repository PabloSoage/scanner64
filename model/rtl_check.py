#!/usr/bin/env python3
"""
Comprueba el RTL sin simulador Verilog.

En esta maquina no hay iverilog ni verilator, asi que el RTL no se puede
simular. Este fichero es lo mas parecido honesto: una transcripcion a Python
de la SEMANTICA del Verilog tal y como esta escrito — con asignaciones no
bloqueantes, es decir, todas las lecturas usan el valor del registro ANTES del
flanco — y una comparacion contra los vectores dorados de tb/vectors/.

La diferencia con ddc_model.py es la direccion de la transcripcion:
  ddc_model.py  se escribio primero, y de el salio el RTL.
  rtl_check.py  se escribe LEYENDO el RTL, y se compara contra los vectores.

Si las dos coinciden, la probabilidad de un error de transcripcion baja mucho.
Lo que esto NO comprueba: sintesis, cierre de tiempos, uso de recursos, y
cualquier cosa que dependa del comportamiento real de las herramientas. Para
eso hay que ejecutar tb/tb_ddc_channel.v en Vivado o iverilog.

Uso:
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
    """Lee un fichero estilo $readmemh y devuelve enteros con signo."""
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.split("//")[0].strip()
            if line:
                out.append(wrap(int(line, 16), bits))
    return out


# ---------------------------------------------------------------------------
# Transcripcion de rtl/nco.v
# ---------------------------------------------------------------------------

class RtlNco:
    """nco.v — acumulador de fase + LUT de doble puerto.

    Ojo: en el RTL cos_o/sin_o son REGISTROS, asi que salen un ciclo despues
    de la fase que los genero.
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
        # No bloqueantes: se calculan con el valor previo de phase.
        self.cos_o = SIN_LUT[addr_cos]
        self.sin_o = SIN_LUT[addr_sin]
        self.phase = (self.phase + self.ftw) & self.PMASK


# ---------------------------------------------------------------------------
# Transcripcion de rtl/cic_decim.v
# ---------------------------------------------------------------------------

class RtlCic:
    """cic_decim.v — cascadas registradas, desbordamiento envolvente."""

    def __init__(self):
        self.integ = [0] * CIC_N
        self.cnt = 0
        self.comb_prev = [0] * CIC_N
        self.comb_val = [0] * CIC_N
        self.out_valid = False
        self.out_data = 0

    def tick(self, in_valid, in_data):
        # ---- combinatorio ----
        integ_last_next = wrap(self.integ[CIC_N-1] + self.integ[CIC_N-2], CIC_W)
        decim_now = in_valid and (self.cnt == CIC_R - 1)

        # ---- secuencial: todo se calcula con los valores PREVIOS ----
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
# Transcripcion de rtl/ddc_channel.v
# ---------------------------------------------------------------------------

class RtlDdcChannel:
    """Encadena nco + mezclador registrado + dos CIC, como el RTL."""

    def __init__(self, ftw):
        self.nco = RtlNco(ftw)
        self.cic_i = RtlCic()
        self.cic_q = RtlCic()
        self.mix_i = 0
        self.mix_q = 0
        self.mix_valid = False
        self.x_d1 = 0          # retardo para alinear con el registro del NCO
        self.v_d1 = False

    def tick(self, in_valid, x):
        # Etapa 1: NCO (registrado) y retardo de la muestra para alinearla.
        cos_v, sin_v = self.nco.cos_o, self.nco.sin_o
        xd, vd = self.x_d1, self.v_d1

        # Etapa 2: mezclador (registrado)
        new_mix_i = saturate((xd * cos_v) >> (LUT_W - 1), MIX_W)
        new_mix_q = saturate((-xd * sin_v) >> (LUT_W - 1), MIX_W)
        new_mix_valid = vd

        # Etapa 3: CIC, con lo que el mezclador saco el ciclo anterior
        self.cic_i.tick(self.mix_valid, self.mix_i)
        self.cic_q.tick(self.mix_valid, self.mix_q)

        # Avance de los registros
        self.nco.tick(in_valid)
        self.x_d1, self.v_d1 = x, in_valid
        self.mix_i, self.mix_q, self.mix_valid = new_mix_i, new_mix_q, new_mix_valid

        if self.cic_i.out_valid:
            return (wrap(self.cic_i.out_data >> CIC_GROWTH, OUT_W),
                    wrap(self.cic_q.out_data >> CIC_GROWTH, OUT_W))
        return None


# ---------------------------------------------------------------------------
# Comprobacion contra los vectores dorados
# ---------------------------------------------------------------------------

def main():
    for f in ("stim.hex", "gold_i.hex", "gold_q.hex", "params.vh"):
        if not os.path.exists(os.path.join(VEC, f)):
            print(f"Faltan vectores. Ejecuta primero:  py gen_vectors.py")
            return 1

    stim = read_hex(os.path.join(VEC, "stim.hex"), IN_W)
    gold_i = read_hex(os.path.join(VEC, "gold_i.hex"), OUT_W)
    gold_q = read_hex(os.path.join(VEC, "gold_q.hex"), OUT_W)

    # La palabra de sintonia se lee de params.vh para no duplicarla.
    ftw = None
    with open(os.path.join(VEC, "params.vh")) as fh:
        for line in fh:
            if "P_FTW" in line and "'h" in line:
                ftw = int(line.split("'h")[1].split(";")[0].strip(), 16)
    if ftw is None:
        print("No se pudo leer P_FTW de params.vh")
        return 1

    print("Comprobando la semantica del RTL contra los vectores dorados")
    print(f"  estimulo : {len(stim)} muestras")
    print(f"  esperado : {len(gold_i)} salidas I/Q")
    print(f"  FTW      : 0x{ftw:08x}")
    print()

    ch = RtlDdcChannel(ftw)
    got = []
    for x in stim:
        y = ch.tick(True, x)
        if y is not None:
            got.append(y)

    # El RTL tiene latencia de pipeline (NCO + mezclador), asi que produce
    # menos salidas o desplazadas. Buscamos el desplazamiento que alinea.
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
    comparadas = n - 8
    print(f"  salidas del RTL     : {len(got)}")
    print(f"  desplazamiento pipe : {best_shift} muestras")
    print(f"  comparadas          : {comparadas}")
    print(f"  discrepancias       : {best_bad}")
    print()

    if best_bad == 0:
        print("RESULTADO: OK — la semantica del RTL coincide con el modelo verificado.")
        print()
        print("AVISO: esto NO sustituye a una simulacion. No comprueba sintesis,")
        print("cierre de tiempos ni uso de recursos. Ejecuta tb/tb_ddc_channel.v")
        print("en Vivado (o iverilog) antes de fiarte del diseno.")
        return 0

    print("RESULTADO: FALLO — el RTL no coincide con el modelo.")
    for k in range(8, min(n, 20)):
        g, r = (gold_i[k], gold_q[k]), got[k + best_shift]
        marca = "  " if g == r else "<-"
        print(f"  [{k:3d}] esperado I={g[0]:8d} Q={g[1]:8d}   "
              f"rtl I={r[0]:8d} Q={r[1]:8d} {marca}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
