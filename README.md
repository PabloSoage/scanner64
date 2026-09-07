# scanner64 — Escáner multicanal en tiempo real para la PL de la KV260

Banco de **N canales DDC** (down-converters digitales) que vigilan N frecuencias
**simultáneamente**, muestra a muestra, sin perder ni una.

No es un demo de juguete: es **el primer bloque real del SDR** del proyecto. Cuando llegue el
HackRF (etapa 0) o la placa a medida, este mismo RTL procesa las muestras de verdad.

---

## Por qué esto no lo hace una CPU

Conviene decirlo con precisión, porque la versión de folleto (*"la FPGA es más rápida"*) es
falsa: un PC de sobremesa con AVX-512 tiene **más** GOPS brutos que la PL de un ZU5EV.

El argumento real es otro:

| | CPU | PL de la KV260 |
|---|---|---|
| Coste de añadir un canal | **Más tiempo** por muestra | **4 DSP48 más**, el tiempo no cambia |
| Tasa sostenida | Depende de la carga | **Una muestra por ciclo, siempre** |
| Latencia | Variable (planificador, cachés, interrupciones) | **Fija y conocida** |
| Muestras perdidas | Inevitables si te pasas | **Imposible por construcción** |
| Potencia | 15–125 W | ~5 W |

Y la comparación que de verdad importa no es contra tu sobremesa, sino contra **los cuatro
Cortex-A53 que la KV260 lleva al lado**: ahí el factor es de ~10× a favor de la PL, en el mismo
chip y con el mismo presupuesto de potencia. Esa es la razón por la que la PL existe.

Mídelo tú mismo con `sw/bench_cpu.py` en tu PC y en la KV260.

---

## Qué está verificado y qué no

Esto importa más que el código. En esta máquina **no hay simulador Verilog ni compilador C**,
solo Python, así que hay que ser exacto sobre el alcance de la verificación:

| Elemento | Estado | Cómo se comprobó |
|---|---|---|
| **Algoritmo y aritmética de punto fijo** | ✅ **Verificado** | `model/ddc_model.py` — 4 pruebas ejecutadas y pasando |
| **Semántica del RTL** | ✅ **Verificado** | `model/rtl_check.py` — 39 muestras comparadas contra vectores dorados, **0 discrepancias** |
| **Vectores de test del testbench** | ✅ **Generados y validados** | `model/gen_vectors.py` |
| **Simulación de `ddc_channel`** | ✅ **Verificado** | XSim (Vivado 2026.1) — 40 salidas comparadas, **0 discrepancias** |
| **Simulación de `scanner_top`** | ❌ **Sin comprobar** | No hay testbench del banco de N canales |
| **Síntesis, cierre de tiempos, recursos** | ❌ **Sin comprobar** | Requiere Vivado |
| **Comportamiento en hardware** | ❌ **Sin comprobar** | Requiere la placa |

**Lo primero que debes hacer es ejecutar el testbench.** Si pasa, el RTL está bien transcrito.
Si no, el fallo está en el RTL, porque el modelo sí está verificado.

### Resultados de la verificación

```
$ py model/ddc_model.py
  [1] Tono en banda    f= 10.00 MHz   potencia =  -12.04 dBFS
  [2] Tono fuera banda f= 15.00 MHz   potencia =  -84.70 dBFS   (rechazo 72.7 dB)
  [3] Dos tonos a la vez, dos canales:  A=-13.98 dBFS   B=-13.98 dBFS
  [4] Entrada nula -> salida nula (integradores estables)
  RESULTADO: OK

$ py model/rtl_check.py
  comparadas    : 39
  discrepancias : 0
  RESULTADO: OK — la semantica del RTL coincide con el modelo verificado.

$ xsim tb_sim -runall
  tb_ddc_channel
    salidas producidas : 48
    comparadas         : 40
    discrepancias      : 0
  RESULTADO: PASA
```

El testbench se ha ejecutado en **XSim (Vivado 2026.1)**: 3072 muestras de estímulo entran por el
canal, salen 48 tras el diezmado por 64, se descartan las 8 del transitorio del CIC y las 40
restantes coinciden exactamente, I y Q, con los vectores dorados. El análisis y la elaboración
pasan limpios con `default_nettype none` activo.

