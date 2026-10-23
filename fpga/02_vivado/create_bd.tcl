# ============================================================================
#  create_bd.tcl  --  build the Block Design for the pure-PL dehaze demo
#
#  Called from build.tcl after the project exists and the HLS IP repo is added.
#
#  Topology:
#
#    PS7 M_AXI_GP0 --[smartconnect]--> dehaze_top/s_axi_ctrl    (AXI-Lite)
#    dehaze_top/m_axi_gmem0 --[proto_conv]--> PS7 S_AXI_HP0     (read  src)
#    dehaze_top/m_axi_gmem1 --[proto_conv]--> PS7 S_AXI_HP1     (write dst)
#
#    The protocol converters are required because Vivado HLS emits AXI4 masters
#    while the Zynq-7000 HP ports are AXI3-only.
#
#    Everything runs on FCLK0 = 50 MHz, single clock domain.
#    No camera, no DPU, no VDMA, no interrupts -- the app polls ap_done.
# ============================================================================

create_bd_design "system"

# ---------------------------------------------------------------- PS7
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0
source [file join [file dirname [info script]] ps7_props.tcl]

create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO
connect_bd_intf_net [get_bd_intf_ports DDR]      [get_bd_intf_pins processing_system7_0/DDR]
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]

# ---------------------------------------------------------------- reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]     [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]

# ---------------------------------------------------------------- control path
# Two slaves now: the dehaze control registers and the camera status port.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {2} \
    CONFIG.NUM_CLKS {1} \
] [get_bd_cells axi_smc]

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]      [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_smc/aresetn]

# ---------------------------------------------------------------- dehaze core
create_bd_cell -type ip -vlnv dehaze.local:hls:dehaze_top:1.0 dehaze_top_0

connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins dehaze_top_0/s_axi_ctrl]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]      [get_bd_pins dehaze_top_0/ap_clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins dehaze_top_0/ap_rst_n]

# ---------------------------------------------------------------- AXI4 -> AXI3
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_pc_rd
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI4} \
    CONFIG.MI_PROTOCOL {AXI3} \
] [get_bd_cells axi_pc_rd]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_pc_wr
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI4} \
    CONFIG.MI_PROTOCOL {AXI3} \
] [get_bd_cells axi_pc_wr]

# scratch rides on its own master + HP2. Putting it on gmem0 (shared with src)
# cost 42% on mode 0 -- the extra address register degraded the read bursts.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_pc_sc
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI4} \
    CONFIG.MI_PROTOCOL {AXI3} \
] [get_bd_cells axi_pc_sc]

connect_bd_intf_net [get_bd_intf_pins dehaze_top_0/m_axi_gmem0] [get_bd_intf_pins axi_pc_rd/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_pc_rd/M_AXI]          [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins dehaze_top_0/m_axi_gmem1] [get_bd_intf_pins axi_pc_wr/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_pc_wr/M_AXI]          [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
connect_bd_intf_net [get_bd_intf_pins dehaze_top_0/m_axi_gmem2] [get_bd_intf_pins axi_pc_sc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_pc_sc/M_AXI]          [get_bd_intf_pins processing_system7_0/S_AXI_HP2]

foreach pc [list axi_pc_rd axi_pc_wr axi_pc_sc] {
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]      [get_bd_pins $pc/aclk]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins $pc/aresetn]
}

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/S_AXI_HP2_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/S_AXI_HP3_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]

# ---------------------------------------------------------------- camera capture
# One module reference bundles SCCB + DVP capture + the dual-clock line buffer +
# the AXI burst writer (04_camera/rtl). Its AXI4 master goes to HP3 through a
# protocol converter, same as the dehaze masters: Zynq-7000 HP ports are AXI3.
# It also carries an AXI4-Lite status/control port -- without JTAG that port is
# the only way to find out *why* a capture produced nothing.
create_bd_cell -type module -reference camera_top cam_top_0

create_bd_port -dir I -type clk cmos_pclk
set_property CONFIG.FREQ_HZ 43750000 [get_bd_ports cmos_pclk]
create_bd_port -dir I cmos_vsync
create_bd_port -dir I cmos_href
create_bd_port -dir I -from 7 -to 0 cmos_data
create_bd_port -dir O cmos_xclk
create_bd_port -dir O cmos_scl
create_bd_port -dir IO cmos_sda

connect_bd_net [get_bd_ports cmos_pclk]   [get_bd_pins cam_top_0/cam_pclk]
connect_bd_net [get_bd_ports cmos_vsync]  [get_bd_pins cam_top_0/cam_vsync]
connect_bd_net [get_bd_ports cmos_href]   [get_bd_pins cam_top_0/cam_href]
connect_bd_net [get_bd_ports cmos_data]   [get_bd_pins cam_top_0/cam_data]
connect_bd_net [get_bd_ports cmos_xclk]   [get_bd_pins cam_top_0/cam_xclk]
connect_bd_net [get_bd_ports cmos_scl]    [get_bd_pins cam_top_0/cam_scl]
connect_bd_net [get_bd_ports cmos_sda]    [get_bd_pins cam_top_0/cam_sda]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]      [get_bd_pins cam_top_0/aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins cam_top_0/aresetn]

# The module reference exposes exactly one AXI-Lite SLAVE interface; find it by
# MODE rather than by name, because the inferred bus name is not guaranteed.
set cam_saxi ""
foreach p [get_bd_intf_pins -of_objects [get_bd_cells cam_top_0]] {
    if {[get_property MODE $p] eq "Slave"} {
        set cam_saxi $p
    }
}
if {$cam_saxi eq ""} {
    error "camera_top_0: no AXI-Lite slave interface was inferred"
}
puts "INFO: camera status port = $cam_saxi"
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] $cam_saxi

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_pc_cam
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI4} \
    CONFIG.MI_PROTOCOL {AXI3} \
] [get_bd_cells axi_pc_cam]

connect_bd_intf_net [get_bd_intf_pins cam_top_0/m_axi]  [get_bd_intf_pins axi_pc_cam/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_pc_cam/M_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP3]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]      [get_bd_pins axi_pc_cam/aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_pc_cam/aresetn]

# ---------------------------------------------------------------- addresses
# 1) control registers at a fixed, easy-to-see base address
assign_bd_address -offset 0x43C00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs dehaze_top_0/s_axi_ctrl/Reg]
puts "INFO: dehaze control registers at 0x43C00000"

# 2) camera status/control block, right above it.
# The address segment of a module-reference AXI-Lite slave is named
# <cell>/<bus>/reg0 (lower case, and not "Reg" like an HLS IP), so look it up
# through the interface pin rather than hard-coding the name.
set cam_seg ""
foreach s [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins cam_top_0/s_axi]] {
    set cam_seg $s
}
if {$cam_seg eq ""} {
    error "camera_top_0: no address segment was inferred for its AXI-Lite slave"
}
assign_bd_address -offset 0x43C10000 -range 0x00001000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    $cam_seg
puts "INFO: camera status registers at 0x43C10000 ($cam_seg)"

# 3) everything else (the masters must see all 1 GiB of DDR)
assign_bd_address

validate_bd_design
save_bd_design
puts "INFO: block design saved"
