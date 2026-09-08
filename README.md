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
| **Simulación de `scanner_top`** | ✅ **Verificado** | XSim — 4 canales, 160 muestras comparadas, **0 discrepancias**, 6 pruebas |
| **Peines compartidos vs. replicados** | ✅ **Verificado** | XSim — 368 comparaciones contra `cic_decim`, **0 discrepancias** |
| **Síntesis y recursos de `ddc_channel`** | ✅ **Medido** | Síntesis OOC, Vivado 2026.1 — 0 errores, 0 warnings críticos |
| **Síntesis del banco completo, cierre de tiempos** | ❌ **Sin comprobar** | Falta el barrido de `N_CH` con implementación |
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
│   ├── gen_vectors_bank.py  Vectores dorados del banco multicanal.
│   └── rtl_check.py      Transcribe la semántica del RTL y la compara.
├── rtl/
│   ├── nco.v             Acumulador de fase + LUT de coseno en BRAM.
│   ├── cic_decim.v       Decimador CIC. Sin multiplicadores.
│   ├── cic_integ.v       Integradores del CIC, a la tasa de entrada.
│   ├── comb_chain.v      Peines de UNA unidad, a la tasa diezmada.
│   ├── comb_bank.v       Peines compartidos por turnos entre 32 unidades.
│   ├── ddc_front.v       NCO + mezclador + integradores. Sin peines.
│   ├── ddc_channel.v     Un canal completo y autonomo: ddc_front + peines.
│   ├── scanner_top.v     N canales en paralelo + medidor de potencia.
│   ├── sig_source.v      Generador de señal en la PL (la "antena" sin ADC).
│   └── sin_lut.mem       Generado por gen_vectors.py.
├── tb/
│   ├── tb_ddc_channel.v  Testbench del canal: aritmetica contra el modelo.
│   ├── tb_scanner_top.v  Testbench del banco: 6 pruebas, imprime PASA o FALLA.
│   ├── tb_comb_bank.v    Equivalencia peines compartidos vs. replicados.
│   └── vectors/          Generados por gen_vectors*.py.
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

Y el del **banco de canales**, que prueba lo que el del canal no puede ver:

```bash
xvlog -sv -i vectors ../rtl/nco.v ../rtl/cic_decim.v ../rtl/ddc_channel.v                      ../rtl/scanner_top.v ../tb/tb_scanner_top.v
xelab tb_scanner_top -s tb_bank
xsim tb_bank -runall
```

Seis pruebas, con su propio contador de fallos cada una:

| | Qué comprueba |
|---|---|
| **T1** | `cfg_we` escribe la sintonía en el canal indicado, y solo en ese |
| **T2** | los N canales producen a la vez sin pisarse, cada uno con su sintonía |
| **T3** | el mux de `tap_ch` devuelve el canal seleccionado |
| **T4** | el medidor de potencia acumula, congela y reinicia; `rd_ch` lee bien |
| **T5** | el escáner **discrimina**: los canales sobre un tono miden potencia alta y los sintonizados al vacío, baja |
| **T6** | `cfg_clear` reinicia los acumuladores |

El escenario sintoniza cuatro canales sobre un estímulo de dos tonos: dos canales sobre los
tonos y dos sobre banda vacía, con **59 dB** de margen entre unos y otros.

> El testbench se validó por mutación: introduciendo a propósito un mux de `tap_ch` que
> ignora la selección y un `cfg_we` que escribe siempre en el canal 0, T1 da 4 fallos, T2
> da 160, T3 da 3, T4 da 4 y T5 da 4. Un testbench que nunca has visto fallar no sabes si
> comprueba algo.

### 3. Abrirlo en la GUI de Vivado

Para ver las formas de onda, el esquemático o los informes con el raton en vez de por consola,
[`syn/make_project.tcl`](syn/make_project.tcl) monta el proyecto entero:

```bash
vivado -mode batch -source <repo>/syn/make_project.tcl -tclargs C:/kv/s64
vivado C:/kv/s64/scanner64.xpr
```

Deja el RTL y los tres testbenches cargados, el *include path* puesto y los vectores copiados
donde XSim los busca. Dentro:

