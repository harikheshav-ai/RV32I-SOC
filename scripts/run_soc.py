#!/usr/bin/env python3
"""Run programs on the full SoC simulation: the program is loaded over the
UART by the bootloader, exactly as on the FPGA.

usage: run_soc.py [--verilog] [filter...]    run examples + C tests
       run_soc.py --boot OUT_DIR             only build OUT_DIR/boot.mem

Each run directory (out-soc/<name>/) gets prog.bin, sim output (sim.log) and
the UART logger output (uart.log).
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from run_tests import CC, LD, OBJCOPY, RV32UI, sh  # noqa: E402

OUT = os.environ.get("SOC_OUT", os.path.join(ROOT, "out-soc"))
ENV = os.path.join(ROOT, "tests", "env")
LIB = os.path.join(ROOT, "sw", "lib")
SOC_WORDS = 1 << 15       # 128 KiB BRAM
BOOT_OFFSET = 0x10000     # bootloader at 0x80010000
BANK_WORDS = 1 << 12      # boot.mem initialises only the 16 KiB bank at BOOT_OFFSET
CFLAGS = ["--target=riscv32", "-march=rv32i", "-mabi=ilp32", "-nostdlib",
          "-ffreestanding", "-fno-builtin", "-mno-relax", "-I" + ENV, "-I" + LIB]
BUILD = os.path.join(ROOT, os.environ.get("BUILD", "build"))
SIMS = {"bluesim": os.path.join(BUILD, "socsim", "sim"),
        "verilog": os.path.join(BUILD, "socvsim", "vsim")}


def link(name, sources, opt, d, script):
    objs = []
    for s in sources:
        o = os.path.join(d, os.path.basename(s) + ".o")
        sh([CC] + CFLAGS + [opt, "-c", s, "-o", o])
        objs.append(o)
    elf = os.path.join(d, name + ".elf")
    sh([LD, "-T", script, "-o", elf] + objs)
    with open(os.path.join(d, name + ".dis"), "w") as f:
        sh([OBJCOPY.replace("objcopy", "objdump"), "-d", elf], stdout=f)
    return elf


def to_bin(elf, out):
    # .tohost is never read, so leave it out to keep the UART transfer short.
    sh([OBJCOPY, "-O", "binary", "--remove-section=.tohost", elf, out])
    return open(out, "rb").read()


def build_boot(d):
    os.makedirs(d, exist_ok=True)
    src = os.path.join(ROOT, "sw", "boot")
    elf = link("boot", [os.path.join(src, "start.S"), os.path.join(src, "boot.c")],
               "-Os", d, os.path.join(src, "link.ld"))
    img = to_bin(elf, os.path.join(d, "boot.bin"))
    assert len(img) <= BANK_WORDS * 4, "bootloader does not fit its BRAM bank"
    mem = bytearray(BANK_WORDS * 4)
    mem[:len(img)] = img
    path = os.path.join(d, "boot.mem")
    with open(path, "w") as f:
        for i in range(0, len(mem), 4):
            f.write("%08x\n" % int.from_bytes(mem[i:i + 4], "little"))
    return path


def build_prog(name, sources, opt, d):
    os.makedirs(d, exist_ok=True)
    elf = link(name, sources, opt, d, os.path.join(ENV, "link.ld"))
    to_bin(elf, os.path.join(d, "prog.bin"))
    return elf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", metavar="OUT_DIR")
    ap.add_argument("--verilog", action="store_true", help="use the iverilog build")
    ap.add_argument("filters", nargs="*")
    args = ap.parse_args()

    if args.boot:
        print(build_boot(args.boot))
        return

    sim = SIMS["verilog" if args.verilog else "bluesim"]
    boot = build_boot(os.path.join(OUT, "boot"))
    rt = [os.path.join(ENV, "crt0.S"), os.path.join(ENV, "lib.c"), os.path.join(LIB, "uart.c")]
    tests = []
    for s in sorted(glob.glob(os.path.join(ROOT, "sw/examples/*.c"))):
        tests.append(("ex-" + os.path.basename(s)[:-2], rt + [s], "-O2"))
    for s in sorted(glob.glob(os.path.join(ROOT, "tests/c/*.c"))):
        tests.append(("c-" + os.path.basename(s)[:-2], rt + [s], "-O2"))
    for t in ("add", "lw", "sb", "jalr", "bltu"):
        tests.append(("rv32ui-" + t, [os.path.join(RV32UI, t + ".S")], "-O0"))
    if args.filters:
        tests = [t for t in tests if any(f in t[0] for f in args.filters)]

    failed = []
    for name, srcs, opt in tests:
        d = os.path.join(OUT, name)
        build_prog(name, srcs, opt, d)
        shutil.copy(boot, d)
        with open(os.path.join(d, "sim.log"), "w") as f:
            subprocess.run([sim], cwd=d, stdout=f, stderr=subprocess.STDOUT, timeout=1800)
        log = open(os.path.join(d, "sim.log")).read()
        ok = "[tb] PASS" in log
        last = [l for l in log.splitlines() if l.startswith("[tb]")]
        print("%-4s %-16s %s" % ("PASS" if ok else "FAIL", name, " / ".join(last)), flush=True)
        if not ok:
            failed.append(name)
    print("\n%d/%d passed" % (len(tests) - len(failed), len(tests)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
