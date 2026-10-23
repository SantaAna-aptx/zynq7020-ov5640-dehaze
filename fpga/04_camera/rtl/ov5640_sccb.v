// ============================================================================
//  ov5640_sccb.v  --  SCCB (I2C-like) master + one-shot register sequencer
//
//  Why this module exists:
//    The YOLO project drove the OV5640 through a third-party SCCB controller
//    whose register table lived inside a Verilog case statement. That table hit
//    a LUT_SIZE truncation (entry 258 could never be written) and the file is
//    under a restrictive third-party licence.
//
//    Here the table is a generated block ROM (ov5640_init_rom.v, produced by
//    04_camera/tools/gen_sccb_table.py), so:
//      * no state-machine width can truncate it,
//      * changing camera settings means re-running one script,
//      * the ROM costs one BRAM instead of ~1k LUTs of case-statement logic,
//      * nothing is copied from the third-party source.
//
//  Timing:
//    SCL is generated from a quarter-period counter, so SCL_HZ must divide
//    CLK_HZ/4 exactly enough. 100 kHz is the OV5640 SCCB maximum.
//
//    One entry needs an explicit 5 ms pause: after the software-reset write
//    (0x3008 = 0x82) the sensor re-initialises its own registers and ignores
//    the bus. The vendor demo expressed this as a usleep(2000) between every
//    single write, which takes half a second per boot; only this one needs it.
//
//  Frame format (SCCB "3-wire", which is really 2-wire like I2C):
//      start | dev_addr(7) | W | ack | reg_addr(8) | ack | data(8) | ack | stop
//  The ack bit is "don't care" for SCCB writes; we still sample it so a missing
//  device shows up as a sticky error instead of a silent black image.
// ============================================================================
`timescale 1ns / 1ps

module ov5640_sccb #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer SCL_HZ   = 100_000,
    parameter integer N_REGS   = 512,            // table capacity
    parameter [6:0]   DEV_ADDR = 7'h3C,          // OV5640 write address (0x78>>1)
    parameter integer RST_MS   = 5,              // hold after software reset
    // Gap between two register writes. The working vendor demo puts usleep(2000)
    // after EVERY write (0.5 s total), which is almost certainly conservative --
    // but it is also the only structural difference between that flow and a
    // continuous 100 kHz burst, and some OV5640 PLL/clock registers are documented
    // as needing settle time. 1 ms costs 251 ms and removes the doubt.
    parameter integer GAP_MS   = 1
)(
    input  wire clk,
    input  wire rstn,
    input  wire start,          // pulse high for >= 1 clk to begin
    output reg  busy,
    output reg  done,           // 1 clk pulse when the table finished
    output reg  err,            // sticky: an ack was not seen
    output reg  [8:0] idx,      // how many entries were written
    // SCCB pins. Driven by the write sequencer, or by the read-back sequencer
    // once the table is done -- the mux at the bottom of the file selects.
    output wire scl_o,          // drive SCL (push-pull is fine for SCCB)
    output wire sda_o,          // SDA drive value
    input  wire sda_i,          // SDA read-back (before the IOBUF)
    output wire sda_oe,         // 1 = drive, 0 = release (open drain)

    // ---------------- read-back of a few registers ----------------
    // Answers the one question simulation cannot: did the writes actually land
    // in the sensor? Reads 0x300A/0x300B (chip ID, expect 0x56/0x40) and
    // 0x3035/0x3036 (the values we wrote). If the ID reads correctly but the
    // others do not, the transport works and something else is wrong; if nothing
    // reads back, the writes are not committing at all.
    output reg  [31:0] rdbk,    // {300A, 300B, 3035, 3036}
    output reg  [1:0]  rd_state // 0 = idle, 1 = reading, 2 = done, 3 = no response
);

    // ---------------------------------------------------------------- table
    wire [23:0] rom_dout;
    ov5640_init_rom u_rom (.clk(clk), .idx(idx), .dout(rom_dout));

    // Write-sequencer pin drivers (muxed onto the ports at the end).
    reg w_scl = 1'b1, w_sda = 1'b1, w_soe = 1'b0;

    // ---------------------------------------------------------------- timing
    localparam integer QDIV  = (CLK_HZ / SCL_HZ / 4 < 1) ? 1 : (CLK_HZ / SCL_HZ / 4);
    localparam integer RST_CLKS = (CLK_HZ / 1000) * RST_MS;
    localparam integer GAP_CLKS = (CLK_HZ / 1000) * GAP_MS;

    reg [15:0] qcnt;
    reg [3:0]  phase;            // 0..3 within one SCL period
    wire       tick = (qcnt == QDIV - 1);

    // ---------------------------------------------------------------- FSM
    localparam S_IDLE  = 4'd0,
               S_LOAD  = 4'd1,   // let the ROM's registered read settle
               S_EVAL  = 4'd2,   // decide what to do with the fetched entry
               S_START = 4'd3,
               S_BIT   = 4'd4,
               S_ACK   = 4'd5,
               S_STOP  = 4'd6,
               S_NEXT  = 4'd7,
               S_DELAY = 4'd8,   // post-software-reset hold
               S_DONE  = 4'd9;

    reg [3:0]  st;
    reg [23:0] cur;              // current table entry
    reg [1:0]  byte_sel;         // 0 = dev addr, 1 = reg hi, 2 = reg lo, 3 = data
    reg [2:0]  bit_cnt;          // 7..0
    reg [7:0]  shreg;
    reg        ack_sample;
    reg [2:0]  load_cnt;         // ROM latency padding
    reg        delay_after;      // this entry needs the post-reset pause
    reg [31:0] dly_cnt;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            st         <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            err        <= 1'b0;
            idx        <= 9'd0;
            qcnt       <= 16'd0;
            phase      <= 4'd0;
            w_scl      <= 1'b1;
            w_sda      <= 1'b1;
            w_soe     <= 1'b0;
            byte_sel   <= 2'd0;
            bit_cnt    <= 3'd7;
            shreg      <= 8'h00;
            cur        <= 24'hFFFFFF;
            ack_sample <= 1'b0;
            load_cnt   <= 3'd0;
            delay_after<= 1'b0;
            dly_cnt    <= 32'd0;
        end else begin
            done <= 1'b0;

            case (st)
            // ---------------- wait for a start pulse ----------------
            S_IDLE: begin
                w_scl  <= 1'b1;
                w_soe <= 1'b0;
                if (start) begin
                    idx      <= 9'd0;
                    busy     <= 1'b1;
                    err      <= 1'b0;
                    qcnt     <= 16'd0;
                    phase    <= 4'd0;
                    load_cnt <= 3'd0;
                    st       <= S_LOAD;
                end
            end

            // ---------------- let the registered ROM read settle ----------
            S_LOAD: begin
                if (load_cnt == 3'd1) begin
                    load_cnt <= 3'd0;
                    cur      <= rom_dout;
                    st       <= S_EVAL;
                end else begin
                    load_cnt <= load_cnt + 3'd1;
                end
            end

            // ---------------- end of table? -------------------------------
            S_EVAL: begin
                if (cur[23:16] == 8'hFF) begin       // end marker
                    st <= S_DONE;
                end else begin
                    // 0x3008 <- 0x82 is the software reset: everything after it
                    // is ignored until the sensor has re-initialised
                    delay_after <= (cur[23:8] == 16'h3008) && (cur[7:0] == 8'h82);

                    byte_sel <= 2'd0;
                    bit_cnt  <= 3'd7;
                    shreg    <= {DEV_ADDR, 1'b0};
                    qcnt     <= 16'd0;
                    phase    <= 4'd0;
                    st       <= S_START;
                end
            end

            // ---------------- START condition: SDA falls while SCL high ----
            S_START: begin
                if (phase == 4'd0) begin
                    w_scl  <= 1'b1;
                    w_soe <= 1'b1;
                    w_sda  <= 1'b1;
                end
                if (tick) begin
                    qcnt <= 16'd0;
                    if (phase == 4'd1) w_sda <= 1'b0;       // SDA fall
                    if (phase == 4'd3) begin
                        w_scl <= 1'b0;
                        phase <= 4'd0;      // MUST reset: S_BIT starts at phase 0.
                        st    <= S_BIT;     // Leaving it at 3 ran the phase-3
                    end else phase <= phase + 4'd1;   // branch once more and ate a bit.
                end else qcnt <= qcnt + 16'd1;
            end

            // ---------------- one data bit per SCL cycle ----------------
            // phase 0: SCL low, set SDA
            // phase 1: SCL rising
            // phase 2: SCL high
            // phase 3: SCL falling, advance bit
            S_BIT: begin
                if (tick) begin
                    qcnt <= 16'd0;
                    case (phase)
                    4'd0: begin
                        w_soe <= 1'b1;
                        w_sda  <= shreg[bit_cnt];
                        w_scl  <= 1'b0;
                        phase  <= 4'd1;
                    end
                    4'd1: begin
                        w_scl <= 1'b1;
                        phase <= 4'd2;
                    end
                    4'd2: begin
                        w_scl <= 1'b1;
                        phase <= 4'd3;
                    end
                    default: begin                       // phase 3
                        w_scl <= 1'b0;
                        phase <= 4'd0;
                        if (bit_cnt == 3'd0) begin
                            st <= S_ACK;
                        end else begin
                            bit_cnt <= bit_cnt - 3'd1;
                        end
                    end
                    endcase
                end else qcnt <= qcnt + 16'd1;
            end

            // ---------------- ACK slot: release SDA, sample it ----------------
            S_ACK: begin
                if (tick) begin
                    qcnt <= 16'd0;
                    case (phase)
                    4'd0: begin
                        w_soe <= 1'b0;                  // release for the slave
                        w_scl  <= 1'b0;
                        phase  <= 4'd1;
                    end
                    4'd1: begin
                        w_scl <= 1'b1;
                        phase <= 4'd2;
                    end
                    4'd2: begin
                        ack_sample <= sda_i;             // SDA should be low
                        w_scl      <= 1'b1;
                        phase      <= 4'd3;
                    end
                    default: begin
                        w_scl <= 1'b0;
                        phase <= 4'd0;
                        if (ack_sample) err <= 1'b1;     // NACK / no device
                        // advance to the next byte of this entry
                        case (byte_sel)
                        2'd0: begin
                            shreg    <= cur[23:16];      // register address high byte
                            byte_sel <= 2'd1;
                            bit_cnt  <= 3'd7;
                            st       <= S_BIT;
                        end
                        2'd1: begin
                            shreg    <= cur[15:8];       // register address low byte
                            byte_sel <= 2'd2;
                            bit_cnt  <= 3'd7;
                            st       <= S_BIT;
                        end
                        2'd2: begin
                            shreg    <= cur[7:0];        // DATA byte
                            byte_sel <= 2'd3;
                            bit_cnt  <= 3'd7;
                            st       <= S_BIT;
                        end
                        default: begin
                            st <= S_STOP;
                        end
                        endcase
                    end
                    endcase
                end else qcnt <= qcnt + 16'd1;
            end

            // ---------------- STOP: SDA rises while SCL high ----------------
            S_STOP: begin
                if (tick) begin
                    qcnt <= 16'd0;
                    case (phase)
                    4'd0: begin
                        w_soe <= 1'b1;
                        w_sda  <= 1'b0;
                        w_scl  <= 1'b0;
                        phase  <= 4'd1;
                    end
                    4'd1: begin
                        w_scl <= 1'b1;
                        phase <= 4'd2;
                    end
                    4'd2: begin
                        w_sda <= 1'b1;                       // SDA rise
                        phase <= 4'd3;
                    end
                    default: begin
                        w_soe <= 1'b0;
                        phase  <= 4'd0;
                        st     <= S_NEXT;
                    end
                    endcase
                end else qcnt <= qcnt + 16'd1;
            end

            // ---------------- next entry ----------------
            S_NEXT: begin
                if (idx == N_REGS - 1) begin
                    st <= S_DONE;
                end else begin
                    dly_cnt <= 32'd0;
                    st      <= S_DELAY;      // settle time, RST_CLKS or GAP_CLKS
                end
            end

            // ---------------- settle time ----------------
            // RST_CLKS after the software reset, GAP_CLKS between ordinary writes.
            S_DELAY: begin
                if (dly_cnt >= (delay_after ? RST_CLKS : GAP_CLKS)) begin
                    idx         <= idx + 9'd1;
                    load_cnt    <= 3'd0;
                    delay_after <= 1'b0;
                    st          <= S_LOAD;
                end else begin
                    dly_cnt <= dly_cnt + 32'd1;
                end
            end

            // ---------------- finished ----------------
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ========================================================================
    //  Read-back sequencer
    //
    //  Runs once, ~1000 clocks after the write table finishes, and reads four
    //  registers so the status port can show whether the writes landed:
    //      rdbk[31:24] <- 0x300A   chip ID high  (0x56 on an OV5640)
    //      rdbk[23:16] <- 0x3035   should read back what the table wrote (0x91)
    //      rdbk[15:8]  <- 0x380C   HTS high byte  (should be 0x07)
    //      rdbk[7:0]   <- 0x380D   HTS low byte   (should be 0x64 = 1892)
    //
    //  HTS is the one that matters for the "line period is 3x too long" symptom:
    //  if the sensor did not take 0x380C/0x380D, the pixel-per-line measurement
    //  and the line rate disagree by exactly the ratio of the real HTS to 1892.
    //
    //  Wire format per register:
    //      START | 0x78 | reg_hi | reg_lo | STOP | START | 0x79 | byte | NAK | STOP
    //
    //  This is deliberately a separate state machine with its own quarter-period
    //  counter. Folding it into the write sequencer would have put the one piece
    //  that simulation verifies bit-exactly (the write table) at risk.
    // ========================================================================
    localparam integer RDSTART_DLY = 1024;

    // SCCB has NO repeated START: the OmnVision bus specification requires a
    // STOP between the "write register address" phase and the "read data"
    // phase. The first version went straight from the address ACK into another
    // START, which the OV5640 ignores (it still ACKs, because the address byte
    // alone looks like a valid write) -- so the master clocked out eight bits
    // with nobody driving SDA and read back 0xFF for every register.
    localparam [3:0] RS_IDLE  = 4'd0,
                     RS_WAIT  = 4'd1,
                     RS_START = 4'd2,
                     RS_SEND  = 4'd3,
                     RS_ACK   = 4'd4,
                     RS_RECV  = 4'd5,
                     RS_NAK   = 4'd6,
                     RS_STOP  = 4'd7,
                     RS_BSTOP = 4'd8;      // STOP before the read-address START

    function [15:0] rd_reg_of(input [1:0] i);
        case (i)
        2'd0:    rd_reg_of = 16'h300A;
        2'd1:    rd_reg_of = 16'h3035;
        2'd2:    rd_reg_of = 16'h380C;
        default: rd_reg_of = 16'h380D;
        endcase
    endfunction

    reg [3:0]  rs      = RS_IDLE;
    reg [15:0] rq      = 16'd0;
    reg [3:0]  rph     = 4'd0;
    reg [2:0]  rbit    = 3'd7;
    reg [1:0]  rdi     = 2'd0;
    reg [3:0]  rstep   = 4'd0;      // 0..2 while sending the address, 3 = dev|R
    reg [7:0]  rsh     = 8'd0;
    reg [7:0]  rdat    = 8'd0;
    reg        rd_active = 1'b0;
    reg [15:0] rd_dly  = 16'd0;
    reg        restart = 1'b0;      // next START is a repeated start (no STOP first)

    reg r_scl = 1'b1, r_sda = 1'b1, r_soe = 1'b0;

    wire rtick  = (rq == QDIV - 1);
    wire r_tick = rtick;
    wire [15:0] raddr = rd_reg_of(rdi);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rs        <= RS_IDLE;
            rd_active <= 1'b0;
            rd_state  <= 2'd0;
            rdbk      <= 32'h0;
            rq        <= 16'd0;
            rph       <= 4'd0;
            r_scl     <= 1'b1;
            r_sda     <= 1'b1;
            r_soe     <= 1'b0;
            rd_dly    <= 16'd0;
            rdi       <= 2'd0;
            restart   <= 1'b0;
        end else begin
            case (rs)
            RS_IDLE: begin
                r_scl <= 1'b1;
                r_soe <= 1'b0;
                if (done) begin
                    rd_dly    <= 16'd0;
                    rs        <= RS_WAIT;
                    rd_active <= 1'b1;
                    rd_state  <= 2'd1;
                end
            end

            // let the write sequencer's last STOP settle before we grab the bus
            RS_WAIT: begin
                r_scl <= 1'b1;
                r_soe <= 1'b0;
                if (rd_dly >= RDSTART_DLY) begin
                    rdi      <= 2'd0;
                    rstep    <= 4'd0;
                    restart  <= 1'b0;
                    rq       <= 16'd0;
                    rph      <= 4'd0;
                    rs       <= RS_START;
                end else begin
                    rd_dly <= rd_dly + 16'd1;
                end
            end

            // ---------------- START (or repeated START) ----------------
            RS_START: begin
                if (rph == 4'd0) begin
                    r_scl <= 1'b1;
                    r_soe <= 1'b1;
                    r_sda <= 1'b1;
                end
                if (r_tick) begin
                    rq <= 16'd0;
                    if (rph == 4'd1) r_sda <= 1'b0;       // SDA falls while SCL high
                    if (rph == 4'd3) begin
                        r_scl <= 1'b0;
                        rph   <= 4'd0;
                        rbit  <= 3'd7;
                        // step 0..2 send dev|W then the register address; step 3
                        // sends dev|R after the repeated start
                        if (restart) rsh <= {7'h3C, 1'b1};   // 0x79 = read
                        else         rsh <= (rstep == 4'd0) ? {7'h3C, 1'b0} : rsh;
                        rs    <= RS_SEND;
                    end else begin
                        rph <= rph + 4'd1;
                    end
                end else rq <= rq + 16'd1;
            end

            // ---------------- send one byte ----------------
            RS_SEND: begin
                if (r_tick) begin
                    rq <= 16'd0;
                    case (rph)
                    4'd0: begin
                        r_soe <= 1'b1;
                        r_sda <= rsh[rbit];
                        r_scl <= 1'b0;
                        rph   <= 4'd1;
                    end
                    4'd1: begin r_scl <= 1'b1; rph <= 4'd2; end
                    4'd2: begin r_scl <= 1'b1; rph <= 4'd3; end
                    default: begin
                        r_scl <= 1'b0;
                        rph   <= 4'd0;
                        if (rbit == 3'd0) rs <= RS_ACK;
                        else              rbit <= rbit - 3'd1;
                    end
                    endcase
                end else rq <= rq + 16'd1;
            end

            // ---------------- ACK slot (write phases only) ----------------
            RS_ACK: begin
                if (r_tick) begin
                    rq <= 16'd0;
                    case (rph)
                    4'd0: begin r_soe <= 1'b0; r_scl <= 1'b0; rph <= 4'd1; end
                    4'd1: begin r_scl <= 1'b1; rph <= 4'd2; end
                    4'd2: begin r_scl <= 1'b1; rph <= 4'd3; end
                    default: begin
                        r_scl <= 1'b0;
                        rph   <= 4'd0;
                        rbit  <= 3'd7;
                        case (rstep)
                        4'd0: begin                     // dev|W acked -> reg_hi
                            rsh   <= raddr[15:8];
                            rstep <= 4'd1;
                            rs    <= RS_SEND;
                        end
                        4'd1: begin                     // reg_hi acked -> reg_lo
                            rsh   <= raddr[7:0];
                            rstep <= 4'd2;
                            rs    <= RS_SEND;
                        end
                        4'd2: begin                     // reg_lo acked -> STOP, then START
                            restart <= 1'b1;
                            rstep   <= 4'd3;
                            rs      <= RS_BSTOP;
                        end
                        default: begin                  // dev|R acked -> read a byte
                            rs <= RS_RECV;
                        end
                        endcase
                    end
                    endcase
                end else rq <= rq + 16'd1;
            end

            // ---------------- receive one byte ----------------
            RS_RECV: begin
                if (r_tick) begin
                    rq <= 16'd0;
                    case (rph)
                    4'd0: begin r_soe <= 1'b0; r_scl <= 1'b0; rph <= 4'd1; end
                    4'd1: begin r_scl <= 1'b1; rph <= 4'd2; end
                    4'd2: begin
                        rdat <= {rdat[6:0], sda_i};     // sampled while SCL is high
                        r_scl <= 1'b1;
                        rph  <= 4'd3;
                    end
                    default: begin
                        r_scl <= 1'b0;
                        rph   <= 4'd0;
                        if (rbit == 3'd0) rs <= RS_NAK;
                        else              rbit <= rbit - 3'd1;
                    end
                    endcase
                end else rq <= rq + 16'd1;
            end

            // ---------------- NAK: release SDA for the 9th clock ----------------
            RS_NAK: begin
                if (r_tick) begin
                    rq <= 16'd0;
                    case (rph)
                    4'd0: begin r_soe <= 1'b0; r_sda <= 1'b1; r_scl <= 1'b0; rph <= 4'd1; end
                    4'd1: begin r_scl <= 1'b1; rph <= 4'd2; end
                    4'd2: begin r_scl <= 1'b1; rph <= 4'd3; end
                    default: begin
                        r_scl <= 1'b0;
                        rph   <= 4'd0;
                        case (rdi)
                        2'd0:    rdbk[31:24] <= rdat;
                        2'd1:    rdbk[23:16] <= rdat;
                        2'd2:    rdbk[15:8]  <= rdat;
                        default: rdbk[7:0]   <= rdat;
                        endcase
                        rs <= RS_STOP;
                    end
                    endcase
                end else rq <= rq + 16'd1;
            end

            // ---------------- STOP between address write and data read -----
            RS_BSTOP: begin
                if (r_tick) begin
                    rq <= 16'd0;
                    case (rph)
                    4'd0: begin r_soe <= 1'b1; r_sda <= 1'b0; r_scl <= 1'b0; rph <= 4'd1; end
                    4'd1: begin r_scl <= 1'b1; rph <= 4'd2; end
                    4'd2: begin r_sda <= 1'b1; rph <= 4'd3; end   // STOP: SDA rises, SCL high
                    default: begin
                        r_soe <= 1'b0;
                        r_scl <= 1'b1;
                        rph   <= 4'd0;
                        rbit  <= 3'd7;
                        rs    <= RS_START;                        // 0x79 follows
                    end
                    endcase
                end else rq <= rq + 16'd1;
            end

            // ---------------- STOP ----------------
            RS_STOP: begin
                if (r_tick) begin
                    rq <= 16'd0;
                    case (rph)
                    4'd0: begin r_soe <= 1'b1; r_sda <= 1'b0; r_scl <= 1'b0; rph <= 4'd1; end
                    4'd1: begin r_scl <= 1'b1; rph <= 4'd2; end
                    4'd2: begin r_sda <= 1'b1; rph <= 4'd3; end
                    default: begin
                        r_soe <= 1'b0;
                        rph   <= 4'd0;
                        restart <= 1'b0;
                        if (rdi == 2'd3) begin
                            rd_active <= 1'b0;
                            rd_state  <= 2'd2;      // 2 = all four read
                            rs        <= RS_IDLE;
                        end else begin
                            rdi   <= rdi + 2'd1;
                            rstep <= 4'd0;
                            rs    <= RS_START;
                        end
                    end
                    endcase
                end else rq <= rq + 16'd1;
            end

            default: rs <= RS_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- pin mux
    assign scl_o  = rd_active ? r_scl : w_scl;
    assign sda_o  = rd_active ? r_sda : w_sda;
    assign sda_oe = rd_active ? r_soe : w_soe;

endmodule
