# -*- coding: utf-8 -*-
"""Compare the dehazed output before and after the atmospheric-light fix.

Old captures (sw_orig / sw_b) were taken with the v1 estimator: A = RGB of one
pixel, measured on the board as (206,190,198) -- a 16-level spread. New captures
(n_*) use the v2 estimator: mean colour of the top band, compressed by `acomp`.
"""
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))

panes = [
    ("raw (input)",        "sw_raw2"),
    ("v1 A single px\n243/26",     "sw_orig"),
    ("v2 243/26 acomp90",  "n_orig"),
    ("v1 160/80",          "sw_b"),
    ("v2 160/80 acomp90",  "n_b"),
    ("v2 160/80 acomp0",   "n_b0"),
    ("v2 160/80 acomp256", "n_b256"),
]

ims = {}
for label, f in panes:
    p = os.path.join(HERE, f + ".bmp")
    if os.path.exists(p):
        ims[label] = Image.open(p).convert("RGB")

if not ims:
    raise SystemExit("no captures found")

W, H = next(iter(ims.values())).size
sc = 0.5
tw, th = int(W * sc), int(H * sc)
cols = 4
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cols * tw + (cols + 1) * 6,
                          rows * (th + 30) + (rows + 1) * 6), (15, 15, 15))
d = ImageDraw.Draw(sheet)

for i, (label, im) in enumerate(ims.items()):
    r, c = divmod(i, cols)
    x = 6 + c * (tw + 6)
    y = 6 + r * (th + 30 + 6)
    d.text((x + 2, y), label, fill=(180, 220, 200))
    sheet.paste(im.resize((tw, th)), (x, y + 26))

sheet.save(os.path.join(HERE, "qa_compare.png"))
print("sheet:", sheet.size)

print(f"\n{'capture':<22}{'mean':>7}{'R':>7}{'G':>7}{'B':>7}{'spread':>8}{'black%':>8}")
for label, im in ims.items():
    a = np.asarray(im).astype(np.float32)
    r, g, b = a[:, :, 0].mean(), a[:, :, 1].mean(), a[:, :, 2].mean()
    spread = max(r, g, b) - min(r, g, b)
    black = float((a.max(axis=2) <= 2).mean() * 100)
    print(f"{label.replace(chr(10),' '):<22}{a.mean():7.1f}{r:7.1f}{g:7.1f}{b:7.1f}"
          f"{spread:8.1f}{black:8.2f}")
