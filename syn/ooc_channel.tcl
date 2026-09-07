# ---------------------------------------------------------------------------
# ooc_channel.tcl — Sintesis out-of-context de UN ddc_channel.
#
# Mide el coste del ladrillo que despues se replica N veces en scanner_top.
# No crea proyecto: solo lee el RTL, sintetiza y saca los informes.
#
# Uso (desde un directorio de trabajo con RUTA CORTA, ver aviso abajo):
#     cp <repo>/rtl/sin_lut.mem .
#     vivado -mode batch -nojournal -notrace -source <repo>/syn/ooc_channel.tcl
#
# AVISO EN WINDOWS: si el directorio de trabajo tiene una ruta larga (~250
# caracteres) las herramientas fallan con "Failed to compile generated C file".
# No es el diseno: es el gcc interno. Trabaja desde una ruta corta.
#
# La LUT del NCO (sin_lut.mem) tiene que estar en el directorio de trabajo,
# porque nco.v la carga con $readmemh en tiempo de elaboracion.
# ---------------------------------------------------------------------------

set part xck26-sfvc784-2LV-c
set here [file dirname [file normalize [info script]]]
set rtl  [file join $here .. rtl]

read_verilog -sv [list \
    [file join $rtl nco.v] \
    [file join $rtl cic_decim.v] \
    [file join $rtl ddc_channel.v]]

# El reloj va en un XDC leido con read_xdc: create_clock suelto en el Tcl falla
# con "No open design", porque necesita un diseno ya abierto.
read_xdc [file join $here clk.xdc]

synth_design -top ddc_channel -part $part -mode out_of_context

report_utilization     -file util.rpt
report_timing_summary  -delay_type max -file timing.rpt

set wns  [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / (10.0 - $wns)}]

puts "=== ddc_channel, out-of-context sobre $part ==="
puts [format "  WNS  = %.3f ns" $wns]
puts [format "  Fmax = %.2f MHz  (post-sintesis, sin rutar: optimista)" $fmax]
