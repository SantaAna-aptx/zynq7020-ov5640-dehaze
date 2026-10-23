# ============================================================================
#  build.tcl  --  Vivado 2019.1 batch flow for the pure-PL dehaze demo
#
#  Run from this directory (02_vivado):
#      vivado -mode batch -source build.tcl
#
#  Stages (env var VIVADO_STAGE):
#      bd     : project + block design + wrapper only (fast sanity check)
#      bit    : bd + synthesis + implementation + bitstream  (default)
#      hdf    : bit + export hardware handoff (.hdf) for SDK
#
#  Expects the HLS IP at ../01_hls/proj_dehaze/sol1/impl/ip
# ============================================================================
set part_name "xc7z020clg400-2"
set proj_name "dehaze_vivado"
set proj_dir  "./vivado"
set out_dir   "./output"
set hls_ip    "../01_hls/proj_dehaze/sol1/impl/ip"

if {[info exists ::env(VIVADO_STAGE)]} {
    set stage $::env(VIVADO_STAGE)
} else {
    set stage "hdf"
}

if {![file exists $hls_ip/component.xml]} {
    error "HLS IP not found at $hls_ip. Run 01_hls/build.tcl with VHLS_STAGE=all first."
}

file mkdir $out_dir
create_project -force $proj_name $proj_dir -part $part_name
set_property ip_repo_paths [file normalize $hls_ip] [current_project]
update_ip_catalog -rebuild