| En el panel *Flow Navigator* | Qué ves |
|---|---|
| **Run Simulation → Run Behavioral Simulation** | Corre el testbench hasta su `$finish`. El veredicto sale en la consola **Tcl Console**; las señales, en la ventana de ondas |
| **Open Elaborated Design → Schematic** | El circuito **tal y como lo escribiste**: sumadores, registros, multiplexores. Es el dibujo del RTL |
| **Run Synthesis → Open Synthesized Design → Schematic** | El circuito **tal y como cabe en el chip**: LUT, FF, DSP48, RAMB18. Aquí se ve de verdad dónde se va cada recurso |
| **Open Synthesized Design → Report Utilization** | La tabla de recursos, interactiva y por jerarquía: qué módulo gasta qué |
| **Open Synthesized Design → Report Timing Summary** | El WNS y los caminos críticos, clicables hasta la señal concreta |

Para cambiar de testbench: *Sources → Simulation Sources*, botón derecho sobre el que quieras →
**Set as Top**. Por defecto está puesto `tb_scanner_top`.

En la ventana de ondas solo aparecen las señales del nivel superior. Para ver el interior —los
integradores, el estado de los peines— despliega la jerarquía en el panel **Scope**, selecciona
las señales que te interesen y arrástralas a la forma de onda; luego **Relaunch Simulation**
para que se registren desde el principio.

### 4. Sintetizar y medir recursos

Sin placa y sin crear proyecto. Desde un directorio de trabajo vacío:

```bash
cp <repo>/rtl/sin_lut.mem .
vivado -mode batch -nojournal -notrace -source <repo>/syn/ooc_channel.tcl
```

Sintetiza **un** `ddc_channel` *out-of-context* para `xck26-sfvc784-2LV-c` y deja `util.rpt`
y `timing.rpt`. Los informes de la última ejecución están en [`syn/results/`](syn/results).

### 5. Llevarlo a la placa

1. Proyecto Vivado para **XCK26-SFVC784-2LV-C** (el SoM de la KV260).
2. Diagrama de bloques: Zynq UltraScale+ MPSoC → AXI Interconnect → tu envoltorio AXI4-Lite
   sobre `scanner_top`, más un AXI DMA para volcar `tap_i`/`tap_q` a memoria.
3. Alimenta `in_data` desde `sig_source` (sin hardware externo) o desde el ADC cuando exista.
4. Reloj de la PL: empieza en 100 MHz. Sube hasta donde cierre tiempos — ese número **es** el
   resultado del experimento.

### 6. Exprimirla de verdad

El experimento interesante es **subir `N_CH` hasta que deje de caber o de cerrar tiempos**.

Primer dato medido, por síntesis *out-of-context* de **un** `ddc_channel` sobre
`xck26-sfvc784-2LV-c` (Vivado 2026.1, `T = 10 ns`):

Barrido medido, síntesis *out-of-context* de `scanner_top` sobre `xck26-sfvc784-2LV-c`
(Vivado 2026.1, `T = 10 ns`), con `syn/sweep_bank.tcl`:

| N_CH | DSP48E2 | CLB LUT | FF | BRAM tile | RAMB18 | WNS | Fmax |
|---|---|---|---|---|---|---|---|
| 1 (solo `ddc_channel`) | 3 | 600 | 677 | 1 | 2 | 5,467 ns | 220,6 MHz |
| **8** | 40 | 5 634 | 6 578 | 4 | 8 | 5,467 ns | 220,6 MHz |
| **16** | 80 | 11 227 | 13 138 | 16 | 32 | 5,467 ns | 220,6 MHz |
| **32** | 160 | 22 536 | 26 320 | 32 | 64 | 5,432 ns | 218,9 MHz |

Por canal el coste es **plano**: 5,00 DSP, ~703 LUT, ~822 FF. Y el Fmax **no se degrada** hasta
32 canales, que era el riesgo real. Los 5 DSP son 3 del `ddc_channel` más 2 del medidor de
potencia.

### Dónde está el techo

| Recurso | Disponible en el ZU5EV | Coste por canal | Techo |
|---|---|---|---|
| DSP48E2 | 1248 | 5,0 | 249 |
| **CLB LUT** | **117 120** | **703** | **166** |
| BRAM tile | 144 | 1,0 | 144 |