---

## Estructura

```
scanner64/
├── model/
│   ├── ddc_model.py      Modelo bit-exacto. LA REFERENCIA del diseño. Autotest.
│   ├── gen_vectors.py    Genera la LUT del NCO y los vectores dorados.
│   └── rtl_check.py      Transcribe la semántica del RTL y la compara.
├── rtl/
│   ├── nco.v             Acumulador de fase + LUT de coseno en BRAM.
│   ├── cic_decim.v       Decimador CIC. Sin multiplicadores.
│   ├── ddc_channel.v     Un canal: NCO + mezclador + 2 CIC.
│   ├── scanner_top.v     N canales en paralelo + medidor de potencia.
│   ├── sig_source.v      Generador de señal en la PL (la "antena" sin ADC).
│   └── sin_lut.mem       Generado por gen_vectors.py.
├── tb/
│   ├── tb_ddc_channel.v  Testbench autocomprobante: imprime PASA o FALLA.
│   └── vectors/          Generados por gen_vectors.py.
└── sw/
    └── bench_cpu.py      El mismo DSP en CPU, para medir el gap de verdad.
```

---

## Cómo usarlo

### 1. Regenerar los vectores (opcional, ya están)

```bash
cd model
py ddc_model.py      # autotest del modelo
py gen_vectors.py    # genera sin_lut.mem y tb/vectors/
py rtl_check.py      # comprueba la semántica del RTL
```

### 2. Simular el RTL

Con **iverilog**:
```bash
cd fpga/scanner64
iverilog -g2012 -o tb.vvp -I tb/vectors \
    tb/tb_ddc_channel.v rtl/nco.v rtl/cic_decim.v rtl/ddc_channel.v
cp rtl/sin_lut.mem .
vvp tb.vvp
```

Con **XSim** (línea de comandos, sin crear proyecto). El testbench lee los vectores con rutas
relativas al directorio de trabajo, así que ahí tiene que haber un `vectors/` y el `sin_lut.mem`:

```bash
mkdir build && cd build
cp -r ../tb/vectors . && cp ../rtl/sin_lut.mem .
xvlog -sv -i vectors ../rtl/nco.v ../rtl/cic_decim.v ../rtl/ddc_channel.v ../tb/tb_ddc_channel.v
xelab tb_ddc_channel -s tb_sim
xsim tb_sim -runall
```

> **Aviso en Windows:** si el directorio de trabajo tiene una ruta muy larga (~250 caracteres),
> `xelab` falla con `Failed to compile generated C file`. No es el diseño: es el gcc interno de
> XSim. Trabaja desde una ruta corta.

Con la **GUI de Vivado**: añade `rtl/*.v` como fuentes de diseño y `tb/tb_ddc_channel.v` como
fuente de simulación, pon `tb/vectors/` en el *include path*, y copia `rtl/sin_lut.mem` al
directorio de trabajo del simulador.

Debe imprimir `RESULTADO: PASA`.

### 3. Llevarlo a la placa

1. Proyecto Vivado para **XCK26-SFVC784-2LV-C** (el SoM de la KV260).
2. Diagrama de bloques: Zynq UltraScale+ MPSoC → AXI Interconnect → tu envoltorio AXI4-Lite
   sobre `scanner_top`, más un AXI DMA para volcar `tap_i`/`tap_q` a memoria.
3. Alimenta `in_data` desde `sig_source` (sin hardware externo) o desde el ADC cuando exista.
4. Reloj de la PL: empieza en 100 MHz. Sube hasta donde cierre tiempos — ese número **es** el
   resultado del experimento.

### 4. Exprimirla de verdad

El experimento interesante es **subir `N_CH` hasta que deje de caber o de cerrar tiempos**, e ir
anotando:

| N_CH | DSP48 usados | LUT | Fmax | Gop/s sostenidos |
|---|---|---|---|---|
| 8 | | | | |
| 16 | | | | |
| 32 | | | | |
| 64 | | | | |
| 128 | | | | |

