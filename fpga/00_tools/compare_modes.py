# -*- coding: utf-8 -*-
"""Four-panel comparison and PSNR check for both modes.

Prefers the real board outputs when they exist:
    hw_out_mode0.bin / hw_out_mode1.bin   (32-bit words, from the board)
and falls back to the C-simulation dumps:
    hw_out_mode0.u8 / hw_out_mode1.u8     (3 BGR bytes per pixel)

Panels: hazy input | mode 0 | mode 1 | Python reference (mode 1)
"""
import argparse
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
TV = os.path.join(ROOT, "01_hls", "tv")
OUT = os.path.join(ROOT, "output")


def load_u8(path, shape):
    a = np.fromfile(path, dtype=np.uint8)
    if a.size != int(np.prod(shape)):
        raise SystemExit(f"{path}: {a.size} bytes, expected {int(np.prod(shape))}")
    return a.reshape(shape)


def load_words(path, shape):
    w = np.fromfile(path, dtype="<u4")
    if w.size != shape[0] * shape[1]:
        raise SystemExit(f"{path}: {w.size} words, expected {shape[0]*shape[1]}")
    out = np.empty(shape, np.uint8)
    out[:, :, 0] = (w & 0xFF).reshape(shape[:2])
    out[:, :, 1] = ((w >> 8) & 0xFF).reshape(shape[:2])
    out[:, :, 2] = ((w >> 16) & 0xFF).reshape(shape[:2])
    return out


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if mse < 1e-12 else 10 * np.log10(255.0 ** 2 / mse)


def load_mode(mode, shape):
    """Return (image, source_label) for a given mode, board output first."""
    b = os.path.join(TV, f"hw_out_mode{mode}.bin")
    u = os.path.join(TV, f"hw_out_mode{mode}.u8")
    if os.path.exists(b):
        return load_words(b, shape), "board"
    if os.path.exists(u):
        return load_u8(u, shape), "csim"
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", action="store_true", help="require board outputs")
    args = ap.parse_args()

    src = cv2.imread(os.path.join(TV, "fog_in.png"))
    if src is None:
        raise SystemExit("fog_in.png missing -- run make_testvector.py")
    h, w = src.shape[:2]
    shp = (h, w, 3)

    ref0 = load_u8(os.path.join(TV, "fog_ref_mode0.u8"), shp)
    ref1 = load_u8(os.path.join(TV, "fog_ref_mode1.u8"), shp)

    m0, s0 = load_mode(0, shp)
    m1, s1 = load_mode(1, shp)
    if args.board and (s0 != "board" or s1 != "board"):
        raise SystemExit("board outputs missing (hw_out_mode{0,1}.bin)")

    print(f"{'mode':<6}{'source':<8}{'PSNR vs Python':>16}{'max|diff|':>12}")
    for tag, img, ref, src_lbl in (("0", m0, ref0, s0), ("1", m1, ref1, s1)):
        if img is None:
            print(f"{tag:<6}{'-':<8}{'(missing)':>16}")
            continue
        print(f"{tag:<6}{src_lbl:<8}{psnr(img, ref):>16.2f}"
              f"{int(np.abs(img.astype(int)-ref.astype(int)).max()):>12}")

    tiles = [src]
    labels = ["(a) hazy"]
    for tag, img in (("0", m0), ("1", m1)):
        if img is not None:
            tiles.append(img)
            labels.append(f"(b) mode {tag}")
    tiles.append(ref1)
    labels.append("(c) Python GF ref")

    sep = 8
    canvas = np.full((h, w * len(tiles) + sep * (len(tiles) - 1), 3), 255, np.uint8)
    for i, im in enumerate(tiles):
        canvas[:, i * (w + sep): i * (w + sep) + w] = im

    os.makedirs(OUT, exist_ok=True)
    dst = os.path.join(OUT, "hw_compare_mode1.png")
    cv2.imwrite(dst, canvas)
    print(f"[ok] {dst}")


if __name__ == "__main__":
    main()
