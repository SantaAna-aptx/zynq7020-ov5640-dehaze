# -*- coding: utf-8 -*-
"""Stage-B check: rebuild the output from the *hardware's own* (a,b) map.

If this reproduces the Python reference, the RTL's stage B is at fault; if it
also collapses, my abmap -> q -> recover math is wrong.

Usage: python check_stageb.py
"""
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
TV = os.path.join(ROOT, "01_hls", "tv")

W, H = 1025, 720
GF_R = 30
K = 2 * GF_R + 1
T0_Q8 = 26
GAIN_Q8 = 269
A = np.array([217, 215, 214], dtype=np.int64)
INV_T = np.array([65535] + [(65536 + i // 2) // i for i in range(1, 257)], dtype=np.int64)


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if mse < 1e-12 else 10 * np.log10(255.0 ** 2 / mse)


def main():
    src = cv2.imread(os.path.join(TV, "fog_in.png"))
    raw = np.fromfile(os.path.join(TV, "hw_abmap.bin"), dtype="<u4").reshape(H, W).astype(np.int64)
    a_q8 = (raw >> 10) & 0xFFF
    a_q8 = np.where(a_q8 >= 0x800, a_q8 - 0x1000, a_q8)
    b8 = raw & 0x3FF
    b8 = np.where(b8 >= 0x200, b8 - 0x400, b8)

    rep = cv2.BORDER_REPLICATE
    mA = cv2.boxFilter(a_q8.astype(np.float64), -1, (K, K), borderType=rep)
    mB = cv2.boxFilter(b8.astype(np.float64), -1, (K, K), borderType=rep)

    g8 = cv2.cvtColor(src, cv2.COLOR_BGR2GRAY).astype(np.float64)
    q = mA * g8 / 256.0 + mB                     # 8-bit domain
    tq8 = np.rint(q * 256.0 / 255.0).astype(np.int64)
    tq8 = np.clip(tq8, 0, 255)
    teff = np.maximum(tq8, T0_Q8)

    I = src.astype(np.float64)
    out = np.empty_like(I)
    for c in range(3):
        invt = INV_T[teff].astype(np.float64) / 256.0     # 256/t_q8 == 1/t
        j = (I[:, :, c] - A[c]) * invt + A[c]
        j = np.clip(j, 0, 255)
        j = np.clip(j * GAIN_Q8 / 256.0, 0, 255)
        out[:, :, c] = j
    out_u8 = np.rint(out).astype(np.uint8)

    ref1 = np.fromfile(os.path.join(TV, "fog_ref_mode1.u8"), dtype=np.uint8).reshape(H, W, 3)
    hw1 = np.fromfile(os.path.join(TV, "hw_out_mode1.u8"), dtype=np.uint8).reshape(H, W, 3)

    print(f"q range        : {q.min():.1f} .. {q.max():.1f}   mean {q.mean():.1f}")
    print(f"PSNR(py-from-hw-abmap vs ref1) = {psnr(out_u8, ref1):.2f} dB")
    print(f"PSNR(hw mode1          vs ref1) = {psnr(hw1, ref1):.2f} dB")
    print(f"PSNR(py-from-hw-abmap vs hw)   = {psnr(out_u8, hw1):.2f} dB")

    print("\nshift search (hw vs py-from-abmap), PSNR:")
    for dy in (-2, -1, 0, 1, 2):
        row = []
        for dx in (-2, -1, 0, 1, 2):
            h = np.roll(np.roll(hw1, dy, axis=0), dx, axis=1)
            row.append(psnr(h[40:-40, 40:-40], out_u8[40:-40, 40:-40]))
        print("  dy=%+d  " % dy + "  ".join("%6.2f" % v for v in row))

    print(f"\nhw1   mean BGR = {hw1.reshape(-1,3).mean(axis=0)}")
    print(f"pyout mean BGR = {out_u8.reshape(-1,3).mean(axis=0)}")
    print(f"hw1[400,500] = {hw1[400,500]}   pyout[400,500] = {out_u8[400,500]}")
    print(f"q[400,500] = {q[400,500]:.1f}  tq8[400,500] = {tq8[400,500]}")

    cv2.imwrite(os.path.join(ROOT, "output", "dbg_stageb.png"),
                np.hstack([src, ref1, out_u8, hw1]))


if __name__ == "__main__":
    main()
