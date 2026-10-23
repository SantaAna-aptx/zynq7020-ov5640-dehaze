# -*- coding: utf-8 -*-
"""Compute the SAME sparse checksum the on-board program prints.

dehaze_linux.c (and main.c) do:
    s = 0;  for (i = 0; i < N; i += 97)  s = (s << 1) ^ p[i];
over the 32-bit output words, where word = B | G<<8 | R<<16.

This lets us verify the hardware without transferring 3 MB back:
just compare the number printed on the board with the one derived here
from the PC-side C-simulation output.

Usage:  python hw_checksum.py [--file ...hw_out_mode0.u8]
"""
import argparse
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
TV = os.path.join(ROOT, "01_hls", "tv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=os.path.join(TV, "hw_out_mode0.u8"))
    args = ap.parse_args()

    a = np.fromfile(args.file, dtype=np.uint8)
    n_bytes = a.size
    if n_bytes % 4 == 0 and n_bytes % 3 == 0:
        # ambiguous; the board dump is the 32-bit form, prefer it when the name says so
        use_words = 'board' in os.path.basename(args.file).lower() or n_bytes % 3 != 0
    else:
        use_words = (n_bytes % 4 == 0)

    if use_words:
        words = np.fromfile(args.file, dtype='<u4')
    else:
        if n_bytes % 3 != 0:
            raise SystemExit(f"{args.file}: size {n_bytes} is neither u32 words nor BGR bytes")
        b = a[0::3].astype(np.uint32)
        g = a[1::3].astype(np.uint32)
        r = a[2::3].astype(np.uint32)
        words = (r << 16) | (g << 8) | b
    n = words.size

    s = np.uint32(0)
    for i in range(0, n, 97):
        s = np.uint32(((int(s) << 1) ^ int(words[i])) & 0xFFFFFFFF)

    print(f"file      : {os.path.basename(args.file)}")
    print(f"pixels    : {n}")
    print(f"checksum  : 0x{int(s):08X}")
    print("")
    print("Compare this with the 'checksum' line printed on the board.")


if __name__ == "__main__":
    main()
