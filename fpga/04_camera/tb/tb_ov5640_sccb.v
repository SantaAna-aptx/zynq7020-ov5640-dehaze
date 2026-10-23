// ============================================================================
//  tb_ov5640_sccb.v  --  self-checking testbench for ov5640_sccb
//
//  Verification strategy: rather than modelling a full SCCB slave (which is
//  itself a state machine that can be wrong), this bench RECORDS the SDA value
//  at every SCL rising edge and decodes the transfers afterwards.
//
//  The only thing it drives back is the ack bit, because the DUT reports a
//  missing ack as a sticky error and we want that path exercised.
//
//  Wire format per entry:
//      0x78 | ack | reg_hi | ack | reg_lo | ack | data | ack
//  i.e. four 9-bit slots, then one extra SCL rise inside the STOP condition.
//  So entry e occupies rising edges [37e .. 37e+36) and bit b of slot s is at
//  37e + 9s + b. START is the only thing that resets the slot counter: an
//  earlier version counted edges modulo 9 from the start of the run and got
//  desynchronised by the SCL rise inside every STOP.
//
//  The decoded bytes are compared against the generated ROM itself, which pins
//  down the whole chain: ROM contents -> registered read -> shift-out order ->
//  byte order on the wire.
// ============================================================================
`timescale 1ns / 1ps

module tb_ov5640_sccb;

    localparam integer CLK_HZ = 50_000_000;
    localparam integer N_REGS = 512;
    // must match the entry count in 04_camera/tools/ov5640_640x480_rgb565.reg
    localparam integer N_TEST = 254;
    localparam integer ENTRY_EDGES = 37;          // 36 slots + 1 STOP rise
    localparam integer N_BITS = N_TEST * 40;

    reg clk = 0;
    reg rstn = 0;
    reg start = 0;
    wire busy, done, err;
    wire [8:0] idx;
    wire scl_o, sda_o, sda_oe, sda_i;
    // tri1 rather than a pullup primitive: the net must read as 1 whenever every
    // driver is released. An undriven `tri` reads as z in simulation, which
    // silently disables the START detector below.
    tri1 sda;

    always #10 clk = ~clk;                     // 50 MHz

    assign sda_i = sda;

    ov5640_sccb #(
        .CLK_HZ(CLK_HZ),
        .SCL_HZ(2_000_000),                    // accelerated for simulation
        .N_REGS(N_REGS),
        // The inter-write gap is a real-time settle delay (~1 ms per entry, so
        // 340 ms for the table). Keep the bench fast; the board confirms it,
        // because "SCCB finished after ~340 ms" only happens with the gap in.
        .GAP_MS(0)
    ) dut (
        .clk(clk), .rstn(rstn), .start(start),
        .busy(busy), .done(done), .err(err), .idx(idx),
        .scl_o(scl_o), .sda_o(sda_o), .sda_i(sda_i), .sda_oe(sda_oe)
    );

    // ------------------------------------------------------- bus model
    // SDA is open drain: the master drives 0, this bench drives the ack, and
    // both release to the weak 1 of the tri1 net otherwise.
    reg ack_en = 1'b0;

    assign sda = ((sda_oe && !sda_o) || ack_en) ? 1'b0 : 1'bz;

    // ------------------------------------------------------- bit recorder
    reg  bits [0:N_BITS-1];
    integer nbits     = 0;
    integer bit_index = 0;       // slots since the last START, in bits
    reg  scl_d = 1'b1;
    reg  sda_d = 1'b1;

    always @(posedge clk) begin
        scl_d <= scl_o;
        sda_d <= sda;

        // START: SDA falls while SCL is high -> the transfer restarts at bit 0
        if (scl_o === 1'b1 && sda === 1'b0 && sda_d === 1'b1) bit_index <= 0;

        // sample on every SCL rising edge
        if (scl_o === 1'b1 && scl_d === 1'b0) begin
            if (nbits < N_BITS) bits[nbits] <= sda;
            nbits     <= nbits + 1;
            bit_index <= bit_index + 1;
        end

        // the slave only ever releases SDA while SCL is low, otherwise the
        // release itself would look like a STOP condition
        if (scl_o === 1'b0) ack_en <= ((bit_index % 9) == 8);
    end

    // ------------------------------------------------------- decode helpers
    // SCCB sends the most significant bit first, so sample offset b carries
    // bit (7-b) of the byte.
    function [7:0] slot_byte(input integer entry, input integer slot);
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                slot_byte[7-b] = bits[ENTRY_EDGES*entry + 9*slot + b];
        end
    endfunction

    // ------------------------------------------------------- stimulus
    integer e, b, errors;
    reg [23:0] exp;
    reg [7:0]  dev, rhi, rlo, dat;

    initial begin
        errors = 0;
        rstn = 0;
        for (e = 0; e < N_BITS; e = e + 1) bits[e] = 1'bx;
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait (done === 1'b1);
        repeat (20) @(posedge clk);

        $display("sccb: idx=%0d err=%b  scl rising edges recorded=%0d",
                 idx, err, nbits);

        if (err) begin
            $display("FAIL: ack not seen (err=1) -- clock or table problem");
            errors = errors + 1;
        end
        if (idx !== N_TEST) begin
            $display("FAIL: idx=%0d, expected %0d entries", idx, N_TEST);
            errors = errors + 1;
        end
        if (nbits !== N_TEST * ENTRY_EDGES) begin
            $display("FAIL: %0d SCL rising edges, expected %0d",
                     nbits, N_TEST * ENTRY_EDGES);
            errors = errors + 1;
        end

        // ------------------------------------------------ decode every entry
        for (e = 0; e < N_TEST; e = e + 1) begin
            exp  = dut.u_rom.mem[e];
            dev  = slot_byte(e, 0);
            rhi  = slot_byte(e, 1);
            rlo  = slot_byte(e, 2);
            dat  = slot_byte(e, 3);
            if (dev !== 8'h78) begin
                if (errors < 10)
                    $display("FAIL: entry %0d device address 0x%02x, expected 0x78",
                             e, dev);
                errors = errors + 1;
            end
            if ({rhi, rlo} !== exp[23:8] || dat !== exp[7:0]) begin
                if (errors < 10)
                    $display("FAIL: entry %0d sent 0x%04x=0x%02x, table says 0x%04x=0x%02x",
                             e, {rhi, rlo}, dat, exp[23:8], exp[7:0]);
                errors = errors + 1;
            end
        end

        $display("decoded %0d entries; entry 0 = 0x%02x 0x%04x=0x%02x, entry %0d = 0x%04x=0x%02x",
                 N_TEST, slot_byte(0, 0),
                 slot_byte(0, 1) * 256 + slot_byte(0, 2), slot_byte(0, 3),
                 N_TEST - 1,
                 slot_byte(N_TEST-1, 1) * 256 + slot_byte(N_TEST-1, 2),
                 slot_byte(N_TEST-1, 3));

        if (errors == 0)
            $display("PASS: %0d register writes verified bit-exactly on the wire", N_TEST);
        else
            $display("FAIL: %0d error(s)", errors);

        $finish;
    end

    initial begin
        #50_000_000;   // 251 entries at 2 MHz SCCB plus the 5 ms reset hold
        $display("FAIL: timeout");
        $finish;
    end

endmodule
