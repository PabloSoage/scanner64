#!/usr/bin/env python3
"""
Modelo bit-exacto de un canal DDC (Digital Down-Converter).

Este fichero es la REFERENCIA del diseno. El RTL de rtl/ es una transcripcion
directa de lo que hay aqui, y el testbench de tb/ usa los vectores que genera
gen_vectors.py a partir de este modelo.

Cadena por canal:

    x[n] (real, 16 b)
       |
       +--> mezclador complejo  <-- NCO (acumulador de fase de 32 b + LUT)
       |
       +--> CIC decimador (N=3 etapas, R=64, M=1), I y Q por separado
       |
       +--> normalizacion (>> 18) y salida I/Q

Todo con enteros de Python emulando aritmetica de complemento a dos de ancho
fijo, para que el resultado sea IDENTICO al del hardware.

Uso:
    py ddc_model.py          # ejecuta el autotest
"""

import math

# ---------------------------------------------------------------------------
# Parametros del diseno. Deben coincidir con los `localparam` del RTL.
# ---------------------------------------------------------------------------

IN_W       = 16      # ancho de la muestra de entrada
PHASE_W    = 32      # ancho del acumulador de fase del NCO
LUT_ADDR_W = 10      # bits de fase que direccionan la LUT -> 1024 entradas
LUT_W      = 16      # ancho de las muestras de seno/coseno
MIX_W      = 18      # ancho a la salida del mezclador
CIC_N      = 3       # etapas del CIC
CIC_R      = 64      # factor de diezmado
CIC_M      = 1       # retardo diferencial del peine

# Crecimiento de bits del CIC: N * log2(R*M) = 3 * 6 = 18 bits.
CIC_GROWTH = CIC_N * int(math.log2(CIC_R * CIC_M))
CIC_W      = MIX_W + CIC_GROWTH          # 36 bits de acumulador interno
OUT_W      = 18                          # ancho de la salida tras normalizar


# ---------------------------------------------------------------------------
# Utilidades de aritmetica de ancho fijo
# ---------------------------------------------------------------------------

def wrap(value, bits):
    """Trunca a `bits` en complemento a dos, con desbordamiento envolvente.

    El CIC depende de este comportamiento: los integradores desbordan de forma
    natural y los peines lo deshacen, siempre que el ancho sea suficiente.
    Emular esto mal es el error clasico al portar un CIC a punto fijo.
    """
    mask = (1 << bits) - 1
    value &= mask
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def saturate(value, bits):
    """Satura a `bits` en complemento a dos (para el mezclador, que no debe
    envolver: una envolvente ahi genera chasquidos en la senal)."""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return lo if value < lo else hi if value > hi else value


# ---------------------------------------------------------------------------
# NCO
# ---------------------------------------------------------------------------

def build_sin_lut():
    """LUT de coseno de 2^LUT_ADDR_W entradas, con LUT_W bits con signo.

    En el RTL esto es una BRAM inicializada con el .mem que genera
    gen_vectors.py, de modo que los valores son exactamente estos.
    """
    n = 1 << LUT_ADDR_W
    peak = (1 << (LUT_W - 1)) - 1          # 32767
    return [int(round(peak * math.cos(2.0 * math.pi * i / n))) for i in range(n)]


SIN_LUT = build_sin_lut()


def tuning_word(f_hz, fs_hz):
    """Palabra de sintonia del NCO para una frecuencia dada."""
    return int(round((f_hz / fs_hz) * (1 << PHASE_W))) & ((1 << PHASE_W) - 1)


class NCO:
    """Acumulador de fase + LUT. Devuelve (cos, sin) de LUT_W bits."""

    def __init__(self, ftw, phase0=0):
        self.ftw = ftw & ((1 << PHASE_W) - 1)
        self.phase = phase0 & ((1 << PHASE_W) - 1)

    def step(self):
        # Los LUT_ADDR_W bits altos de la fase direccionan la LUT.
        addr = self.phase >> (PHASE_W - LUT_ADDR_W)
        cos_v = SIN_LUT[addr]
        # sin(x) = cos(x - pi/2)  ->  desplazar un cuarto de tabla.
        sin_v = SIN_LUT[(addr - (1 << (LUT_ADDR_W - 2))) & ((1 << LUT_ADDR_W) - 1)]
        self.phase = (self.phase + self.ftw) & ((1 << PHASE_W) - 1)
        return cos_v, sin_v


