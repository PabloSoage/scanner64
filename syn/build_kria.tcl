# ---------------------------------------------------------------------------
# build_kria.tcl — Del RTL al bitstream para la KV260, de una tacada.
#
# Monta el proyecto, crea el block design (Zynq UltraScale+ MPSoC + AXI4-Lite
# hacia scanner_axi), sintetiza, implementa y genera el bitstream.
#
# Uso (desde un directorio de trabajo con RUTA CORTA):
#     vivado -mode batch -source <repo>/syn/build_kria.tcl -tclargs C:/kv/bit 16
#
# El segundo argumento es N_CH (16 por defecto).
#
# Al terminar deja:
#     <dir>/scanner64_kria.runs/impl_1/design_1_wrapper.bit
#     <dir>/scanner64_kria.gen/.../design_1.hwh      (para el device tree)
#
# NO hace falta AXI DMA para validar el diseno: sig_source genera el estimulo
# dentro de la PL y las potencias se leen por registros. El DMA solo hara falta
# el dia que se quiera volcar I/Q de forma continua.
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

puts "== Proyecto en $outdir, N_CH=$n_ch =="
create_project $pname $outdir -part $part -force
set_property board_part $board [current_project]

# ---- Fuentes ---------------------------------------------------------------
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

# El PS, con el preset de la placa: eso ya deja pl_clk0 y los relojes bien.
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config \
    {apply_board_preset "1"} $ps

# UN solo maestro AXI (HPM0_FPD) y pl_clk0 a 100 MHz. GP1 hay que APAGARLO:
# el preset de la placa lo deja encendido, y un maestro encendido pero sin
# conectar deja su reloj suelto -> [BD 41-758] clock pins not connected.
# 100 MHz va sobradisimo: el diseno cierra a 170 MHz post-rutado.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $ps

# El escaner, como modulo RTL: Vivado infiere la interfaz AXI4-Lite por los
# nombres s_axi_*, asi que no hace falta empaquetarlo como IP.
set scan [create_bd_cell -type module -reference scanner_axi scanner_axi_0]
set_property -dict [list CONFIG.N_CH $n_ch] $scan

# La automatizacion crea el smartconnect y el reset processor system, y conecta
# relojes y resets. Es lo que uno haria a mano en la GUI.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config \
    [list Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Clk {Auto}] \
    [get_bd_intf_pins scanner_axi_0/s_axi]

# NO fijar CONFIG.FREQ_HZ a mano en el pin de reloj: el PLL del PS no da
# 100 MHz exactos sino 99999001 Hz, y validate_bd_design aborta con
#   [BD 41-238] Port/Pin property FREQ_HZ does not match
# Vivado propaga la frecuencia real el solo. El warning de 'no FREQ_HZ'
# que suelta al inferir la interfaz es inofensivo.

assign_bd_address
validate_bd_design

save_bd_design
set bd_file [get_files design_1.bd]
make_wrapper -files $bd_file -top -import

set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- Sintesis, implementacion y bitstream ---------------------------------
puts "== Sintesis =="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: la sintesis fallo"
    exit 1
}

puts "== Implementacion y bitstream =="
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: la implementacion fallo"
    exit 1
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts ""
puts "=== LISTO ==="
puts [format "  WNS a 100 MHz : %.3f ns" $wns]
puts [format "  Fmax          : %.2f MHz" [expr {1000.0/(10.0-$wns)}]]
report_utilization -file [file join $outdir utilization.rpt]
puts "  bitstream     : [glob -nocomplain $outdir/$pname.runs/impl_1/*.bit]"
puts "  hwh           : [glob -nocomplain $outdir/$pname.gen/sources_1/bd/design_1/hw_handoff/*.hwh]"
puts ""
