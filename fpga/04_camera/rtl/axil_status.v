// ============================================================================
//  axil_status.v  --  minimal AXI4-Lite status/control slave
//
//  Why this exists: the camera path has no JTAG on this board, so the only way
//  to find out *why* a capture produced nothing is to be able to read the
//  capture's own state from Linux. Reading "no camera data" out of the DDR ring
//  cannot distinguish "SCCB never ran" from "SCCB fine, no PCLK" from "PCLK
//  fine, buffer overflowed" -- and each of those is a different bug.
//
//  Register map (byte offsets, araddr[11:2] selects):
//      0x00  RO  status  { ... , err, done, busy, overflow }
//      0x04  RO  measured line length in words (2 pixels per word)
//      0x08  RO  frames captured
//      0x0C  RO  current ring row
//      0x10  RO  free-running aclk counter  (read twice to get FCLK0 exactly)
//      0x14  RW  control: bit0 toggled re-runs the SCCB sequence
//
//  AW and W are accepted INDEPENDENTLY. Requiring both in the same cycle (the
//  obvious one-liner) deadlocks against any master that presents AW, waits for
//  AWREADY and only then drives W -- which is what a PS AXI-Lite write through
//  a smartconnect does. One outstanding transaction at a time, no pipelining,
//  no bursts: this is a debug port, not a memory.
// ============================================================================
`timescale 1ns / 1ps

module axil_status (
    input  wire        clk,
    input  wire        rstn,

    // ---------------- AXI4-Lite slave ----------------
    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---------------- user side ----------------
    input  wire [31:0] st_status,       // read-only register 0
    input  wire [31:0] st_line_len,     // 1
    input  wire [31:0] st_frames,       // 2
    input  wire [31:0] st_row,          // 3
    input  wire [31:0] st_cycles,       // 4
    output reg  [31:0] ctl,             // 5, writable
    input  wire [31:0] st_dbg,          // 6, capture activity probes
    input  wire [31:0] st_rdbk,         // 7, SCCB read-back {300A,300B,3035,3036}
    input  wire [31:0] st_rd_state,     // 8, 0 idle / 1 reading / 2 done
    input  wire [31:0] st_lines,        // 9, HREF falling edges (free-running, AXI domain)
    input  wire [31:0] st_pclk_per,     // 10, 1024-pixel-clock periods (free-running)
    input  wire [31:0] st_xclk_per,     // 11, 1024-XCLK periods (free-running)
    input  wire [31:0] st_pix_line,     // 12, pixels captured in the last line
    input  wire [31:0] st_per_line,     // 13, pixel clocks between HREF falling edges
    input  wire [31:0] st_wr_dbg,       // 14, writer state {stuck, 3'b0, st}
    input  wire [31:0] st_axi,          // 15, live AXI handshake snapshot
    input  wire [31:0] st_wcnt          // 16, {n_words, sent}
);

    assign s_axi_bresp = 2'b00;          // OKAY, always
    assign s_axi_rresp = 2'b00;

    // ---------------- write channel ----------------
    reg        aw_got, w_got;
    reg [11:0] awaddr_r;
    reg [31:0] wdata_r;

    assign s_axi_awready = !aw_got;
    assign s_axi_wready  = !w_got;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            aw_got       <= 1'b0;
            w_got        <= 1'b0;
            awaddr_r     <= 12'h0;
            wdata_r      <= 32'h0;
            s_axi_bvalid <= 1'b0;
            ctl          <= 32'h0;
        end else begin
            if (s_axi_awvalid && !aw_got) begin
                awaddr_r <= s_axi_awaddr;
                aw_got   <= 1'b1;
            end

            if (s_axi_wvalid && !w_got) begin
                wdata_r <= s_axi_wdata;
                w_got   <= 1'b1;
            end

            // both halves present -> apply and answer
            if (aw_got && w_got && !s_axi_bvalid) begin
                if (awaddr_r[11:2] == 10'd5) ctl <= wdata_r;
                s_axi_bvalid <= 1'b1;
                aw_got       <= 1'b0;
                w_got        <= 1'b0;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---------------- read channel ----------------
    assign s_axi_arready = !s_axi_rvalid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'h0;
        end else begin
            if (s_axi_arvalid && !s_axi_rvalid) begin
                case (s_axi_araddr[11:2])
                10'd0:   s_axi_rdata <= st_status;
                10'd1:   s_axi_rdata <= st_line_len;
                10'd2:   s_axi_rdata <= st_frames;
                10'd3:   s_axi_rdata <= st_row;
                10'd4:   s_axi_rdata <= st_cycles;
                10'd5:   s_axi_rdata <= ctl;
                10'd6:   s_axi_rdata <= st_dbg;
                10'd7:   s_axi_rdata <= st_rdbk;
                10'd8:   s_axi_rdata <= st_rd_state;
                10'd9:   s_axi_rdata <= st_lines;
                10'd10:  s_axi_rdata <= st_pclk_per;
                10'd11:  s_axi_rdata <= st_xclk_per;
                10'd12:  s_axi_rdata <= st_pix_line;
                10'd13:  s_axi_rdata <= st_per_line;
                10'd14:  s_axi_rdata <= st_wr_dbg;
                10'd15:  s_axi_rdata <= st_axi;
                10'd16:  s_axi_rdata <= st_wcnt;
                default: s_axi_rdata <= 32'hDEADBEEF;
                endcase
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
