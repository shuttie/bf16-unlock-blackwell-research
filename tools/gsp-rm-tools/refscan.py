#!/usr/bin/env python3
"""Scan the GSP-RM .fwimage for references to absolute addresses.

Handles RISC-V JAL, AUIPC+ADDI, LUI+ADDI, and raw 32/64-bit literals.
Scans every 2-byte offset (RVC), with correct sign extension.
"""
import struct
import sys

BASE = 0x01000000


def sx(v, bits):
    sign = 1 << (bits - 1)
    return (v & (sign - 1)) - (v & sign)


def jal_imm(w):
    imm = (((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12)
    imm |= (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1)
    return sx(imm, 21)


def main():
    path = sys.argv[1]
    targets = {int(x, 0) for x in sys.argv[2:]}
    data = open(path, "rb").read()
    n = len(data)
    hits = []

    # raw literals
    for t in targets:
        for width, fmt in ((4, "<I"), (8, "<Q")):
            needle = struct.pack(fmt, t)
            start = 0
            while True:
                i = data.find(needle, start)
                if i < 0:
                    break
                hits.append((BASE + i, "literal%d" % (width * 8), t))
                start = i + 1

    # instruction references at every 2-byte boundary
    for i in range(0, n - 8, 2):
        pc = BASE + i
        w = struct.unpack_from("<I", data, i)[0]
        op = w & 0x7F

        if op == 0x6F:  # JAL
            t = pc + jal_imm(w)
            if t in targets:
                hits.append((pc, "jal", t))

        elif op == 0x17:  # AUIPC rd, imm20
            rd = (w >> 7) & 0x1F
            base = pc + sx(w & 0xFFFFF000, 32)
            # look ahead a few instructions for addi rd, rd, imm12
            j = i + 2
            for _ in range(6):
                if j + 4 > n:
                    break
                w2 = struct.unpack_from("<I", data, j)[0]
                op2 = w2 & 0x7F
                if op2 == 0x13:
                    rd2 = (w2 >> 7) & 0x1F
                    rs1 = (w2 >> 15) & 0x1F
                    funct3 = (w2 >> 12) & 7
                    if rd2 == rd and rs1 == rd and funct3 == 0:
                        imm12 = sx((w2 >> 20) & 0xFFF, 12)
                        t = base + imm12
                        if t in targets:
                            hits.append((pc, "auipc+addi", t))
                        break
                # advance by RVC length
                if (w2 & 3) != 3:
                    j += 2
                else:
                    j += 4

        elif op == 0x37:  # LUI rd, imm20
            rd = (w >> 7) & 0x1F
            base = sx(w & 0xFFFFF000, 32)
            j = i + 2
            for _ in range(6):
                if j + 4 > n:
                    break
                w2 = struct.unpack_from("<I", data, j)[0]
                op2 = w2 & 0x7F
                if op2 == 0x13:
                    rd2 = (w2 >> 7) & 0x1F
                    rs1 = (w2 >> 15) & 0x1F
                    funct3 = (w2 >> 12) & 7
                    if rd2 == rd and rs1 == rd and funct3 == 0:
                        imm12 = sx((w2 >> 20) & 0xFFF, 12)
                        t = base + imm12
                        if t in targets:
                            hits.append((pc, "lui+addi", t))
                        break
                if (w2 & 3) != 3:
                    j += 2
                else:
                    j += 4

    seen = set()
    for pc, kind, t in sorted(hits):
        key = (pc, kind, t)
        if key in seen:
            continue
        seen.add(key)
        print("0x%08x  %-12s -> 0x%08x" % (pc, kind, t))


if __name__ == "__main__":
    main()
