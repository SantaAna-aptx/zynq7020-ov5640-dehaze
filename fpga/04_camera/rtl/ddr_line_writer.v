// ============================================================================
//  ddr_line_writer.v  --  line buffer to AXI4 write bursts into the DDR ring
//
//  AXI clock domain. Waits for a completed line from ov5640_dvp_linebuf (a
//  toggle flip), then writes that bank to DDR as one or more INCR bursts.
//
//  Design notes, each one bought with a bug:
//    * A burst is only issued for a COMPLETE line, so awlen is known in advance
//      and WLAST can never disagree with it. An earlier version tried to end a
//      burst early, which AXI forbids and which deadlocked the bus.
//    * Lines are split into MAX_CHUNK-beat bursts (16, the AXI3 limit of the
//      Zynq HP ports). See the MAX_CHUNK parameter for what 256-beat bursts did.
//    * The block RAM read is registered, and the beat pipeline is
//      address -> data -> present. Reading the RAM combinationally is what
//      turned this into a 20k LUT mux tree in the first attempt.
//    * B responses are latched: the slave may answer before the FSM gets back
//      to its response state.
//
//  Ring layout (one 32-bit beat per two RGB565 pixels, first pixel in the low
//  half):
//      byte address = BASE + (row % RING_ROWS) * STRIDE * 4 + word * 4
//  A ring means the reader never synchronises with a frame start: it reads the
//  most recent RING_ROWS lines.
// ============================================================================
`timescale 1ns / 1ps

module ddr_line_writer #(
    parameter integer STRIDE    = 2048,            // 32-bit words per ring row
    parameter integer RING_ROWS = 1024,            // lines in the ring
    parameter [31:0]  BASE      = 32'h2000_0000,
    parameter integer HALF      = 1024,            // words per line bank
    // Beats per AXI burst. The Zynq-7000 HP ports are AXI3, where a burst may not
    // exceed 16 beats; anything longer has to be split by the AXI4->AXI3 protocol
    // converter in the block design. Asking for 256 beats put the write into a
    // state where AW was accepted and WREADY never came back (measured on the
    // board: wvalid=1, wready=0, forever), so the writer now issues bursts the
    // native port can take directly.
    parameter integer MAX_CHUNK = 16
)(
    input  wire        aclk,
    input  wire        aresetn,

    // ---------------- line hand-over (from the pixel clock domain) ----------
    input  wire        line_tgl,
    input  wire [10:0] line_words,
    input  wire        line_bank,
    input  wire        line_first,       // this line is row 0 of a frame

    // ---------------- line buffer read port ----------------
    output reg  [10:0] rd_addr,
    input  wire [31:0] rd_data,

    // ---------------- AXI4 master (write only) ----------------
    output wire [3:0]  m_axi_awid,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awcache,
    output wire [1:0]  m_axi_awlock,
    output reg  [31:0] m_axi_awaddr,
    output reg  [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [3:0]  m_axi_wid,
    output reg  [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output reg         m_axi_wlast,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [3:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,
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
    output reg  [15:0] row_out,
    output reg  [15:0] line_len_out,     // words in the last line written
    output reg  [15:0] frames_out,       // frames whose row 0 has been written
    output reg         drop,             // sticky: a line arrived mid-burst
    output wire [7:0]  dbg_wr,           // {stuck, 3'b0, st}
    output wire [15:0] dbg_axi,          // live handshake snapshot
    output wire [21:0] dbg_cnt           // {n_words, sent}
);

    // ---------------------------------------------------------------- tie-offs
    assign m_axi_awid    = 4'h0;
    assign m_axi_awprot  = 3'h0;
    assign m_axi_awcache = 4'h0;
    assign m_axi_awlock  = 2'h0;
    assign m_axi_awsize  = 3'b010;      // 4 bytes per beat
    assign m_axi_awburst = 2'b01;       // INCR
    assign m_axi_wid     = 4'h0;
    assign m_axi_wstrb   = 4'hF;
    assign m_axi_araddr  = 32'h0;
    assign m_axi_arlen   = 8'h0;
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arid    = 4'h0;
    assign m_axi_arprot  = 3'h0;
    assign m_axi_arcache = 4'h0;
    assign m_axi_arlock  = 2'h0;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b1;        // never issue reads

    // ---------------------------------------------------------------- CDC
    // Only a toggle crosses; the count and bank are stable for the whole line,
    // so sampling them a couple of cycles after the toggle is safe. The two
    // synchroniser flops are marked ASYNC_REG so they are placed next to each
    // other and excluded from timing on the crossing itself (the two clocks are
    // genuinely asynchronous: PCLK comes from the sensor's own PLL).
    (* ASYNC_REG = "TRUE" *) reg tgl_s1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg tgl_s2 = 1'b0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            tgl_s1 <= 1'b0;
            tgl_s2 <= 1'b0;
        end else begin
            tgl_s1 <= line_tgl;
            tgl_s2 <= tgl_s1;
        end
    end
    wire line_ready = tgl_s2 ^ tgl_s1;   // pulses when the toggle toggled

    // ---------------------------------------------------------------- FSM
    localparam S_IDLE = 2'd0,
               S_AW   = 2'd1,
               S_W    = 2'd2,
               S_B    = 2'd3;

    reg [1:0]  st;
    reg [15:0] row;
    reg [10:0] n_words;      // words in the line being written
    reg [10:0] sent;         // words already handed to the bus
    reg [10:0] chunk;        // words in the current burst
    reg [10:0] beat;         // beats done in this burst
    reg [10:0] bank_r;
    reg [31:0] line_addr;
    reg [2:0]  wphase;
    reg        b_seen;

    wire [31:0] row_off   = ({{16{1'b0}}, row} & (RING_ROWS - 1)) * (STRIDE * 4);
    wire [10:0] remaining = n_words - sent;
    wire [10:0] next_chunk = (remaining > MAX_CHUNK) ? MAX_CHUNK : remaining;
    wire [10:0] beat_idx   = sent + beat;

    // B channel: latch the response, the slave may answer early
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)                 b_seen <= 1'b0;
        else if (m_axi_bvalid)        b_seen <= 1'b1;
        else if (st == S_B && b_seen) b_seen <= 1'b0;
    end

    // ---------------------------------------------------------------- watchdog
    // Diagnostic only: if a line has been in flight for more than 262144 AXI
    // clocks (5.2 ms at 50 MHz, versus ~26 us for a healthy 320-word line), the
    // bus is not answering. This does NOT abort the transaction -- AXI forbids
    // withdrawing VALID -- it only makes the hang visible from Linux.
    reg [17:0] busy_cnt = 18'd0;
    reg        stuck    = 1'b0;

    assign dbg_wr = {stuck, 3'b000, st};
    assign dbg_axi = {4'h0, stuck, st, wphase, m_axi_bready, m_axi_bvalid,
                      m_axi_wready, m_axi_wvalid, m_axi_awready, m_axi_awvalid};
    assign dbg_cnt = {n_words, sent};

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            busy_cnt <= 18'd0;
            stuck    <= 1'b0;
        end else if (st == S_IDLE) begin
            busy_cnt <= 18'd0;
        end else if (busy_cnt != 18'h3FFFF) begin
            busy_cnt <= busy_cnt + 18'd1;
        end else begin
            stuck <= 1'b1;
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            st            <= S_IDLE;
            row           <= 16'h0;
            n_words       <= 11'd0;
            sent          <= 11'd0;
            chunk         <= 11'd0;
            beat          <= 11'd0;
            bank_r        <= 1'b0;
            line_addr     <= 32'h0;
            wphase        <= 3'd0;
            rd_addr       <= 11'd0;
            m_axi_awaddr  <= 32'h0;
            m_axi_awlen   <= 8'h0;
            m_axi_awvalid <= 1'b0;
            m_axi_wdata   <= 32'h0;
            m_axi_wlast   <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b1;
            row_out       <= 16'h0;
            line_len_out  <= 16'h0;
            frames_out    <= 16'h0;
            drop          <= 1'b0;
        end else begin
            // new lines arriving while a burst is running are lost on purpose:
            // the capture side keeps writing into the same bank, so the correct
            // action is to flag it rather than to send a torn line
            if (line_ready) begin
                if (st != S_IDLE) begin
                    drop <= 1'b1;
                end else begin
                    n_words   <= (line_words == 11'd0) ? 11'd1 : line_words;
                    bank_r    <= line_bank;
                    // Row 0 of a frame always lands on ring row 0, otherwise the
                    // ring would rotate with no relation to the frame boundary:
                    // 1024 rows is not a multiple of 480, so "read rows 0..479"
                    // would only be frame-aligned by accident.
                    //
                    // `row` holds the ring row THIS line is written to, so it is
                    // advanced here, at the start of the line, and not when the
                    // burst finishes. The first version advanced it in S_B *and*
                    // forced it to 0 on line_first, which made the second line of
                    // every frame overwrite ring row 0 again (one row short, one
                    // stale row at the end of the frame).
                    if (line_first) begin
                        line_addr <= BASE;
                        row       <= 16'd1;
                        row_out   <= 16'd1;
                        frames_out <= frames_out + 16'd1;
                    end else begin
                        line_addr <= BASE + row_off;
                        if (row == RING_ROWS - 1) begin
                            row     <= 16'h0;
                            row_out <= 16'h0;
                        end else begin
                            row     <= row + 16'd1;
                            row_out <= row + 16'd1;
                        end
                    end
                    sent      <= 11'd0;
                    beat      <= 11'd0;
                    wphase    <= 3'd0;
                    line_len_out <= {5'h0, line_words};
                    st        <= S_AW;
                end
            end else begin
                case (st)
                // -------------------------------------------- write address
                S_AW: begin
                    if (wphase == 3'd0) begin
                        chunk         <= next_chunk;
                        m_axi_awaddr  <= line_addr + sent * 4;
                        m_axi_awlen   <= (next_chunk - 11'd1) & 8'hFF;
                        m_axi_awvalid <= 1'b1;
                        wphase        <= 3'd1;
                    end else if (m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b0;
                        m_axi_wlast   <= 1'b0;
                        wphase        <= 3'd0;
                        st            <= S_W;
                    end
                end

                // -------------------------------------------- beats
                // Four phases per beat, because the RAM read is registered:
                //   phase 0: present the address
                //   phase 1: wait, the RAM output lands in rd_data
                //   phase 2: present the beat
                //   phase 3: hold until wready
                // Three phases (the first version) latched rd_data one cycle too
                // early, so beat N carried the data of beat N-1 and the whole
                // line came out shifted by one word.
                S_W: begin
                    case (wphase)
                    3'd0: begin
                        rd_addr <= {bank_r, beat_idx[9:0]};
                        wphase  <= 3'd1;
                    end
                    3'd1: begin
                        wphase <= 3'd2;
                    end
                    3'd2: begin
                        m_axi_wdata  <= rd_data;
                        m_axi_wlast  <= ((beat + 11'd1) == chunk);
                        m_axi_wvalid <= 1'b1;
                        wphase       <= 3'd3;
                    end
                    default: begin
                        if (m_axi_wready) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast  <= 1'b0;
                            if ((beat + 11'd1) == chunk) begin
                                beat <= 11'd0;
                                sent <= sent + chunk;
                                st   <= S_B;
                            end else begin
                                beat   <= beat + 11'd1;
                                wphase <= 3'd0;
                            end
                        end
                    end
                    endcase
                end

                // -------------------------------------------- response
                // `row` was already advanced when this line started, so there is
                // no ring bookkeeping left to do here.
                S_B: begin
                    if (b_seen) begin
                        if (sent >= n_words) begin
                            st <= S_IDLE;
                        end else begin
                            wphase <= 3'd0;
                            st     <= S_AW;          // next chunk of this line
                        end
                    end
                end

                default: st <= S_IDLE;
                endcase
            end
        end
    end

endmodule
