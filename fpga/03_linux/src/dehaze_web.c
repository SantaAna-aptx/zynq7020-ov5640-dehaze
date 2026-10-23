// ============================================================================
//  dehaze_web.c  --  live view for the pure-PL camera + dehaze demo
//
//  What it does, once per iteration:
//      1. waits for the PL to move on to a new frame in the DDR ring,
//      2. converts that frame from the ring (RGB565, 2 pixels per 32-bit word,
//         row stride CAM_STRIDE words) into the packed BGRx the dehaze core
//         expects, and writes it out as raw.bmp,
//      3. runs the HLS dehaze core on it,
//      4. writes the result as out.bmp and a one-line stats.txt.
//
//  A static index.html in the same directory shows the two BMPs and refreshes
//  them from JavaScript. Nothing on the board encodes an image format: a 24-bit
//  BMP is a 54-byte header plus the pixels, so there is no libjpeg/libpng
//  dependency on a busybox rootfs, and every browser can display it.
//
//  Usage:
//      dehaze_web <outdir> [mode] [width] [height]
//  and optional runtime override:
//      echo 0 > <outdir>/mode.cfg      (0 = no refinement, 1 = guided filter)
//
//  Why the ring is read with a stride but the core is fed without one: the HLS
//  core has no stride register -- it walks exactly W*H pixels -- so the rows are
//  repacked here, and the BMP is written from the repacked buffer, not the ring.
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
#define REG_PHYS     0x43C00000UL            // dehaze control registers
#define REG_SIZE     0x00010000UL
#define CAM_REG_PHYS 0x43C10000UL            // camera status/control
#define CAM_REG_SIZE 0x00001000UL
#define SRC_PHYS     0x08000000UL            // dehaze input, BGR888 32 bit/px
#define DST_PHYS     0x0C000000UL            // dehaze output
#define SCRATCH_PHYS 0x10000000UL            // mode 1 workspace
#define CAM_PHYS     0x20000000UL            // camera ring base (matches BASE in RTL)

#define CAM_STRIDE   2048                    // 32-bit words per ring row (RTL)
#define CAM_ROWS     1024                    // ring depth (RTL)

#define IMG_W_MAX    1024
#define IMG_H_MAX    720
#define IMG_WORDS    ((size_t)IMG_W_MAX * IMG_H_MAX)
#define IMG_BYTES    (IMG_WORDS * 4)

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
#define C_WRDBG     0x38

#define AP_START  (1u << 0)
#define AP_DONE   (1u << 1)
#define AP_IDLE   (1u << 2)
#define POLL_US   100

#define ST_BUSY   (1u << 0)
#define ST_DONE   (1u << 1)
#define ST_ERR    (1u << 2)
#define ST_OVF    (1u << 3)
#define ST_DROP   (1u << 4)

static volatile uint32_t* reg  = NULL;
static volatile uint32_t* creg = NULL;

static inline void     wr(uint32_t off, uint32_t v) { *(volatile uint32_t*)((char*)reg + off) = v; }
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

// RGB565 -> 8 bit per channel, with bit replication so 0xFFFF becomes 255
static inline void rgb565_to_bgr(uint16_t p, uint8_t* b, uint8_t* g, uint8_t* r) {
    uint8_t r5 = (p >> 11) & 0x1F;
    uint8_t g6 = (p >> 5)  & 0x3F;
    uint8_t b5 =  p        & 0x1F;
    *r = (uint8_t)((r5 << 3) | (r5 >> 2));
    *g = (uint8_t)((g6 << 2) | (g6 >> 4));
    *b = (uint8_t)((b5 << 3) | (b5 >> 2));
}

