# -*- coding: utf-8 -*-
"""Compare our OV5640 register table against a known-good reference table.

Both sides are reduced to an ordered list of (register, value) pairs and diffed
positionally, because the ORDER matters for a sensor init sequence: a PLL
register written after the wake-up is not the same as before it.

    python diff_table.py path/to/reference_init.v

The reference is whatever vendor demo you trust -- it only ever contributed
register values (facts about the sensor), never code.
"""
import re
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUR = os.path.join(HERE, "ov5640_640x480_rgb565.reg")
# Second argument, or the REF_TABLE environment variable. Left as a placeholder
# on purpose: the reference file used during development lives outside this repo.
REF = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("REF_TABLE", "")

# 24'h3103_11  ->  (0x3103, 0x11)   (the underscore is cosmetic)
PAT = re.compile(r"24'h([0-9a-fA-F]{6})|24'h([0-9a-fA-F]{4})_([0-9a-fA-F]{2})")


def load_ours():
    out = []
    with open(OUR, encoding="utf-8") as f:
        for raw in f:
            s = raw.split("#", 1)[0].strip()
            if not s or s.upper().startswith("RESOLUTION"):
                continue
            p = s.split()
            reg = int(p[0], 16)
            expr = p[1].replace("{W}", "640").replace("{H}", "480")
            out.append((reg, eval(expr, {"__builtins__": {}}, {}) & 0xFF))
    return out


def load_ref():
    out = []
    with open(REF, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = PAT.search(line)
            if not m:
                continue
            if m.group(1):
                v = int(m.group(1), 16)
            else:
                v = (int(m.group(2), 16) << 8) | int(m.group(3), 16)
            out.append(((v >> 8) & 0xFFFF, v & 0xFF))
    return out


def main():
    ours = load_ours()
    ref = load_ref()
    print(f"ours: {len(ours)} entries   ref: {len(ref)} entries")

    # Does our sequence appear in theirs (allowing the resolution block to differ)?
    o_only_from = None
    diffs = 0
    for i in range(max(len(ours), len(ref))):
        a = ours[i] if i < len(ours) else None
        b = ref[i] if i < len(ref) else None
        if a != b:
            diffs += 1
            if diffs <= 60:
                fa = f"0x{a[0]:04X}=0x{a[1]:02X}" if a else "-- missing --"
                fb = f"0x{b[0]:04X}=0x{b[1]:02X}" if b else "-- missing --"
                print(f"[{i:3d}] ours {fa:18s} ref  {fb}")
            if o_only_from is None:
                o_only_from = i
    if diffs == 0:
        print("IDENTICAL")
    else:
        print(f"\n{diffs} differing positions, first at index {o_only_from}")

    # registers present in one table but not the other at all
    rs_o = {r for r, _ in ours}
    rs_y = {r for r, _ in ref}
    only_o = sorted(rs_o - rs_y)
    only_y = sorted(rs_y - rs_o)
    if only_o:
        print("registers only in OURS :", " ".join(f"0x{r:04X}" for r in only_o))
    if only_y:
        print("registers only in ref  :", " ".join(f"0x{r:04X}" for r in only_y))


if __name__ == "__main__":
    main()
