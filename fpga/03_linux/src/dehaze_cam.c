// ============================================================================
//  dehaze_cam.c  --  camera -> dehaze -> file, on the board
//
//  Data path
//      OV5640 (DVP) -> PL capture -> dual-clock line buffer -> PL ring writer
//                   -> DDR ring @ 0x20000000
//      this program: read the camera status, RGB565 -> BGR888 (32 bit/pixel),
//                    run the dehaze core, write a file
//
//  Camera status port (camera_top's AXI4-Lite slave, at CAM_REG_PHYS)
//      0x00 RO  bit0 SCCB busy, bit1 done, bit2 err, bit3 line-buffer overflow,
//               bit4 writer dropped a line, bits 12:4 SCCB entries written
//      0x04 RO  words in the last line written (2 pixels per word)
//      0x08 RO  frames captured
//      0x0C RO  current ring row
//      0x10 RO  free-running AXI clock counter -- read twice with a known delay
//               and you get the real FCLK0, instead of guessing what the
//               devmem divisor did
//      0x14 RW  bit0 toggled re-runs the SCCB sequence
//  Without JTAG this port is the only way to tell "SCCB never ran" from
//  "SCCB fine, no PCLK" from "PCLK fine, buffer overflowed".
//
//  Ring layout produced by the PL (see 04_camera/rtl/ddr_line_writer.v):
//      word index = row * STRIDE + word     (STRIDE = 2048, RING_ROWS = 1024)
//      each word  = { pixel[2k+1], pixel[2k] }   (first pixel in the low half)
//
//  Why the ring is bigger than a frame: the writer never synchronises with a
//  frame boundary, so at any instant the ring already holds a full frame.
//  Reading rows 0..H-1 therefore always returns a complete frame, at the risk of
//  a horizontal seam if the writer rolled over while we read. For a still or
//  slow scene that is fine; a frame-synchronised read would need more status.
//
//  Usage:
//      ./dehaze_cam <out_file> <mode 0|1> [width] [height]
// ============================================================================
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/mman.h>

// ---------------------------------------------------------------- addresses
#define REG_PHYS     0x43C00000UL          // dehaze control registers
#define REG_SIZE     0x00010000UL
#define CAM_REG_PHYS 0x43C10000UL          // camera status/control
#define CAM_REG_SIZE 0x00001000UL
#define SRC_PHYS     0x08000000UL          // dehaze input, BGR888 32 bit/px
#define DST_PHYS     0x0C000000UL          // dehaze output
#define SCRATCH_PHYS 0x10000000UL          // mode 1 workspace
#define CAM_PHYS     0x20000000UL          // camera ring base (matches BASE in RTL)

#define CAM_STRIDE   2048                  // 32-bit words per ring row (must match RTL)
#define CAM_ROWS     1024                  // ring depth (must match RTL)

// Buffer sizing. The dehaze core has no stride register: it walks the image as
// exactly W*H pixels, so the software MUST pack rows at stride == W. These
// maxima only size the mmap, they are not used as a stride.
#define IMG_W_MAX    1024
#define IMG_H_MAX    720
#define IMG_WORDS    ((size_t)IMG_W_MAX * IMG_H_MAX)
#define IMG_BYTES    (IMG_WORDS * 4)

// scratch = tone map (one byte per 4x4 block, one word each) + a copy of the image
#define TMAP_WORDS_MAX ((((size_t)IMG_W_MAX + 3) / 4) * IMG_H_MAX)
#define SCRATCH_WORDS (TMAP_WORDS_MAX + IMG_WORDS)
#define SCRATCH_BYTES (SCRATCH_WORDS * 4)

// ---------------------------------------------------------------- dehaze regs
#define R_AP_CTRL   0x00
#define R_AP_RETURN 0x10
#define R_SRC       0x18
#define R_DST       0x20
#define R_SCRATCH   0x28
#define R_WIDTH     0x30
#define R_HEIGHT    0x38
#define R_OMEGA     0x40
#define R_T0        0x48
#define R_GAIN      0x50
#define R_ACOMP     0x58
#define R_MODE      0x60

