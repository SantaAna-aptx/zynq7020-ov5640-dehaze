# -*- coding: utf-8 -*-
"""Sanity check the live page: sliders present, UTF-8 clean, no stray '?' from a
bad round-trip through a non-UTF-8 editor."""
import io
import os

p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
s = io.open(p, encoding="utf-8").read()

print("bytes on disk :", os.path.getsize(p))
print("chars         :", len(s))
print("range sliders :", s.count('type="range"'))
for sid in ("s_omega", "s_t0", "s_gain", "s_acomp"):
    print(f"  {sid:<8}", "present" if f'id="{sid}"' in s else "MISSING")
print("set.cgi call  :", "yes" if "set.cgi?" in s else "MISSING")
print("centre dots   :", "yes" if "\u2022" in s else "no")

# U+FFFD means a character was destroyed by an encoding round-trip
bad = s.count("\ufffd")
print("replacement chars:", bad, "(must be 0)")
