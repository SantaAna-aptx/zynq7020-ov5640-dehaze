# ============================================================================
#  run_jtag.tcl  --  push bitstream + image over JTAG, run, read the result back
#
#  Run from 03_baremetal, with the board powered and the JTAG cable attached:
#      xsct run_jtag.tcl
#
#  Sequence:
#    1. connect, reset the PS
#    2. download the bitstream
#    3. run ps7_init (DDR/MIO/PLL bring-up -- without it DDR is unusable)
#    4. download the ELF, then the raw image into 0x10000000
#    5. continue, poll the result block at 0x13000000 for MAGIC_DONE
#    6. dump 0x12000000 back to hw_out.bin
# ============================================================================
set BIT  "../02_vivado/output/system_wrapper.bit"
set ELF  "./ws/dehaze_app/Debug/dehaze_app.elf"
set INIT "./ws/hw/ps7_init.tcl"
set IMG  "../01_hls/tv/fog_in.bin"
set OUT  "../01_hls/tv/hw_out_board.bin"

set SRC_ADDR 0x10000000
set DST_ADDR 0x12000000
set RES_ADDR 0x13000000
set N_WORDS  738000
set MAGIC    0xD0DE0001

foreach f [list $BIT $ELF $INIT $IMG] {
    if {![file exists $f]} { error "missing input: $f" }
}

puts "=== connect ==="
connect
targets -set -filter {name =~ "APU*"}
rst -system
after 2000

puts "=== download bitstream ==="
fpga -file $BIT

puts "=== ps7 init (DDR / clocks / MIO) ==="
source $INIT
ps7_init
ps7_post_config

puts "=== download ELF + image ==="
targets -set -filter {name =~ "ARM*#0"}
rst -processor
dow $ELF
dow -data $IMG $SRC_ADDR
con

puts "=== wait for the core to finish ==="
set done 0
for {set i 0} {$i < 300} {incr i} {
    after 200
    set v [lindex [mrd -value $RES_ADDR] 0]
    if {$v == 0xD0DEBAD0} { error "target reported failure (magic 0xD0DEBAD0)" }
    if {$v == $MAGIC} { set done 1; break }
}
if {!$done} { error "timeout waiting for MAGIC_DONE at $RES_ADDR" }

puts "=== result block ==="
set r [mrd -value $RES_ADDR 6]
puts [format "  A word     = 0x%08x  (B=%d G=%d R=%d)" \
      [lindex $r 1] [expr {[lindex $r 1] & 0xFF}] \
      [expr {([lindex $r 1] >> 8) & 0xFF}] [expr {([lindex $r 1] >> 16) & 0xFF}]]
puts [format "  cycles     = %u" [lindex $r 2]]
puts [format "  checksum   = 0x%08x" [lindex $r 4]]

puts "=== read back output image ==="
stop
mrd -bin -file $OUT $DST_ADDR $N_WORDS
con
puts "OK: $OUT ([file size $OUT] bytes)"
puts "Next: python 00_tools/make_report.py --board"
