# OOC synthesis of ddc_fold on its own, to find out how much each piece weighs.
#     vivado -mode batch -nojournal -notrace -source ooc_fold.tcl -tclargs 16
set part xck26-sfvc784-2LV-c
set here [file dirname [file normalize [info script]]]
set rtl  [file join $here .. rtl]
set fold [lindex $argv 0]
if {$fold eq ""} { set fold 16 }
read_verilog [list [file join $rtl ddc_fold.v]]
read_xdc [file join $here clk.xdc]
synth_design -top ddc_fold -part $part -mode out_of_context -generic FOLD=$fold
report_utilization -file fold_solo_f${fold}.rpt
puts ""
puts "=== ddc_fold alone, FOLD=$fold  ($fold channels) ==="
set fh [open fold_solo_f${fold}.rpt r]
set txt [read $fh]
close $fh
foreach row {"CLB LUTs" "CLB Registers" "LUT as Distributed RAM" "Block RAM Tile" "DSPs"} {
    foreach line [split $txt "\n"] {
        if {[string match "|*$row*|*" $line]} {
            set fields [split $line "|"]
            set v [string trim [lindex $fields 2]]
            puts [format "  %-24s %8s   (%.1f per channel)" $row $v [expr {double($v)/$fold}]]
            break
        }
    }
}
puts ""
