# -*- coding: utf-8 -*-
"""Strip a UTF-8 BOM from the given text files.

PowerShell 5.1's `Set-Content -Encoding UTF8` always writes a BOM, and Python
refuses to parse a .py that starts with one ("invalid non-printable character
U+FEFF"). C compilers tolerate it, but a clean tree is better than a tolerated
one. .ps1 files are deliberately left alone: without the BOM, PowerShell 5.1
decodes them as ANSI and mangles the Chinese comments.
"""
import os
import sys

targets = sys.argv[1:]
if not targets:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # fpga/
    targets = []
    for dirpath, _dirnames, filenames in os.walk(root):
        if any(p in dirpath for p in ("proj_dehaze", "\\vivado", "\\.Xil", "\\ws", "\\work")):
            continue
        for fn in filenames:
            if fn.endswith((".py", ".c", ".cpp", ".h", ".v", ".tcl", ".reg", ".json", ".md", ".txt", ".cgi", ".conf")):
                targets.append(os.path.join(dirpath, fn))

fixed = 0
for p in targets:
    try:
        raw = open(p, "rb").read()
    except OSError as e:
        print("skip", p, e)
        continue
    if raw.startswith(b"\xef\xbb\xbf"):
        open(p, "wb").write(raw[3:])
        print("BOM removed:", os.path.relpath(p))
        fixed += 1

print(f"{fixed} file(s) fixed, {len(targets)} inspected")
