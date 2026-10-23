# -*- coding: utf-8 -*-
"""Compare the HLS intermediate maps (t, a, b) against a fixed-point Python model.

This is the debugging tool used while bringing up mode 1: it isolates whether a
numerical error comes from the transmission stage, the guided-filter stage A or
stage B, instead of staring at a 8 dB PSNR.

Run after csim produced hw_tmap.u8 / hw_abmap.bin.
"""
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
TV = os.path.join(ROOT, "01_hls", "tv")

W, H = 1025, 720
PATCH = 15
OMEGA_Q8 = 243
GF_R = 30
EPS_Q8 = 1665
N = W * H
GF_KQ = 4509


def dark_channel(img8, patch=15):
    mn = img8.min(axis=2)
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (patch, patch))
    return cv2.erode(mn, k)


def main():
    src = cv2.imread(os.path.join(TV, "fog_in.png"))
    if src is None:
        raise SystemExit("fog_in.png missing")
    assert src.shape[:2] == (H, W)

    A = np.array([217, 215, 214], dtype=np.int64)      # B,G,R from the hardware run

    # ---- expected t (8-bit domain), same formula as the RTL ----
    I = src.astype(np.int64)
    # the RTL erodes the I/A ratio, not I
    ratio = np.stack([np.minimum(255, ((I[:, :, c] * 65536) // A[c]) >> 8)
                      for c in range(3)], 2)
    rmin = ratio.min(axis=2).astype(np.uint16)
    dark_q8 = cv2.erode(rmin, cv2.getStructuringElement(cv2.MORPH_RECT, (PATCH, PATCH))).astype(np.int64)
    t_q8 = 256 - ((OMEGA_Q8 * dark_q8) >> 8)
    t_q8 = np.clip(t_q8, 0, 255)
    p8 = ((t_q8 * 255 + 128) >> 8).astype(np.uint8)

    hw_t = np.fromfile(os.path.join(TV, "hw_tmap.u8"), dtype=np.uint8).reshape(H, W)
    diff = np.abs(hw_t.astype(int) - p8.astype(int))
    print(f"tmap : max|diff| = {diff.max()}   mean = {diff.mean():.2f}   "
          f"nonzero = {int((diff != 0).sum())}/{N}")
    if diff.max() > 1:
        ys, xs = np.where(diff > 1)
        print(f"       first bad pixel: ({ys[0]},{xs[0]})  hw={hw_t[ys[0], xs[0]]} "
              f"exp={p8[ys[0], xs[0]]}")
        print(f"       hw  row0[0:8] = {hw_t[0, :8].tolist()}")
        print(f"       exp row0[0:8] = {p8[0, :8].tolist()}")

    # ---- expected a,b via the same fixed-point box filter ----
    g8 = cv2.cvtColor(src, cv2.COLOR_BGR2GRAY)
    k = 2 * GF_R + 1
    rep = cv2.BORDER_REPLICATE

    def box(x):
        s = cv2.boxFilter(x.astype(np.float64), -1, (k, k), borderType=rep) * (k * k)
        return np.rint(s).astype(np.int64)

    sI = box(g8)
    sP = box(p8)
    sII = box(g8.astype(np.int64) * g8.astype(np.int64))
    sIP = box(g8.astype(np.int64) * p8.astype(np.int64))

    mI = (sI * GF_KQ) >> 16
    mP = (sP * GF_KQ) >> 16
    mII = (sII * GF_KQ) >> 16
    mIP = (sIP * GF_KQ) >> 16

    var = mII - ((mI * mI) >> 8)
    cov = mIP - ((mI * mP) >> 8)
    var = np.maximum(var, 0)

    den = np.maximum(var + EPS_Q8, 1)
    # same normalised reciprocal as the RTL
    kk = np.zeros_like(den)
    y = den.copy()
    for thr, sh in ((4096, 12), (262144, 6), (2097152, 3), (4194304, 2), (8388608, 1)):
        m = y < thr
        y[m] <<= sh
        kk[m] += sh
    j = ((y >> 15) & 0xFF).astype(np.int64)
    lut = np.array([(2**32 + (256 + i) // 2) // (256 + i) for i in range(256)], dtype=np.int64)
    rcp = lut[j] >> (23 - kk)

    aq = (np.abs(cov) * rcp) >> 16
    aq = np.where(cov < 0, -aq, aq)
    aq = np.clip(aq, -2048, 2047)
    bq = mP - ((aq * mI) >> 8)
    b8 = (bq + 128) >> 8
    b8 = np.clip(b8, -512, 511)

    # cast to int64 *before* masking, otherwise the subtract underflows on uint32
    # RTL packing: b in bits [9:0], a in bits [21:10]
    raw = np.fromfile(os.path.join(TV, "hw_abmap.bin"), dtype="<u4").reshape(H, W).astype(np.int64)
    hw_a = (raw >> 10) & 0xFFF
    hw_a = np.where(hw_a >= 0x800, hw_a - 0x1000, hw_a)
    hw_b = raw & 0x3FF
    hw_b = np.where(hw_b >= 0x200, hw_b - 0x400, hw_b)

    da = np.abs(hw_a.astype(int) - aq)
    db = np.abs(hw_b.astype(int) - b8)
    print(f"a    : max|diff| = {da.max()}   mean = {da.mean():.2f}   "
          f"hw mean = {hw_a.mean():.1f}  exp mean = {aq.mean():.1f}")
    print(f"b    : max|diff| = {db.max()}   mean = {db.mean():.2f}   "
          f"hw mean = {hw_b.mean():.1f}  exp mean = {b8.mean():.1f}")

    # ---- is the map merely shifted, or genuinely wrong? ----
    print("\nshift search (a):")
    for dy in (-2, -1, 0, 1, 2):
        row = []
        for dx in (-2, -1, 0, 1, 2):
            h = np.roll(np.roll(hw_a, dy, axis=0), dx, axis=1)
            row.append(np.abs(h[5:-5, 5:-5] - aq[5:-5, 5:-5]).mean())
        print("  dy=%+d  " % dy + "  ".join("%8.2f" % v for v in row))

    # ---- per-pixel breakdown at one location ----
    yy, xx = 400, 500
    print(f"\nsample ({yy},{xx}):")
    print(f"  g8={g8[yy,xx]} p8={p8[yy,xx]}")
    print(f"  mI={mI[yy,xx]} mP={mP[yy,xx]} mII={mII[yy,xx]} mIP={mIP[yy,xx]}")
    print(f"  var={var[yy,xx]} cov={cov[yy,xx]} den={den[yy,xx]} rcp={rcp[yy,xx]}")
    print(f"  exp a={aq[yy,xx]} b={b8[yy,xx]}   hw a={hw_a[yy,xx]} b={hw_b[yy,xx]}")

    # ---- how much of the hw map is pinned at the clamp? ----
    print(f"\nhw a: at clamp(-2048)={int((hw_a<=-2048).sum())}  at clamp(2047)={int((hw_a>=2047).sum())}  zeros={int((hw_a==0).sum())}")
    print(f"hw b: at clamp(-512)={int((hw_b<=-512).sum())}   at clamp(511)={int((hw_b>=511).sum())}")
    print(f"exp a: min={aq.min()} max={aq.max()}   exp b: min={b8.min()} max={b8.max()}")


if __name__ == "__main__":
    main()