# ---------------------------------------------------------------------------
# CIC decimador
# ---------------------------------------------------------------------------

class CICDecimator:
    """CIC de N etapas, diezmado R, retardo diferencial M.

    Integradores a la tasa alta, peines a la tasa baja. La ganancia de continua
    es (R*M)^N, que aqui son 2^18 exactos, de modo que normalizar es un simple
    desplazamiento aritmetico a la derecha.

    ESTRUCTURA REGISTRADA (pipelined), no combinatoria.
    ----------------------------------------------------
    Cada etapa usa el valor PREVIO de la anterior, no el recien calculado. Es
    decir, entre etapa y etapa hay un registro.

    La version "de libro" encadena las etapas de forma combinatoria dentro del
    mismo ciclo. Matematicamente da lo mismo (misma funcion de transferencia,
    solo cambia la latencia), pero en hardware crea una cadena de acarreo de
    N * ACC_W bits que no cierra tiempos a frecuencias altas: son 3 sumadores
    de 36 bits en serie en un solo ciclo.

    El modelo emula la estructura registrada para que sea CICLO A CICLO igual
    que el RTL. Si el modelo usara la version combinatoria, los vectores de
    test no cuadrarian con el hardware y no habria forma de saber si el fallo
    esta en el RTL o en el modelo.
    """

    def __init__(self):
        self.integ = [0] * CIC_N
        self.comb_prev = [0] * CIC_N
        self.comb_val = [0] * CIC_N
        self.count = 0
        self.snapshot = 0

    def push(self, x):
        """Introduce una muestra. Devuelve la salida diezmada o None."""
        # --- Integradores: cascada REGISTRADA -------------------------------
        nxt = [0] * CIC_N
        nxt[0] = wrap(self.integ[0] + x, CIC_W)
        for i in range(1, CIC_N):
            nxt[i] = wrap(self.integ[i] + self.integ[i - 1], CIC_W)
        self.integ = nxt

        # --- Diezmado -------------------------------------------------------
        self.count += 1
        if self.count < CIC_R:
            return None
        self.count = 0

        # --- Peines: cascada REGISTRADA, a la tasa de salida ----------------
        # Con M=1 el retardo del peine es de una muestra diezmada.
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
# Canal DDC completo
# ---------------------------------------------------------------------------

class DDCChannel:
    """Un canal: NCO + mezclador complejo + dos CIC + normalizacion."""

    def __init__(self, f_hz, fs_hz, phase0=0):
        self.nco = NCO(tuning_word(f_hz, fs_hz), phase0)
        self.cic_i = CICDecimator()
        self.cic_q = CICDecimator()

    def push(self, x):
        """Introduce una muestra real de IN_W bits.

        Devuelve (I, Q) de OUT_W bits cuando hay salida, o None.
        """
        cos_v, sin_v = self.nco.step()

        # Mezclador: x[n] * e^(-j*w*n).  El desplazamiento de LUT_W-1 deshace
        # la escala de la LUT (32767 ~ 1.0).
        mix_i = saturate((x * cos_v) >> (LUT_W - 1), MIX_W)
        mix_q = saturate((-x * sin_v) >> (LUT_W - 1), MIX_W)

        yi = self.cic_i.push(mix_i)
        yq = self.cic_q.push(mix_q)
        if yi is None:
            return None

        # Normalizacion: la ganancia del CIC es 2^CIC_GROWTH exactos.
        return (wrap(yi >> CIC_GROWTH, OUT_W), wrap(yq >> CIC_GROWTH, OUT_W))


def power_db(i, q):
    """Potencia del canal en dBFS, referida al fondo de escala de ENTRADA.

    Se referencia a la entrada y no a la salida porque es lo que interesa en un
    escaner: "cuanta senal hay respecto a lo que satura el ADC". La salida tiene
    OUT_W bits y la entrada IN_W, asi que hay OUT_W-IN_W bits de margen: una
    senal a fondo de escala de entrada NO satura la salida.
    """
    mag2 = i * i + q * q
    if mag2 == 0:
        return -999.0
    full = float((1 << (IN_W - 1)) - 1) ** 2
    return 10.0 * math.log10(mag2 / full)


# ---------------------------------------------------------------------------
# Autotest
# ---------------------------------------------------------------------------

