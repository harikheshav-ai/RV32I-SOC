#!/usr/bin/env python3
"""Build test programs, run them on the Bluesim model and compare the commit
log against spike (when available).

usage: run_tests.py [--no-spike] [--random N] [--keep] [filter...]
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RV32UI = os.path.join(ROOT, "tests", "riscv-tests", "isa", "rv32ui")   # fetched by `make riscv-tests`
RV32UI_SKIP = {"fence_i", "ma_data"}   # need Zifencei / misaligned access support
ENV = os.path.join(ROOT, "tests", "env")
OUT = os.path.join(ROOT, "out")
SIM = os.path.join(ROOT, "build", "sim")
SPIKE = os.environ.get("SPIKE", "/opt/riscv/riscv64-unknown-elf/bin/spike")
CC = os.environ.get("CC", "clang")
LD = os.environ.get("LD", "ld.lld")
OBJCOPY = os.environ.get("OBJCOPY") or shutil.which("llvm-objcopy") \
    or shutil.which("llvm-objcopy-17") or shutil.which("llvm-objcopy-15")
CFLAGS = ["--target=riscv32", "-march=rv32i", "-mabi=ilp32", "-nostdlib",
          "-ffreestanding", "-fno-builtin", "-mno-relax", "-I" + ENV]
MEM_WORDS = 1 << 14
MEM_BASE = 0x80000000
COMMIT = re.compile(r"core\s+0: 3 0x([0-9a-f]+) \(0x([0-9a-f]+)\)(.*)")


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def build(name, sources, opt, d):
    objs = []
    for s in sources:
        o = os.path.join(d, os.path.basename(s) + ".o")
        sh([CC] + CFLAGS + [opt, "-c", s, "-o", o])
        objs.append(o)
    elf = os.path.join(d, name + ".elf")
    sh([LD, "-T", os.path.join(ENV, "link.ld"), "-o", elf] + objs)
    binf = os.path.join(d, name + ".bin")
    sh([OBJCOPY, "-O", "binary", elf, binf])
    data = open(binf, "rb").read()
    assert len(data) <= MEM_WORDS * 4, "image too large"
    data = data.ljust(MEM_WORDS * 4, b"\0")
    with open(os.path.join(d, "prog.hex"), "w") as f:
        for i in range(0, len(data), 4):
            f.write("%08x\n" % int.from_bytes(data[i:i + 4], "little"))
    with open(os.path.join(d, name + ".dis"), "w") as f:
        sh([OBJCOPY.replace("objcopy", "objdump"), "-d", elf], stdout=f)
    return elf


def parse(path):
    """Commit records: (pc, inst, reg write, store) from a spike-style log."""
    recs = []
    for line in open(path, errors="replace"):
        m = COMMIT.match(line)
        if not m:
            continue
        pc, inst = int(m.group(1), 16), int(m.group(2), 16)
        if pc < MEM_BASE:
            continue  # spike boot ROM
        toks = m.group(3).split()
        reg = store = None
        i = 0
        while i < len(toks):
            if re.fullmatch(r"x\d+", toks[i]):
                if toks[i] != "x0":
                    reg = (toks[i], int(toks[i + 1], 16) & 0xFFFFFFFF)
                i += 2
            elif toks[i] == "x" and i + 2 < len(toks) and toks[i + 1].isdigit():
                # Spike 1.1.0 separates the register prefix and index for
                # single-digit registers (for example, ``x 3``).
                name = "x" + toks[i + 1]
                if name != "x0":
                    reg = (name, int(toks[i + 2], 16) & 0xFFFFFFFF)
                i += 3
            elif toks[i] == "mem":
                if i + 2 < len(toks) and toks[i + 2].startswith("0x"):  # store: addr data
                    store = (int(toks[i + 1], 16), int(toks[i + 2], 16))
                    i += 3
                else:
                    i += 2
            else:
                i += 1
        recs.append((pc, inst, reg, store))
    return recs


def compare(core_log, spike_log):
    a, b = parse(core_log), parse(spike_log)
    if not a:
        return "empty core trace"
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return "mismatch at commit %d:\n  core : %s\n  spike: %s" % (i, fmt(x), fmt(y))
    if len(a) > len(b):
        return "core committed more instructions (%d) than spike (%d)" % (len(a), len(b))
    return None


def fmt(r):
    pc, inst, reg, st = r
    s = "pc=%08x inst=%08x" % (pc, inst)
    if reg:
        s += " %s=%08x" % reg
    if st:
        s += " mem[%08x]=%x" % st
    return s


def run_one(name, sources, opt, use_spike):
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    try:
        elf = build(name, sources, opt, d)
    except subprocess.CalledProcessError as e:
        return False, "build failed: %s" % e
    trace = os.path.join(d, "core.log")
    with open(trace, "w") as f:
        sh([SIM, "+trace"], cwd=d, stdout=f, timeout=600)
    text = open(trace).read()
    stats = re.search(r"cycles=(\d+) instret=(\d+)", text)
    info = ""
    if stats:
        c, n = int(stats.group(1)), int(stats.group(2))
        info = "%7d instrs %7d cycles CPI %.2f" % (n, c, c / max(n, 1))
    if "[tb] PASS" not in text:
        last = [l for l in text.splitlines() if l.startswith("[")]
        return False, " / ".join(last[-2:])
    if use_spike:
        slog = os.path.join(d, "spike.log")
        with open(slog, "w") as f:
            subprocess.run([SPIKE, "--isa=rv32i", "-m0x80000000:0x10000", "-l",
                            "--log-commits", elf], stderr=f, stdout=f, timeout=60)
        err = compare(trace, slog)
        if err:
            return False, err
        info += "  [matches spike]"
    return True, info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-spike", action="store_true")
    ap.add_argument("--random", type=int, default=10, help="number of random tests")
    ap.add_argument("filters", nargs="*")
    args = ap.parse_args()
    use_spike = not args.no_spike and os.path.exists(SPIKE)

    tests = []
    for s in sorted(glob.glob(os.path.join(RV32UI, "*.S"))):
        name = os.path.basename(s)[:-2]
        if name not in RV32UI_SKIP:
            tests.append(("rv32ui-" + name, [s], "-O0"))
    lib = [os.path.join(ENV, "crt0.S"), os.path.join(ENV, "lib.c")]
    for s in sorted(glob.glob(os.path.join(ROOT, "tests/c/*.c"))):
        base = os.path.basename(s)[:-2]
        for opt in ("-O0", "-O2"):
            tests.append(("c-%s%s" % (base, opt), lib + [s], opt))
    rdir = os.path.join(OUT, "random-src")
    os.makedirs(rdir, exist_ok=True)
    for seed in range(args.random):
        src = os.path.join(rdir, "random%d.S" % seed)
        with open(src, "w") as f:
            sh([sys.executable, os.path.join(ROOT, "scripts", "gen_random.py"), str(seed)], stdout=f)
        tests.append(("random%d" % seed, [src], "-O0"))
    if args.filters:
        tests = [t for t in tests if any(f in t[0] for f in args.filters)]

    failed = []
    for name, srcs, opt in tests:
        ok, msg = run_one(name, srcs, opt, use_spike)
        print("%-4s %-22s %s" % ("PASS" if ok else "FAIL", name, msg), flush=True)
        if not ok:
            failed.append(name)
    print("\n%d/%d passed" % (len(tests) - len(failed), len(tests)))
    if not use_spike:
        print("(spike not used: results are self-checking only)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
