# ---------------------------------------------------------------------------
# fold_check.tcl — El plegado contra el original, en area.
#
# La pregunta es sencilla y no se puede contestar simulando: con los MISMOS
# canales, ¿plegar ahorra area de verdad o solo la mueve de sitio?
#
# El plegado quita N_CH-N_SET juegos de NCO, mezclador e integradores, pero
# mete a cambio un array de estado indexado por ranura. Si Vivado lo infiere
# como LUTRAM distribuida, el ahorro es real; si lo pone en flip-flops --que es
# lo que hizo con comb_bank cuando se le reseteaba-- el plegado puede salir
# incluso mas caro. La sintesis es el unico arbitro.
#
# Uso (desde un directorio de ruta corta con sin_lut.mem dentro):
#     vivado -mode batch -nojournal -notrace \
#            -source <repo>/syn/fold_check.tcl -tclargs 16 4
#
# Argumentos: N_CH y FOLD. Deja <N>ch_fold<F>_util.rpt y ..._timing.rpt.
# ---------------------------------------------------------------------------

set part xck26-sfvc784-2LV-c
set here [file dirname [file normalize [info script]]]
set rtl  [file join $here .. rtl]

set n [lindex $argv 0]
if {$n eq ""} { set n 16 }
set fold [lindex $argv 1]
if {$fold eq ""} { set fold 1 }

read_verilog [list \
    [file join $rtl nco.v] \
    [file join $rtl cic_integ.v] \
    [file join $rtl comb_chain.v] \
    [file join $rtl comb_bank.v] \
    [file join $rtl ddc_front.v] \
    [file join $rtl ddc_fold.v] \
    [file join $rtl scanner_top.v]]

read_xdc [file join $here clk.xdc]

synth_design -top scanner_top -part $part -mode out_of_context \
             -generic N_CH=$n -generic FOLD=$fold

set tag "${n}ch_fold${fold}"
report_utilization -file ${tag}_util.rpt
report_timing_summary -file ${tag}_timing.rpt

# Lo que importa, en la salida, para no tener que abrir los informes.
puts ""
puts "=== N_CH=$n  FOLD=$fold ==="
set fh [open ${tag}_util.rpt r]
set txt [read $fh]
close $fh
foreach fila {"CLB LUTs" "CLB Registers" "Block RAM Tile" "DSPs"} {
    foreach linea [split $txt "
"] {
        if {[string match "|*$fila*|*" $linea]} {
            set campos [split $linea "|"]
            puts [format "  %-16s %8s" $fila [string trim [lindex $campos 2]]]
            break
        }
    }
}
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts [format "  %-16s %8.3f ns   ->  Fmax %.2f MHz" WNS $wns [expr {1000.0/(10.0-$wns)}]]
puts ""