// ---------------------------------------------------------------- BMP output
// 24-bit uncompressed, bottom-up, written through a temporary file and renamed:
// the web server may be reading the old file at any moment, and rename(2) makes
// the swap atomic, so a browser never sees a half-written image.
static int write_bmp(const char* dir, const char* name,
                     const volatile uint8_t* bgrx, int w, int h) {
    char tmp[512], dst[512];
    snprintf(tmp, sizeof(tmp), "%s/%s.tmp", dir, name);
    snprintf(dst, sizeof(dst), "%s/%s", dir, name);

    FILE* f = fopen(tmp, "wb");
    if (!f) { fprintf(stderr, "open %s: %s\n", tmp, strerror(errno)); return -1; }

    const int row_bytes = w * 3;
    const int pad       = (4 - (row_bytes & 3)) & 3;
    const uint32_t img  = (uint32_t)(row_bytes + pad) * (uint32_t)h;
    const uint32_t fsz  = 54 + img;

    uint8_t hdr[54];
    memset(hdr, 0, sizeof(hdr));
    hdr[0] = 'B'; hdr[1] = 'M';
    memcpy(&hdr[2],  &fsz, 4);
    uint32_t off = 54; memcpy(&hdr[10], &off, 4);
    uint32_t dib = 40; memcpy(&hdr[14], &dib, 4);
    int32_t  iw = w, ih = h; memcpy(&hdr[18], &iw, 4); memcpy(&hdr[22], &ih, 4);
    uint16_t planes = 1, bpp = 24; memcpy(&hdr[26], &planes, 2); memcpy(&hdr[28], &bpp, 2);
    memcpy(&hdr[34], &img, 4);
    int32_t ppm = 2835; memcpy(&hdr[38], &ppm, 4); memcpy(&hdr[42], &ppm, 4);
    fwrite(hdr, 1, sizeof(hdr), f);

    static uint8_t* rowbuf = NULL;
    if (!rowbuf) rowbuf = (uint8_t*)malloc((size_t)row_bytes + 4);
    const uint8_t zero[4] = {0, 0, 0, 0};

    for (int y = h - 1; y >= 0; y--) {
        const volatile uint8_t* src = bgrx + (size_t)y * (size_t)w * 4;
        for (int x = 0; x < w; x++) {
            rowbuf[x * 3 + 0] = src[x * 4 + 0];
            rowbuf[x * 3 + 1] = src[x * 4 + 1];
            rowbuf[x * 3 + 2] = src[x * 4 + 2];
        }
        fwrite(rowbuf, 1, (size_t)row_bytes, f);
        if (pad) fwrite(zero, 1, (size_t)pad, f);
    }
    fclose(f);
    if (rename(tmp, dst) != 0) {
        fprintf(stderr, "rename %s: %s\n", dst, strerror(errno));
        return -1;
    }
    return 0;
}

// ---------------------------------------------------------------- core control
// Runtime parameters. omega / t0 / gain are Q8 values the core takes from its
// AXI-Lite registers, so they can be changed without touching the bitstream --
// which is exactly what makes quality tuning practical on this board (one PL
// reload costs one of the ~6 the board allows between power cycles).
typedef struct {
    int omega_q8;      // 0..256, dehazing strength (256 = 1.0)
    int t0_q8;         // 1..256, floor on the transmission
    int gain_q8;       // 256 = 1.0, final brightness
    int acomp_q8;      // 256 = keep A's colour, 0 = force it grey
    int mode;          // 0 = no refinement, 1 = guided filter
} params_t;

static params_t P = { 176, 72, 280, 96, 1 };

static void write_stats(const char* dir, double fps, double core_ms,
                        uint32_t A, uint32_t frames, int w, int h) {
    char tmp[512], dst[512];
    snprintf(tmp, sizeof(tmp), "%s/stats.txt.tmp", dir);
    snprintf(dst, sizeof(dst), "%s/stats.txt", dir);
    FILE* f = fopen(tmp, "w");
    if (!f) return;
    // one short line, no spaces inside a value: the page splits on whitespace
    fprintf(f, "fps=%.1f core=%.0fms A=%u,%u,%u mode=%d frames=%u res=%dx%d "
               "omega=%d t0=%d gain=%d acomp=%d\n",
            fps, core_ms, A & 0xFF, (A >> 8) & 0xFF, (A >> 16) & 0xFF,
            P.mode, (unsigned)frames, w, h, P.omega_q8, P.t0_q8, P.gain_q8, P.acomp_q8);
    fclose(f);
    rename(tmp, dst);
}