// ---------------------------------------------------------------- camera regs
#define C_STATUS    0x00
#define C_LINE_WORDS 0x04
#define C_FRAMES    0x08
#define C_ROW       0x0C
#define C_CYCLES    0x10
#define C_CTL       0x14
#define C_DBG       0x18
#define C_RDBK      0x1C
#define C_RDST      0x20
#define C_LINES     0x24
#define C_PCLKPER   0x28
#define C_XCLKPER   0x2C
#define C_PIXLINE   0x30
#define C_PERLINE   0x34
#define C_WRDBG     0x38
#define C_AXI       0x3C
#define C_WCNT      0x40

#define AP_START  (1u << 0)
#define AP_DONE   (1u << 1)
#define AP_IDLE   (1u << 2)
#define POLL_US   100

#define ST_BUSY   (1u << 0)
#define ST_DONE   (1u << 1)
#define ST_ERR    (1u << 2)
#define ST_OVF    (1u << 3)
#define ST_DROP   (1u << 4)

// Number of entries in 04_camera/tools/ov5640_640x480_rgb565.reg.
//
// Why this constant exists: the SCCB sequencer reports completion as a
// one-clock pulse, and this program polls a memory-mapped register every 20 ms,
// so it can never observe it. The run is complete when the whole table has been
// written, nothing is busy and no NACK was seen -- that is what the check below
// uses. (The RTL also latches done now, so either signal works.)
#define SCCB_ENTRIES 254

static volatile uint32_t* reg = NULL;
static volatile uint32_t* creg = NULL;

static inline void wr(uint32_t off, uint32_t v) { *(volatile uint32_t*)((char*)reg + off) = v; }
static inline uint32_t rd(uint32_t off) { return *(volatile uint32_t*)((char*)reg + off); }
static inline uint32_t crd(uint32_t off) { return *(volatile uint32_t*)((char*)creg + off); }

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void* map_phys(int fd, unsigned long phys, size_t len) {
    void* p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap 0x%08lx (%zu bytes): %s\n", phys, len, strerror(errno));
        exit(1);
    }
    return p;
}

// ---------------------------------------------------------------- camera helpers
// Measure FCLK0 by sampling the free-running AXI clock counter twice.
static double measure_fclk0(void) {
    uint32_t c0, c1;
    double t0, t1;
    c0 = crd(C_CYCLES);
    t0 = now_ms();
    usleep(50 * 1000);
    c1 = crd(C_CYCLES);
    t1 = now_ms();
    return (double)(c1 - c0) / ((t1 - t0) / 1000.0) / 1e6;   // MHz
}

// Measure the sensor's own timing: the line rate (HREF falling edges per second)
// and PCLK, both from free-running counters that the PL increments in the AXI
// clock domain. This is the measurement that says whether the capture is really
// running at the frequency camera.xdc was written for; without a scope there is
// no other way to tell "PCLK 43.75 MHz" from "PCLK 84 MHz", and the DDR writer's
// line budget depends on it.
static void measure_sensor_rates(void) {
    uint32_t l0, p0, c0, l1, p1, c1;
    double t0, t1;
    l0 = crd(C_LINES); p0 = crd(C_PCLKPER);
    c0 = crd(C_CYCLES); t0 = now_ms();
    usleep(200 * 1000);
    l1 = crd(C_LINES); p1 = crd(C_PCLKPER);
    c1 = crd(C_CYCLES); t1 = now_ms();

    double secs = (t1 - t0) / 1000.0;
    if (secs <= 0.0) return;
    double lines = (double)(l1 - l0) / secs;
    double pclk  = (double)(p1 - p0) * 1024.0 / secs / 1e6;
    double fclk  = (double)(c1 - c0) / secs / 1e6;

    // XCLK is not measured here: it is 24 MHz by construction (MMCM from FCLK0),
    // and the numbers that actually matter are the pixel-domain ones below.
    // All lines are kept short on purpose -- the Linux console wraps at 80
    // columns, and a wrapped line cannot be matched by the PC-side script.
    printf("sensor: lines/s=%.0f pclk=%.1fMHz fclk=%.1fMHz\n", lines, pclk, fclk);
    printf("  line: %u pclk, %u px (HTS in table=1892)\n",
           crd(C_PERLINE), crd(C_PIXLINE));
    uint32_t wd = crd(C_WRDBG);
    printf("  writer: state=%u%s\n", wd & 0xF,
           (wd & 0x20) ? " STUCK(>5ms)" : "");
    uint32_t ax = crd(C_AXI), wn = crd(C_WCNT);
    printf("  axi: awv=%u awr=%u wv=%u wr=%u bv=%u wph=%u\n",
           (ax >> 0) & 1, (ax >> 1) & 1, (ax >> 2) & 1, (ax >> 3) & 1,
           (ax >> 4) & 1, (ax >> 6) & 7);
    printf("  burst: n_words=%u sent=%u\n", (wn >> 11) & 0x7FF, wn & 0x7FF);
}

