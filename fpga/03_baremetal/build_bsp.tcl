# ============================================================================
#  build_bsp.tcl  --  create + build the bare-metal BSP and app with XSCT
#
#  Run from 03_baremetal:
#      xsct build_bsp.tcl
#
#  Inputs : ../02_vivado/output/system.hdf   (produced by 02_vivado/build.tcl)
#  Outputs: ws/dehaze_app/Debug/dehaze_app.elf
#           ws/hw/ps7_init.tcl                (needed by the JTAG run script)
# ============================================================================
set hdf "../02_vivado/output/system.hdf"
set proc "ps7_cortexa9_0"

if {![file exists $hdf]} {
    error "hardware handoff not found: $hdf (run 02_vivado/build.tcl first)"
}

setws ./ws

# clean previous run so the BSP always matches the current .hdf
if {[file exists ./ws/hw]} {
    puts "INFO: removing previous workspace"
    file delete -force ./ws
    setws ./ws
}

puts "=== create hardware platform ==="
createhw -name hw -hwspec $hdf

puts "=== create BSP ==="
createbsp -name dehaze_bsp -hwproject hw -proc $proc -os standalone

puts "=== create app ==="
# NOTE: plain xsct exposes 'createapp'; the 'app create' form only exists in xsdk.
# Pin the app to our explicit BSP -- without -bsp, createapp silently makes a
# second, under-generated BSP (<app>_bsp) whose include/ lacks xparameters_ps.h.
createapp -name dehaze_app -bsp dehaze_bsp -hwproject hw -proc $proc \
          -os standalone -lang C -app {Empty Application}

file copy -force ./src/main.c ./ws/dehaze_app/src/main.c

puts "=== build BSP ==="
# Building the BSP is what populates include/ (xparameters_ps.h + driver headers).
projects -build -type bsp -name dehaze_bsp

puts "=== build app ==="
projects -build -type app -name dehaze_app

set elf "./ws/dehaze_app/Debug/dehaze_app.elf"
if {[file exists $elf]} {
    puts "OK: $elf ([file size $elf] bytes)"
} else {
    error "build failed, check ./ws/dehaze_app/Debug/*.log"
}

# the JTAG script needs ps7_init.tcl generated inside the hw project
foreach p [list ./ws/hw/ps7_init.tcl ./ws/hw/system/ps7_init.tcl] {
    if {[file exists $p]} { puts "OK: init script -> $p" }
}
exit 0
