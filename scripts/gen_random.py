#!/usr/bin/env python3
"""Generate a random RV32I program for co-simulation against spike.

Registers are drawn from a small pool so back-to-back dependencies (and thus
scoreboard stalls/bypasses) are frequent. x31 is the data pointer, x30 the
loop counter; neither is a random destination.
"""
import random
import sys

POOL = ["x%d" % i for i in range(1, 10)]
RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
RI = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH = ["slli", "srli", "srai"]
BR = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LD = [("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4)]
ST = [("sb", 1), ("sh", 2), ("sw", 4)]
DATA_BYTES = 256


class Gen:
    def __init__(self, rng):
        self.r = rng
        self.lines = []
        self.label = 0

    def new_label(self):
        self.label += 1
        return "L%d" % self.label

    def reg(self):
        return self.r.choice(POOL + ["x0"] if self.r.random() < 0.05 else POOL)

    def mem_off(self, size):
        return self.r.randrange(0, DATA_BYTES, size)

    def simple(self, pool=None):
        r = self.r
        rd = r.choice(pool) if pool else self.reg()
        k = r.random()
        if k < 0.25:
            return "%s %s, %s, %s" % (r.choice(RR), rd, self.reg(), self.reg())
        if k < 0.45:
            return "%s %s, %s, %d" % (r.choice(RI), rd, self.reg(), r.randint(-2048, 2047))
        if k < 0.55:
            return "%s %s, %s, %d" % (r.choice(SH), rd, self.reg(), r.randint(0, 31))
        if k < 0.62:
            return "lui %s, 0x%x" % (rd, r.randrange(1 << 20))
        if k < 0.65:
            return "auipc %s, 0x%x" % (rd, r.randrange(1 << 20))
        if k < 0.83:
            op, sz = r.choice(LD)
            return "%s %s, %d(x31)" % (op, rd, self.mem_off(sz))
        op, sz = r.choice(ST)
        return "%s %s, %d(x31)" % (op, self.reg(), self.mem_off(sz))

    def block(self, n):
        r = self.r
        while n > 0:
            k = r.random()
            if k < 0.12:  # forward conditional branch
                lab = self.new_label()
                self.lines.append("%s %s, %s, %s" % (r.choice(BR), self.reg(), self.reg(), lab))
                for _ in range(r.randint(0, 3)):
                    self.lines.append(self.simple())
                self.lines.append(lab + ":")
            elif k < 0.16:  # jal over a few instructions
                lab = self.new_label()
                self.lines.append("jal %s, %s" % (self.reg(), lab))
                for _ in range(r.randint(0, 2)):
                    self.lines.append(self.simple())
                self.lines.append(lab + ":")
            elif k < 0.19:  # indirect jump through jalr
                lab = self.new_label()
                tmp = r.choice(POOL)
                self.lines.append("la %s, %s" % (tmp, lab))
                self.lines.append("jalr %s, 0(%s)" % (self.reg(), tmp))
                for _ in range(r.randint(0, 2)):
                    self.lines.append(self.simple())
                self.lines.append(lab + ":")
            elif k < 0.22:  # short counted loop (backward branch)
                lab = self.new_label()
                self.lines.append("li x30, %d" % r.randint(1, 5))
                self.lines.append(lab + ":")
                for _ in range(r.randint(1, 4)):
                    self.lines.append(self.simple())
                self.lines.append("addi x30, x30, -1")
                self.lines.append("bnez x30, " + lab)
            else:
                self.lines.append(self.simple())
            n -= 1


def main():
    seed = int(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    rng = random.Random(seed)
    g = Gen(rng)
    out = ["# random test, seed %d" % seed,
           ".section .text.init", ".globl _start", "_start:",
           "la x31, data"]
    for i in range(1, 30):
        out.append("li x%d, 0x%08x" % (i, rng.randrange(1 << 32)))
    g.block(n)
    out += g.lines
    out += ["li t0, 1", "la t1, tohost", "sw t0, 0(t1)", "1: j 1b",
            ".data", ".align 4", "data:"]
    out += [".word 0x%08x" % rng.randrange(1 << 32) for _ in range(DATA_BYTES // 4)]
    out += ['.section .tohost,"aw",@progbits', ".align 6", ".globl tohost",
            "tohost: .dword 0", ".align 6", ".globl fromhost", "fromhost: .dword 0"]
    print("\n".join(out))


if __name__ == "__main__":
    main()