static void dump_camera_status(const char* when) {
    uint32_t s = crd(C_STATUS);
    printf("camera %s: busy=%u done=%u err=%u ovf=%u drop=%u entries=%u "
           "line_words=%u frames=%u row=%u\n",
           when,
           (s & ST_BUSY) ? 1 : 0, (s & ST_DONE) ? 1 : 0, (s & ST_ERR) ? 1 : 0,
           (s & ST_OVF) ? 1 : 0, (s & ST_DROP) ? 1 : 0,
           (s >> 4) & 0x1FF,
           crd(C_LINE_WORDS), crd(C_FRAMES), crd(C_ROW));
}

// The sequence is finished if the RTL says so, or if the whole table has been
// written and nothing is busy or failing. See the SCCB_ENTRIES comment.
static int sccb_finished(uint32_t s) {
    if (s & ST_ERR) return 1;
    if (s & ST_DONE) return 1;
    if (!(s & ST_BUSY) && (((s >> 4) & 0x1FF) >= SCCB_ENTRIES)) return 1;
    return 0;
}

// The capture's own view of the DVP bus. Without JTAG and without a scope this
// is how "no picture" gets narrowed down: it says whether the pixel clock is
// toggling at all, whether VSYNC/HREF ever arrived, and whether the data lines
// carried anything other than zero.
static void dump_probes_brief(const char* when) {
    uint32_t d = crd(C_DBG);
    printf("probes %s: pclk=%u vsync_edge=%u vhi=%u vlo=%u href=%u data=%u "
           "gate=%u line_end=%u (0x%02x)\n",
           when,
           (d >> 7) & 1, (d >> 0) & 1, (d >> 1) & 1, (d >> 2) & 1,
           (d >> 3) & 1, (d >> 4) & 1, (d >> 5) & 1, (d >> 6) & 1, d & 0xFF);
}

