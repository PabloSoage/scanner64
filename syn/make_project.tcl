# ---------------------------------------------------------------------------
# make_project.tcl — Monta un proyecto de Vivado con todo listo.
#
# Crea el proyecto, mete el RTL y los tres testbenches, configura el include
# path y deja los vectores donde el simulador los busca. Al terminar puedes
# abrir la GUI y darle a "Run Simulation" o a "Open Elaborated Design" sin
# tocar nada mas.
#
# Uso (desde cualquier sitio, con una RUTA CORTA de destino):
#     vivado -mode batch -source <repo>/syn/make_project.tcl -tclargs C:/kv/s64
#
# Y luego:
#     vivado C:/kv/s64/scanner64.xpr
#
# Sin argumento, el proyecto se crea en ../scanner64_vivado, al lado del repo.
#
# AVISO: Vivado en Windows se atraganta con rutas largas. Si la ruta del
# proyecto pasa de ~200 caracteres veras errores raros del estilo
# "Failed to compile generated C file". No es tu diseno.
#
# El proyecto se puede regenerar cuando quieras: este script usa -force, asi
# que borra y rehace. No guardes nada dentro que te importe.
# ---------------------------------------------------------------------------

set part  xck26-sfvc784-2LV-c
set pname scanner64

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]

set pdir [lindex $argv 0]
if {$pdir eq ""} {
    set pdir [file normalize [file join $root .. scanner64_vivado]]
}

puts "Creando proyecto en $pdir"
create_project $pname $pdir -part $part -force

# ---- Fuentes de diseno -----------------------------------------------------
add_files -fileset sources_1 [glob [file join $root rtl *.v]]

# La LUT del NCO. Vivado la reconoce como fichero de inicializacion de memoria
# y la deja donde la sintesis pueda leerla.
add_files -fileset sources_1 [file join $root rtl sin_lut.mem]
set_property file_type {Memory Initialization Files} \
    [get_files [file join $root rtl sin_lut.mem]]

set_property top scanner_top [get_filesets sources_1]

# ---- Fuentes de simulacion -------------------------------------------------
add_files -fileset sim_1 [glob [file join $root tb *.v]]

# params.vh y params_bank.vh viven aqui, y los testbenches los incluyen.
set_property include_dirs [list [file join $root tb vectors]] [get_filesets sim_1]

# Testbench por defecto: el del banco completo, que es el que mas prueba.
# Para cambiarlo, en la GUI: Sources > Simulation Sources > boton derecho
# sobre el testbench que quieras > Set as Top.
set_property top tb_scanner_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Correr hasta el $finish del testbench en vez de pararse a los 1000 ns.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# ---- Vectores donde el simulador los busca ---------------------------------
# Los testbenches hacen $readmemh("vectors/stim.hex", ...), con ruta RELATIVA
# al directorio de trabajo de xsim. En un proyecto ese directorio es
# <proj>.sim/sim_1/behav/xsim, asi que los vectores y la LUT van ahi.
set simwork [file join $pdir ${pname}.sim sim_1 behav xsim]
file mkdir $simwork
file copy -force [file join $root rtl sin_lut.mem] $simwork
if {[file exists [file join $simwork vectors]]} {
    file delete -force [file join $simwork vectors]
}
file copy -force [file join $root tb vectors] $simwork

puts ""
puts "== Proyecto listo =="
puts "  abrelo con:  vivado [file join $pdir ${pname}.xpr]"
puts ""
puts "  Run Simulation      -> corre tb_scanner_top y para en el \$finish"
puts "  Open Elaborated     -> Schematic: el circuito tal y como lo escribiste"
puts "  Run Synthesis       -> Schematic: el circuito en LUT, FF, DSP y BRAM"
puts "                         + Report Utilization y Report Timing Summary"
puts ""
