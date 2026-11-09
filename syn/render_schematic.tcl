# ---------------------------------------------------------------------------
# render_schematic.tcl - Schematics for the README, as SVG.
#
# Elaborates the RTL (no synthesis) of one complete channel (ddc_channel: the
# front end and the two comb chains) and of its front end (ddc_front: NCO,
# mixer, CIC integrators), and writes each schematic.
#
# Usage (GUI mode; it exits by itself):
#     vivado -mode gui -source <repo>/syn/render_schematic.tcl -tclargs <out dir>
# ---------------------------------------------------------------------------
lassign $argv out
file mkdir $out
set root [file dirname [file dirname [file normalize [info script]]]]
read_verilog [glob [file join $root rtl *.v]]
read_mem [file join $root rtl sin_lut.mem]
proc draw {top generics name file} {
    set g [expr {[llength $generics] ? [list -generic $generics] : {}}]
    synth_design -rtl -top $top -part xck26-sfvc784-2LV-c {*}$g
    show_schematic -name $name [concat [get_cells] [get_ports] [get_nets]]
    write_schematic -force -format svg -orientation landscape -scope all -name $name $file
    close_design
}
draw ddc_channel {} channel $out/ddc_channel.svg
draw ddc_front {} front $out/ddc_front.svg
puts "render_schematic.tcl: done"
exit
