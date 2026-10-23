# -*- coding: utf-8 -*-
"""Is the green tint the scene, the sensor's white balance, or the dehazer?

Looks at the brightest pixels of a raw capture (the white book spines in this
scene) and reports their mean RGB. Under correct AWB a neutral object reads
nearly equal R/G/B; a strong G excess means the sensor's AWB is not compensating.
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(HERE, sys.argv[1] if len(sys.argv) > 1 else "sw_raw2.bmp")
im = Image.open(path).convert("RGB")
a = np.asarray(im).astype(np.float32)
R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]
lum = a.mean(axis=2)

print(f"{os.path.basename(path)}  {a.shape[1]}x{a.shape[0]}")
print(f"  whole frame   R={R.mean():6.1f} G={G.mean():6.1f} B={B.mean():6.1f}"
      f"   spread={max(R.mean(),G.mean(),B.mean())-min(R.mean(),G.mean(),B.mean()):5.1f}")

for pct in (0.5, 1, 5):
    thr = np.percentile(lum, 100.0 - pct)
    m = lum >= thr
    r, g, b = R[m].mean(), G[m].mean(), B[m].mean()
    print(f"  brightest {pct:>4}%  R={r:6.1f} G={g:6.1f} B={b:6.1f}"
          f"   G/R={g/max(r,1e-6):5.3f} G/B={g/max(b,1e-6):5.3f}")

# gray-world gains that would neutralise the frame
r, g, b = R.mean(), G.mean(), B.mean()
avg = (r + g + b) / 3.0
print(f"  gray-world gain (normalised to G): "
      f"R x{avg/r:.3f}  G x{avg/g:.3f}  B x{avg/b:.3f}")
print(f"  to equalise B to G: B x{g/b:.3f}")
