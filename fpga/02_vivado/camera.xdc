# ============================================================================
#  camera.xdc  --  OV5640 pin and clock constraints (MZ7X / Zynq-7020)
#
#  Pin numbers follow the board's own constraints: the camera connector on this
#  board puts PCLK on D19, which is NOT a clock-capable pin. Vivado refuses to
#  route a clock from an ordinary I/O unless CLOCK_DEDICATED_ROUTE is relaxed,
#  which is the last line of this file. Without it the build stops with
#  "CLOCK_DEDICATED_ROUTE" / "IO Clock Placer" errors that look unrelated to the
#  camera.
#
#  I/O standard is LVCMOS33 on every camera pin. The sensor is powered from the
#  3.3 V rail on this board; using LVCMOS18 by mistake still builds but the
#  levels are wrong and the capture is garbage.
# ============================================================================

# ---------------------------------------------------------------- pinout
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33 PULLUP true} [get_ports cmos_scl]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33 PULLUP true} [get_ports cmos_sda]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33 PULLUP true} [get_ports cmos_vsync]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33 PULLUP true} [get_ports cmos_href]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33}             [get_ports cmos_pclk]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33 DRIVE 8 SLEW fast} [get_ports cmos_xclk]

set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {cmos_data[7]}]
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports {cmos_data[6]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {cmos_data[5]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {cmos_data[4]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {cmos_data[3]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {cmos_data[2]}]
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS33} [get_ports {cmos_data[1]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {cmos_data[0]}]

# ---------------------------------------------------------------- pixel clock
# PCLK is produced by the sensor's own PLL from XCLK. XCLK is 24 MHz (MMCM: VCO
# 1200 MHz / 50) because that is what the vendor register table's PLL settings
# are written for; the line rate is then halved in the sensor (0x3035 = 0x91,
# SYSCLK divider 10 instead of 5) so PCLK comes out at 42 MHz rather than 84.
# 42 MHz is what this capture path is timed for and what leaves the DDR line
# writer (26 us per line at FCLK0 = 50 MHz) room inside a 45 us line.
create_clock -period 23.810 -name cmos_pclk_clk [get_ports cmos_pclk]

# The sensor drives data and control from the same PCLK edge, so the board delay
# is small. 6/1 ns brackets the skew without pretending to know the trace length.
set_input_delay -clock cmos_pclk_clk -max 6.0 [get_ports {cmos_data[*]}]
set_input_delay -clock cmos_pclk_clk -min 1.0 [get_ports {cmos_data[*]}]

# VSYNC / HREF are sampled in the same pclk domain but only gate the capture;
# constraining them as data would just add false paths.
set_input_delay -clock cmos_pclk_clk -max 6.0 [get_ports {cmos_vsync cmos_href}]
set_input_delay -clock cmos_pclk_clk -min 1.0 [get_ports {cmos_vsync cmos_href}]

# ---------------------------------------------------------------- CDC
# PCLK comes from the OV5640's own PLL, driven by XCLK, which is FCLK0 divided --
# so the two clocks are related by design but NOT phase-related: the sensor PLL
# has an arbitrary phase and the divider makes the ratio non-integer. The
# crossing must therefore be treated as asynchronous.
#
# What actually crosses, and why a single-cycle requirement is meaningless:
#   * a toggle flip, through two ASYNC_REG synchroniser flops (u_wr/tgl_s*)
#   * the line word count / bank / first-line flag, stable for a whole line
#     (~29 us) before and after that toggle, sampled 2 cycles after it
#   * the capture overflow flag, a sticky bit into a two-flop synchroniser
#     (u_pipe/ovf_s1)
#   * the reset, async-asserted and de-asserted through the three-stage bridge
#     in camera_pipe.v (u_pipe/prst_s*)
#
# Note what does NOT cross any more: the capture's 16-bit frame counter used to
# be wired straight into the AXI-Lite status mux. A multi-bit counter cannot be
# carried bit-by-bit safely, so the frame count is now produced on the AXI side
# (the writer counts row-0 lines) and only the sticky overflow bit crosses.
#
# Why this file is processed LATE (see build.tcl): it declares the pixel clock
# and its relationship to FCLK0, and the PS clock only exists once the PS7's
# generated constraints have been applied.
#
# IMPORTANT: no Tcl control flow here. Vivado's XDC parser rejects `if` / `error`
# during synthesis with "Command 'if' is not supported in the xdc constraint
# file" and simply SKIPS the block -- which silently disabled this whole section
# for two builds. Any verification of these constraints lives in build.tcl
# instead, which runs as ordinary Tcl.
#
# The pixel clock comes from the OV5640's own PLL, driven by XCLK, which is FCLK0
# divided -- related by design but NOT phase-related: the sensor PLL has an
# arbitrary phase and the divider makes the ratio non-integer. So the crossing is
# asynchronous, and a single-cycle requirement on it is meaningless.
#
# What actually crosses:
#   * a toggle flip, through two ASYNC_REG synchroniser flops (u_wr/tgl_s*)
#   * the line word count / bank / first-line flag, stable for a whole line
#     (~29 us) before and after that toggle, sampled 2 cycles after it
#   * the capture overflow flag, a sticky bit into a two-flop synchroniser
#   * the reset, async-asserted and de-asserted through a three-stage bridge
#   * the pixel clock's own registers, which is the trade-off below
#
# What does NOT cross any more: the capture's 16-bit frame counter used to be
# wired straight into the AXI-Lite status mux. A multi-bit counter cannot be
# carried bit-by-bit safely, so the frame count is now produced on the AXI side
# (the writer counts row-0 lines) and only the sticky overflow bit crosses.
#
# The broad form below is deliberate. A narrower `-to <cells>` version missed
# timing endpoints on clock-ENABLE pins (row_reg[*]/CE), which stayed in the
# report as -3.1 ns "max delay" violations. `-from [get_clocks cmos_pclk_clk]`
# with no `-to` covers every endpoint reachable from the pixel domain, including
# CE/CLR pins, and needs no knowledge of the PS clock's name. The cost is that
# pixel-domain to pixel-domain paths inside the capture are no longer timed; that
# domain is 16 registers deep with ~20 ns of slack at 43.75 MHz, and its
# behaviour is covered by tb_camera_pipe.v instead.
set_false_path -from [get_clocks cmos_pclk_clk]

# The other direction is only the reset bridge (async assert, three-stage
# de-assert in the pixel domain).
set_false_path -to [get_cells -hierarchical -filter {NAME =~ "*u_pipe/prst_s*"}]

# XCLK leaves the device; nothing downstream is timed against it.
set_false_path -from [get_clocks -quiet -include_generated_clocks cmos_pclk_clk] \
                -to [get_ports cmos_xclk]

# SCCB is a static, slow interface.
set_false_path -to [get_ports cmos_scl]
set_false_path -to [get_ports cmos_sda]
set_false_path -from [get_ports cmos_sda]

# ---------------------------------------------------------------- routing
# PCLK arrives on D19, an ordinary I/O. Relaxing the dedicated-route rule is
# required; the small input delay above keeps the capture path honest.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cmos_pclk_IBUF]
