#!/bin/sh
# ============================================================================
#  run_on_board.sh  --  run the PL dehaze demo without JTAG
#
#  Prerequisites on the board side (this is the flow the YOLO project already
#  proved on this exact board):
#      - Linux booted from SD (U-Boot -> image.ub -> rootfs), init=/bin/sh is fine
#      - fpga_manager available at /sys/class/fpga_manager/fpga0
#      - network up (for wget) or the files already copied to /home/root
#
#  On the PC side, serve this directory over HTTP, e.g.
#      python -m http.server 8000
#  and put dehaze_top.bin / dehaze_linux / dehaze_cam / fog_in.bin where the
#  server can see them.
# ============================================================================
set -e

PC_IP="${PC_IP:-192.168.1.100}"
HTTP_PORT="${HTTP_PORT:-8000}"
BASE="http://${PC_IP}:${HTTP_PORT}"

echo "=== 1. fetch artifacts ==="
cd /home/root
wget -O dehaze_top.bin  "${BASE}/dehaze_top.bin"
wget -O dehaze_linux    "${BASE}/dehaze_linux"
wget -O dehaze_cam      "${BASE}/dehaze_cam"
wget -O fog_in.bin      "${BASE}/fog_in.bin"
chmod +x dehaze_linux dehaze_cam
md5sum dehaze_top.bin dehaze_linux dehaze_cam fog_in.bin

echo "=== 2. program the PL through fpga_manager ==="
cp dehaze_top.bin /lib/firmware/dehaze_top.bin
echo dehaze_top.bin > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state     # 'operating' is a false positive here

echo "=== 3. clocks and AFI widths ==="
# FCLK0 is set by the PS, NOT by the bitstream we just loaded, so whatever the
# FSBL left in it applies to our core.
#
# FCLK0 = 250 MHz / DIVISOR0 on this board (FPGA0_CLK_CTRL = 0xF8000170,
# DIVISOR0 in bits[13:8]). Measured: divisor 20 -> ~12.5 MHz, 8 -> 31 MHz,
# 6 -> 42 MHz, 5 -> 50 MHz, 4 -> 62 MHz (fails, above Fmax).
# Divisor 5 = 50 MHz is what ps7_init programs anyway, and it is what the camera
# path assumes: XCLK = FCLK0/4 = 12.5 MHz, PCLK = 3.5 x XCLK ~ 43.75 MHz.
#
# SLCR is locked at boot: unlock, write, re-lock.
devmem 0xF8000008 32 0xDF0D
devmem 0xF8000170 32 0x00200500
echo "FCLK0 ctrl now: $(devmem 0xF8000170)   (0x00200500 = 50 MHz)"

# AFI widths: each HP port must be told the PL master is 32 bit. Forgetting one
# leaves it at 64 bit and silently corrupts that master's data (HP2 = scratch,
# HP3 = camera ring).
for afi in 0xF8008000 0xF8008014 0xF8009000 0xF8009014 0xF800A000 0xF800A014 0xF800B000 0xF800B014; do
    devmem $afi 32 0x1
done
devmem 0xF8000004 32 0x767B     # re-lock SLCR

echo "=== 4. sanity check: the design is really loaded ==="
# fpga_manager's 'state' reads 'operating' even before we load anything, because
# QSPI boot already configured the PL. A register that only OUR design has is the
# real probe: 0x43C00000 must read 0x00000004 (ap_ctrl, idle).
echo "ap_ctrl = $(devmem 0x43C00000 32)   (expect 0x00000004)"

echo "=== 5. dehaze from a file (no camera involved) ==="
./dehaze_linux fog_in.bin hw_out_board.bin

echo "=== 6. camera -> dehaze (the full PL demo) ==="
# Prints the measured FCLK0, the camera status word, the measured line width and
# the frame count; if it exits early the message says which stage failed.
./dehaze_cam hw_out_cam.bin 1

echo "=== 7. fetch the results back to the PC ==="
echo "  from the PC:  wget http://<board-ip>/hw_out_board.bin"
echo "  or copy it to a shared/SD location, then:"
echo "     python 00_tools/make_report.py --board"
