#!/usr/bin/env python3
"""Summarize icd_trace pc_<gpu>_<tag>.csv files.

Columns: t_us,cpuctl,pc,cmd,engine,rplm

Read-only analysis.  The interesting question is whether the host can see the
GSP core at all during the HS boot window and where it executes:

  0x93000000..0x93dcffff  runtime VA of the GSP-RM code segment
                          (link 0x01000000 + 0x92000000)
  0x01000000..0x01dcd000  PA/link of the same segment
  anything else           BootROM / FMC / staging code -- the prize

  engine = 0xbadf5720     Falcon block blocked to the host (PRIV-locked)
  cpuctl bit 7            core active
"""
import glob
import os
import sys
from collections import Counter


def sentinel(v):
    return 0xBADF0000 <= v <= 0xBADFFFFF


def classify_pc(pc):
    if pc == 0:
        return "zero"
    if sentinel(pc):
        return "sentinel"
    if 0x93000000 <= pc <= 0x93DCFFFF:
        return "gsp-rm-runtime"
    if 0x01000000 <= pc <= 0x01DCD000:
        return "gsp-rm-link"
    return "OTHER"


def analyse(path):
    rows = []
    with open(path, errors="replace") as f:
        hdr = f.readline().strip()
        for line in f:
            p = line.strip().split(",")
            if len(p) != 6:
                continue
            try:
                rows.append(tuple(int(x, 16) if i else int(x) for i, x in enumerate(p)))
            except ValueError:
                continue
    if not rows:
        print(f"{path}: no samples")
        return

    n = len(rows)
    dur = rows[-1][0] - rows[0][0]
    print(f"== {os.path.basename(path)}  ({hdr})")
    print(f"   samples={n} span={dur/1000:.1f} ms")

    ct = Counter(r[1] for r in rows)
    eng = Counter(r[4] for r in rows)
    cmd = Counter(r[3] for r in rows)
    print("   CPUCTL : " + ", ".join(f"0x{k:08x}x{v}" for k, v in ct.most_common(6)))
    print("   ENGINE : " + ", ".join(f"0x{k:08x}x{v}" for k, v in eng.most_common(6)))
    print("   CMD    : " + ", ".join(f"0x{k:08x}x{v}" for k, v in cmd.most_common(6)))
    active = sum(1 for r in rows if (r[1] >> 7) & 1)
    blocked = sum(1 for r in rows if sentinel(r[4]))
    print(f"   active={active}/{n} ({100.0*active/n:.0f}%)  engine-blocked={blocked}")

    kinds = Counter(classify_pc(r[2]) for r in rows)
    print("   PC class: " + ", ".join(f"{k}x{v}" for k, v in kinds.most_common()))

    # transitions
    trans = []
    prev = None
    for r in rows:
        if r[2] != prev:
            trans.append(r)
            prev = r[2]
    print(f"   distinct-PC transitions: {len(trans)}")
    show = trans[:40]
    if len(trans) > 60:
        show = trans[:25] + [None] + trans[-25:]
    for r in show:
        if r is None:
            print("     ...")
            continue
        t, cpuctl, pc, cmdv, engv, rplm = r
        print(f"     t={t/1000:9.3f} ms  ct=0x{cpuctl:08x} pc=0x{pc:08x} "
              f"eng=0x{engv:08x} rplm=0x{rplm:08x}  {classify_pc(pc)}")


def main():
    paths = sys.argv[1:] or sorted(glob.glob(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "icd_trace", "pc_*.csv")))
    if not paths:
        print("no pc_*.csv found; run icd_trace_run.sh first")
        return 1
    for p in paths:
        analyse(p)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
