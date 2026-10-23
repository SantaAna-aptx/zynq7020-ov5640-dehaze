// ============================================================================
//  dehaze_linux.c  --  userspace driver for the PL dehaze core (v1, no JTAG)
//
//  Reuses the flow the YOLO project already proved on this board:
//      wget -> /lib/firmware/<x>.bin
//      echo <x>.bin > /sys/class/fpga_manager/fpga0/firmware
//      mmap /dev/mem, poke the AXI-Lite registers, poll ap_done
//
//  Usage (on the board):
//      ./dehaze_linux <in.bin> <out.bin> <mode>
//          mode 0 : dark channel + transmission + recover (no refinement)
//          mode 1 : + guided filter refinement
//
//      <in.bin>  IMG_W*IMG_H little-endian u32 words, low 24 bits = B,G,R
//                (exactly what 00_tools/make_testvector.py produces)
//
//  Register map (must match xdehaze_top_hw.h from the exported IP):
//      0x00 ap_ctrl   0x10 ap_return  0x18 src     0x20 dst
//      0x28 scratch   0x30 width      0x38 height  0x40 omega
//      0x48 t0        0x50 gain       0x58 mode
//
//  Build (PC, SDK's aarch32 linux-gnueabi toolchain):
//      arm-linux-gnueabihf-gcc -O2 -Wall -o dehaze_linux dehaze_linux.c
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

// ---------------------------------------------------------------- memory map
// All buffers sit above the kernel's mem=120M window; /dev/mem still reaches
// them (the camera buffer at 0x08000000 in the YOLO project proves this).
#define REG_PHYS     0x43C00000UL
#define REG_SIZE     0x00010000UL

#define SRC_PHYS     0x08000000UL
#define DST_PHYS     0x0C000000UL
#define SCRATCH_PHYS 0x10000000UL

#define IMG_W      1025
#define IMG_H      720
#define IMG_WORDS  ((size_t)IMG_W * IMG_H)
#define IMG_BYTES  (IMG_WORDS * 4)

// scratch layout, must match TMAP_STRIDE / ABMAP_BASE in dehaze_top.cpp
#define TMAP_STRIDE   ((IMG_W + 3) / 4)                 // 257 words per row
#define TMAP_WORDS    ((size_t)TMAP_STRIDE * IMG_H)     // 185040
#define SCRATCH_WORDS (TMAP_WORDS + IMG_WORDS)          // 923040
#define SCRATCH_BYTES (SCRATCH_WORDS * 4)

// ---------------------------------------------------------------- registers
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

#define CAL_ITERS 10000000   /* must match CAL_ITERS in dehaze_top.cpp */

#define POLL_US   100        /* delay between ap_done polls */

#define AP_START  (1u << 0)
#define AP_DONE   (1u << 1)
#define AP_IDLE   (1u << 2)

static volatile uint32_t* reg = NULL;

static inline void wr(uint32_t off, uint32_t v) { *(volatile uint32_t*)((char*)reg + off) = v; }
static inline uint32_t rd(uint32_t off) { return *(volatile uint32_t*)((char*)reg + off); }

static void* map_phys(int fd, unsigned long phys, size_t len) {
    void* p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap 0x%08lx (%zu bytes) failed: %s\n", phys, len, strerror(errno));
        fprintf(stderr, "  hint: if STRICT_DEVMEM is on, add iomem=relaxed to bootargs\n");
        exit(1);
    }
    return p;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int read_all(const char* path, void* buf, size_t len) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return -1; }
    size_t n = fread(buf, 1, len, f);
    fclose(f);
    if (n != len) { fprintf(stderr, "%s: short read %zu/%zu\n", path, n, len); return -1; }
    return 0;
}

static int write_all(const char* path, const void* buf, size_t len) {
    FILE* f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "create %s: %s\n", path, strerror(errno)); return -1; }
    size_t n = fwrite(buf, 1, len, f);
    fclose(f);
    if (n != len) { fprintf(stderr, "%s: short write %zu/%zu\n", path, n, len); return -1; }
    return 0;
}

static uint32_t checksum(const uint32_t* p, size_t n) {
    uint32_t s = 0;
    for (size_t i = 0; i < n; i += 97) s = (s << 1) ^ p[i];
    return s;
}

