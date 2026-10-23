// ============================================================================
//  camera_pipe.v  --  the OV5640 capture pipeline and its dual-clock line buffer
//
//  The block RAM has to live outside both halves of the pipeline, because its
//  two ports run on different clocks:
//
//      port A (pclk) : written by ov5640_dvp_linebuf, 32 bits at a time
//      port B (aclk) : read by ddr_line_writer, only through a registered output
//
//  Both ports are registered, which is what makes this infer as one or two block
//  RAMs instead of a mux tree. See the header of ov5640_dvp_linebuf.v for the
//  two FIFO designs this replaced and why they were worse.
//
//  Bank layout: 2 x HALF words. The capture fills one bank while the writer
//  bursts the other. HALF = 1024 words = 2048 pixels, which covers a 1280-wide
//  RGB565 line with room to spare.
// ============================================================================
`timescale 1ns / 1ps

module camera_pipe #(
    parameter integer HALF      = 1024,
    parameter integer STRIDE    = 2048,
    parameter integer RING_ROWS = 1024,
    parameter [31:0]  BASE      = 32'h2000_0000,
    parameter integer WARMUP    = 5,
    parameter integer LINES_PER_FRAME = 480,
    parameter integer WARM_LINES = 0
)(
    // ---------------- camera pins ----------------
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,

    // ---------------- AXI clock domain ----------------
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4 master (write only)
    output wire [3:0]  m_axi_awid,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awcache,
    output wire [1:0]  m_axi_awlock,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [3:0]  m_axi_wid,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [3:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
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
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    // ---------------- status ----------------
    output wire [15:0] line_len,       // measured pixels per line (pclk domain)
    output wire [15:0] frame_cnt,      // frames written to the ring (AXI domain)
    output wire [15:0] row_out,
    output wire [15:0] words_out,      // words in the last line written
    output wire        overflow,       // sticky, synchronised into the AXI domain
    output wire        drop,
    output wire [7:0]  dbg,            // capture activity probes, AXI domain
    // Rate measurements, both AXI-domain counters that software reads twice:
    //   href_cnt  : HREF falling edges   (every sensor line, even an empty one)
    //   pclk_cnt  : 1024-pixel-clock periods (from the capture's PCLK strobe)
    // Together with the free-running aclk counter they give the real line rate
    // and the real PCLK without a scope or a JTAG cable.
    output wire [31:0] href_cnt,
    output wire [31:0] pclk_cnt,
    // Last line as the pixel domain measured it (see ov5640_dvp_linebuf):
    //   pix_line = pixels captured in that line (0 = the line was empty)
    //   per_line = pixel clocks between two HREF falling edges (should be HTS)
    output wire [15:0] pix_line,
    output wire [15:0] per_line,
    // Writer FSM state + a sticky "has been busy for more than 256k cycles" flag.
    // Without JTAG this is the only way to tell a hung AXI burst from a writer
    // that is simply idle because the capture stopped handing lines over.
    output wire [7:0]  dbg_wr,
    output wire [15:0] dbg_axi,
    output wire [21:0] dbg_cnt
);

    // ---------------------------------------------------------------- line buffer
    wire        lb_we;
    wire [10:0] lb_addr;
    wire [31:0] lb_data;

    wire        line_tgl;
    wire [10:0] line_words;
    wire        line_bank;
    wire        line_first;

    wire [10:0] rd_addr;
    wire [31:0] rd_data;

    (* ram_style = "block" *) reg [31:0] mem [0:2*HALF-1];

    reg [31:0] rd_data_r;

    // ---------------------------------------------------------------- resets
    // aresetn is produced in the AXI clock domain. Using it directly as an
    // asynchronous reset on pixel-clock flops leaves recovery/removal
    // unchecked -- and shows up as 139 failing CDC endpoints in the timing
    // report. Assert asynchronously, de-assert through three synchroniser
    // stages in the pixel clock domain (the classic reset bridge).
    (* ASYNC_REG = "TRUE" *) reg prst_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg prst_s2 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg prst_s3 = 1'b0;

    always @(posedge cam_pclk or negedge aresetn) begin
        if (!aresetn) begin
            prst_s1 <= 1'b0;
            prst_s2 <= 1'b0;
            prst_s3 <= 1'b0;
        end else begin
            prst_s1 <= 1'b1;
            prst_s2 <= prst_s1;
            prst_s3 <= prst_s2;
        end
    end
    wire presetn = prst_s3;

    // port A: capture side, pixel clock
    always @(posedge cam_pclk) begin
        if (lb_we) mem[lb_addr] <= lb_data;
    end

    // port B: writer side, AXI clock, registered output
    always @(posedge aclk) begin
        rd_data_r <= mem[rd_addr];
    end
    assign rd_data = rd_data_r;

    // ---------------------------------------------------------------- status
    // Everything the AXI-Lite port can read must already be in the AXI clock
    // domain. Two values were not, and the timing report caught it: the capture
    // side's 16-bit frame counter and its overflow flag were wired straight into
    // the status mux. A multi-bit counter cannot be carried across bit by bit,
    // so the frame count now comes from the writer (which sees every row-0 line),
    // and the overflow flag -- which is sticky, so a plain synchroniser is
    // enough -- gets two flops.
    wire        cap_overflow;
    wire [15:0] cap_frame_cnt;
    wire [15:0] cap_line_len;

    (* ASYNC_REG = "TRUE" *) reg ovf_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg ovf_s2 = 1'b0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ovf_s1 <= 1'b0;
            ovf_s2 <= 1'b0;
        end else begin
            ovf_s1 <= cap_overflow;
            ovf_s2 <= ovf_s1;
        end
    end

    assign overflow = ovf_s2;
    assign line_len = cap_line_len;      // measured pixels, pclk domain

    // ---------------------------------------------------------------- probes
    // Seven sticky flags cross bit by bit -- safe, because each is a single bit
    // with a two-flop synchroniser. The eighth is a strobe that toggles every
    // 1024 pixel clocks: if it never changes, PCLK is not running at all, which
    // is the first thing to rule out when no picture arrives.
    wire [7:0] cap_dbg;

    (* ASYNC_REG = "TRUE" *) reg [6:0] dbg_s1 = 7'd0;
    (* ASYNC_REG = "TRUE" *) reg [6:0] dbg_s2 = 7'd0;
    (* ASYNC_REG = "TRUE" *) reg       pclk_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg       pclk_s2 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg       pclk_s3 = 1'b0;
    reg pclk_alive = 1'b0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            dbg_s1     <= 7'd0;
            dbg_s2     <= 7'd0;
            pclk_s1    <= 1'b0;
            pclk_s2    <= 1'b0;
            pclk_s3    <= 1'b0;
            pclk_alive <= 1'b0;
        end else begin
            dbg_s1  <= cap_dbg[6:0];
            dbg_s2  <= dbg_s1;
            pclk_s1 <= cap_dbg[7];
            pclk_s2 <= pclk_s1;
            pclk_s3 <= pclk_s2;
            if (pclk_s2 ^ pclk_s3) pclk_alive <= 1'b1;   // sticky once it moves
        end
    end

    assign dbg = {pclk_alive, dbg_s2};

    // ---------------------------------------------------------------- rate counters
    // Only the single-bit toggles cross the clock boundary; the counting itself is
    // done here in the AXI domain, so nothing multi-bit is ever transferred.
    // A PCLK period counter is 2048 pixel clocks apart (the strobe flips every
    // 1024), so PCLK = f_aclk * 1024 * d(pclk_cnt) / d(cycles) exactly.
    wire href_tgl;
    wire [15:0] cap_stat_pix, cap_stat_per;
    wire        cap_stat_tgl;
    (* ASYNC_REG = "TRUE" *) reg ht_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg ht_s2 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg ht_s3 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg pk_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg st_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg st_s2 = 1'b0;

    reg [31:0] href_cnt_r = 32'd0;
    reg [31:0] pclk_cnt_r = 32'd0;
    reg [15:0] pix_line_r = 16'd0;
    reg [15:0] per_line_r = 16'd0;

    assign href_cnt = href_cnt_r;
    assign pclk_cnt = pclk_cnt_r;
    assign pix_line = pix_line_r;
    assign per_line = per_line_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ht_s1 <= 1'b0;
            ht_s2 <= 1'b0;
            ht_s3 <= 1'b0;
            pk_s1 <= 1'b0;
            st_s1 <= 1'b0;
            st_s2 <= 1'b0;
            href_cnt_r <= 32'd0;
            pclk_cnt_r <= 32'd0;
            pix_line_r <= 16'd0;
            per_line_r <= 16'd0;
        end else begin
            ht_s1 <= href_tgl;
            ht_s2 <= ht_s1;
            ht_s3 <= ht_s2;
            if (ht_s2 ^ ht_s3) href_cnt_r <= href_cnt_r + 32'd1;
            pk_s1 <= pclk_s3;
            if (pk_s1 ^ pclk_s3) pclk_cnt_r <= pclk_cnt_r + 32'd1;
            // stat_pix / stat_per / stat_tgl are written together in the pixel
            // domain, so latching them two clocks after the toggle moved is safe
            // (the same handshake the line buffer uses for line_words).
            st_s1 <= cap_stat_tgl;
            st_s2 <= st_s1;
            if (st_s1 ^ st_s2) begin
                pix_line_r <= cap_stat_pix;
                per_line_r <= cap_stat_per;
            end
        end
    end

    // ---------------------------------------------------------------- capture
    ov5640_dvp_linebuf #(
        .HALF(HALF), .WARMUP(WARMUP),
        .LINES_PER_FRAME(LINES_PER_FRAME), .WARM_LINES(WARM_LINES)
    ) u_cap (
        .pclk(cam_pclk), .presetn(presetn),
        .vsync_raw(cam_vsync), .href_raw(cam_href), .d(cam_data),
        .lb_we(lb_we), .lb_addr(lb_addr), .lb_data(lb_data),
        .line_tgl(line_tgl), .line_words(line_words), .line_bank(line_bank),
        .line_first(line_first),
        .href_tgl(href_tgl),
        .stat_pix(cap_stat_pix), .stat_per(cap_stat_per), .stat_tgl(cap_stat_tgl),
        .line_len(cap_line_len), .frame_cnt(cap_frame_cnt),
        .overflow(cap_overflow), .dbg(cap_dbg)
    );

    // ---------------------------------------------------------------- writer
    ddr_line_writer #(
        .STRIDE(STRIDE), .RING_ROWS(RING_ROWS), .BASE(BASE), .HALF(HALF)
    ) u_wr (
        .aclk(aclk), .aresetn(aresetn),
        .line_tgl(line_tgl), .line_words(line_words), .line_bank(line_bank),
        .line_first(line_first),
        .rd_addr(rd_addr), .rd_data(rd_data),
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
        .row_out(row_out), .line_len_out(words_out),
        .frames_out(frame_cnt), .drop(drop), .dbg_wr(dbg_wr),
        .dbg_axi(dbg_axi), .dbg_cnt(dbg_cnt)
    );

endmodule