static void dump_probes(void) {
    uint32_t d = crd(C_DBG);
    dump_probes_brief("after");

    // Read-back of the sensor's own registers: the only way to tell "the sensor
    // accepted the configuration" from "the sensor never listened", which look
    // identical from the outside when there are no pixels.
    uint32_t rb = crd(C_RDBK);
    uint32_t rs = crd(C_RDST);
    printf("readback: state=%u  0x300A(chip hi)=0x%02X 0x3035(sysclk div)=0x%02X "
           "0x380C(HTS hi)=0x%02X 0x380D(HTS lo)=0x%02X\n",
           rs,
           (rb >> 24) & 0xFF, (rb >> 16) & 0xFF, (rb >> 8) & 0xFF, rb & 0xFF);
    if (rs == 0) {
        printf("  -> the read-back sequencer never ran (SCCB table did not complete)\n");
    } else if (rs == 1) {
        printf("  -> read-back still in progress\n");
    } else if (rb == 0xFFFFFFFFu) {
        printf("  -> every byte read 0xFF: nobody drove SDA during the read phase\n");
    } else if (((rb >> 24) & 0xFF) == 0x56) {
        unsigned hts = (((rb >> 8) & 0xFF) << 8) | (rb & 0xFF);
        printf("  -> chip ID 0x56xx: this IS an OV5640 and reads work\n");
        printf("     0x3035 = 0x%02X (table writes 0x91), HTS = %u (table writes 1892)\n",
               (rb >> 16) & 0xFF, hts);
        if (hts != 0 && hts != 1892) {
            printf("     -> HTS is %u, not 1892 -- that is why the measured line period\n"
                   "        and 1892 clocks disagree\n", hts);
        }
    }

    if (!((d >> 7) & 1)) {
        printf("  -> the pixel clock is NOT running: the sensor has no XCLK, or its "
               "PLL never locked\n");
    } else if (!((d >> 0) & 1)) {
        printf("  -> PCLK is running but VSYNC never changed level: check the VSYNC "
               "pin (C20)\n");
    } else if (!((d >> 3) & 1)) {
        printf("  -> VSYNC arrives but HREF never goes high: the sensor is not "
               "outputting pixels (format/PLL registers)\n");
    } else if (!((d >> 4) & 1)) {
        printf("  -> HREF is high but every data byte is zero: check D[7:0]\n");
    } else if (!((d >> 5) & 1)) {
        printf("  -> data is present but the warm-up gate never opened: fewer than "
               "WARMUP frames arrived\n");
    }
}

// RGB565 -> 8-bit per channel, with bit replication so 0xFFFF maps to 255
static inline void rgb565_to_bgr(uint16_t p, uint8_t* b, uint8_t* g, uint8_t* r) {
    uint8_t r5 = (p >> 11) & 0x1F;
    uint8_t g6 = (p >> 5)  & 0x3F;
    uint8_t b5 =  p        & 0x1F;
    *r = (uint8_t)((r5 << 3) | (r5 >> 2));
    *g = (uint8_t)((g6 << 2) | (g6 >> 4));
    *b = (uint8_t)((b5 << 3) | (b5 >> 2));
}

// FNV-1a over exactly the words the reader uses (row*STRIDE + word, for a whole
// frame). If the PL never managed to write the ring, this number does not change
// and the "image" we dump is whatever DDR happened to hold from an earlier boot
// -- which is precisely the trap this check exists to close. One whole run of
// this costs a few milliseconds.
static uint32_t ring_sum(const uint32_t* cam, int rows, int words_per_row) {
    uint32_t s = 2166136261u;
    for (int y = 0; y < rows; y++) {
        const uint32_t* line = cam + (size_t)y * CAM_STRIDE;
        for (int k = 0; k < words_per_row; k++) {
            s ^= line[k];
            s *= 16777619u;
        }
    }
    return s;
}

