# ============================================================================
#  build.tcl  --  Vivado HLS 2019.1 project for dehaze_top
#  Run from this directory (01_hls):
#      vivado_hls -f build.tcl
#
#  Stage selection via environment variable VHLS_STAGE:
#      csim   : C simulation only (fast, checks numerics against the Python ref)
#      csynth : synthesize only (resources / timing estimate)
#      export : export the IP catalog only (reuses the existing solution)
#      all    : csim + csynth + export IP        (default)
#
#  NOTE: only 'export' reuses the on-disk solution; the other stages reset the
#        project first. Never run a reset stage and then expect 'export' to work
#        without a fresh synthesis.
# ============================================================================
set proj_name  "proj_dehaze"
set part_name  "xc7z020clg400-2"
set top_func   "dehaze_top"
set clk_period "20"          ;# ns -> 50 MHz, matches PS7 FCLK0 on MZ7X

if {[info exists ::env(VHLS_STAGE)]} {
    set stage $::env(VHLS_STAGE)
} else {
    set stage "all"
}

if {$stage eq "export"} {
    open_project $proj_name
    open_solution "sol1"
    set flow_reset 0
} else {
    set flow_reset 1
    open_project -reset $proj_name
    set_top $top_func
    add_files -cflags "-Isrc -std=c++11" src/dehaze_top.cpp
    add_files -tb -cflags "-Isrc -Itv -std=c++11" tb/dehaze_tb.cpp
    open_solution -reset "sol1"
    set_part $part_name
    create_clock -period $clk_period -name default

    config_interface -m_axi_addr64=0
    config_rtl -reset state
    config_compile -name_max_length 256
}

if {$stage eq "csim" || $stage eq "all"} {
    puts "=== C simulation ==="
    if {[catch {csim_design -clean} err]} {
        puts "CSIM FAILED: $err"
        exit 1
    }
}

if {$stage eq "csynth" || $stage eq "all"} {
    puts "=== C synthesis ==="
    if {[catch {csynth_design} err]} {
        puts "CSYNTH FAILED: $err"
        exit 1
    }
    puts "=== reports under proj_dehaze/sol1/syn/report/ ==="
}

if {$stage eq "all" || $stage eq "export"} {
    puts "=== export IP ==="
    if {[catch {
        export_design -format ip_catalog -vendor "dehaze.local" -library "hls" \
                      -version "1.0" -ipname "dehaze_top" \
                      -description "Dark channel prior dehazing"
    } err]} {
        puts "EXPORT FAILED: $err"
        exit 1
    }
    puts "IP repo: proj_dehaze/sol1/impl/ip"
}

puts "=== done: $stage ==="
close_project
exit 0