# ---------------------------------------------------------------- camera RTL
# Plain Verilog modules referenced from the block design (not packaged as IP).
# They must be in the project before the BD tries to reference them.
set cam_rtl [glob -nocomplain ../04_camera/rtl/*.v]
if {[llength $cam_rtl] > 0} {
    add_files -norecurse $cam_rtl
    puts "INFO: added [llength $cam_rtl] camera RTL file(s)"
} else {
    puts "WARNING: no camera RTL found, block design will not elaborate"
}

if {[file exists ./camera.xdc]} {
    add_files -fileset constrs_1 -norecurse ./camera.xdc
    # LATE processing: camera.xdc declares the pixel clock and the asynchronous
    # relationship to FCLK0. The PS clock only exists once the PS7's generated
    # constraints have been applied, and those come after the user XDC by
    # default -- which made `get_clocks clk_fpga_0` return nothing and turned the
    # clock-group constraint into a silent no-op (two builds were spent on that).
    # Processing this file late makes both clock objects visible.
    set_property PROCESSING_ORDER LATE [get_files camera.xdc]
    puts "INFO: added camera.xdc (processed LATE so the PS clock is visible)"
}

source ./create_bd.tcl

# wrapper
set bd_files [get_files system.bd]
make_wrapper -files $bd_files -top -import
set wrapper [get_files system_wrapper.v]

set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: wrapper = $wrapper"
puts "INFO: sources = [llength [get_files -of_objects [get_filesets sources_1]]]"

if {$stage eq "bd"} {
    puts "=== bd stage done ==="
    exit 0
}

# ---------------------------------------------------------------- build
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synthesis failed, see $proj_dir/$proj_name.runs/synth_1/runme.log"
}
puts "INFO: synthesis done"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "implementation failed, see $proj_dir/$proj_name.runs/impl_1/runme.log"
}
puts "INFO: implementation done"

# ---------------------------------------------------------------- reports
open_run impl_1
report_utilization -file $out_dir/utilization.rpt
report_timing_summary -file $out_dir/timing_summary.rpt
report_utilization -hierarchical -file $out_dir/utilization_hier.rpt
puts "INFO: reports in $out_dir/"

# ---------------------------------------------------------------- timing gate
# Vivado only prints a CRITICAL WARNING when timing is missed; the build then
# carries on and produces a bitstream. That is exactly how two builds earlier
# shipped a design with 56 unconstrained clock-domain-crossing endpoints while
# the log looked "fine apart from one warning". Fail the build instead, and say
# what failed.
proc worst_slack {delay} {
    set paths [get_timing_paths -delay_type $delay -max_paths 1 -nworst 1 \
                   -quiet -slack_lesser_than 1e9]
    if {[llength $paths] == 0} { return 1e9 }
    return [get_property SLACK [lindex $paths 0]]
}

set wns [worst_slack max]
set whs [worst_slack min]
puts [format "INFO: worst setup slack = %.3f ns, worst hold slack = %.3f ns" $wns $whs]

if {$wns < 0.0} {
    set bad [get_timing_paths -delay_type max -max_paths 5 -nworst 1 -quiet \
                 -slack_lesser_than 0]
    foreach p $bad {
        puts [format "  VIOLATION %s -> %s : %s ns" \
                  [get_property STARTPOINT_PIN $p] \
                  [get_property ENDPOINT_PIN $p] \
                  [get_property SLACK $p]]
    }
    error "timing not met: worst setup slack ${wns} ns. Refusing to ship the bitstream."
}
if {$whs < 0.0} {
    error "hold time not met: worst hold slack ${whs} ns."
}

# The design must also have no clock-domain crossing that is still *required* to
# meet a single cycle. `get_timing_paths` returns connected-but-false-pathed
# paths too (with no numeric slack), so ask only for negative slack -- that is
# the condition that actually matters, and it is what bit us before.
set xclk [get_clocks -quiet clk_fpga_0]
set pclk [get_clocks -quiet cmos_pclk_clk]
if {[llength $xclk] > 0 && [llength $pclk] > 0} {
    set cross [get_timing_paths -from $pclk -to $xclk -max_paths 1 -nworst 1 \
                   -quiet -slack_lesser_than 0]
    if {[llength $cross] > 0} {
        error [format "unconstrained CDC: %s -> %s has slack %s ns" \
                   [get_property STARTPOINT_PIN [lindex $cross 0]] \
                   [get_property ENDPOINT_PIN [lindex $cross 0]] \
                   [get_property SLACK [lindex $cross 0]]]
    }
    puts "INFO: no setup-required paths between cmos_pclk_clk and clk_fpga_0 (CDC clean)"
}

set bit [glob $proj_dir/$proj_name.runs/impl_1/system_wrapper.bit]
file copy -force $bit $out_dir/system_wrapper.bit
puts "INFO: bitstream -> $out_dir/system_wrapper.bit"

if {$stage eq "bit"} {
    puts "=== bit stage done ==="
    exit 0
}

# ---------------------------------------------------------------- hdf (SDK handoff, 2019.1)
write_hwdef -force -file $out_dir/system.hwdef
write_sysdef -force -hwdef $out_dir/system.hwdef \
             -bitfile $out_dir/system_wrapper.bit \
             -file $out_dir/system.hdf
puts "INFO: hardware handoff -> $out_dir/system.hdf"

# ---------------------------------------------------------------- fpga_manager image
# Linux loads the PL through /sys/class/fpga_manager/fpga0/firmware, which wants
# a headerless, word-swapped .bin -- exactly what bootgen -process_bitstream
# produces. This is the JTAG-free programming path.
set bootgen "D:/vivado2019.1/VIVADO20191/SDK/2019.1/bin/bootgen.bat"
set bit_abs [file normalize $out_dir/system_wrapper.bit]
set bif     [file normalize $out_dir/dehaze_bin.bif]

set fh [open $bif w]
puts $fh "all:"
puts $fh "{"
puts $fh "    $bit_abs"
puts $fh "}"
close $fh

if {[file exists $bootgen]} {
    if {[catch {exec cmd /c "$bootgen -image $bif -process_bitstream bin -w on"} err]} {
        puts "WARNING: bootgen failed: $err"
    } else {
        set raw "${bit_abs}.bin"
        set dst [file normalize $out_dir/dehaze_top.bin]
        if {[file exists $raw]} {
            file rename -force $raw $dst
            puts "INFO: fpga_manager image -> $dst ([file size $dst] bytes)"
        } else {
            puts "WARNING: bootgen produced no output"
        }
    }
} else {
    puts "WARNING: bootgen not found at $bootgen, skip .bin generation"
}

puts "=== hdf stage done ==="
exit 0
