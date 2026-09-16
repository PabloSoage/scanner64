# ---------------------------------------------------------------------------
# ooc_channel.tcl - Out-of-context synthesis of ONE ddc_channel.
#
# Measures the cost of the brick that later gets replicated N times inside
# scanner_top. It creates no project: it just reads the RTL, synthesises and
# writes the reports.
#
# Usage (from a working directory with a SHORT PATH, see the warning below):
#     cp <repo>/rtl/sin_lut.mem .
#     vivado -mode batch -nojournal -notrace -source <repo>/syn/ooc_channel.tcl
#
# WINDOWS WARNING: if the working directory has a long path (~250 characters)
# the tools fail with "Failed to compile generated C file". It is not the
# design: it is the internal gcc. Work from a short path.
#
# The NCO LUT (sin_lut.mem) has to be in the working directory, because nco.v
# loads it with $readmemh at elaboration time.
# ---------------------------------------------------------------------------

set part xck26-sfvc784-2LV-c
set here [file dirname [file normalize [info script]]]
set rtl  [file join $here .. rtl]

read_verilog -sv [list \
    [file join $rtl nco.v] \
    [file join $rtl cic_decim.v] \
    [file join $rtl ddc_channel.v]]

# The clock goes in an XDC read with read_xdc: a bare create_clock in the Tcl
# fails with "No open design", because it needs a design already open.
read_xdc [file join $here clk.xdc]

synth_design -top ddc_channel -part $part -mode out_of_context

report_utilization     -file util.rpt
report_timing_summary  -delay_type max -file timing.rpt

set wns  [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / (10.0 - $wns)}]

puts "=== ddc_channel, out-of-context on $part ==="
puts [format "  WNS  = %.3f ns" $wns]
puts [format "  Fmax = %.2f MHz  (post-synthesis, not routed: optimistic)" $fmax]
