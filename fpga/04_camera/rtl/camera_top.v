// ============================================================================
//  camera_top.v  --  OV5640 capture subsystem, wrapped for block-design use
//
//  Bundles the pieces into one module so the block design only has to reference
//  a single cell:
//
//      ov5640_sccb          register sequencer (auto-starts after reset)
//      ov5640_dvp_capture   DVP -> AXI4-Stream (with warm-up frame gating)
//      axis_ddr_writer      AXI4-Stream -> AXI4 write bursts into DDR
//      axil_status          AXI4-Lite status/control, for bring-up
//
//  Camera clocking
//      XCLK is FCLK/xXCLK_DIV, produced by a toggle divider. Not an MMCM:
//      FCLK0 on this board is whatever ps7_init and the user's devmem writes
//      make it, and an MMCM programmed for a nominal input would silently
//      produce the wrong XCLK. A fixed integer divider at least keeps XCLK
//      inside the OV5640's 6-27 MHz window for any plausible FCLK.
//
//      The sensor's own PLL settings in the register table were captured with a
//      24 MHz XCLK, and PCLK scales linearly with XCLK at 3.5x. So:
//          FCLK0 = 50 MHz (ps7_init default), xXCLK_DIV = 4
//              -> XCLK 12.5 MHz -> PCLK ~43.75 MHz -> ~31 fps at 640x480
//      Read register 0x10 (free-running cycle counter) to measure FCLK0 on the
//      real board instead of guessing.
//
//  SCCB start
//      Auto-starts ~300 ms after reset, which covers the sensor's power-on
//      settling. Writing a *changed* bit 0 of the control register re-runs the
//      whole sequence, so a failed init does not need a power cycle.
// ============================================================================
`timescale 1ns / 1ps

module camera_top #(
    parameter integer STRIDE    = 2048,
    parameter integer RING_ROWS = 1024,
    parameter [31:0]  BASE      = 32'h2000_0000,
    parameter integer SCCB_WAIT = 15_000_000,   // aclk cycles before SCCB starts
    parameter integer XCLK_DIV  = 4,            // even; XCLK = aclk / XCLK_DIV
    parameter integer ACLK_HZ   = 50_000_000
)(
    // ---------------- camera pins ----------------
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,
    output wire        cam_xclk,
    output wire        cam_scl,
    inout  wire        cam_sda,

    // ---------------- PL side ----------------
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4 master (write only) into the camera ring. Full signal set for the
    // AXI4->AXI3 protocol converter; the read channel and all IDs are tied off
    // inside the writer.
    output wire [3:0]  m_axi_awid,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awcache,
    output wire [1:0]  m_axi_awlock,
    output wire [3:0]  m_axi_wid,
    input  wire [3:0]  m_axi_bid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire [3:0]  m_axi_arid,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arcache,
    output wire [1:0]  m_axi_arlock,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    output wire        m_axi_rready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    // ---------------- AXI4-Lite status/control ----------------
    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
);

    // control register written over AXI4-Lite (declared early: used by the
    // SCCB restart logic)
    wire [31:0] ctl;

    // ---------------------------------------------------------------- XCLK
    // 24 MHz from an MMCM, exactly like the reference design that is known to
    // work on this board (一份厂商 5640_sccb_hdmi 采集+显示例程
    // drives XCLK from a clk_wiz at 24 MHz; the yolo project does the same from
    // FCLK0 at 50 MHz).
    //
    // The previous version divided FCLK0 by XCLK_DIV. That is electrically a
    // square wave too, and 12.5 MHz / 25 MHz were both tried, yet the sensor
    // produced no PCLK at all -- while still ACKing SCCB, which means it *is*
    // clocked and out of reset. Rather than keep guessing, this now mirrors the
    // known-good clock source.
    //
    //   50 MHz * 24 = 1200 MHz VCO, /50 = 24.000 MHz   (same as the vendor demo)
    //
    // XCLK is gated by MMCM lock: if FCLK0 is not 50 MHz the sensor gets no
    // clock at all and the capture probes say so, instead of silently running
    // at the wrong frequency.
    //
    // Why 24 MHz and not something slower:
    //   * The vendor register table (0x3035/0x3036/0x3037) is written for a
    //     24 MHz XCLK; at 12 MHz the PLL pre-divider lands on 4 MHz, the PLL does
    //     not lock cleanly and the sensor crawls (measured: PCLK 4.7 MHz,
    //     858 lines/s instead of ~22 kHz).
    //   * 24 MHz XCLK with the vendor PLL settings would ask for PCLK = 84 MHz.
    //     That is too fast for this capture path, so the line rate is halved in
    //     the sensor instead, by taking the SYSCLK divider from 5 to 10
    //     (0x3035 = 0x91 instead of 0x41). PCLK then comes out at ~42 MHz, the
    //     sensor's own timing stays inside its valid range, and the frame rate is
    //     30 fps at 640x480.
    localparam real CLKIN_MHZ = ACLK_HZ / 1000000.0;
    localparam real VCO_MHZ   = 1200.0;
    localparam real MULT_F    = VCO_MHZ / CLKIN_MHZ;   // 24.0 at FCLK0 = 50 MHz
    localparam real DIV0_F    = VCO_MHZ / 24.0;        // 1200 / 24 MHz = 50

    wire clkfb_raw, clkfb_buf, clk24_raw, clk24, mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (MULT_F),
        .CLKFBOUT_PHASE     (0.0),
        .CLKIN1_PERIOD      (1000.0 / CLKIN_MHZ),
        .CLKOUT0_DIVIDE_F   (DIV0_F),
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .DIVCLK_DIVIDE      (1),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_xclk_mmcm (
        .CLKOUT0   (clk24_raw),
        .CLKOUT0B  (),
        .CLKOUT1   (), .CLKOUT1B (),
        .CLKOUT2   (), .CLKOUT2B (),
        .CLKOUT3   (), .CLKOUT3B (),
        .CLKOUT4   (), .CLKOUT5  (), .CLKOUT6 (),
        .CLKFBOUT  (clkfb_raw),
        .CLKFBOUTB (),
        .LOCKED    (mmcm_locked),
        .CLKIN1    (aclk),
        .PWRDWN    (1'b0),
        .RST       (~aresetn),
        .CLKFBIN   (clkfb_buf)
    );

    BUFG u_xclk_bufg (.I(clk24_raw), .O(clk24));
    BUFG u_fb_bufg   (.I(clkfb_raw), .O(clkfb_buf));

    assign cam_xclk = mmcm_locked ? clk24 : 1'b0;

    // XCLK is not measured here. It is generated by the MMCM *from aclk*, so it is
    // 1200/50 = 24.000 MHz by construction whenever the MMCM is locked, and if it
    // were not locked cam_xclk would be 0 and there would be no PCLK at all. An
    // XCLK counter was tried and cost a clk24_raw -> clk_fpga_0 crossing that did
    // not make setup timing (-0.6 ns), for a number that is already known.

    // ---------------------------------------------------------------- free-running counter
    reg [31:0] cycles = 32'd0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) cycles <= 32'd0;
        else          cycles <= cycles + 32'd1;
    end

    // ---------------------------------------------------------------- SCCB auto-start
    reg [31:0] wait_cnt   = 32'd0;
    reg        sccb_start = 1'b0;
    reg        started    = 1'b0;
    reg        ctl0_d     = 1'b0;

    wire sccb_busy, sccb_done, sccb_err;
    wire [31:0] sccb_rdbk;
    wire [1:0]  sccb_rd_state;
    wire [8:0] sccb_idx;
    wire ctl0   = ctl[0];
    wire ctl0_chg = ctl0 ^ ctl0_d;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wait_cnt   <= 32'd0;
            sccb_start <= 1'b0;
            started    <= 1'b0;
            ctl0_d     <= 1'b0;
        end else begin
            sccb_start <= 1'b0;
            ctl0_d     <= ctl0;

            if (!started) begin
                if (wait_cnt >= SCCB_WAIT) begin
                    sccb_start <= 1'b1;
                    started    <= 1'b1;
                end else begin
                    wait_cnt <= wait_cnt + 32'd1;
                end
            end else if (ctl0_chg && !sccb_busy) begin
                sccb_start <= 1'b1;      // software asked for a re-run
            end
        end
    end

    // ---------------------------------------------------------------- SCCB
    wire sccb_scl_o, sccb_sda_o, sccb_sda_oe, sccb_sda_i;

    ov5640_sccb #(
        .CLK_HZ (ACLK_HZ),
        .SCL_HZ (100_000),
        .N_REGS (512)
    ) u_sccb (
        .clk(aclk), .rstn(aresetn),
        .start(sccb_start),
        .busy(sccb_busy), .done(sccb_done), .err(sccb_err), .idx(sccb_idx),
        .scl_o(sccb_scl_o),
        .sda_o(sccb_sda_o), .sda_i(sccb_sda_i), .sda_oe(sccb_sda_oe),
        .rdbk(sccb_rdbk), .rd_state(sccb_rd_state)
    );

    // ---------------------------------------------------------------- SDA pin
    // SDA is a real bidirectional pin: open-drain output plus an input buffer.
    //
    // This is written as an explicit IOBUF on purpose. With the equivalent
    // tri-state form
    //     assign cam_sda   = (oe && !o) ? 1'b0 : 1'bz;
    //     assign sda_i_net = cam_sda;
    // synthesis produced an **OBUF only** -- the netlist had no input buffer on
    // the pin. The consequence is nasty and silent: sda_i read a constant 0, so
    // every "ACK" looked present (err stayed 0), the SCCB sequencer reported all
    // 251 entries written, and a register read-back returned 0x00 for everything.
    // In other words the entire SCCB status was fiction. An explicit IOBUF cannot
    // be optimised away, because its O output feeds the ACK and read-data paths.
    //
    // T = 1 releases the line (external/internal pull-up makes it high),
    // T = 0 drives it low. The write sequencer and the read-back sequencer both
    // share this pin through the mux inside ov5640_sccb.
    wire sda_drive_low = sccb_sda_oe && !sccb_sda_o;

    IOBUF #(
        .DRIVE        (12),
        .IBUF_LOW_PWR ("TRUE"),
        .IOSTANDARD   ("LVCMOS33"),
        .SLEW         ("SLOW")
    ) u_sda_iobuf (
        .O  (sccb_sda_i),
        .IO (cam_sda),
        .I  (1'b0),
        .T  (~sda_drive_low)
    );

    assign cam_scl = sccb_scl_o;

    // The sequencer reports completion as a one-clock pulse; software polls a
    // memory-mapped register every few milliseconds and can never see that. Latch
    // it, and clear it when a new run starts.
    reg sccb_done_r = 1'b0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)            sccb_done_r <= 1'b0;
        else if (sccb_start)     sccb_done_r <= 1'b0;
        else if (sccb_done)      sccb_done_r <= 1'b1;
    end

    // ---------------------------------------------------------------- capture + DDR ring
    wire [15:0] cap_line_len, cap_frames, wr_row, wr_words;
    wire        cap_overflow, wr_drop;
    wire [7:0]  cap_dbg;
    wire [31:0] cap_lines, cap_pclk_per;
    wire [15:0] cap_px_line, cap_per_line;
    wire [7:0]  wr_dbg;
    wire [15:0] wr_axi;
    wire [21:0] wr_cnt;

    camera_pipe #(
        .HALF(1024), .STRIDE(STRIDE), .RING_ROWS(RING_ROWS), .BASE(BASE)
    ) u_pipe (
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync),
        .cam_href(cam_href), .cam_data(cam_data),
        .aclk(aclk), .aresetn(aresetn),
        .m_axi_awid(m_axi_awid), .m_axi_awprot(m_axi_awprot),
        .m_axi_awcache(m_axi_awcache), .m_axi_awlock(m_axi_awlock),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wid(m_axi_wid), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arid(m_axi_arid), .m_axi_arprot(m_axi_arprot),
        .m_axi_arcache(m_axi_arcache), .m_axi_arlock(m_axi_arlock),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rready(m_axi_rready), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .line_len(cap_line_len), .frame_cnt(cap_frames),
        .row_out(wr_row), .words_out(wr_words),
        .overflow(cap_overflow), .drop(wr_drop), .dbg(cap_dbg),
        .href_cnt(cap_lines), .pclk_cnt(cap_pclk_per),
        .pix_line(cap_px_line), .per_line(cap_per_line),
        .dbg_wr(wr_dbg), .dbg_axi(wr_axi), .dbg_cnt(wr_cnt)
    );

    // ---------------------------------------------------------------- status/control
    // 0x00: bit0 SCCB busy, bit1 done, bit2 err (a NACK was seen),
    //       bit3 capture line-buffer overflow, bit4 writer dropped a line,
    //       bits 12:4 how many SCCB entries were written
    wire [31:0] st_status = {18'h0,
                             wr_drop,
                             sccb_idx[8:0],
                             cap_overflow,
                             sccb_err,
                             sccb_done_r,
                             sccb_busy};

    axil_status u_axil (
        .clk(aclk), .rstn(aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .st_status(st_status),
        .st_line_len({5'h0, wr_words}),
        .st_frames({16'h0, cap_frames}),
        .st_row({16'h0, wr_row}),
        .st_cycles(cycles),
        .ctl(ctl),
        .st_dbg({24'h0, cap_dbg}),
        .st_rdbk(sccb_rdbk),
        .st_rd_state({30'h0, sccb_rd_state}),
        .st_lines(cap_lines),
        .st_pclk_per(cap_pclk_per),
        .st_xclk_per(32'h0),
        .st_pix_line({16'h0, cap_px_line}),
        .st_per_line({16'h0, cap_per_line}),
        .st_wr_dbg({24'h0, wr_dbg}),
        .st_axi({16'h0, wr_axi}),
        .st_wcnt({10'h0, wr_cnt})
    );

endmodule
