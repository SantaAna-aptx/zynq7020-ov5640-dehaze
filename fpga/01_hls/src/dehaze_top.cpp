// ============================================================================
//  dehaze_top.cpp  --  Dark Channel Prior dehazing, fixed-point HW (v1)
//
//  Passes over DDR:
//    1. dark channel (separable 15x15 min) + 256-bin histogram  -> atmospheric A
//    2a. normalized dark channel -> transmission t  (mode 0: recover -> dst)
//    2b. guided filter stage A: box(guide) / box(t) -> (a,b)     [mode 1]
//    2c. guided filter stage B: box(a,b) -> q, then recover      [mode 1]
//
//  Atmospheric light (v2): the per-bin accumulators now carry the SUM of each of
//  R,G,B, so A is the mean colour of the top 0.1 % of the dark-channel
//  histogram, not the RGB of one single pixel. The single-pixel estimate was the
//  main source of colour casts: it latched onto one specular pixel whose channel
//  spread was arbitrary (measured on the board: A = 206,190,198), and J_c =
//  (I_c - A_c)/t + A_c turns a 16-level A difference into a ~40-level channel
//  shift once t drops to 0.3 -- the blue channel ends up crushed and the picture
//  goes green. `acomp_q8` then pulls A towards grey: 256 keeps it as estimated,
//  0 makes it perfectly neutral. That knob is a register, so the cast can be
//  finished off from Linux without re-synthesising.
//
//  Fixed point (all values are in the 8-bit image domain unless noted):
//    guide g, transmission p : 8 bit, 0..255
//    means, a, b, dark, t    : Q8 (value * 256) internally
//    a stored as Q8 (a*256), b stored as the plain 8-bit value (b*255)
//    No runtime divider in the hot loops: 1/A once per frame, 1/t from a
//    257-entry ROM, and 1/(var+eps) from a normalised 256-entry ROM.
//
//  Line buffers: one 61-row x 1025 x 32 bit window, reused by passes 2b and 2c.
//  Separable box filter: 61 row accumulator + a sliding column sum.
// ============================================================================
#include "dehaze_top.h"
#include "invt_lut.h"
#include "recip_lut.h"

#define LB_SLOTS 16          // power of two, used as a mask; window is 15 rows
#define GF_K     61          // guided-filter window (radius 30)
#define GF_N     3721        // 61*61
#define GF_KQ    4509        // round(2^24 / 3721)

// mean_q8 = (sum * 4509) >> 16  ==  sum * 256 / 3721

#define GRAY_SHIFT 14
#define GRAY_R     4899
#define GRAY_G     9617
#define GRAY_B     1868

#define CAL_ITERS  10000000     // mode 2: iterations at II=1 -> known cycle count

static inline ap_uint<16> min16(ap_uint<16> a, ap_uint<16> b) {
#pragma HLS INLINE
    return (a < b) ? a : b;
}

// ---------------------------------------------------------------------------
//  1/x in Q24 (i.e. returns 2^24 / x) for x in [1, 2^24).
//  x is normalised into [2^23,2^24); an 8-bit mantissa lookup then gives
//  ~0.4 % worst-case relative error, which is far below the 8-bit output step.
// ---------------------------------------------------------------------------
static inline ap_uint<32> recip_q24(ap_uint<24> x) {
#pragma HLS INLINE
    ap_uint<24> y = x;
    int k = 0;
    if (y < 4096u)      { y <<= 12; k += 12; }
    if (y < 262144u)    { y <<= 6;  k += 6;  }
    if (y < 2097152u)   { y <<= 3;  k += 3;  }
    if (y < 4194304u)   { y <<= 2;  k += 2;  }
    if (y < 8388608u)   { y <<= 1;  k += 1;  }
    int j = (int)((y >> 15) & 0xFF);
    ap_uint<32> m = RECIP_LUT[j];
    return m >> (23 - k);
}

