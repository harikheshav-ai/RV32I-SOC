#!/usr/bin/env python3
"""Copy the Bluespec library Verilog modules used by the generated design.

usage: bsv_libs.py BLUESPEC_VERILOG_DIR OUT_DIR
Scans OUT_DIR/*.v for identifiers naming a library module and copies those
modules (and, transitively, the modules they use) into OUT_DIR.
"""
import os
import re
import shutil
import sys

libdir, outdir = sys.argv[1], sys.argv[2]
lib = {f[:-2] for f in os.listdir(libdir) if f.endswith(".v") and f != "main.v"}
ident = re.compile(r"\b[A-Za-z_]\w*\b")

todo = [os.path.join(outdir, f) for f in os.listdir(outdir) if f.endswith(".v")]
copied = set()
while todo:
    text = open(todo.pop()).read()
    for name in set(ident.findall(text)) & lib - copied:
        copied.add(name)
        dst = os.path.join(outdir, name + ".v")
        shutil.copy(os.path.join(libdir, name + ".v"), dst)
        todo.append(dst)
print("bluespec library modules:", " ".join(sorted(copied)))