**El muro está en ~144 canales por BRAM, pero el LUT viene justo detrás, en 166.** Esa cercanía
es lo que decide qué merece la pena optimizar, y la respuesta es contraintuitiva.

### Por qué compartir la LUT del NCO no sirve

Parecía la optimización obvia: cada `nco` infiere su propia ROM de coseno, así que compartirla
debería mover el techo. Se midió, y no.

Vivado replica la tabla en 2 RAMB18 por canal a partir de `N_CH = 16` (con 8 canales sí infiere
doble puerto real y usa 1). Forzándolo con `-max_bram` se consigue 0,5 tile por canal, pero el
coste aparece en otro sitio:

| | LUT/canal | tile/canal | Techo LUT | Techo BRAM | **Muro** |
|---|---|---|---|---|---|
| Automático | 703 | 1,0 | 166 | 144 | **144** |
| Forzado a 1 RAMB18 | **916** | 0,5 | **127** | 288 | **127** |

Ahorrar la BRAM cuesta **+214 LUT por canal**, y como el LUT es el segundo limitante el techo
global **empeora**: 144 → 127. Aunque la BRAM saliera gratis, el techo solo subiría a 166: el
retorno máximo de esta optimización es **+15 %**, y cualquier implementación que cueste más de
unos 30 LUT por canal lo destruye.

### El CIC en los DSP: un intercambio, no una mejora

Los ~703 LUT por canal son casi todos acumuladores del CIC de 36 bits, mientras los DSP48
—que llevan dentro un acumulador de 48 bits— están a menos de la mitad de su techo. Sintetizar
con `-verilog_define CIC_USE_DSP=1` los manda al DSP:

| | LUT/canal | DSP/canal | tile/canal | Fmax | Techo LUT | Techo DSP | Techo BRAM | **Muro** |
|---|---|---|---|---|---|---|---|---|
| Por defecto | 703 | 5,0 | 1,0 | 220,6 MHz | 166 | 249 | 144 | **144** |
| `CIC_USE_DSP=1` | **419** | 11,0 | 1,0 | 220,6 MHz | 280 | **113** | 144 | **113** |

**−284 LUT por canal, +6 DSP, y el Fmax no se mueve.** Pero el techo *baja*, de 144 a 113: el
cuello pasa del BRAM al DSP. Por eso no es el comportamiento por defecto.

Donde sí sirve es cuando el escáner no es lo único que va en el chip. A 64 canales, que es lo
realista una vez metes el AXI4-Lite, el DMA y el resto del sistema:

| | LUT | DSP | BRAM |
|---|---|---|---|
| Por defecto | 38,5 % | 25,6 % | 44,4 % |
| `CIC_USE_DSP=1` | **23,0 %** | 56,4 % | 44,4 % |

Liberas un 15 % del chip en LUT a cambio de DSP que de todas formas no estabas usando. **Elige
según el recurso que te falte**, no por defecto.

### Resumen: el diseño está en un óptimo plano

Los tres recursos se agotan casi a la vez —144 por BRAM, 166 por LUT, 249 por DSP— y por eso
ninguna optimización de mapeo mueve el techo:

| Cambio | Muro resultante |
|---|---|
| Nada | **144** |
| Compartir la LUT del NCO (`-max_bram`) | 127 |
| CIC en DSP | 113 |
| Ambas a la vez | 151 |

El mejor caso son 151 canales, un +5 % a cambio de bastante complejidad. **Para pasar de ahí
hace falta cambiar la arquitectura, no el mapeo.**

### Peines compartidos: `comb_bank`

Y ahí sí hay recorrido. Los peines trabajan a **1/64 de la tasa de entrada**: están parados el
98 % del tiempo y aun así había seis acumuladores de 36 bits replicados **por canal**. Medido,
eso costaba **216 LUT y 360 FF por canal**.

[`rtl/comb_bank.v`](rtl/comb_bank.v) es un solo juego de peines que atiende 32 unidades por
turnos —una unidad es una cadena I o Q, así que son 16 canales por banco—. Todos los canales
diezman en el mismo ciclo, así que captura las 32 muestras de golpe y las procesa de una en
una en los 32 ciclos siguientes, con margen de sobra antes del siguiente diezmado.

