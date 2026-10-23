# -*- coding: utf-8 -*-
"""Compare the hardware output with the Python reference and build a 3-panel image.

Inputs (all in 01_hls/tv/):
    fog_in.png          the hazy input
    fog_ref_mode0.u8    Python float reference (BGR bytes)
    hw_out_mode0.u8     HLS C-sim output (BGR bytes)          -- from csynth's csim
    hw_out_board.bin    board output (32-bit words, from JTAG) -- from 03_baremetal

Usage:
    python make_report.py           # prefer the C-sim output
    python make_report.py --board   # prefer the board output

Output:
    ../output/hw_compare_mode0.png
"""
import argparse
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
TV = os.path.join(ROOT, "01_hls", "tv")
OUT = os.path.join(ROOT, "output")


def load_u8(path, shape):
    a = np.fromfile(path, dtype=np.uint8)
    if a.size != int(np.prod(shape)):
        raise SystemExit(f"{path}: got {a.size} bytes, expected {int(np.prod(shape))}")
    return a.reshape(shape)


def load_words_bgr(path, shape):
    """32-bit words (low 24 bits = B,G,R) -> HxWx3 uint8 BGR."""
    w = np.fromfile(path, dtype='<u4')
    if w.size != int(np.prod(shape[:2])):
        raise SystemExit(f"{path}: got {w.size} words, expected {int(np.prod(shape[:2]))}")
    out = np.empty((shape[0], shape[1], 3), np.uint8)
    out[:, :, 0] = (w & 0xFF).reshape(shape[:2])
    out[:, :, 1] = ((w >> 8) & 0xFF).reshape(shape[:2])
    out[:, :, 2] = ((w >> 16) & 0xFF).reshape(shape[:2])
    return out


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if mse < 1e-12 else 10.0 * np.log10(255.0 ** 2 / mse)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", action="store_true",
                    help="use the JTAG readback instead of the C-sim output")
    args = ap.parse_args()

    src = cv2.imread(os.path.join(TV, "fog_in.png"))
    if src is None:
        raise SystemExit("fog_in.png not found -- run make_testvector.py first")
    h, w = src.shape[:2]

    ref = load_u8(os.path.join(TV, "fog_ref_mode0.u8"), (h, w, 3))

    tiles = [("(a) hazy input", src), ("(b) Python float reference", ref)]

    hw = None
    board_bin = os.path.join(TV, "hw_out_board.bin")
    sim_u8 = os.path.join(TV, "hw_out_mode0.u8")
    if args.board:
        if not os.path.exists(board_bin):
            sys.exit(f"--board given but {board_bin} not found; run 03_baremetal/run_jtag.tcl")
        hw = load_words_bgr(board_bin, (h, w, 3))
        label = "(c) FPGA board output"
    elif os.path.exists(sim_u8):
        hw = load_u8(sim_u8, (h, w, 3))
        label = "(c) FPGA fixed-point (C-sim)"
    elif os.path.exists(board_bin):
        hw = load_words_bgr(board_bin, (h, w, 3))
        label = "(c) FPGA board output"

    if hw is not None:
        tiles.append((label, hw))
        print(f"PSNR({label} vs Python) = {psnr(hw, ref):.2f} dB")
        print(f"max |diff|               = {np.abs(hw.astype(int) - ref.astype(int)).max()}")

    n = len(tiles)
    sep = 8
    canvas = np.full((h, w * n + sep * (n - 1), 3), 255, np.uint8)
    for i, (_, img) in enumerate(tiles):
        x = i * (w + sep)
        canvas[:, x:x + w] = img

    os.makedirs(OUT, exist_ok=True)
    dst = os.path.join(OUT, "hw_compare_mode0.png")
    cv2.imwrite(dst, canvas)
    print(f"[ok] {dst}")


if __name__ == "__main__":
    main()
