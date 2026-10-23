# -*- coding: utf-8 -*-
"""Report which text files are not valid UTF-8.

The Windows console mangles UTF-8 Chinese when it prints it as ANSI, which makes
a perfectly good UTF-8 file look like mojibake. This decodes the bytes instead,
so the answer is about the file, not about the console.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # fpga/
EXT = (".md", ".py", ".c", ".cpp", ".h", ".v", ".tcl", ".ps1", ".reg", ".json",
       ".html", ".cgi", ".conf", ".sh", ".xdc")

bad = []
ok = 0
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in
                   ("proj_dehaze", "vivado", ".Xil", "ws", "work", "probe_cam")]
    for fn in filenames:
        if not fn.endswith(EXT):
            continue
        p = os.path.join(dirpath, fn)
        raw = open(p, "rb").read()
        try:
            raw.decode("utf-8")
            ok += 1
        except UnicodeDecodeError as e:
            bad.append((os.path.relpath(p, ROOT), str(e)))

print(f"valid UTF-8: {ok}")
if bad:
    print("NOT UTF-8:")
    for p, e in bad:
        print("  ", p, "->", e)
else:
    print("no encoding problems")
