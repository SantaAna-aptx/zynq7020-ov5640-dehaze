# -*- coding: utf-8 -*-
"""Turn raw BGR888 dumps from the board into a PNG.

Two inputs, side by side, with a printed PSNR and mean brightness -- enough to
tell "the camera gave us a sensible image" from "the picture is black" without
opening anything else.

    python bin_to_png.py --w 640 --h 480 --out out/cam_compare.png \
        hw_out_cam.in.bgr hw_out_cam.bgr

Each input is a tightly packed W x H x 3 byte array, BGR order (the order the
dehaze core uses internally), which is what `dehaze_cam` writes.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image


def load_bgr(path, w, h):
    n = w * h * 3
    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size != n:
        sys.exit(f"{path}: {raw.size} bytes, expected {n} for {w}x{h}x3")
    return raw.reshape(h, w, 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--gap", type=int, default=8)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()

    tiles = []
    for f in a.files:
        if not os.path.exists(f):
            sys.exit(f"{f} not found")
        bgr = load_bgr(f, a.w, a.h)
        rgb = bgr[:, :, ::-1]
        tiles.append((os.path.basename(f), rgb))
        print(f"{os.path.basename(f):28s} mean={bgr.mean():6.2f}  "
              f"min={bgr.min():3d}  max={bgr.max():3d}")

    if len(tiles) == 2:
        d = (tiles[0][1].astype(np.float64) - tiles[1][1].astype(np.float64))
        mse = np.mean(d ** 2)
        psnr = 99.0 if mse < 1e-12 else 10.0 * np.log10(255.0 ** 2 / mse)
        print(f"PSNR(a, b)                 = {psnr:.2f} dB")

    gap = a.gap
    w, h = a.w, a.h
    n = len(tiles)
    canvas = np.full((h, w * n + gap * (n - 1), 3), 255, np.uint8)
    for i, (_, img) in enumerate(tiles):
        canvas[:, i * (w + gap):i * (w + gap) + w] = img

    out = a.out or (os.path.splitext(a.files[0])[0] + "_compare.png")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    Image.fromarray(canvas).save(out)
    print(f"[ok] {out}")


if __name__ == "__main__":
    main()