int main(int argc, char** argv) {
    if (argc < 3 || argc > 5) {
        fprintf(stderr, "usage: %s <out_file> <mode 0|1> [width] [height]\n", argv[0]);
        return 1;
    }
    int mode = atoi(argv[2]);
    if (mode != 0 && mode != 1) { fprintf(stderr, "mode must be 0 or 1\n"); return 1; }

    int W = (argc >= 4) ? atoi(argv[3]) : 640;
    int H = (argc >= 5) ? atoi(argv[4]) : 480;
    if (W < 64 || W > IMG_W_MAX) { fprintf(stderr, "width %d out of range\n", W); return 1; }
    if (H < 32 || H > IMG_H_MAX) { fprintf(stderr, "height %d out of range\n", H); return 1; }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { fprintf(stderr, "open /dev/mem: %s\n", strerror(errno)); return 1; }

    reg  = (volatile uint32_t*)map_phys(fd, REG_PHYS, REG_SIZE);
    creg = (volatile uint32_t*)map_phys(fd, CAM_REG_PHYS, CAM_REG_SIZE);
    uint8_t* src = (uint8_t*)map_phys(fd, SRC_PHYS, IMG_BYTES);
    uint8_t* dst = (uint8_t*)map_phys(fd, DST_PHYS, IMG_BYTES);
    (void)map_phys(fd, SCRATCH_PHYS, SCRATCH_BYTES);
    uint32_t* cam = (uint32_t*)map_phys(fd, (unsigned long)CAM_PHYS,
                                        (size_t)CAM_STRIDE * CAM_ROWS * 4);

    // ---- 0. what clock did the PL actually get? ----
    double fclk0 = measure_fclk0();
    printf("FCLK0 = %.2f MHz (measured), XCLK = FCLK0/4 -> PCLK ~ %.2f MHz\n",
           fclk0, fclk0 / 4.0 * 3.5);
    dump_camera_status("at start");
    // Read the probes BEFORE the SCCB sequence finishes too: PCLK should already
    // be running (the sensor outputs it whenever it is out of reset, even before
    // we configure it). If it is dead here as well, the problem is upstream of
    // the register table entirely.
    dump_probes_brief("before SCCB");

    // ---- 1. wait for the SCCB sequence, then for the warm-up frames ----
    // Poll instead of sleeping a fixed time: the SCCB sequence starts ~300 ms
    // after reset and takes ~90 ms (251 entries at 100 kHz), then five frames are
    // discarded at whatever rate the sensor is tuned for. A fixed 1 s would be
    // wrong the moment someone changes VTS or the frame rate.
    double tw = now_ms();
    for (;;) {
        uint32_t c = crd(C_STATUS);
        if (sccb_finished(c)) break;
        if (now_ms() - tw > 5000.0) {
            fprintf(stderr, "SCCB never finished within 5 s (status 0x%08x)\n", c);
            dump_camera_status("timeout");
            return 1;
        }
        usleep(20 * 1000);
    }
    printf("SCCB finished after %.0f ms\n", now_ms() - tw);

    tw = now_ms();
    while (crd(C_FRAMES) == 0) {
        if (now_ms() - tw > 5000.0) break;
        usleep(20 * 1000);
    }

    uint32_t s = crd(C_STATUS);
    dump_camera_status("after wait");
    dump_probes();
    measure_sensor_rates();

    // ---- 1b. proof that the PL is really writing DDR ----
    // Everything above can look perfect while the AXI write path to the ring is
    // dead, in which case the frame we are about to dump is stale DDR from an
    // earlier boot. Measuring the ring twice is the only way to tell those apart
    // from Linux, and it is cheap.
    {
        uint32_t sum0 = ring_sum(cam, H, W / 2);
        uint32_t fr0  = crd(C_FRAMES);
        double   tr   = now_ms();
        while ((uint16_t)(crd(C_FRAMES) - fr0) < 2) {
            if (now_ms() - tr > 6000.0) break;
            usleep(20 * 1000);
        }
        double   secs = (now_ms() - tr) / 1000.0;
        uint16_t nfr  = (uint16_t)(crd(C_FRAMES) - fr0);
        uint32_t sum1 = ring_sum(cam, H, W / 2);
        printf("ring: %u new frames in %.2f s (%.1f fps), content %s\n",
               (unsigned)nfr, secs, secs > 0.0 ? nfr / secs : 0.0,
               (sum0 != sum1) ? "CHANGED -- the PL is writing DDR" :
                                "UNCHANGED -- the PL never wrote DDR");
        if (nfr == 0 && sum0 == sum1) {
            fprintf(stderr,
                "\n*** The DDR ring was not updated. Everything the capture side\n"
                "*** reports may still be perfect, but there is no new picture:\n"
                "*** the AXI write path (cam_top -> axi_pc_cam -> S_AXI_HP3) is\n"
                "*** stalled. Check registers 0x38/0x3C/0x40 on the printout above:\n"
                "***   wvalid=1 wready=0  -> the port never accepts write data\n"
                "***   state=2 stuck=1    -> the writer has been waiting >5 ms\n"
                "*** The image written below is STALE DDR, not the camera.\n\n");
        } else if (nfr == 0) {
            fprintf(stderr, "warning: the ring changed but no frame counter moved "
                            "-- the writer is finishing lines without row 0\n");
        }
    }

    if (s & ST_ERR) {
        fprintf(stderr, "SCCB got a NACK: the sensor is not answering on SCL/SDA.\n"
                        "  check 3.3 V on the module, the F19/F20 pins and the "
                        "pull-ups.\n");
        return 1;
    }
    if (!sccb_finished(s)) {
        fprintf(stderr, "SCCB did not finish (entries written = %u of %d).\n",
                (s >> 4) & 0x1FF, SCCB_ENTRIES);
        return 1;
    }
    if (crd(C_FRAMES) == 0) {
        fprintf(stderr, "SCCB finished but no frame arrived: XCLK/PCLK or VSYNC "
                        "problem.\n  line_words=%u frames=0\n", crd(C_LINE_WORDS));
        return 1;
    }
    if (s & ST_OVF) {
        fprintf(stderr, "warning: capture line buffer overflowed -- broken line\n");
    }
    if (s & ST_DROP) {
        fprintf(stderr, "warning: writer dropped a line -- DDR ring too slow\n");
    }

    // ---- 2. sanity-check the width against the sensor configuration ----
    // 640x480 RGB565 means 320 words per line. A wildly different number means
    // the sensor is not in the mode the table asked for.
    uint32_t lw = crd(C_LINE_WORDS);
    printf("measured line: %u words = %u pixels (expected %d)\n", lw, lw * 2, W);
    if (lw == 0) {
        fprintf(stderr, "measured line width is zero\n");
        return 1;
    }
    if ((int)(lw * 2) < W) {
        fprintf(stderr, "sensor delivers %u pixels per line, requested %d -- "
                        "using the measured width\n", lw * 2, W);
        W = (int)(lw * 2);
    }

    // ---- 3. RGB565 -> BGR888 into the dehaze input buffer ----
    // Rows are packed at stride W: the HLS core has no stride register.
    // While converting, also dump the packed BGR888 input next to the requested
    // output file (<out>.in.bgr), so the PC can show hazy-vs-dehazed side by
    // side without another round trip to the board.
    char in_name[512];
    snprintf(in_name, sizeof(in_name), "%s.in.bgr", argv[1]);
    FILE* fin = fopen(in_name, "wb");

    for (int y = 0; y < H; y++) {
        const uint32_t* line = cam + (size_t)y * CAM_STRIDE;
        uint8_t* o = src + (size_t)y * (size_t)W * 4;
        for (int x = 0; x < W; x += 2) {
            uint32_t w = line[x >> 1];
            uint8_t b, g, r;
            rgb565_to_bgr((uint16_t)(w & 0xFFFF), &b, &g, &r);
            o[x*4 + 0] = b;  o[x*4 + 1] = g;  o[x*4 + 2] = r;  o[x*4 + 3] = 0;
            if (x + 1 < W) {
                rgb565_to_bgr((uint16_t)(w >> 16), &b, &g, &r);
                o[(x+1)*4 + 0] = b;  o[(x+1)*4 + 1] = g;
                o[(x+1)*4 + 2] = r;  o[(x+1)*4 + 3] = 0;
            }
        }
        if (fin) {
            // repack BGR (drop the pad byte) as the PNG converter expects
            for (int x = 0; x < W; x++) fwrite(o + (size_t)x * 4, 1, 3, fin);
        }
    }
    if (fin) { fclose(fin); printf("wrote %s (hazy input, BGR888)\n", in_name); }
    printf("converted %dx%d from RGB565 to BGR888\n", W, H);

    // ---- 4. run the dehaze core ----
    if (!(rd(R_AP_CTRL) & AP_IDLE)) {
        printf("warning: core not idle (ap_ctrl=0x%08x)\n", rd(R_AP_CTRL));
    }
    wr(R_SRC,     (uint32_t)SRC_PHYS);
    wr(R_DST,     (uint32_t)DST_PHYS);
    wr(R_SCRATCH, (uint32_t)SCRATCH_PHYS);
    wr(R_WIDTH,   (uint32_t)W);
    wr(R_HEIGHT,  (uint32_t)H);
    wr(R_OMEGA,   243);
    wr(R_T0,      26);
    wr(R_GAIN,    269);
    wr(R_ACOMP,   90);
    wr(R_MODE,    (uint32_t)mode);

    double t0 = now_ms();
    wr(R_AP_CTRL, AP_START);
    for (;;) {
        if (rd(R_AP_CTRL) & AP_DONE) break;
        if (now_ms() - t0 > 20000.0) {
            fprintf(stderr, "timeout waiting for ap_done (ap_ctrl=0x%08x)\n",
                    rd(R_AP_CTRL));
            return 1;
        }
        usleep(POLL_US);
    }
    double t1 = now_ms();

    uint32_t A = rd(R_AP_RETURN);
    printf("dehaze mode %d: %dx%d  A(B,G,R) = %u,%u,%u  latency = %.2f ms\n",
           mode, W, H, A & 0xFF, (A >> 8) & 0xFF, (A >> 16) & 0xFF, t1 - t0);
    dump_camera_status("after dehaze");

    // ---- 5. write a BGR888 file the PC can turn into a PNG ----
    // Stride is W (see the note above), so the rows are already tightly packed.
    FILE* f = fopen(argv[1], "wb");
    if (!f) { fprintf(stderr, "create %s: %s\n", argv[1], strerror(errno)); return 1; }
    uint8_t* row = (uint8_t*)malloc((size_t)W * 3);
    for (int y = 0; y < H; y++) {
        const uint8_t* sp = dst + (size_t)y * (size_t)W * 4;
        for (int x = 0; x < W; x++) {
            row[x*3 + 0] = sp[x*4 + 0];
            row[x*3 + 1] = sp[x*4 + 1];
            row[x*3 + 2] = sp[x*4 + 2];
        }
        fwrite(row, 1, (size_t)W * 3, f);
    }
    fclose(f);
    free(row);

    printf("wrote %s (%d x %d BGR888)\n", argv[1], W, H);

    // ---- 6. one-glance verdict ----
    // Every stage of the chain reduced to a single character, so a bad run says
    // which stage is at fault without another round trip. The `sccb=..` line is
    // deliberately short: the Linux console wraps at 80 columns, and a wrapped
    // line cannot be grepped by the PC-side acceptance script.
    {
        uint32_t sv = crd(C_STATUS);
        uint32_t px = crd(C_PIXLINE);
        uint32_t wd = crd(C_WRDBG);
        uint32_t wn = crd(C_WCNT);
        int ok_sccb = (!(sv & ST_ERR)) && (((sv >> 4) & 0x1FF) >= SCCB_ENTRIES);
        int ok_cap  = (px == (uint32_t)W);
        int ok_ddr  = (crd(C_FRAMES) > 0) && !(wd & 0x20);
        printf("\n=== VERDICT ===\n");
        printf("sccb=%d cap=%d ddr=%d deh=1 px=%u nw=%u sent=%u st=%u\n",
               ok_sccb, ok_cap, ok_ddr, (unsigned)px,
               (unsigned)((wn >> 11) & 0x7FF), (unsigned)(wn & 0x7FF),
               (unsigned)(wd & 0xF));
        printf("  chip=%02X frames=%u A=%u,%u,%u t=%.1fms\n",
               (unsigned)((crd(C_RDBK) >> 24) & 0xFF), (unsigned)crd(C_FRAMES),
               A & 0xFF, (A >> 8) & 0xFF, (A >> 16) & 0xFF, t1 - t0);
        printf("  images: %s + %s\n", in_name, argv[1]);
        printf("===============\n");
    }

    printf("DONE\n");
    return 0;
}