// ---------------------------------------------------------------- core control
// <dir>/params.cfg holds one key=value per line:
//     omega=192
//     t0=64
//     gain=269
//     mode=1
// The page writes it through a tiny CGI script, but plain `echo` on the serial
// console works just as well.
static void read_params(const char* dir) {
    char path[512];
    snprintf(path, sizeof(path), "%s/params.cfg", dir);
    FILE* f = fopen(path, "r");
    if (!f) return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char key[32];
        int  val;
        if (sscanf(line, " %31[^= \t]=%d", key, &val) != 2) continue;
        if (!strcmp(key, "omega") && val >= 0 && val <= 256) P.omega_q8 = val;
        else if (!strcmp(key, "t0")    && val >= 1 && val <= 256) P.t0_q8 = val;
        else if (!strcmp(key, "gain")  && val >= 128 && val <= 512) P.gain_q8 = val;
        else if (!strcmp(key, "acomp") && val >= 0   && val <= 256) P.acomp_q8 = val;
        else if (!strcmp(key, "mode")  && (val == 0 || val == 1)) P.mode = val;
    }
    fclose(f);
}

static int run_core(int w, int h, double* out_ms) {
    if (!(rd(R_AP_CTRL) & AP_IDLE)) {
        double t = now_ms();
        while (!(rd(R_AP_CTRL) & AP_IDLE)) {
            if (now_ms() - t > 3000.0) return -2;      // stuck, caller retries
            usleep(POLL_US);
        }
    }
    wr(R_SRC,     (uint32_t)SRC_PHYS);
    wr(R_DST,     (uint32_t)DST_PHYS);
    wr(R_SCRATCH, (uint32_t)SCRATCH_PHYS);
    wr(R_WIDTH,   (uint32_t)w);
    wr(R_HEIGHT,  (uint32_t)h);
    wr(R_OMEGA,   (uint32_t)P.omega_q8);
    wr(R_T0,      (uint32_t)P.t0_q8);
    wr(R_GAIN,    (uint32_t)P.gain_q8);
    wr(R_ACOMP,   (uint32_t)P.acomp_q8);
    wr(R_MODE,    (uint32_t)P.mode);

    double t0 = now_ms();
    wr(R_AP_CTRL, AP_START);
    for (;;) {
        if (rd(R_AP_CTRL) & AP_DONE) break;
        if (now_ms() - t0 > 5000.0) return -1;
        usleep(POLL_US);
    }
    if (out_ms) *out_ms = now_ms() - t0;
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <outdir> [mode 0|1] [width] [height]\n", argv[0]);
        return 1;
    }
    const char* outdir = argv[1];
    int W    = (argc >= 4) ? atoi(argv[3]) : 640;
    int H    = (argc >= 5) ? atoi(argv[4]) : 480;
    if (W < 64 || W > IMG_W_MAX || H < 32 || H > IMG_H_MAX) {
        fprintf(stderr, "bad geometry %dx%d\n", W, H);
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { fprintf(stderr, "open /dev/mem: %s\n", strerror(errno)); return 1; }

    reg  = (volatile uint32_t*)map_phys(fd, REG_PHYS, REG_SIZE);
    creg = (volatile uint32_t*)map_phys(fd, CAM_REG_PHYS, CAM_REG_SIZE);
    uint8_t* src = (uint8_t*)map_phys(fd, SRC_PHYS, IMG_BYTES);
    uint8_t* dst = (uint8_t*)map_phys(fd, DST_PHYS, IMG_BYTES);
    (void)map_phys(fd, SCRATCH_PHYS, SCRATCH_BYTES);
    uint32_t* cam = (uint32_t*)map_phys(fd, CAM_PHYS, (size_t)CAM_STRIDE * CAM_ROWS * 4);

    // The sensor delivers 640 pixels per line; take the measured width if it
    // differs, so the view shows what the camera actually produces.
    uint32_t lw = crd(C_LINE_WORDS);
    if (lw != 0 && (int)(lw * 2) != W) {
        printf("note: sensor sends %u px/line, using that instead of %d\n", lw * 2, W);
        W = (int)(lw * 2);
        if (W > IMG_W_MAX) W = IMG_W_MAX;
    }

    // start from the values on the command line, then let params.cfg override
    P.mode     = (argc >= 3) ? atoi(argv[2]) : 1;   // omega/t0/gain/acomp keep their defaults
    read_params(outdir);

    printf("dehaze_web: %dx%d mode %d omega %d t0 %d gain %d acomp %d -> %s\n",
           W, H, P.mode, P.omega_q8, P.t0_q8, P.gain_q8, P.acomp_q8, outdir);
    fflush(stdout);

    uint32_t last_frames = crd(C_FRAMES);
    uint32_t total = 0;
    double   t_start = now_ms();
    double   core_ms = 0.0;
    uint32_t A = 0;
    uint32_t ovf_warned = 0;

    for (;;) {
        // ---- 1. wait for a new frame ------------------------------------
        double tw = now_ms();
        while (crd(C_FRAMES) == last_frames) {
            if (now_ms() - tw > 2000.0) break;      // sensor stalled: keep serving
            usleep(3000);
        }
        last_frames = crd(C_FRAMES);

        // ---- 2. ring -> packed BGRx (+ raw.bmp) -------------------------
        for (int y = 0; y < H; y++) {
            const uint32_t* line = cam + (size_t)y * CAM_STRIDE;
            uint8_t* o = src + (size_t)y * (size_t)W * 4;
            for (int x = 0; x < W; x += 2) {
                uint32_t w32 = line[x >> 1];
                uint8_t b, g, r;
                rgb565_to_bgr((uint16_t)(w32 & 0xFFFF), &b, &g, &r);
                o[x * 4 + 0] = b; o[x * 4 + 1] = g; o[x * 4 + 2] = r; o[x * 4 + 3] = 0;
                if (x + 1 < W) {
                    rgb565_to_bgr((uint16_t)(w32 >> 16), &b, &g, &r);
                    o[(x + 1) * 4 + 0] = b; o[(x + 1) * 4 + 1] = g;
                    o[(x + 1) * 4 + 2] = r; o[(x + 1) * 4 + 3] = 0;
                }
            }
        }
        write_bmp(outdir, "raw.bmp", src, W, H);

        // ---- 3. run the core -------------------------------------------
        int rc = run_core(W, H, &core_ms);
        if (rc != 0) {
            printf("core did not finish (rc=%d), retrying\n", rc);
            fflush(stdout);
            usleep(50 * 1000);
            continue;
        }
        A = rd(R_AP_RETURN);
        write_bmp(outdir, "out.bmp", dst, W, H);

        // ---- 4. stats + runtime parameter override -----------------------
        total++;
        double elapsed = (now_ms() - t_start) / 1000.0;
        write_stats(outdir, elapsed > 0.0 ? total / elapsed : 0.0, core_ms, A,
                    last_frames, W, H);

        // params.cfg is rewritten by the page (through a CGI script) or by hand
        // on the serial console; picking it up here makes tuning interactive.
        params_t before = P;
        read_params(outdir);
        if (P.omega_q8 != before.omega_q8 || P.t0_q8 != before.t0_q8 ||
            P.gain_q8 != before.gain_q8 || P.acomp_q8 != before.acomp_q8 ||
            P.mode != before.mode) {
            printf("params -> mode %d omega %d t0 %d gain %d acomp %d\n",
                   P.mode, P.omega_q8, P.t0_q8, P.gain_q8, P.acomp_q8);
            fflush(stdout);
        }

        uint32_t st = crd(C_STATUS);
        if ((st & ST_OVF) && !ovf_warned) {
            // Sticky flag, normally set by the very first line after the
            // bitstream is loaded, before the sensor has settled.
            printf("note: capture overflow flag is set (sticky, from start-up)\n");
            fflush(stdout);
            ovf_warned = 1;
        }
        if ((st & ST_DROP) && !ovf_warned) {
            printf("note: writer dropped a line (DDR too slow)\n");
            fflush(stdout);
            ovf_warned = 1;
        }

        if ((total % 20) == 0) {
            printf("frames=%u fps=%.1f core=%.0fms A=%u,%u,%u\n", (unsigned)last_frames,
                   elapsed > 0.0 ? total / elapsed : 0.0, core_ms,
                   A & 0xFF, (A >> 8) & 0xFF, (A >> 16) & 0xFF);
            fflush(stdout);
        }
    }
    return 0;
}
