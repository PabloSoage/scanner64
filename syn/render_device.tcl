# ---------------------------------------------------------------------------
# render_device.tcl - Pictures of a built KV260 project for the README.
#
# Writes the block design as SVG, then opens the routed design and highlights
# every channel's front end (NCO + mixer + integrators) in its own colour, the
# shared comb banks in white and the signal source in grey. It leaves the GUI
# open on the device view, for a screenshot of that window.
#
# Usage (GUI mode, on a project from build_kria.tcl):
#     vivado -mode gui -source <repo>/syn/render_device.tcl -tclargs <dir>/scanner64_kria.xpr <out dir>
# ---------------------------------------------------------------------------
lassign $argv xpr out
file mkdir $out
open_project $xpr
open_bd_design [get_files design_1.bd]
write_bd_layout -force -format svg -orientation landscape $out/block_design.svg
close_bd_design [current_bd_design]

open_run impl_1 -name impl_1
proc leaves {cell} {
    current_instance $cell
    set l [get_cells -quiet -hier -filter {IS_PRIMITIVE}]
    current_instance
    return $l
}
set palette {
    {230 25 75} {60 180 75} {255 225 25} {0 130 200} {245 130 48} {145 30 180} {70 240 240}
    {240 50 230} {210 245 60} {250 190 212} {0 128 128} {220 190 255} {170 110 40}
    {255 250 200} {128 0 0} {170 255 195}
}
set i 0
foreach u [get_cells -hier -filter {REF_NAME =~ *ddc_front* && IS_PRIMITIVE == 0}] {
    highlight_objects -rgb [lindex $palette [expr {$i % [llength $palette]}]] [leaves $u]
    incr i
}
foreach u [get_cells -hier -filter {REF_NAME =~ *comb_bank* && IS_PRIMITIVE == 0}] {
    highlight_objects -rgb {255 255 255} [leaves $u]
}
foreach u [get_cells -hier -filter {REF_NAME =~ *sig_source* && IS_PRIMITIVE == 0}] {
    highlight_objects -rgb {150 150 150} [leaves $u]
}
puts "render_device.tcl: $i channels highlighted"
set fh [open $out/ready w]
puts $fh $i
close $fh
