// ============================================================================
//  ov5640_dvp_linebuf.v  --  OV5640 DVP capture into a dual-clock line buffer
//
//  Pixel-clock domain only. Turns the sensor's 8-bit DVP bus into 32-bit words
//  (two RGB565 pixels each) written straight into a block RAM that the AXI side
//  reads with its own clock. Nothing crosses a clock boundary except a toggle
//  plus the word count, and those are stable for a whole line.
//
//  Why not an AXI-Stream plus an async FIFO (the two previous designs):
//    * a hand-written grey-pointer FIFO exposed its read data combinationally,
//      so synthesis turned 1024x18 into a mux tree worth ~6k LUTs and the
//      device stopped fitting;
//    * the XPM FIFO replacement mapped to one BRAM but its first-word-fall-
//      through read returned the *same* word for two consecutive reads in RTL
//      simulation, which silently doubled every pixel.
//  A line buffer with a registered read port and a toggle handshake has neither
//  problem, and it is also exactly what the DDR writer needs.
//
//  Double buffered: two half-banks. The capture fills one while the writer
//  bursts the other, so a line is never half-visible to the AXI side.
//
//  Warm-up: the first WARMUP frames after reset are discarded (AEC/AGC and AWB
//  are still hunting, so they are black). The gate is latched once per frame --
//  evaluating "vs_cnt >= WARMUP" continuously instead let frame 0 through as
//  soon as the counter incremented mid-frame.
// ============================================================================
`timescale 1ns / 1ps

module ov5640_dvp_linebuf #(
    parameter integer HALF      = 1024,    // words per bank (power of two)
    parameter integer WARMUP    = 5,       // unused, kept for port compatibility
    parameter integer LINES_PER_FRAME = 480,  // DVPVO: lines in one frame
    parameter integer WARM_LINES = 0,        // lines discarded before handing over
    parameter         VSYNC_INV = 1'b0,    // 1 = active-low VSYNC
    parameter         HREF_INV  = 1'b0     // 1 = active-low HREF
)(
    // ---------------- pixel clock domain ----------------
    input  wire        pclk,
    input  wire        presetn,
    input  wire        vsync_raw,
    input  wire        href_raw,
    input  wire [7:0]  d,

    // ---------------- line buffer write port ----------------
    output reg         lb_we,
    output reg  [10:0] lb_addr,          // {bank, word}
    output reg  [31:0] lb_data,

    // ---------------- hand-over to the AXI clock domain ----------------
    // line_tgl flips once per completed line; line_words / line_bank /
    // line_first are stable while it does, so the reader may sample them a
    // couple of cycles after it sees the toggle change.
    output reg         line_tgl,
    output reg  [10:0] line_words,
    output reg         line_bank,
    output reg         line_first,       // this line is row 0 of a frame
    output reg         href_tgl,         // flips on EVERY HREF falling edge
    // Per-line statistics, latched with stat_tgl so the AXI side can sample them
    // safely: stat_pix = pixels counted in that line, stat_per = pixel clocks
    // between two HREF falling edges. These are the two numbers that separate
    // "the sensor is not sending pixels" from "the frame is being read wrong",
    // and they are measured where the truth is (the pixel clock domain).
    output reg  [15:0] stat_pix,
    output reg  [15:0] stat_per,
    output reg         stat_tgl,

    // ---------------- status (pclk domain) ----------------
    output reg  [15:0] line_len,         // pixels in the last complete line
    output reg  [15:0] frame_cnt,
    output reg         overflow,         // sticky: a line was too long / dropped

    // ---------------- activity probes ----------------
    // Single-bit, mostly sticky flags. Each one crosses into the AXI clock
    // domain through its own two-flop synchroniser, which is safe for individual
    // bits; a multi-bit counter would not be, which is why these are flags and
    // not counts. They exist because this board has no JTAG and, without a scope,
    // "no picture" cannot otherwise be split into "no pixel clock", "no VSYNC",
    // "no HREF" and "HREF but all-zero data".
    //   [0] VSYNC changed level at least once
    //   [1] VSYNC was seen high
    //   [2] VSYNC was seen low
    //   [3] HREF was seen high
    //   [4] a non-zero byte arrived while HREF was high
    //   [5] the warm-up gate opened
    //   [6] a line ended (HREF falling edge)
    //   [7] toggles every 1024 pixel-clock cycles  (is PCLK alive at all?)
    output reg  [7:0]  dbg
);


    // ---------------------------------------------------------------- sync
    reg vs_d = 1'b0, hr_d = 1'b0;
    wire vsync = VSYNC_INV ? ~vsync_raw : vsync_raw;
    wire href  = HREF_INV  ? ~href_raw  : href_raw;

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            vs_d <= 1'b0;
            hr_d <= 1'b0;
        end else begin
            vs_d <= vsync;
            hr_d <= href;
        end
    end

    wire vs_rise = vsync & ~vs_d;
    wire hr_fall = ~href & hr_d;

    // ---------------------------------------------------------------- warm-up
    reg       gate    = 1'b0;              // latched once per frame

    // ---------------------------------------------------------------- pairing
    // OV5640 RGB565 on DVP sends {high, low} per pixel, so four bytes make one
    // 32-bit word: word = {pixel1, pixel0}.
    reg [1:0]  bc      = 2'd0;      // byte phase within the 4-byte group
    reg [15:0] pix0    = 16'h0000;
    reg [15:0] hi1     = 16'h0000;
    reg [15:0] pix_cnt = 16'h0000;
    reg [10:0] widx    = 11'd0;     // words written in this line (11 bit on purpose)
    reg        bank    = 1'b0;
    reg [15:0] line_cnt = 16'd0;    // lines since reset (saturating, warm-up only)
    reg [15:0] row_cnt  = 16'd0;    // 0 .. LINES_PER_FRAME-1  (frame framing)
    reg [15:0] per_cnt  = 16'd0;    // pixel clocks since the last HREF falling edge

    // VSYNC polarity is NOT assumed any more. Counting frames on the rising edge
    // only (the original design) left the warm-up gate shut for ever when the
    // sensor drove the opposite polarity: dbg showed PCLK, VSYNC, HREF and data
    // all present, yet gate=0 and zero frames. The OV5640's VSYNC polarity is
    // programmable (0x4740) and differs between module configurations, so:
    //   * a frame is counted on EITHER VSYNC edge,
    //   * row 0 is "the first line after a VSYNC pulse", found by waiting for the
    //     next HREF rising edge. During vertical blanking HREF is low, so this is
    //     exact for both polarities.

    wire       have_room = (widx < HALF);

    // ---------------------------------------------------------------- probes
    // These live here, not next to the port list, because they sample vsync /
    // href / d / gate and Verilog wants the declarations first.
    reg [9:0] pclk_div = 10'd0;

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            pclk_div <= 10'd0;
            dbg      <= 8'h00;
        end else begin
            if (pclk_div == 10'd1023) begin
                pclk_div <= 10'd0;
                dbg[7]   <= ~dbg[7];               // PCLK liveness strobe
            end else begin
                pclk_div <= pclk_div + 10'd1;
            end

            if (vsync !== vs_d)       dbg[0] <= 1'b1;   // any VSYNC edge
            if (vsync)                dbg[1] <= 1'b1;   // VSYNC seen high
            else                      dbg[2] <= 1'b1;   // VSYNC seen low
            if (href)                 dbg[3] <= 1'b1;   // HREF seen high
            if (href && (d != 8'h00)) dbg[4] <= 1'b1;   // real data on the bus
            if (gate)                 dbg[5] <= 1'b1;   // warm-up gate opened
            if (hr_fall)              dbg[6] <= 1'b1;   // a line boundary arrived
        end
    end

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            lb_we      <= 1'b0;
            lb_addr    <= 11'd0;
            lb_data    <= 32'd0;
            line_tgl   <= 1'b0;
            line_words <= 11'd0;
            line_bank  <= 1'b0;
            line_first <= 1'b1;
            href_tgl   <= 1'b0;
            stat_pix   <= 16'd0;
            stat_per   <= 16'd0;
            stat_tgl   <= 1'b0;
            per_cnt    <= 16'd0;
            line_len   <= 16'd0;
            frame_cnt  <= 16'd0;
            overflow   <= 1'b0;
            gate       <= (WARM_LINES == 0);   // no warm-up unless asked for
            line_cnt   <= 16'd0;
            row_cnt    <= 16'd0;
            bc         <= 2'd0;
            pix0       <= 16'h0000;
            hi1        <= 16'h0000;
            pix_cnt    <= 16'h0000;
            widx       <= 11'd0;
            bank       <= 1'b0;
        end else begin
            lb_we <= 1'b0;

            // line period measurement: counts pixel clocks between HREF falling
            // edges. Cleared by the hr_fall block below (which assigns later in
            // this same always block, so it wins on that cycle).
            per_cnt <= per_cnt + 16'd1;


            // ---- pixel data ----
            // Capture unconditionally: the warm-up gate now only decides whether a
            // finished line is *handed over*, not whether pixels are counted. That
            // matters because the gate's own progress depends on lines being seen.
            if (!href) begin
                bc <= 2'd0;                 // re-align at every line start
            end else begin
                case (bc)
                2'd0: begin
                    pix0 <= {d, 8'h00};
                    bc   <= 2'd1;
                end
                2'd1: begin
                    pix0 <= {pix0[15:8], d};   // pixel 0 complete
                    bc   <= 2'd2;
                end
                2'd2: begin
                    hi1  <= {d, 8'h00};
                    bc   <= 2'd3;
                end
                default: begin
                    bc <= 2'd0;
                    if (have_room) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bank, widx[9:0]};
                        // word = {pixel1, pixel0}; pixel1 is {high byte latched
                        // at bc=2, low byte arriving now}
                        lb_data <= {{hi1[15:8], d}, pix0};
                        widx    <= widx + 11'd1;
                    end else begin
                        overflow <= 1'b1;
                    end
                    pix_cnt <= pix_cnt + 16'd2;
                end
                endcase
            end

            // ---- end of line: hand the bank over ----
            // Frame boundaries come from a ROW COUNTER, not from VSYNC.
            //
            // On this board the sensor streams HREF and data perfectly but never
            // pulses VSYNC reliably, so any framing that waits for VSYNC stalls.
            // The geometry is fixed (DVPVO = LINES_PER_FRAME lines per frame), so
            // counting lines is both sufficient and independent of VSYNC polarity
            // and frame rate.
            //
            // The counter is deliberately 0..LINES_PER_FRAME-1 and wraps there.
            // The previous version was a free-running 16-bit line counter tested
            // with (line_cnt % LINES_PER_FRAME) == 0 and it SATURATED at 0xFFFF
            // after 65535 lines (~25 s of streaming). From then on the modulo was
            // stuck at 65535 % 480 = 255, line_first never asserted again, the
            // ring stopped resetting to row 0 every frame and the image degenerated
            // into an arbitrary sliding window of the ring. Register 0x08 (frames)
            // freezing on hardware is what exposed it.
            if (hr_fall) begin
                bc       <= 2'd0;
                line_len <= pix_cnt;
                href_tgl <= ~href_tgl;       // every line, for the line-rate counter
                // Latch the two per-line measurements on every line, including an
                // empty one -- that is the whole point: a line with zero pixels is
                // exactly the case that used to be invisible.
                stat_pix <= pix_cnt;
                stat_per <= per_cnt;
                stat_tgl <= ~stat_tgl;
                per_cnt  <= 16'd0;
                if (pix_cnt != 16'd0) begin
                    if (gate) begin
                        line_tgl   <= ~line_tgl;
                        line_words <= widx;
                        line_bank  <= bank;
                        line_first <= (row_cnt == 16'd0);
                        bank       <= ~bank;
                        if (row_cnt == 16'd0) frame_cnt <= frame_cnt + 16'd1;
                    end

                    if (row_cnt == LINES_PER_FRAME - 1) row_cnt <= 16'd0;
                    else                                row_cnt <= row_cnt + 16'd1;

                    if (line_cnt != 16'hFFFF) line_cnt <= line_cnt + 16'd1;
                    gate <= (line_cnt >= WARM_LINES);
                end
                widx    <= 11'd0;
                pix_cnt <= 16'h0000;
            end
        end
    end

endmodule
