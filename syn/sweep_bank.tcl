# ---------------------------------------------------------------------------
# sweep_bank.tcl — Barrido de N_CH sobre scanner_top.
#
# Sintetiza el banco completo out-of-context para un N_CH dado y deja los
# informes. Repetido sobre varios N_CH da la curva de coste por canal, que es
# lo que dice hasta donde se puede subir.
#
# Uso (desde un directorio de trabajo con ruta corta, con sin_lut.mem dentro):
#     vivado -mode batch -nojournal -notrace \
#            -source <repo>/syn/sweep_bank.tcl -tclargs 16
#
# Tercer argumento opcional: limite de BRAM tiles, para experimentar con el
# reparto BRAM/LUT. Ver la nota sobre esto en el README, seccion "Exprimirla
# de verdad": forzarlo sale caro y empeora el techo.
#     ... -tclargs 16 8
# ---------------------------------------------------------------------------

set part xck26-sfvc784-2LV-c
set here [file dirname [file normalize [info script]]]
set rtl  [file join $here .. rtl]

set n [lindex $argv 0]
if {$n eq ""} { set n 16 }
set max_bram [lindex $argv 1]

read_verilog -sv [list \
    [file join $rtl nco.v] \
    [file join $rtl cic_decim.v] \
    [file join $rtl ddc_channel.v] \
    [file join $rtl scanner_top.v]]

read_xdc [file join $here clk.xdc]

if {$max_bram eq ""} {
    synth_design -top scanner_top -part $part -mode out_of_context \
                 -generic N_CH=$n
} else {
    synth_design -top scanner_top -part $part -mode out_of_context \
                 -generic N_CH=$n -max_bram $max_bram
}

report_utilization    -file util_n$n.rpt
report_timing_summary -delay_type max -file timing_n$n.rpt

set wns  [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / (10.0 - $wns)}]

puts "=== scanner_top N_CH=$n sobre $part ==="
puts [format "  WNS  = %.3f ns" $wns]
puts [format "  Fmax = %.2f MHz  (post-sintesis, sin rutar: optimista)" $fmax]
