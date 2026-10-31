#!/usr/bin/env python3
"""Summarize the kernel-written bf16_ctxdump_*.bin files.

Usage: parse_ctxfiles.py <outdir>
"""
import glob
import os
import struct
import sys

CONSTANTS = [
    ("FEAT_OVR_PLM", 0x00823804),
    ("FEAT_READOUT_1", 0x00823818),
    ("FEAT_OVR_SM_SS0", 0x0082381c),
    ("FEAT_OVR_SM_SS1", 0x00823820),
    ("FUSE_SS_FMLA32", 0x008207d8),
    ("SM_ISSUE_RATE_MODIFIER", 0x00504204),
    ("READOUT_1_STOCK", 0x00c36180),
    # Common fill/mask pattern. NOT evidence of an Ada SS0 payload: D.31/D.32
    # found 1,000 position-identical occurrences in both cards' main images.
    ("0x88888888_FILL", 0x88888888),
    ("POISON", 0xaddeadde),
]

# Blackwell FEAT_READOUT_1 packing (D.18): 8 x 3-bit fields at these shifts,
# DP at [30:28]. A genuine selector word would decode to this vector; the
# stock fused value is [0,0,3,0,3,3,0,3] with DP=0.
FEAT_SHIFTS = (0, 3, 7, 10, 13, 16, 19, 22)
FEAT_STOCK = (0, 0, 3, 0, 3, 3, 0, 3, 0)


def feat_decode(word):
    return tuple((word >> s) & 7 for s in FEAT_SHIFTS) + ((word >> 28) & 7,)


def main():
    outdir = sys.argv[1]
    paths = sorted(glob.glob(os.path.join(outdir, "bf16_ctxdump_*.bin")))
    if not paths:
        print("no bf16_ctxdump_*.bin files in %s" % outdir)
        return 1

    lines = []
    for path in paths:
        d = open(path, "rb").read()
        nz = sum(1 for b in d if b)
        hits = []
        for name, value in CONSTANTS:
            pat = struct.pack("<I", value)
            count = d.count(pat)
            if count:
                hits.append("%s x%d" % (name, count))
        # Count words that decode to the stock Blackwell selector vector.
        n = len(d) // 4
        feat_stock = sum(
            1 for word in struct.unpack_from("<%dI" % n, d, 0)
            if feat_decode(word) == FEAT_STOCK)
        if feat_stock:
            hits.append("FEAT_STOCK_VECTOR x%d" % feat_stock)
        line = "%-42s size=%-8d nonzero=%-8d first=%s%s" % (
            os.path.basename(path), len(d), nz, d[:64].hex(),
            (" hits=" + ",".join(hits)) if hits else "")
        lines.append(line)
        print(line)

    text = "\n".join(lines) + "\n"
    with open(os.path.join(outdir, "file_summary.txt"), "w") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