// J_c = ((I_c - A_c) / max(t,t0) + A_c) clipped, then * gain clipped
// invt is Q16 of 1/t_q8; t_q8 is already Q8 so the shift is 8, not 16.
static inline int recover_ch(int iv, int av, ap_uint<17> invt, int gain) {
#pragma HLS INLINE
    ap_int<10>  d    = (ap_int<10>)iv - (ap_int<10>)av;
    ap_int<18>  invi = (ap_int<18>)invt;
    ap_int<28>  prod = d * invi;
    ap_int<28>  q    = prod >> 8;
    ap_int<11>  j    = (ap_int<11>)q + (ap_int<11>)av;
    if (j < 0)   j = 0;
    if (j > 255) j = 255;
    ap_int<20>  jg   = (ap_int<20>)j * (ap_int<20>)gain;
    jg = jg >> 8;
    if (jg < 0)   jg = 0;
    if (jg > 255) jg = 255;
    return jg.to_int();
}

ap_uint<32> dehaze_top(
    ap_uint<32>* src,
    ap_uint<32>* dst,
    ap_uint<32>* scratch,
    ap_uint<16> width,
    ap_uint<16> height,
    ap_uint<16> omega_q8,
    ap_uint<16> t0_q8,
    ap_uint<16> gain_q8,
    ap_uint<16> acomp_q8,
    ap_uint<8>  mode)
{
#pragma HLS INTERFACE m_axi     port=src     offset=slave bundle=gmem0 depth=738000 \
                            max_read_burst_length=64 max_write_burst_length=64 \
                            num_read_outstanding=32 num_write_outstanding=32
#pragma HLS INTERFACE m_axi     port=scratch offset=slave bundle=gmem2 depth=1000000 \
                            max_read_burst_length=64 max_write_burst_length=64 \
                            num_read_outstanding=32 num_write_outstanding=32
#pragma HLS INTERFACE m_axi     port=dst     offset=slave bundle=gmem1 depth=738000 \
                            max_write_burst_length=64 num_write_outstanding=32
#pragma HLS INTERFACE s_axilite port=width    bundle=ctrl
#pragma HLS INTERFACE s_axilite port=height   bundle=ctrl
#pragma HLS INTERFACE s_axilite port=omega_q8 bundle=ctrl
#pragma HLS INTERFACE s_axilite port=t0_q8    bundle=ctrl
#pragma HLS INTERFACE s_axilite port=gain_q8  bundle=ctrl
#pragma HLS INTERFACE s_axilite port=acomp_q8 bundle=ctrl
#pragma HLS INTERFACE s_axilite port=mode     bundle=ctrl
#pragma HLS INTERFACE s_axilite port=return   bundle=ctrl

    int W = width.to_int();
    int H = height.to_int();
    if (W > DEHAZE_MAX_W) W = DEHAZE_MAX_W;
    if (H > DEHAZE_MAX_H) H = DEHAZE_MAX_H;
    if (W < 64) W = 64;
    if (H < 64) H = 64;

    int omega = omega_q8.to_int();
    int t0q   = t0_q8.to_int();
    int gain  = gain_q8.to_int();
    int acomp = acomp_q8.to_int();
    if (t0q  < 1) t0q  = 1;
    if (gain < 1) gain = 256;
    if (acomp > 256) acomp = 256;

    const int TMAP_STRIDE = (W + 3) >> 2;        // words per row, 4 pixels each
    const int TMAP_WORDS  = TMAP_STRIDE * H;
    const int ABMAP_BASE  = TMAP_WORDS;
    int use_gf = (mode != 0);

    // NOTE: an earlier "mode 2" clock-calibration loop lived here. It has been
    // removed on purpose: the early `return` inside a conditional left the
    // ap_ctrl FSM with ap_start stuck at 1, so the NEXT invocation never ran.
    // The PL clock is characterised with probe_clock.ps1 instead.

    // ---- 15-row window for the dark channel ----
    ap_uint<16> lb[LB_SLOTS][DEHAZE_MAX_W];
#pragma HLS ARRAY_PARTITION variable=lb complete dim=1

    // ---- 61-row window for the guided filter (reused by both stages) ----
    ap_uint<32> gf_lb[GF_K][DEHAZE_MAX_W];
    ap_uint<32> cs[4][DEHAZE_MAX_W];             // column sums: g, p, g*g, g*p

    // ---- histogram ----
    // bin_cnt counts pixels; bin_sr/sg/sb accumulate each channel inside the bin,
    // which is what makes A the mean colour of the top band instead of one pixel.
    ap_uint<20> bin_cnt[256];
    ap_uint<24> bin_sr[256];
    ap_uint<24> bin_sg[256];
    ap_uint<24> bin_sb[256];

    for (int b = 0; b < 256; b++) {
#pragma HLS PIPELINE II=1
        bin_cnt[b] = 0;
        bin_sr[b]  = 0;
        bin_sg[b]  = 0;
        bin_sb[b]  = 0;
    }

    // ==================== pass 1: dark channel + histogram ====================
    int wy = 0;

    for (int k = 0; k < H + 14; k++) {
        int ry = k - 7;
        if (ry < 0)   ry = 0;
        if (ry > H-1) ry = H-1;
        int base = ry * W;

        ap_uint<16> hs[15];
#pragma HLS ARRAY_PARTITION variable=hs complete

        // Split the border clamping OUT of the hot loop: the middle sweep now
        // walks src[base + x] with x strictly sequential, which is what lets
        // HLS infer AXI bursts instead of single beats.
        //   j = 0..6      -> column 0 repeated        (no output)
        //   j = 7..W+6    -> columns 0..W-1           (outputs 0 .. W-8)
        //   j = W+7..W+13 -> column W-1 repeated      (outputs W-7 .. W-1)
        for (int j = 0; j < 7; j++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[base];
            ap_uint<16> m = px.range(7,0);
            if (px.range(15,8)  < m) m = px.range(15,8);
            if (px.range(23,16) < m) m = px.range(23,16);
            for (int i = 14; i > 0; i--) {
#pragma HLS UNROLL
                hs[i] = hs[i-1];
            }
            hs[0] = m;
        }
        for (int x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[base + x];
            ap_uint<16> m = px.range(7,0);
            if (px.range(15,8)  < m) m = px.range(15,8);
            if (px.range(23,16) < m) m = px.range(23,16);

            for (int i = 14; i > 0; i--) {
#pragma HLS UNROLL
                hs[i] = hs[i-1];
            }
            hs[0] = m;

            ap_uint<16> mn = hs[0];
            for (int i = 1; i < 15; i++) {
#pragma HLS UNROLL
                mn = min16(mn, hs[i]);
            }
            if (x >= 7) {
                lb[wy & (LB_SLOTS-1)][x-7] = mn;
            }
        }
        for (int j = 0; j < 7; j++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[base + W-1];
            ap_uint<16> m = px.range(7,0);
            if (px.range(15,8)  < m) m = px.range(15,8);
            if (px.range(23,16) < m) m = px.range(23,16);

            for (int i = 14; i > 0; i--) {
#pragma HLS UNROLL
                hs[i] = hs[i-1];
            }
            hs[0] = m;

            ap_uint<16> mn = hs[0];
            for (int i = 1; i < 15; i++) {
#pragma HLS UNROLL
                mn = min16(mn, hs[i]);
            }
            lb[wy & (LB_SLOTS-1)][W-7+j] = mn;
        }
        wy++;

        if (k >= 14) {
            int y     = k - 14;
            int obase = y * W;
            for (int x = 0; x < W; x++) {
#pragma HLS PIPELINE II=2
                ap_uint<16> mn = 65535;
                for (int q = 0; q < 15; q++) {
#pragma HLS UNROLL
                    mn = min16(mn, lb[(wy + 1 + q) & (LB_SLOTS-1)][x]);
                }
                ap_uint<8> dark8 = mn.range(7,0);

                // The pixel colour for the A estimate. This is a second read of
                // the row (the old code kept a 7-row R+G+B buffer instead), which
                // costs one extra image read per frame -- worth it: keeping three
                // channels in that buffer would have tripled it, and the frame is
                // not DDR-bound (the guided filter dominates).
                ap_uint<32> pxh = src[obase + x];

                bin_cnt[dark8] = bin_cnt[dark8] + 1;
                bin_sr[dark8]  = bin_sr[dark8] + (ap_uint<8>)pxh.range(23,16);
                bin_sg[dark8]  = bin_sg[dark8] + (ap_uint<8>)pxh.range(15,8);
                bin_sb[dark8]  = bin_sb[dark8] + (ap_uint<8>)pxh.range(7,0);
            }
        }
    }

    // ==================== estimate atmospheric light A ====================
    int n_top = (W * H) / 1000;
    if (n_top < 1) n_top = 1;

    int acc = 0, T = 255;
    bool found = false;
    for (int b = 255; b >= 0; b--) {
        int cnt = bin_cnt[b].to_int();
        if (!found && cnt != 0) {
            acc += cnt;
            T = b;
            if (acc >= n_top) found = true;
        }
    }

    // Mean colour of the top band, per channel. A single pixel used to be taken
    // here and it was the main cause of the colour cast (see the header).
    long sumr = 0, sumg = 0, sumb = 0, cnt_all = 0;
    for (int b = 255; b >= T; b--) {
        sumr += bin_sr[b].to_int();
        sumg += bin_sg[b].to_int();
        sumb += bin_sb[b].to_int();
        cnt_all += bin_cnt[b].to_int();
    }

    int Ar = 128, Ag = 128, Ab = 128;
    if (cnt_all > 0) {
        Ar = (int)(sumr / cnt_all);
        Ag = (int)(sumg / cnt_all);
        Ab = (int)(sumb / cnt_all);
    }

    // Pull A towards its own grey level: acomp = 256 keeps the estimate as is,
    // 0 forces a perfectly neutral A. Per-channel A divided by a low t is what
    // turns a small estimation error into a visible colour cast.
    {
        int grey = (Ar + Ag + Ab) / 3;
        Ar = grey + (((Ar - grey) * acomp) >> 8);
        Ag = grey + (((Ag - grey) * acomp) >> 8);
        Ab = grey + (((Ab - grey) * acomp) >> 8);
    }

    if (Ab < 1) Ab = 1;
    if (Ag < 1) Ag = 1;
    if (Ar < 1) Ar = 1;
    if (Ab > 255) Ab = 255;
    if (Ag > 255) Ag = 255;
    if (Ar > 255) Ar = 255;

    ap_uint<17> invAb = (ap_uint<17>)((65536 + (Ab >> 1)) / Ab);
    ap_uint<17> invAg = (ap_uint<17>)((65536 + (Ag >> 1)) / Ag);
    ap_uint<17> invAr = (ap_uint<17>)((65536 + (Ar >> 1)) / Ar);

    // ==================== pass 2a: transmission ====================
    wy = 0;

    for (int k = 0; k < H + 14; k++) {
        int ry = k - 7;
        if (ry < 0)   ry = 0;
        if (ry > H-1) ry = H-1;
        int base = ry * W;

        ap_uint<16> hs[15];
#pragma HLS ARRAY_PARTITION variable=hs complete

        // same border split as pass 1: the middle sweep must stay sequential
        // so the AXI master can burst.
        for (int j = 0; j < 7; j++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[base];
            ap_uint<24> rb = ((ap_uint<24>)px.range(7,0)   * invAb) >> 8;
            ap_uint<24> rg = ((ap_uint<24>)px.range(15,8)  * invAg) >> 8;
            ap_uint<24> rr = ((ap_uint<24>)px.range(23,16) * invAr) >> 8;
            ap_uint<16> m = rb.range(15,0);
            if (rg.range(15,0) < m) m = rg.range(15,0);
            if (rr.range(15,0) < m) m = rr.range(15,0);
            for (int i = 14; i > 0; i--) {
#pragma HLS UNROLL
                hs[i] = hs[i-1];
            }
            hs[0] = m;
        }
        for (int x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[base + x];

            ap_uint<24> rb = ((ap_uint<24>)px.range(7,0)   * invAb) >> 8;
            ap_uint<24> rg = ((ap_uint<24>)px.range(15,8)  * invAg) >> 8;
            ap_uint<24> rr = ((ap_uint<24>)px.range(23,16) * invAr) >> 8;

            ap_uint<16> m = rb.range(15,0);
            if (rg.range(15,0) < m) m = rg.range(15,0);
            if (rr.range(15,0) < m) m = rr.range(15,0);

            for (int i = 14; i > 0; i--) {
#pragma HLS UNROLL
                hs[i] = hs[i-1];
            }
            hs[0] = m;

            ap_uint<16> mn = hs[0];
            for (int i = 1; i < 15; i++) {
#pragma HLS UNROLL
                mn = min16(mn, hs[i]);
            }
            if (x >= 7) {
                lb[wy & (LB_SLOTS-1)][x-7] = mn;
            }
        }
        for (int j = 0; j < 7; j++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[base + W-1];
            ap_uint<24> rb = ((ap_uint<24>)px.range(7,0)   * invAb) >> 8;
            ap_uint<24> rg = ((ap_uint<24>)px.range(15,8)  * invAg) >> 8;
            ap_uint<24> rr = ((ap_uint<24>)px.range(23,16) * invAr) >> 8;
            ap_uint<16> m = rb.range(15,0);
            if (rg.range(15,0) < m) m = rg.range(15,0);
            if (rr.range(15,0) < m) m = rr.range(15,0);
            for (int i = 14; i > 0; i--) {
#pragma HLS UNROLL
                hs[i] = hs[i-1];
            }
            hs[0] = m;
            ap_uint<16> mn = hs[0];
            for (int i = 1; i < 15; i++) {
#pragma HLS UNROLL
                mn = min16(mn, hs[i]);
            }
            lb[wy & (LB_SLOTS-1)][W-7+j] = mn;
        }
        wy++;

        if (k >= 14) {
            int y     = k - 14;
            int obase = y * W;
            ap_uint<32> wacc = 0;
            for (int x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
                ap_uint<16> mn = 65535;
                for (int q = 0; q < 15; q++) {
#pragma HLS UNROLL
                    mn = min16(mn, lb[(wy + 1 + q) & (LB_SLOTS-1)][x]);
                }
                int dark_q8 = mn.to_int();

                int tq = 256 - ((omega * dark_q8) >> 8);
                if (tq < 0)   tq = 0;
                if (tq > 255) tq = 255;

                if (use_gf) {
                    // pack p = round(t_q8 * 255 / 256), 4 pixels per word.
                    // Accumulate in a register instead of read-modify-writing
                    // DDR, otherwise the 4 lanes of a word race each other.
                    ap_uint<8> p8 = (ap_uint<8>)((tq * 255 + 128) >> 8);
                    if ((x & 3) == 0) wacc = 0;
                    wacc = wacc | ((ap_uint<32>)p8 << ((x & 3) * 8));
                    if ((x & 3) == 3 || x == W-1) {
                        scratch[TMAP_STRIDE * y + (x >> 2)] = wacc;
                    }
                } else {
                    int teff = (tq > t0q) ? tq : t0q;
                    if (teff > 256) teff = 256;
                    ap_uint<17> invt = INV_T_Q16[teff];

                    ap_uint<32> px = src[obase + x];
                    int jb = recover_ch(px.range(7,0).to_int(),   Ab, invt, gain);
                    int jg = recover_ch(px.range(15,8).to_int(),  Ag, invt, gain);
                    int jr = recover_ch(px.range(23,16).to_int(), Ar, invt, gain);
                    dst[obase + x] = (ap_uint<32>)((jr << 16) | (jg << 8) | jb);
                }
            }
        }
    }

    if (!use_gf) {
        return (ap_uint<32>)((Ar << 16) | (Ag << 8) | Ab);
    }

    // ==================== pass 2b: guided filter stage A -> (a,b) ====================
    // Streams rows from -60 to H+29 with the row index clamped, so the window
    // replicates the border rows exactly like BORDER_REPLICATE in OpenCV.
    {
        int x;
        for (x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
            cs[0][x] = 0; cs[1][x] = 0; cs[2][x] = 0; cs[3][x] = 0;
        }
        for (int r = 0; r < GF_K; r++) {
            for (x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
                gf_lb[r][x] = 0;
            }
        }
    }

    int slot = 0;
    for (int yy = -60; yy < H + 30; yy++) {
        int sy = yy;
        if (sy < 0)   sy = 0;
        if (sy > H-1) sy = H-1;
        int sbase = sy * W;

        // ---- A1: push row, update column sums ----
        for (int x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> px = src[sbase + x];
            ap_uint<32> gi = (ap_uint<32>)px.range(23,16) * GRAY_R
                           + (ap_uint<32>)px.range(15,8)  * GRAY_G
                           + (ap_uint<32>)px.range(7,0)   * GRAY_B
                           + 8192u;
            ap_uint<8> g8 = (ap_uint<8>)(gi >> GRAY_SHIFT);

            ap_uint<32> tw = scratch[TMAP_STRIDE * sy + (x >> 2)];
            ap_uint<8>  p8 = (ap_uint<8>)(tw >> ((x & 3) * 8));

            ap_uint<32> old = gf_lb[slot][x];
            ap_uint<8> og = (ap_uint<8>)old.range(7,0);
            ap_uint<8> op = (ap_uint<8>)old.range(15,8);

            gf_lb[slot][x] = (ap_uint<32>)((ap_uint<16>)g8 | ((ap_uint<16>)p8 << 8));

            ap_uint<32> gg  = (ap_uint<32>)((ap_uint<17>)g8 * g8);
            ap_uint<32> ogg = (ap_uint<32>)((ap_uint<17>)og * og);
            ap_uint<32> gp  = (ap_uint<32>)((ap_uint<17>)g8 * p8);
            ap_uint<32> ogp = (ap_uint<32>)((ap_uint<17>)og * op);

            cs[0][x] = cs[0][x] + (ap_uint<32>)g8 - (ap_uint<32>)og;
            cs[1][x] = cs[1][x] + (ap_uint<32>)p8 - (ap_uint<32>)op;
            cs[2][x] = cs[2][x] + gg  - ogg;
            cs[3][x] = cs[3][x] + gp  - ogp;
        }
        slot = (slot == GF_K-1) ? 0 : slot + 1;

        // ---- A2: horizontal sliding window, emit (a,b) for row yy-30 ----
        ap_uint<32> hw0[GF_K], hw1[GF_K], hw2[GF_K], hw3[GF_K];
#pragma HLS ARRAY_PARTITION variable=hw0 complete
#pragma HLS ARRAY_PARTITION variable=hw1 complete
#pragma HLS ARRAY_PARTITION variable=hw2 complete
#pragma HLS ARRAY_PARTITION variable=hw3 complete
        ap_uint<32> s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        for (int i = 0; i < GF_K; i++) {
#pragma HLS UNROLL
            hw0[i] = 0; hw1[i] = 0; hw2[i] = 0; hw3[i] = 0;
        }

        int y_out = yy - 30;
        int obase = (y_out < 0 ? 0 : (y_out > H-1 ? H-1 : y_out)) * W;

        for (int j = 0; j < W + 60; j++) {
#pragma HLS PIPELINE II=1
            int cx = j - 30;
            if (cx < 0)   cx = 0;
            if (cx > W-1) cx = W-1;

            ap_uint<32> a0 = cs[0][cx], a1 = cs[1][cx], a2 = cs[2][cx], a3 = cs[3][cx];
            s0 = s0 + a0 - hw0[GF_K-1];
            s1 = s1 + a1 - hw1[GF_K-1];
            s2 = s2 + a2 - hw2[GF_K-1];
            s3 = s3 + a3 - hw3[GF_K-1];
            for (int i = GF_K-1; i > 0; i--) {
#pragma HLS UNROLL
                hw0[i] = hw0[i-1]; hw1[i] = hw1[i-1];
                hw2[i] = hw2[i-1]; hw3[i] = hw3[i-1];
            }
            hw0[0] = a0; hw1[0] = a1; hw2[0] = a2; hw3[0] = a3;

            if (j >= 60) {
                int xo = j - 60;
                int xg = (xo < 0 ? 0 : (xo > W-1 ? W-1 : xo));

                // means in Q8
                ap_uint<32> mI  = (ap_uint<32>)(((ap_uint<64>)s0 * GF_KQ) >> 16);
                ap_uint<32> mP  = (ap_uint<32>)(((ap_uint<64>)s1 * GF_KQ) >> 16);
                ap_uint<32> mII = (ap_uint<32>)(((ap_uint<64>)s2 * GF_KQ) >> 16);
                ap_uint<32> mIP = (ap_uint<32>)(((ap_uint<64>)s3 * GF_KQ) >> 16);

                ap_int<32> var = (ap_int<32>)mII - (ap_int<32>)((mI * mI) >> 8);
                ap_int<32> cov = (ap_int<32>)mIP - (ap_int<32>)((mI * mP) >> 8);
                if (var < 0) var = 0;

                const int EPS_Q8 = 1665;             // 1e-4 * 255^2 * 256
                ap_uint<24> den = (ap_uint<24>)(var + EPS_Q8);
                if (den < 1u) den = 1u;
                ap_uint<32> rcp = recip_q24(den);

                ap_int<32> acon = cov;
                ap_int<32> asgn = 1;
                if (acon < 0) { acon = -acon; asgn = -1; }
                ap_int<32> aq = (ap_int<32>)(((ap_int<64>)acon * (ap_int<64>)rcp) >> 16);
                aq = aq * asgn;
                if (aq >  2047) aq =  2047;
                if (aq < -2048) aq = -2048;

                // b in Q8, then store it in the plain 8-bit domain: 1 LSB of
                // the 8-bit domain is far below the output quantisation.
                ap_int<32> bq  = (ap_int<32>)mP - ((aq * (ap_int<32>)mI) >> 8);
                ap_int<32> b8s = (bq + 128) >> 8;
                if (b8s >  511) b8s =  511;
                if (b8s < -512) b8s = -512;

                ap_uint<32> packed = (ap_uint<32>)((ap_uint<32>)b8s.range(9,0))
                                   | ((ap_uint<32>)aq.range(11,0) << 10);                scratch[ABMAP_BASE + obase + xg] = packed;
            }
        }
    }

    // ==================== pass 2c: guided filter stage B -> q, recover ====================
    {
        int x;
        for (x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
            cs[0][x] = 0; cs[1][x] = 0;
            cs[2][x] = 0; cs[3][x] = 0;
        }
        for (int r = 0; r < GF_K; r++) {
            for (x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
                gf_lb[r][x] = 0;
            }
        }
    }

    slot = 0;
    for (int yy = -60; yy < H + 30; yy++) {
        int sy = yy;
        if (sy < 0)   sy = 0;
        if (sy > H-1) sy = H-1;
        int sbase = sy * W;

        for (int x = 0; x < W; x++) {
#pragma HLS PIPELINE II=1
            ap_uint<32> w = scratch[ABMAP_BASE + sbase + x];
            ap_uint<32> old = gf_lb[slot][x];
            gf_lb[slot][x] = w;

            // must match the packing in pass 2b: b in [9:0], a in [21:10]
            ap_int<12> na = (ap_int<12>)w.range(21,10);
            ap_int<12> oa = (ap_int<12>)old.range(21,10);
            ap_int<10> nb = (ap_int<10>)w.range(9,0);
            ap_int<10> ob = (ap_int<10>)old.range(9,0);

            cs[0][x] = (ap_uint<32>)((ap_int<32>)cs[0][x] + (ap_int<32>)na - (ap_int<32>)oa);
            cs[1][x] = (ap_uint<32>)((ap_int<32>)cs[1][x] + (ap_int<32>)nb - (ap_int<32>)ob);
        }
        slot = (slot == GF_K-1) ? 0 : slot + 1;

        ap_uint<32> hw0[GF_K], hw1[GF_K];
#pragma HLS ARRAY_PARTITION variable=hw0 complete
#pragma HLS ARRAY_PARTITION variable=hw1 complete
        ap_int<32> s0 = 0, s1 = 0;
        for (int i = 0; i < GF_K; i++) {
#pragma HLS UNROLL
            hw0[i] = 0; hw1[i] = 0;
        }

        int y_out = yy - 30;
        if (y_out >= 0 && y_out < H) {
            int obase = y_out * W;

            for (int j = 0; j < W + 60; j++) {
#pragma HLS PIPELINE II=1
                int cx = j - 30;
                if (cx < 0)   cx = 0;
                if (cx > W-1) cx = W-1;

                ap_int<32> a0 = (ap_int<32>)cs[0][cx];
                ap_int<32> a1 = (ap_int<32>)cs[1][cx];
                s0 = s0 + a0 - (ap_int<32>)hw0[GF_K-1];
                s1 = s1 + a1 - (ap_int<32>)hw1[GF_K-1];
                for (int i = GF_K-1; i > 0; i--) {
#pragma HLS UNROLL
                    hw0[i] = hw0[i-1]; hw1[i] = hw1[i-1];
                }
                hw0[0] = (ap_uint<32>)a0; hw1[0] = (ap_uint<32>)a1;

                if (j >= 60) {
                    int xo = j - 60;
                    ap_int<32> mA = (ap_int<32>)(((ap_int<64>)s0 * GF_KQ) >> 16);
                    ap_int<32> mB = (ap_int<32>)(((ap_int<64>)s1 * GF_KQ) >> 16);

                    // One read serves both roles: the guide at row y_out and the
                    // RGB for the recovery are the SAME pixel (gbase == obase),
                    // so reading it twice used to cost an extra 2.95 MB/frame.
                    ap_uint<32> px = src[obase + xo];

                    ap_int<32> g8 = (ap_int<32>)px.range(23,16) * GRAY_R
                                  + (ap_int<32>)px.range(15,8)  * GRAY_G
                                  + (ap_int<32>)px.range(7,0)   * GRAY_B
                                  + 8192;
                    g8 = g8 >> GRAY_SHIFT;

                    // mA = mean(a_q8)*256 = a*65536, mB = mean(b)*256, so
                    //   ((mA*g8)>>8) + mB = 256*(a*g8 + b)   ->  q8 is Q8
                    ap_int<32> q8 = ((mA * g8) >> 8) + mB;
                    if (q8 < 0) q8 = 0;

                    // t = q8/(256*255), and the core wants t_q8 = t*256,
                    // so t_q8 = q8/255 ~= q8*257 >> 16.
                    int tq = (int)(((ap_int<64>)q8 * 257) >> 16);
                    if (tq < 0)   tq = 0;
                    if (tq > 255) tq = 255;
                    int teff = (tq > t0q) ? tq : t0q;
                    if (teff > 256) teff = 256;
                    ap_uint<17> invt = INV_T_Q16[teff];

                    int jb = recover_ch(px.range(7,0).to_int(),   Ab, invt, gain);
                    int jg = recover_ch(px.range(15,8).to_int(),  Ag, invt, gain);
                    int jr = recover_ch(px.range(23,16).to_int(), Ar, invt, gain);
                    dst[obase + xo] = (ap_uint<32>)((jr << 16) | (jg << 8) | jb);
                }
            }
        }
    }

    return (ap_uint<32>)((Ar << 16) | (Ag << 8) | Ab);
}
