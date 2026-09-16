set part xck26-sfvc784-2LV-c
set n    [lindex $argv 0]
set srcs [lrange $argv 1 end]
read_verilog -sv $srcs
read_xdc clk.xdc
synth_design -top scanner_top -part $part -mode out_of_context -generic N_CH=$n
# In OOC you have to say where the clock comes in, so the skew gets modelled.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_utilization    -file util_impl_n$n.rpt
report_timing_summary -file timing_impl_n$n.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set fh [open wns_impl_n$n.txt w]; puts $fh $wns; close $fh
puts "@@@ IMPL N_CH=$n  WNS=$wns  Fmax=[format %.2f [expr {1000.0/(10.0-$wns)}]] MHz"
