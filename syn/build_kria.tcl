# ---------------------------------------------------------------------------
# build_kria.tcl - From RTL to a KV260 bitstream, in one go.
#
# Builds the project, creates the block design (Zynq UltraScale+ MPSoC +
# AXI4-Lite to scanner_axi), synthesises, implements and generates the
# bitstream.
#
# Usage (from a working directory with a SHORT PATH):
#     vivado -mode batch -source <repo>/syn/build_kria.tcl -tclargs C:/kv/bit 16
#
# The second argument is N_CH (16 by default).
#
# When it finishes it leaves:
#     <dir>/scanner64_kria.runs/impl_1/design_1_wrapper.bit
#     <dir>/scanner64_kria.gen/.../design_1.hwh      (for the device tree)
#
# You do NOT need an AXI DMA to validate the design: sig_source generates the
# stimulus inside the PL and the powers are read through registers. DMA will
# only be needed the day you want to stream I/Q out continuously.
# ---------------------------------------------------------------------------

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]

set outdir [lindex $argv 0]
if {$outdir eq ""} { set outdir [file normalize [file join $root .. scanner64_kria]] }
set n_ch [lindex $argv 1]
if {$n_ch eq ""} { set n_ch 16 }

set pname  scanner64_kria
set part   xck26-sfvc784-2LV-c
set board  xilinx.com:kv260_som:part0:2.0

puts "== Project in $outdir, N_CH=$n_ch =="
create_project $pname $outdir -part $part -force
set_property board_part $board [current_project]

# ---- Sources ---------------------------------------------------------------
add_files -fileset sources_1 [list \
    [file join $root rtl nco.v] \
    [file join $root rtl cic_integ.v] \
    [file join $root rtl comb_chain.v] \
    [file join $root rtl cic_decim.v] \
    [file join $root rtl comb_bank.v] \
    [file join $root rtl ddc_front.v] \
    [file join $root rtl ddc_channel.v] \
    [file join $root rtl scanner_top.v] \
    [file join $root rtl sig_source.v] \
    [file join $root rtl scanner_axi.v]]

add_files -fileset sources_1 [file join $root rtl sin_lut.mem]
set_property file_type {Memory Initialization Files} \
    [get_files [file join $root rtl sin_lut.mem]]

update_compile_order -fileset sources_1

# ---- Block design ----------------------------------------------------------
create_bd_design "design_1"

# The PS, with the board preset: that already sets up pl_clk0 and the clocks.
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config \
    {apply_board_preset "1"} $ps

# ONE single AXI master (HPM0_FPD) and pl_clk0 at 100 MHz. GP1 has to be
# TURNED OFF: the board preset leaves it on, and a master that is on but
# unconnected leaves its clock dangling -> [BD 41-758] clock pins not
# connected. 100 MHz is far more than enough: the design closes at 170 MHz
# post-route.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $ps

# The scanner, as an RTL module: Vivado infers the AXI4-Lite interface from the
# s_axi_* names, so there is no need to package it as IP.
set scan [create_bd_cell -type module -reference scanner_axi scanner_axi_0]
set_property -dict [list CONFIG.N_CH $n_ch] $scan

# The automation creates the smartconnect and the processor system reset, and
# wires up clocks and resets. It is what you would do by hand in the GUI.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    [list Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Clk {Auto}] \
    [get_bd_intf_pins scanner_axi_0/s_axi]

# Do NOT set CONFIG.FREQ_HZ by hand on the clock pin: the PS PLL does not give
# exactly 100 MHz but 99999001 Hz, and validate_bd_design aborts with
#   [BD 41-238] Port/Pin property FREQ_HZ does not match
# Vivado propagates the real frequency on its own. The 'no FREQ_HZ' warning it
# emits while inferring the interface is harmless.

assign_bd_address
validate_bd_design

save_bd_design
set bd_file [get_files design_1.bd]
make_wrapper -files $bd_file -top -import

set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- Synthesis, implementation and bitstream -------------------------------
puts "== Synthesis =="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: synthesis failed"
    exit 1
}

puts "== Implementation and bitstream =="
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: implementation failed"
    exit 1
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts ""
puts "=== DONE ==="
puts [format "  WNS at 100 MHz : %.3f ns" $wns]
puts [format "  Fmax           : %.2f MHz" [expr {1000.0/(10.0-$wns)}]]
report_utilization -file [file join $outdir utilization.rpt]
puts "  bitstream      : [glob -nocomplain $outdir/$pname.runs/impl_1/*.bit]"
puts "  hwh            : [glob -nocomplain $outdir/$pname.gen/sources_1/bd/design_1/hw_handoff/*.hwh]"
puts ""
