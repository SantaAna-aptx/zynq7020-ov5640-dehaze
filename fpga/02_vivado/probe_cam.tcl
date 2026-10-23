# Minimal probe: what does Vivado infer from the camera_top module reference?
create_project -force probe_cam ./probe_cam -part xc7z020clg400-2
add_files -norecurse [glob ../04_camera/rtl/*.v]
update_compile_order -fileset sources_1

create_bd_design "probe"
set cell [create_bd_cell -type module -reference camera_top cam0]

puts "-------- INTERFACE PINS --------"
foreach p [get_bd_intf_pins -of_objects $cell] { puts "  intf: $p" }

puts "-------- SCALAR PINS (first 40) --------"
set i 0
foreach p [get_bd_pins -of_objects $cell] {
    puts "  pin : $p"
    incr i
    if {$i >= 40} break
}
exit 0