static int run_once(unsigned mode, uint8_t* dst, int w, int h) {
    if (!(rd(R_AP_CTRL) & AP_IDLE)) {
        printf("warning: core not idle (ap_ctrl=0x%08x)\n", rd(R_AP_CTRL));
    }
    memset(dst, 0, IMG_BYTES);

    wr(R_SRC,     (uint32_t)SRC_PHYS);
    wr(R_DST,     (uint32_t)DST_PHYS);
    wr(R_SCRATCH, (uint32_t)SCRATCH_PHYS);
    wr(R_WIDTH,   w);
    wr(R_HEIGHT,  h);
    wr(R_OMEGA,   243);      // 0.95 in Q8
    wr(R_T0,      26);       // 0.10 in Q8
    wr(R_GAIN,    269);      // 1.05 in Q8
    wr(R_ACOMP,   90);       // A chroma kept at 0.35 (0 = pure grey)
    wr(R_MODE,    mode);

    double t0 = now_ms();
    wr(R_AP_CTRL, AP_START);
    // Poll with a delay on purpose. A tight uncached read loop hammers the
    // AXI-Lite port and competes with the PL's own DDR traffic through the
    // interconnect -- measuring showed it can dominate the frame time.
    for (;;) {
        if (rd(R_AP_CTRL) & AP_DONE) break;
        if (now_ms() - t0 > 10000.0) {
            fprintf(stderr, "timeout waiting for ap_done (ap_ctrl=0x%08x)\n", rd(R_AP_CTRL));
            return -1;
        }
        usleep(POLL_US);
    }
    double t1 = now_ms();

    uint32_t A = rd(R_AP_RETURN);
    double ms = t1 - t0;
    printf("mode %u: A (B,G,R) = %u,%u,%u   latency = %.2f ms   checksum = 0x%08x\n",
           mode, A & 0xFF, (A >> 8) & 0xFF, (A >> 16) & 0xFF, ms,
           checksum((const uint32_t*)dst, (size_t)w * h));

    if (mode == 2) {
        // CAL_ITERS iterations at II=1 -> that many PL clock cycles exactly
        double clk_mhz = (double)CAL_ITERS / (ms * 1000.0);
        printf("      calibration: %d iters in %.2f ms  =>  FCLK0 = %.2f MHz\n",
               CAL_ITERS, ms, clk_mhz);
        printf("      expected FCLK0 = 50.00 MHz\n");
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc != 4 && argc != 6) {
        fprintf(stderr, "usage: %s <in.bin> <out.bin> <mode> [width height]\n", argv[0]);
        fprintf(stderr, "       expects %dx%d u32 words (%zu bytes)\n", IMG_W, IMG_H, IMG_BYTES);
        return 1;
    }
    int mode = atoi(argv[3]);
    if (mode < 0 || mode > 2) { fprintf(stderr, "mode must be 0, 1 or 2\n"); return 1; }

    // optional width/height override -- used to characterise where the frame
    // time goes (per pixel vs per row vs per launch)
    int w = IMG_W, h = IMG_H;
    if (argc >= 6) { w = atoi(argv[4]); h = atoi(argv[5]); }
    if (w < 64 || w > IMG_W || h < 64 || h > IMG_H) {
        fprintf(stderr, "size out of range (64..%d x 64..%d)\n", IMG_W, IMG_H);
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { fprintf(stderr, "open /dev/mem: %s\n", strerror(errno)); return 1; }

    reg       = (volatile uint32_t*)map_phys(fd, REG_PHYS, REG_SIZE);
    uint8_t* src = (uint8_t*)map_phys(fd, SRC_PHYS, IMG_BYTES);
    uint8_t* dst = (uint8_t*)map_phys(fd, DST_PHYS, IMG_BYTES);
    (void)map_phys(fd, SCRATCH_PHYS, SCRATCH_BYTES);   // touch it so a bad map fails early

    printf("dehaze v1: %dx%d  src=0x%08lx dst=0x%08lx scratch=0x%08lx (%zu bytes) regs=0x%08lx\n",
           IMG_W, IMG_H, SRC_PHYS, DST_PHYS, SCRATCH_PHYS, SCRATCH_BYTES, REG_PHYS);

    if (read_all(argv[1], src, IMG_BYTES) != 0) return 1;
    if (run_once((unsigned)mode, dst, w, h) != 0) return 1;
    if (write_all(argv[2], dst, IMG_BYTES) != 0) return 1;

    printf("wrote %s\nDONE\n", argv[2]);
    return 0;
}
