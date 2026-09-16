# ---------------------------------------------------------------------------
# sweep_bank.tcl - N_CH sweep over scanner_top.
#
# Synthesises the whole bank out-of-context for a given N_CH and leaves the
# reports. Repeated over several N_CH it gives the cost-per-channel curve,
# which is what tells you how far you can push it.
#
# Usage (from a working directory with a short path, with sin_lut.mem in it):
#     vivado -mode batch -nojournal -notrace \
#            -source <repo>/syn/sweep_bank.tcl -tclargs 16
#
# Optional third argument: a BRAM tile limit, to experiment with the BRAM/LUT
# split. See the note about this in the README, section "Pushing it properly":
# forcing it is expensive and makes the ceiling worse.
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

puts "=== scanner_top N_CH=$n on $part ==="
puts [format "  WNS  = %.3f ns" $wns]
puts [format "  Fmax = %.2f MHz  (post-synthesis, not routed: optimistic)" $fmax]
