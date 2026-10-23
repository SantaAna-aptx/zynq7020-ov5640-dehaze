# -*- coding: utf-8 -*-
"""One-off: turn a vendor demo's write_i2c() calls into a plain .reg list.

Point it at a vendor init file you already have locally; it is NOT part of this
repo (that file is somebody else's copyrighted source, so it must not be
committed). Only the (register, value) pairs are taken from it: addresses and
reset values for the OV5640 are facts from the OmniVision datasheet, so the
*data* is reusable; nothing is copied from the vendor's source text beyond
those pairs.

    python extract_ref_regs.py path/to/vendor_ov5640_init.c

Commented-out blocks are skipped. The four resolution registers are emitted with
{W}/{H} placeholders so the table stays resolution-agnostic.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Second argument, or REF_FILE. No default path on purpose: see the docstring.
SRC = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("REF_FILE", "")
OUT = os.path.join(HERE, "ov5640_640x480_rgb565.reg")

# resolution registers take the placeholder instead of a literal
RES = {
    0x3808: "{W}>>8",
    0x3809: "{W}&0xFF",
    0x380A: "{H}>>8",
    0x380B: "{H}&0xFF",
}

# plain calls, plus the four resolution registers which the demo writes with an
# expression (hsize>>8 etc) instead of a literal
CALL = re.compile(r"write_i2c\s*\(\s*sscb_gpio\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*"
                  r"(0x[0-9A-Fa-f]+|hsize[^,)]*|vsize[^,)]*)\s*\)")


def main():
    with open(SRC, encoding="utf-8") as f:
        lines = f.readlines()

    entries = []
    in_block = False
    for raw in lines:
        s = raw.strip()
        if s.startswith("/*"):
            in_block = True
        if in_block:
            if "*/" in s:
                in_block = False
            continue
        if s.startswith("//"):
            continue
        m = CALL.search(s)
        if not m:
            continue
        reg = int(m.group(1), 16)
        expr = m.group(2)
        val = int(expr, 16) if expr.lower().startswith("0x") else expr
        entries.append((reg, val))

    out = [
        "# OV5640 initialisation sequence: DVP, RGB565, {W}x{H}.",
        "# Extracted from the vendor demo by tools/extract_ref_regs.py -- the",
        "# values are OmniVision datasheet register values, nothing else.",
        "#",
        "# Format:  0xRRRR 0xVV   [comment]",
        "# {W} and {H} are substituted by tools/gen_sccb_table.py.",
        "",
        "# Sensor output size. 640x480 is this table's native window: the ISP",
        "# scaler (0x5001 bit0) is enabled, so DVPHO/DVPVO simply select the",
        "# output raster -- the vendor demo ran the same table at 1280x720.",
        "RESOLUTION 640 480",
        "",
    ]
    seen = {}
    for reg, val in entries:
        if isinstance(val, int):
            if reg in RES:
                # the demo wrote a literal there; keep the placeholder anyway so
                # the table follows the RESOLUTION line instead of a copy of it
                out.append(f"0x{reg:04X} {RES[reg]}")
            else:
                out.append(f"0x{reg:04X} 0x{val:02X}")
        else:
            out.append(f"0x{reg:04X} {RES.get(reg, val)}")
        seen.setdefault(reg, []).append(val)

    dups = {r: v for r, v in seen.items() if len(v) > 1}
    if dups:
        print("NOTE: registers written more than once (last write wins):")
        for r, v in sorted(dups.items()):
            print(f"  0x{r:04X}: {v}")

    with open(OUT, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {OUT}: {len(entries)} entries")
    for i, (r, v) in enumerate(entries):
        if r in RES:
            print(f"  [{i}] resolution register 0x{r:04X}")


if __name__ == "__main__":
    main()
