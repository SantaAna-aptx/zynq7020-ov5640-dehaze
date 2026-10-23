// ============================================================================
//  dehaze_tb.cpp  --  C testbench for dehaze_top (mode 0 and mode 1)
//
//  Runs both modes against the same input and compares each against its
//  Python float reference:
//      mode 0  <->  fog_ref_mode0.u8   (no refinement)
//      mode 1  <->  fog_ref_mode1.u8   (guided filter r=30)
//
//  Pass criteria: A matches, and both PSNRs >= 30 dB.
// ============================================================================
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>

#include "dehaze_top.h"
#include "tv_params.h"

#ifndef TV_GF_R
#define TV_GF_R 30
#endif

static std::vector<unsigned char> read_file(const char* path, size_t expect) {
    std::vector<unsigned char> buf(expect, 0);
    FILE* f = fopen(path, "rb");
    if (!f) { printf("[tb] ERROR: cannot open %s\n", path); exit(1); }
    size_t n = fread(&buf[0], 1, expect, f);
    fclose(f);
    if (n != expect) {
        printf("[tb] ERROR: %s short read %lu / %lu\n", path,
               (unsigned long)n, (unsigned long)expect);
        exit(1);
    }
    return buf;
}

static double psnr_of(const std::vector<ap_uint<32> >& img,
                      const std::vector<unsigned char>& ref) {
    double mse = 0.0;
    size_t n = img.size();
    for (size_t i = 0; i < n; i++) {
        ap_uint<32> p = img[i];
        for (int c = 0; c < 3; c++) {
            int hw = p.range(8*c+7, 8*c).to_int();
            int d  = hw - (int)ref[i*3 + c];
            mse += (double)d * (double)d;
        }
    }
    mse /= (double)(n * 3);
    return (mse > 1e-12) ? 10.0 * log10(255.0 * 255.0 / mse) : 99.0;
}

static void dump(const std::vector<ap_uint<32> >& img, const char* path) {
    std::vector<unsigned char> out(img.size() * 3);
    for (size_t i = 0; i < img.size(); i++) {
        ap_uint<32> p = img[i];
        for (int c = 0; c < 3; c++) out[i*3 + c] = (unsigned char)p.range(8*c+7, 8*c).to_int();
    }
    FILE* f = fopen(path, "wb");
    if (f) { fwrite(&out[0], 1, out.size(), f); fclose(f); }
}

int main() {
    const int W = TV_W, H = TV_H;
    const int N = W * H;
    const int TMAP_STRIDE = (W + 3) / 4;
    const int SCRATCH_WORDS = TMAP_STRIDE * H + N + 64;

    printf("[tb] image %d x %d (%d px), scratch %d words\n", W, H, N, SCRATCH_WORDS);

    std::vector<unsigned char> raw = read_file(TV_DIR "/fog_in.bin", (size_t)N * 4);
    std::vector<ap_uint<32> > src(N);
    for (int i = 0; i < N; i++) {
        unsigned int w = (unsigned int)raw[i*4+0]
                       | ((unsigned int)raw[i*4+1] << 8)
                       | ((unsigned int)raw[i*4+2] << 16)
                       | ((unsigned int)raw[i*4+3] << 24);
        src[i] = w;
    }

    std::vector<unsigned char> ref0 = read_file(TV_DIR "/fog_ref_mode0.u8", (size_t)N * 3);
    std::vector<unsigned char> ref1 = read_file(TV_DIR "/fog_ref_mode1.u8", (size_t)N * 3);

    std::vector<ap_uint<32> > dst(N, 0);
    std::vector<ap_uint<32> > scratch(SCRATCH_WORDS, 0);

    bool ok = true;

    for (int mode = 0; mode <= 1; mode++) {
        for (int i = 0; i < N; i++) dst[i] = 0;
        for (int i = 0; i < SCRATCH_WORDS; i++) scratch[i] = 0;

        ap_uint<32> A = dehaze_top(&src[0], &dst[0], &scratch[0],
                                   (ap_uint<16>)W, (ap_uint<16>)H,
                                   (ap_uint<16>)TV_OMEGA_Q8,
                                   (ap_uint<16>)TV_T0_Q8,
                                   (ap_uint<16>)TV_GAIN_Q8,
                                   (ap_uint<16>)TV_ACOMP_Q8,
                                   (ap_uint<8>)mode);

        int Ab = A.range(7,0).to_int();
        int Ag = A.range(15,8).to_int();
        int Ar = A.range(23,16).to_int();

        double p = psnr_of(dst, mode ? ref1 : ref0);
        printf("[tb] mode %d: A = %d,%d,%d (ref %d,%d,%d)  PSNR = %.2f dB\n",
               mode, Ab, Ag, Ar, TV_A_B, TV_A_G, TV_A_R, p);

        if (mode == 0) dump(dst, TV_DIR "/hw_out_mode0.u8");
        else           dump(dst, TV_DIR "/hw_out_mode1.u8");

        if (mode == 1) {
            // dump the intermediate maps so the fixed-point stages can be
            // checked one at a time against Python
            std::vector<unsigned char> tm((size_t)W * H);
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    ap_uint<32> w = scratch[TMAP_STRIDE * y + (x >> 2)];
                    tm[(size_t)y * W + x] = (unsigned char)((w >> ((x & 3) * 8)) & 0xFF).to_int();
                }
            FILE* ft = fopen(TV_DIR "/hw_tmap.u8", "wb");
            if (ft) { fwrite(&tm[0], 1, tm.size(), ft); fclose(ft); }

            std::vector<unsigned int> ab((size_t)W * H);
            for (int i = 0; i < N; i++) ab[i] = scratch[TMAP_STRIDE * H + i].to_int();
            FILE* fa = fopen(TV_DIR "/hw_abmap.bin", "wb");
            if (fa) { fwrite(&ab[0], 4, ab.size(), fa); fclose(fa); }
        }

        // A is now a statistic (mean colour of the top 0.1 % band), not a single
        // pixel, so it is only reproducible up to the dark-channel border
        // handling: the RTL clamps rows/columns at the edge, cv2.erode uses its
        // own border rule, and a slightly different set of pixels lands in the
        // top band. A tolerance of 3 levels keeps the check meaningful (a real
        // regression in the estimator moves A by tens) without failing on that.
        int dA = abs(Ab - TV_A_B) + abs(Ag - TV_A_G) + abs(Ar - TV_A_R);
        if (dA > 9) {
            printf("[tb] FAIL: mode %d atmospheric light mismatch (|delta| = %d)\n",
                   mode, dA);
            ok = false;
        }
        if (p < 30.0) {
            printf("[tb] FAIL: mode %d PSNR below 30 dB\n", mode);
            ok = false;
        }
    }

    printf(ok ? "[tb] PASS\n" : "[tb] FAIL\n");
    return ok ? 0 : 1;
}
