# -*- coding: utf-8 -*-
"""Do neutral objects stay neutral after dehazing?

Takes the brightest 1 % of the RAW frame (white book spines in this scene), then
reports the mean RGB of the SAME pixels in the dehazed output. If those stay
balanced, the core is colour-faithful and any remaining tint in the picture is
the scene itself (a green spine, warm wood) plus the expected saturation boost.
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
raw_f = sys.argv[1] if len(sys.argv) > 1 else "sw_raw2.bmp"
out_f = sys.argv[2] if len(sys.argv) > 2 else "n_b.bmp"

raw = np.asarray(Image.open(os.path.join(HERE, raw_f)).convert("RGB")).astype(np.float32)
out = np.asarray(Image.open(os.path.join(HERE, out_f)).convert("RGB")).astype(np.float32)
if raw.shape != out.shape:
    raise SystemExit("size mismatch")

lum = raw.mean(axis=2)
thr = np.percentile(lum, 99.0)
m = lum >= thr


def stat(name, a, mask):
    r, g, b = a[:, :, 0][mask].mean(), a[:, :, 1][mask].mean(), a[:, :, 2][mask].mean()
    print(f"  {name:<14} R={r:6.1f} G={g:6.1f} B={b:6.1f}   "
          f"G-R={g-r:+5.1f}  G-B={g-b:+5.1f}")


print(f"raw = {raw_f}   out = {out_f}   (mask = brightest 1 %% of raw, {m.sum()} px)")
stat("raw  white", raw, m)
stat("out  white", out, m)
stat("raw  all", raw, np.ones_like(m))
stat("out  all", out, np.ones_like(m))

# how much did saturation grow overall?
def sat(a):
    mx, mn = a.max(axis=2), a.min(axis=2)
    return float(np.mean((mx - mn) / np.maximum(mx, 1)) * 100)

print(f"\n  mean saturation: raw {sat(raw):.1f}%  ->  out {sat(out):.1f}%")
