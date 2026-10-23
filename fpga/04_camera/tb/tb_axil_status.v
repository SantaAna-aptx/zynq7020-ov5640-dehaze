// ============================================================================
//  tb_axil_status.v  --  self-checking testbench for the camera status port
//
//  This block is the one piece of the camera path that can hang the CPU, so it
//  gets its own bench. It covers the two things that actually go wrong:
//
//    1. AW and W arriving in DIFFERENT cycles. The first version required both
//       in the same cycle; a PS AXI-Lite write through a smartconnect presents
//       AW, waits for AWREADY and only then drives W, so that version deadlocked
//       and took the CPU with it.
//    2. BVALID being visible for a full handshake, and the read path returning
//       the right register for each address.
//
//  It also proves that the control register round-trips, which is how software
//  re-runs the SCCB sequence without a power cycle.
// ============================================================================
`timescale 1ns / 1ps

module tb_axil_status;

    localparam [31:0] ST  = 32'h1234_5678;
    localparam [31:0] LN  = 32'd320;
    localparam [31:0] FR  = 32'd41;
    localparam [31:0] RW  = 32'd17;
    localparam [31:0] CYC = 32'hDEAD_0001;
    localparam [31:0] DBG  = 32'h0000_00A5;
    localparam [31:0] RDBK = 32'h5640_4169;   // chip id + PLL regs read back
    localparam [31:0] RDST = 32'd2;

    reg clk = 0, rstn = 0;
    always #10 clk = ~clk;          // 50 MHz

    reg  [11:0] awaddr  = 12'h0;
    reg         awvalid = 1'b0;
    wire        awready;
    reg  [31:0] wdata   = 32'h0;
    reg  [3:0]  wstrb   = 4'hF;
    reg         wvalid  = 1'b0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready  = 1'b1;
    reg  [11:0] araddr  = 12'h0;
    reg         arvalid = 1'b0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready  = 1'b1;

    wire [31:0] ctl;

    axil_status dut (
        .clk(clk), .rstn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .st_status(ST), .st_line_len(LN), .st_frames(FR),
        .st_row(RW), .st_cycles(CYC), .ctl(ctl), .st_dbg(DBG),
        .st_rdbk(RDBK), .st_rd_state(RDST)
    );

    integer errors = 0;
    reg [31:0] got;

    // ---- write, AW and W in separate cycles (this is what the PS does) ----
    task write_split(input [11:0] addr, input [31:0] data, input integer gap);
        begin
            awaddr  <= addr;
            awvalid <= 1'b1;
            @(posedge clk);
            while (!awready) @(posedge clk);
            awvalid <= 1'b0;
            repeat (gap) @(posedge clk);        // W arrives later on purpose
            wdata  <= data;
            wvalid <= 1'b1;
            @(posedge clk);
            while (!wready) @(posedge clk);
            wvalid <= 1'b0;
            @(posedge clk);
            while (!bvalid) @(posedge clk);     // B must stay up until BREADY
            @(posedge clk);
        end
    endtask

    // ---- write, AW and W in the same cycle ----
    task write_together(input [11:0] addr, input [31:0] data);
        begin
            awaddr  <= addr;
            awvalid <= 1'b1;
            wdata   <= data;
            wvalid  <= 1'b1;
            @(posedge clk);
            while (!awready || !wready) @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task read_reg(input [11:0] addr, input [31:0] exp, input [127:0] name);
        begin
            araddr  <= addr;
            arvalid <= 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            arvalid <= 1'b0;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            got = rdata;
            if (got !== exp) begin
                $display("FAIL: read %0s (0x%03x) = 0x%08x, expected 0x%08x",
                         name, addr, got, exp);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        rstn = 0;
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        // ---- 1. PS-style write: AW first, W 4 cycles later ----
        write_split(12'h014, 32'h0000_0001, 4);
        if (ctl !== 32'h0000_0001) begin
            $display("FAIL: split write left ctl = 0x%08x (deadlock or lost write?)", ctl);
            errors = errors + 1;
        end

        // ---- 2. AW and W together ----
        write_together(12'h014, 32'h0000_0000);
        if (ctl !== 32'h0) begin
            $display("FAIL: combined write left ctl = 0x%08x", ctl);
            errors = errors + 1;
        end

        // ---- 3. read every register back ----
        read_reg(12'h000, ST,  "status   ");
        read_reg(12'h004, LN,  "line_len ");
        read_reg(12'h008, FR,  "frames   ");
        read_reg(12'h00C, RW,  "row      ");
        read_reg(12'h010, CYC, "cycles   ");
        read_reg(12'h014, 32'h0, "ctl    ");
        read_reg(12'h018, DBG,  "dbg    ");
        read_reg(12'h01C, RDBK, "rdbk   ");
        read_reg(12'h020, RDST, "rdstat ");

        // ---- 4. write to a read-only address must not disturb anything ----
        write_together(12'h008, 32'hFFFF_FFFF);
        read_reg(12'h008, FR, "frames   ");
        read_reg(12'h014, 32'h0, "ctl    ");
        read_reg(12'h018, DBG,  "dbg    ");
        read_reg(12'h01C, RDBK, "rdbk   ");
        read_reg(12'h020, RDST, "rdstat ");

        if (errors == 0)
            $display("PASS: AXI4-Lite status port handles split and combined AW/W, reads back all registers");
        else
            $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL: timeout (the write path deadlocked)");
        $finish;
    end

endmodule
