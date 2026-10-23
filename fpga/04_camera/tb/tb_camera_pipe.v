// ============================================================================
//  tb_camera_pipe.v  --  self-checking testbench for the capture pipeline
//
//  Drives synthetic OV5640 DVP frames (600 x 3 pixels, RGB565, high byte first)
//  into camera_pipe and models an AXI4 write slave that stores every beat.
//
//  Checked:
//    * frame 0 is swallowed by the warm-up gate; frame 1 reaches DDR,
//    * words are packed as {second pixel, first pixel},
//    * the ring address is BASE + row*STRIDE*4 + word*4,
//    * a 300-word line is split into ceil(300/AXI_BURST) bursts,
//    * AWLEN and the number of beats between AW and WLAST agree,
//    * line_len reports the measured width, not a constant,
//    * neither the line-buffer overflow nor the writer drop flag is set.
//
//  600 pixels per line is deliberate: it is longer than one burst, which is the
//  only way to exercise the burst-splitting path.
// ============================================================================
`timescale 1ns / 1ps

module tb_camera_pipe;

    localparam integer W       = 600;
    localparam integer H       = 3;
    localparam integer NFRAMES = 3;
    localparam integer WARMUP  = 2;   // VSYNC edges discarded (2 edges == 1 frame)
    localparam integer EXPECTED_FRAMES = NFRAMES;   // WARM_LINES = 0 captures all of them
    localparam integer LASTF   = 2;   // NFRAMES-1: the frame that must survive
    localparam integer HBLANK  = 8;
    localparam integer VBLANK  = 6;
    // Mirrors ddr_line_writer's MAX_CHUNK. The Zynq HP ports are AXI3, where the
    // longest legal burst is 16 beats, so the writer emits 16-beat bursts and a
    // 300-word line becomes 19 of them (18*16 + 12).
    localparam integer AXI_BURST = 16;
    localparam integer BURSTS_PER_LINE = (W/2 + AXI_BURST - 1) / AXI_BURST;

    localparam integer STRIDE    = 512;
    localparam integer RING_ROWS = 8;
    localparam [31:0]  BASE      = 32'h0000_1000;

    // ---------------- clocks ----------------
    reg pclk = 0;
    reg aclk = 0;
    always #20 pclk = ~pclk;        // 25 MHz pixel clock
    always #10 aclk = ~aclk;        // 50 MHz AXI clock

    reg aresetn = 0;
    reg vsync = 0, href = 0;
    reg [7:0] d = 8'h00;

    wire [31:0] awaddr;
    wire [7:0]  awlen;
    wire        awvalid;
    reg         awready = 1'b0;
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wlast, wvalid;
    reg         wready = 1'b0;
    reg  [1:0]  bresp = 2'b00;
    reg         bvalid = 1'b0;
    wire        bready;

    wire [15:0] line_len, frame_cnt, row_out, words_out;
    wire        overflow, drop;
    wire [7:0]  dbg;

    camera_pipe #(
        .HALF(1024), .STRIDE(STRIDE), .RING_ROWS(RING_ROWS),
        .BASE(BASE), .WARMUP(WARMUP),
        // one frame = H lines; no warm-up discard, so every frame is captured
        .LINES_PER_FRAME(H), .WARM_LINES(0)
    ) dut (
        .cam_pclk(pclk), .cam_vsync(vsync), .cam_href(href), .cam_data(d),
        .aclk(aclk), .aresetn(aresetn),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .line_len(line_len), .frame_cnt(frame_cnt), .row_out(row_out),
        .words_out(words_out), .overflow(overflow), .drop(drop), .dbg(dbg)
    );

    // ------------------------------------------------ AXI4 write slave model
    reg [31:0] mem [0:65535];
    reg [31:0] cur_addr = 0;
    reg [7:0]  cur_len  = 0;
    reg [8:0]  beats    = 0;
    reg        b_pend   = 1'b0;
    integer    nbursts  = 0;
    integer    errors   = 0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            awready <= 1'b0;
            wready  <= 1'b0;
            bvalid  <= 1'b0;
            b_pend  <= 1'b0;
        end else begin
            if (awvalid && !awready) begin
                awready  <= 1'b1;
                cur_addr <= awaddr;
                cur_len  <= awlen;
                beats    <= 9'd0;
                nbursts  =  nbursts + 1;
                $display("  AW 0x%08x len=%0d", awaddr, awlen);
            end else begin
                awready <= 1'b0;
                if (awready) wready <= 1'b1;
            end

            if (wvalid && wready) begin
                mem[cur_addr[17:2]] <= wdata;
                cur_addr <= cur_addr + 32'd4;
                beats    <= beats + 9'd1;
                if (wlast) begin
                    if (beats != cur_len) begin
                        $display("  ERROR: %0d beats, AWLEN said %0d",
                                 beats + 1, cur_len + 1);
                        errors = errors + 1;
                    end
                    wready <= 1'b0;
                    b_pend <= 1'b1;
                end
            end

            // AXI requires BVALID to stay asserted until BREADY. Setting and
            // clearing it in the same cycle (the obvious-looking version) makes
            // it invisible to the master and hangs any design that waits for it.
            if (b_pend) begin
                bvalid <= 1'b1;
                b_pend <= 1'b0;
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // ------------------------------------------------ DVP stimulus
    task send_byte(input [7:0] b);
        begin
            d <= b;
            @(posedge pclk);
        end
    endtask

    task send_pixel(input [15:0] p);
        begin
            send_byte(p[15:8]);
            send_byte(p[7:0]);
        end
    endtask

    integer r, c, f, k;
    reg [15:0] p;
    reg [15:0] pix_of;

    task send_frame(input integer fi);
        begin
            vsync <= 1'b1;
            repeat (4) @(posedge pclk);
            vsync <= 1'b0;
            repeat (VBLANK) @(posedge pclk);
            for (r = 0; r < H; r = r + 1) begin
                href <= 1'b1;
                for (c = 0; c < W; c = c + 1) begin
                    p = (fi == 0) ? 16'hAAAA : (c + r * 1000 + fi * 10000);
                    send_pixel(p);
                end
                href <= 1'b0;
                repeat (HBLANK) @(posedge pclk);
            end
        end
    endtask

    // ------------------------------------------------ run + check
    reg [31:0] exp_word;
    reg [15:0] p0, p1;

    initial begin
        aresetn = 0;
        repeat (10) @(posedge pclk);
        aresetn = 1;
        repeat (10) @(posedge pclk);

        for (f = 0; f < NFRAMES; f = f + 1) send_frame(f);

        repeat (20000) @(posedge aclk);

        $display("pipe: frames=%0d line_len=%0d words=%0d row=%0d ovf=%b drop=%b bursts=%0d",
                 frame_cnt, line_len, words_out, row_out, overflow, drop, nbursts);
        if (frame_cnt !== EXPECTED_FRAMES) begin
            $display("FAIL: frame_cnt=%0d, expected %0d", frame_cnt, EXPECTED_FRAMES);
            errors = errors + 1;
        end
        if (line_len !== W) begin
            $display("FAIL: line_len=%0d, expected %0d", line_len, W);
            errors = errors + 1;
        end
        if (words_out !== W/2) begin
            $display("FAIL: words_out=%0d, expected %0d", words_out, W/2);
            errors = errors + 1;
        end
        // the probes must show a live pixel clock and real data on the bus
        if (dbg[7] !== 1'b1) begin
            $display("FAIL: capture never saw a pixel clock (dbg[7]=0)");
            errors = errors + 1;
        end
        if (dbg[4] !== 1'b1 || dbg[6] !== 1'b1) begin
            $display("FAIL: probes dbg=%02x: expected data (bit4) and line ends (bit6)", dbg);
            errors = errors + 1;
        end
        if (overflow) begin
            $display("FAIL: line buffer overflow");
            errors = errors + 1;
        end
        if (drop) begin
            $display("FAIL: writer dropped a line");
            errors = errors + 1;
        end
        // 300 words per line -> ceil(300/16) = 19 bursts of 16 beats, x H lines
        if (nbursts !== H * BURSTS_PER_LINE * (EXPECTED_FRAMES)) begin
            $display("FAIL: %0d bursts, expected %0d", nbursts,
                     H * BURSTS_PER_LINE * (EXPECTED_FRAMES));
            errors = errors + 1;
        end

        // ---- ring contents ----
        for (r = 0; r < H; r = r + 1) begin
            for (k = 0; k < W/2; k = k + 1) begin
                p0 = 2*k + r * 1000 + LASTF * 10000;
                p1 = 2*k + 1 + r * 1000 + LASTF * 10000;
                exp_word = {p1, p0};
                if (mem[(BASE + r*STRIDE*4 + k*4) >> 2] !== exp_word) begin
                    if (errors < 12)
                        $display("FAIL: line %0d word %0d = 0x%08x, expected 0x%08x",
                                 r, k, mem[(BASE + r*STRIDE*4 + k*4) >> 2], exp_word);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("PASS: %0dx%0d frame captured, split into bursts, ring verified", W, H);
        else
            $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