Está **integrado en `scanner_top`**, y estos son los números medidos, no proyectados:

| N_CH | LUT/canal | FF/canal | tile/canal | Fmax | Techo LUT | Techo BRAM | **Muro** |
|---|---|---|---|---|---|---|---|
| 16 (antes) | 702 | 821 | 1,000 | 220,6 MHz | 166 | 144 | **144** |
| 32 (antes) | 704 | 823 | 1,000 | 218,9 MHz | 166 | 144 | **144** |
| **16** | **610** | 904 | **0,562** | 220,6 MHz | 192 | 256 | **192** |
| **32** | **612** | 903 | **0,531** | 218,9 MHz | 191 | 271 | **191** |
| **64** | **610** | 906 | **1,000** | 211,0 MHz | 191 | 144 | **144** |

**El LUT baja a ~610 por canal de forma estable, un −13 %, en todos los tamaños.** Eso es firme.

El techo, en cambio, tiene trampa, y conviene decirlo claro: hasta 32 canales sube a ~191
porque Vivado deja de replicar la ROM del NCO al bajar la presión de recursos. **A 64 canales
vuelve a replicarla** y el muro cae otra vez a 144. Es la misma heurística de la herramienta que
apareció en B5, y no depende del RTL.

Forzarla no arregla nada: con `-max_bram` a 64 canales se consigue 0,5 tile/canal, pero cuesta
los mismos **+214 LUT por canal** de siempre (610 → 824) y el techo baja a 142.

| N_CH = 64 | LUT/canal | tile/canal | Techo LUT | Techo BRAM | **Muro** |
|---|---|---|---|---|---|
| BRAM automática | 610 | 1,000 | 191 | 144 | **144** |
| BRAM forzada | 824 | 0,500 | 142 | 288 | **142** |

Así que el estado real es: **−13 % de LUT garantizado, y un techo de 191 canales que solo se
cobra si se resuelve la ROM del NCO sin pagar 214 LUT**. Eso pide instanciar explícitamente una
primitiva de doble puerto (un XPM) en lugar de esperar a que Vivado infiera la buena, y no está
hecho.

El coste de `comb_bank` son 2034 LUT por banco, y el grueso **no** son los sumadores (4 restas
de 36 bits, ~144 LUT) sino los **multiplexores 32:1** que leen el array de estado por índice.
Bajar de ahí pide poner ese estado en BRAM y pipelinear la ronda en tres etapas —leer, calcular,
escribir—. Tampoco está hecho.

> **Cambia la interfaz:** con los peines compartidos los canales **ya no salen todos en el mismo
> ciclo**. El canal que ocupa la unidad *u* de su banco sale *u* ciclos después del diezmado, y
> `ch_valid` marca cada uno lo suyo. Los valores son idénticos bit a bit —lo comprueban
> `tb_comb_bank` y `tb_scanner_top`—, solo se reordenan en el tiempo. Si necesitas una foto
> simultánea de todos los canales, espera a que la ronda termine: dura `UNITS_PER_BANK` ciclos.

Ojo con el Fmax: 220 MHz es **post-síntesis y optimista**. Falta rutar, y en modo OOC sin
`HD.CLK_SRC` tampoco se modela el *skew* de reloj. El número bueno sale de la implementación
completa.

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
- **La ROM del NCO se replica a partir de cierto tamaño.** Vivado usa 1 RAMB18 por canal hasta
  32 canales y 2 a partir de 64, sin que el RTL cambie. Es lo que mantiene el techo en 144 en
  vez de 191. Forzarlo con `-max_bram` cuesta +214 LUT/canal y sale peor; haría falta instanciar
  una primitiva de doble puerto explícita.

- **Sin AXI4-Lite.** La interfaz de registros es síncrona y sencilla a propósito. Envolverla es
  un paso de Vivado.
- **La LUT no está compartida entre canales.** Cada `nco` infiere su propia BRAM. Parece el
  primer sitio donde optimizar, pero se midió y **no compensa**: ver "Por qué compartir la LUT
  del NCO no sirve" más arriba. El recurso crítico es el LUT, no la BRAM.
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