def _tone(n, f_hz, fs_hz, amp=0.5, phase=0.0):
    """Genera n muestras reales de un tono, cuantizadas a IN_W bits."""
    peak = (1 << (IN_W - 1)) - 1
    return [int(round(amp * peak * math.sin(2 * math.pi * f_hz * k / fs_hz + phase)))
            for k in range(n)]


def _selftest():
    fs = 100_000_000.0          # 100 MSPS
    n_out = 40                  # muestras de salida a evaluar
    n_in = (n_out + 8) * CIC_R  # + margen para el transitorio
    ok = True

    print(f"Modelo DDC  ·  fs={fs/1e6:.0f} MSPS  ·  CIC N={CIC_N} R={CIC_R} "
          f"(ganancia 2^{CIC_GROWTH}, acumulador {CIC_W} b)")
    print()

    # --- Prueba 1: tono EN el canal sintonizado -> debe aparecer como continua
    f_ch = 10_000_000.0
    ch = DDCChannel(f_ch, fs)
    outs = [y for y in (ch.push(x) for x in _tone(n_in, f_ch, fs, amp=0.5)) if y]
    steady = outs[8:]           # descartar el transitorio del CIC
    p_in = sum(power_db(i, q) for i, q in steady) / len(steady)
    print(f"  [1] Tono en banda    f={f_ch/1e6:>6.2f} MHz   potencia = {p_in:7.2f} dBFS")

    # Un tono real de amplitud A, al mezclarse a banda base, deja A/2 en el
    # termino de continua:  sin(w n) * (-sin(w n)) = -1/2 + 1/2 cos(2 w n).
    # Con A = 0.5 del fondo de escala, eso son 0.25 -> -12.04 dBFS.
    esperado = 20 * math.log10(0.5 / 2)
    if abs(p_in - esperado) > 1.5:
        print(f"      FALLO: se esperaba ~{esperado:.2f} dBFS")
        ok = False

    # --- Prueba 2: tono FUERA del canal -> debe quedar muy atenuado
    f_off = 10_000_000.0 + 5_000_000.0      # 5 MHz fuera; el CIC corta a ~780 kHz
    ch = DDCChannel(f_ch, fs)
    outs = [y for y in (ch.push(x) for x in _tone(n_in, f_off, fs, amp=0.5)) if y]
    p_out = sum(power_db(i, q) for i, q in outs[8:]) / len(outs[8:])
    rechazo = p_in - p_out
    print(f"  [2] Tono fuera banda f={f_off/1e6:>6.2f} MHz   potencia = {p_out:7.2f} dBFS"
          f"   (rechazo {rechazo:.1f} dB)")
    if rechazo < 40:
        print(f"      FALLO: rechazo insuficiente, se esperaban >40 dB")
        ok = False

    # --- Prueba 3: selectividad, dos canales simultaneos sobre la misma entrada
    f_a, f_b = 10_000_000.0, 12_000_000.0
    sig = [a + b for a, b in zip(_tone(n_in, f_a, fs, 0.4),
                                 _tone(n_in, f_b, fs, 0.4))]
    ch_a, ch_b = DDCChannel(f_a, fs), DDCChannel(f_b, fs)
    oa = [y for y in (ch_a.push(x) for x in sig) if y][8:]
    ob = [y for y in (ch_b.push(x) for x in sig) if y][8:]
    pa = sum(power_db(i, q) for i, q in oa) / len(oa)
    pb = sum(power_db(i, q) for i, q in ob) / len(ob)
    print(f"  [3] Dos tonos a la vez, dos canales:  "
          f"A({f_a/1e6:.0f} MHz)={pa:.2f} dBFS   B({f_b/1e6:.0f} MHz)={pb:.2f} dBFS")
    if abs(pa - pb) > 1.0:
        print("      FALLO: los dos canales deberian medir lo mismo")
        ok = False

    # --- Prueba 4: sin senal -> silencio absoluto (comprueba que no hay
    #     desbordamiento espurio en los integradores)
    ch = DDCChannel(f_ch, fs)
    outs = [y for y in (ch.push(0) for _ in range(n_in)) if y]
    if any(i or q for i, q in outs):
        print("      FALLO: con entrada nula la salida no es nula")
        ok = False
    else:
        print("  [4] Entrada nula -> salida nula (integradores estables)")

    print()
    print("RESULTADO:", "OK — el modelo es correcto" if ok else "FALLO")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(_selftest())
