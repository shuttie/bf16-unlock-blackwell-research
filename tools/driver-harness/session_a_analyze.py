#!/usr/bin/env python3
"""Summarize a Session A FLR poll.

usage: session_a_analyze.py <run_dir>

Reads pre.csv and poll.csv from the run directory and prints the transitions
that matter for C05/C06: the FEAT PLM re-lock, the GSP boot marker, and any
movement in the fuse or FSP columns.
"""
import csv
import sys
from pathlib import Path

INTERESTING = (
    "feat_plm", "ss0", "ss1", "readout1",
    "fuse_38c", "fuse_3f0", "fuse_0d0", "fuse_0d4", "fuse_0d8",
    "fuse_0dc", "fuse_0f8", "fuse_0fc", "fuse_040", "fuse_084", "fuse_7d8",
    "fsp_hwcfg", "fsp_scratch", "fsp_ver", "fsp_engine", "fsp_blkplm",
    "fsp_status", "fsp_config", "fsp_coreplm", "fsp_const",
    "gsp_engine", "gsp_rstplm", "gsp_pc",
)


def read_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def transitions(rows, col):
    out = []
    prev = None
    for r in rows:
        v = r[col]
        if prev is not None and v != prev:
            out.append((int(r["t_ms"]), prev, v))
        prev = v
    return out


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip())
        return 2
    run = Path(sys.argv[1])
    pre_path, poll_path = run / "pre.csv", run / "poll.csv"
    if not poll_path.exists():
        print(f"missing {poll_path}")
        return 1

    if pre_path.exists():
        pre = read_csv(pre_path)
        print("pre-FLR (last sample):")
        for c in INTERESTING:
            if c in pre[-1]:
                print(f"  {c:14s} {pre[-1][c]}")
    else:
        print("no pre.csv")

    rows = read_csv(poll_path)
    print(f"\npoll: {len(rows)} samples, "
          f"{rows[0]['t_ms']}..{rows[-1]['t_ms']} ms after FLR")

    plm = transitions(rows, "feat_plm")
    print("\nFEAT PLM transitions (C05 window):")
    if not plm:
        print("  none")
    for t, a, b in plm:
        note = ""
        if b.lower() == "0xfffffb8f":
            note = "  <- stock lock (write PL3 only)"
        elif b.lower() == "0x80842bcf":
            note = "  <- post-FLR window (write L2+L3)"
        print(f"  {t:6d} ms  {a} -> {b}{note}")

    pc = transitions(rows, "gsp_pc")
    print("\nGSP PC transitions (boot marker):")
    if not pc:
        print("  none")
    for t, a, b in pc:
        print(f"  {t:6d} ms  {a} -> {b}")

    print("\nOther column transitions:")
    any_other = False
    for c in INTERESTING:
        if c in ("feat_plm", "gsp_pc") or c not in rows[0]:
            continue
        tr = transitions(rows, c)
        if tr:
            any_other = True
            print(f"  {c}:")
            for t, a, b in tr:
                print(f"    {t:6d} ms  {a} -> {b}")
    if not any_other:
        print("  none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