El ZU5EV tiene **1248 DSP48**. A ~4 DSP por canal el techo aritmético está sobre los 300 canales;
en la práctica manda el rutado bastante antes. Encontrar ese punto es exactamente "exprimir la
FPGA", y el número te sirve para dimensionar el diseño de verdad.

---

## Parámetros del diseño

| Parámetro | Valor | Nota |
|---|---|---|
| `IN_W` | 16 b | Muestra de entrada |
| `OUT_W` | 18 b | Salida I/Q, con 2 bits de margen sobre la entrada |
| `PHASE_W` | 32 b | Resolución de sintonía: 0.023 Hz a 100 MSPS |
| `LUT_ADDR_W` | 10 b | 1024 entradas; ruido de truncamiento de fase ≈ −60 dBc |
| `CIC_N` | 3 | Etapas |
| `CIC_R` | 64 | Diezmado → 1.5625 MSPS por canal a 100 MSPS |
| `CIC_W` | 36 b | = `MIX_W` + N·log₂(R·M) = 18 + 18 |

Ancho de banda por canal ≈ 780 kHz. Suficiente para FM de banda estrecha, PMR446, AM y SSB.

### Dos trampas del CIC que están documentadas en el código

1. **El desbordamiento de los integradores es intencionado.** Los integradores desbordan y los
   peines lo deshacen exactamente, si `ACC_W ≥ IN_W + N·log₂(R·M)`. Poner saturación ahí **rompe
   el filtro**. Es el error clásico al portar un CIC.
2. **Las cascadas son registradas, no combinatorias.** La versión "de libro" encadena las etapas
   en el mismo ciclo, lo que crea una cadena de acarreo de 3×36 bits que no cierra tiempos. Misma
   función de transferencia, solo cambia la latencia. El modelo emula la versión registrada
   precisamente para ser ciclo a ciclo igual que el hardware.

---

## Limitaciones conocidas

- **Sin compensación de la caída del CIC.** Un CIC de 3 etapas atenúa hacia el borde de la banda
  (~3 dB en el 20 % superior). Para medir potencia no importa; para demodular hay que añadir un
  FIR compensador. No está.
- **Sin AXI4-Lite.** La interfaz de registros es síncrona y sencilla a propósito. Envolverla es
  un paso de Vivado.
- **La LUT no está compartida entre canales.** Cada `nco` infiere su propia BRAM. Con muchos
  canales conviene compartir una LUT multipuerto o generar el seno con CORDIC.
- **El ruido del `sig_source` es un LFSR**, no gaussiano. Sirve para suelo de ruido y rango
  dinámico, no para medir figura de ruido.

---

## Reutilización

El bloque no depende de ningún hardware concreto. La entrada es un flujo de muestras con
`valid`, venga de donde venga:

- De `sig_source.v`, dentro de la propia PL, sin nada externo.
- De un SDR por USB (un HackRF, por ejemplo), volcando las muestras a la PL.
- De un ADC conectado a la interfaz IAS1 de la KV260.

Nació como el front-end digital de un receptor SDR, pero un banco de DDC sirve igual para
vibrometría, sónar, instrumentación o cualquier problema donde haya que vigilar N bandas
estrechas dentro de una ancha, sin perder muestras.

---

## Hoja de ruta

1. Testbench de `scanner_top` — el banco de N canales sigue sin probar.
2. Síntesis para `xck26-sfvc784-2LV-c` y barrido de `N_CH` (ver la tabla de arriba).
3. Compartir la LUT del NCO entre canales: con muchos canales las BRAM se agotan antes que
   los DSP.
4. Comparativa con la misma aritmética en CPU (AVX-512) y GPU (CUDA), en canales·MHz por vatio
   y latencia de peor caso — no en GOPS pico.

---

## Licencia

Apache License 2.0 — ver [LICENSE](LICENSE).

Los algoritmos son de dominio público: el CIC es de Hogenauer (1981) y el NCO/DDS es anterior.
Lo que cubre la licencia es esta implementación, su modelo de referencia y su documentación.

### Cómo citar

```bibtex
@software{soage_scanner64,
  author  = {Soage Rodas, Pablo},
  title   = {scanner64: a real-time multichannel DDC bank for the Kria KV260},
  year    = {2026},
  url     = {https://github.com/PabloSoage/scanner64}
}
```
