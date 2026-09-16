# ---------------------------------------------------------------------------
# fold_check.tcl - The folded version against the original, in area.
#
# The question is simple and cannot be answered by simulating: with the SAME
# channels, does folding really save area or does it just move it somewhere
# else?
#
# Folding removes N_CH-N_SET sets of NCO, mixer and integrators, but puts in a
# slot-indexed state array in exchange. If Vivado infers it as distributed
# LUTRAM the saving is real; if it puts it in flip-flops -- which is what it
# did with comb_bank when that was reset -- folding can come out even more
# expensive. Synthesis is the only referee.
#
# Usage (from a short-path directory with sin_lut.mem in it):
#     vivado -mode batch -nojournal -notrace \
#            -source <repo>/syn/fold_check.tcl -tclargs 16 4
#
# Arguments: N_CH and FOLD. Leaves <N>ch_fold<F>_util.rpt and ..._timing.rpt.
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

# What matters, on stdout, so the reports do not have to be opened.
puts ""
puts "=== N_CH=$n  FOLD=$fold ==="
set fh [open ${tag}_util.rpt r]
set txt [read $fh]
close $fh
foreach row {"CLB LUTs" "CLB Registers" "Block RAM Tile" "DSPs"} {
    foreach line [split $txt "
"] {
        if {[string match "|*$row*|*" $line]} {
            set fields [split $line "|"]
            puts [format "  %-16s %8s" $row [string trim [lindex $fields 2]]]
            break
        }
    }
}
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts [format "  %-16s %8.3f ns   ->  Fmax %.2f MHz" WNS $wns [expr {1000.0/(10.0-$wns)}]]
puts ""
