# ---------------------------------------------------------------------------
# make_project.tcl - Builds a Vivado project with everything ready.
#
# Creates the project, adds the RTL and the testbenches, sets the include path
# and leaves the vectors where the simulator looks for them. When it finishes
# you can open the GUI and hit "Run Simulation" or "Open Elaborated Design"
# without touching anything else.
#
# Usage (from anywhere, with a SHORT destination PATH):
#     vivado -mode batch -source <repo>/syn/make_project.tcl -tclargs C:/kv/s64
#
# And then:
#     vivado C:/kv/s64/scanner64.xpr
#
# With no argument, the project is created in ../scanner64_vivado, next to the
# repo.
#
# WHAT IT IS FOR AND WHAT IT IS NOT. This project is for SIMULATING and for
# looking at the schematic, the utilisation and the timing of scanner_top. It
# does NOT produce a bitstream: synthesis runs out of context because
# scanner_top is a block, not a chip. The KV260 bitstream is built by
# syn/build_kria.tcl.
#
# WARNING: Vivado on Windows chokes on long paths. If the project path goes
# past ~200 characters you will see odd errors of the form "Failed to compile
# generated C file". It is not your design.
#
# The project can be regenerated whenever you like: this script uses -force, so
# it deletes and rebuilds. Do not keep anything you care about inside it.
# ---------------------------------------------------------------------------

set part  xck26-sfvc784-2LV-c
set pname scanner64

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]

set pdir [lindex $argv 0]
if {$pdir eq ""} {
    set pdir [file normalize [file join $root .. scanner64_vivado]]
}

puts "Creating project in $pdir"
create_project $pname $pdir -part $part -force

# ---- Design sources --------------------------------------------------------
add_files -fileset sources_1 [glob [file join $root rtl *.v]]

# The NCO LUT. Vivado recognises it as a memory initialisation file and leaves
# it where synthesis can read it.
add_files -fileset sources_1 [file join $root rtl sin_lut.mem]
set_property file_type {Memory Initialization Files} \
    [get_files [file join $root rtl sin_lut.mem]]

set_property top scanner_top [get_filesets sources_1]

# ---- OUT-OF-CONTEXT synthesis ----------------------------------------------
# THIS PROJECT DOES NOT PRODUCE A BITSTREAM, AND MUST NOT TRY TO.
#
# scanner_top is an internal block, not a chip. If Vivado treats it as the
# FPGA's top level it gives every port a PHYSICAL pin: in_data, cfg_ftw,
# rd_pwr, pwr_ready, tap_i/tap_q... that comes to 197 pins and the KV260's
# XCK26 exposes 189. Hence the errors you see if you hit "Run Implementation":
#
#   [Place 30-58]  IO placement is infeasible. 197 unplaced IO Ports > 189 pins
#   [Place 30-374] IO placer failed to find a solution
#   [Power 33-333] The Vccint supply current exceeds the maximum limit
#
# None of them is a problem with the design. The I/O one is pin arithmetic, and
# the Vccint one is the power estimator assuming 197 output buffers switch at
# once, which is precisely what will never happen.
#
# In out-of-context mode Vivado does NOT insert I/O buffers: it synthesises the
# block as what it is, a module that will go inside something larger. That
# gives the real utilisation and timing, which is what this project is for.
#
# THE BITSTREAM IS BUILT BY syn/build_kria.tcl, which wraps the scanner in
# scanner_axi and hangs it off the PS over AXI4-Lite. There the only real pins
# are the PS's -- which do not consume user pins -- and implementation closes.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context} -objects [get_runs synth_1]

# Without a create_clock the timing report says nothing. This is the same
# starting period the sweep's OOC synthesis uses.
add_files -fileset constrs_1 [file join $root syn clk.xdc]

# ---- Simulation sources ----------------------------------------------------
add_files -fileset sim_1 [glob [file join $root tb *.v]]

# params.vh and params_bank.vh live here, and the testbenches include them.
set_property include_dirs [list [file join $root tb vectors]] [get_filesets sim_1]

# Default testbench: the whole-bank one, which tests the most. To change it,
# in the GUI: Sources > Simulation Sources > right-click the testbench you want
# > Set as Top.
set_property top tb_scanner_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Run to the testbench's $finish instead of stopping at 1000 ns.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# ---- Vectors where the simulator looks for them ----------------------------
# The testbenches do $readmemh("vectors/stim.hex", ...), with a path RELATIVE
# to xsim's working directory. In a project that directory is
# <proj>.sim/sim_1/behav/xsim, so the vectors and the LUT go there.
set simwork [file join $pdir ${pname}.sim sim_1 behav xsim]
file mkdir $simwork
file copy -force [file join $root rtl sin_lut.mem] $simwork
if {[file exists [file join $simwork vectors]]} {
    file delete -force [file join $simwork vectors]
}
file copy -force [file join $root tb vectors] $simwork

puts ""
puts "== Project ready =="
puts "  open it with:  vivado [file join $pdir ${pname}.xpr]"
puts ""
puts "  Run Simulation      -> runs tb_scanner_top and stops at the \$finish"
puts "  Open Elaborated     -> Schematic: the circuit as you wrote it"
puts "  Run Synthesis       -> Schematic: the circuit in LUTs, FFs, DSPs, BRAM"
puts "                         + Report Utilization and Report Timing Summary"
puts ""
puts "  Do NOT hit Run Implementation. This project synthesises scanner_top"
puts "  out of context, and it is a block, not a chip: its 197 ports do not fit"
puts "  in the XCK26's 189 pins and the placer fails. The bitstream is built by"
puts "  syn/build_kria.tcl, which wraps it in AXI4-Lite and hangs it off the"
puts "  PS."
puts ""
