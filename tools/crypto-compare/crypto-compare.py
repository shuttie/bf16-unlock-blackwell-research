#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline ciphertext compares for the firmware corpus.

Subcommands:
  bindata    extract rm.bindata.bin from a GSP-RM fwimage via the libos manifest
  join       count identical aligned 16-byte blocks between two files
  selfjoin   find duplicated ciphertext runs inside one file
  diff       localize differing bytes between two dumps, grouped into ranges
  carray     convert a generated bindata C array file (NvU64 words) to binary

No GPU access, no root, no network. Standard library only.
"""
import argparse
import collections
import hashlib
import re
import struct
import sys


def read(path):
    with open(path, "rb") as f:
        return f.read()


# ---------------------------------------------------------------- bindata

def elf_section(data, want):
    """Return the bytes of section `want` from a little-endian ELF (32/64)."""
    if data[:4] != b"\x7fELF":
        return None
    if data[4] == 2:
        shoff, = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3a)
        names_at = lambda o: struct.unpack_from("<Q", data, o + 0x18)[0]
        parse = lambda o: struct.unpack_from("<IIQQQQ", data, o + 0x00)[0:1] + \
                          struct.unpack_from("<QQ", data, o + 0x18)
    else:
        shoff, = struct.unpack_from("<I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2e)
        names_at = lambda o: struct.unpack_from("<I", data, o + 0x10)[0]
        parse = lambda o: (struct.unpack_from("<I", data, o)[0],
                           *struct.unpack_from("<II", data, o + 0x10))
    strtab_off = names_at(shoff + shstrndx * shentsize)
    strtab = data[strtab_off:strtab_off + 0x4000]
    for i in range(shnum):
        o = shoff + i * shentsize
        name_off, off, size = parse(o)
        end = strtab.find(b"\0", name_off)
        if strtab[name_off:end] == want:
            return data[off:off + size]
    return None


def cmd_bindata(args):
    fw = read(args.fwimage)
    # The manifest lists module names; each name slot is followed by
    # u64 offset (manifest-base relative) at +0x28 and u64 size at +0x30.
    hits = [m.start() for m in re.finditer(rb"rm\.bindata\.bin\x00", fw)]
    if not hits:
        sys.exit("no rm.bindata.bin manifest entry")
    name_off = hits[-1]
    moff, msize = struct.unpack_from("<QQ", fw, name_off + 0x28)
    # Solve the manifest base from the first kernel ELF entry: the first
    # ELF magic below 0x200000 is the first kernel module's file position.
    kern = fw.find(b"\x7fELF", 0x1000)
    kname = fw.rfind(b"kernel_", name_off - 0x2000, name_off)
    koff, = struct.unpack_from("<Q", fw, kname + 0x28)
    base = kern - koff
    start = base + moff
    out = fw[start:start + msize]
    print(f"manifest name at {name_off:#x}, base {base:#x}")
    print(f"rm.bindata.bin {start:#x}..{start + msize:#x} ({msize:#x} bytes)")
    if args.out:
        with open(args.out, "wb") as f:
            f.write(out)


# ---------------------------------------------------------------- joins

def block_join(a, b, label_a, label_b, min_run, top=10, skip_uniform=False):
    """Match aligned 16-byte blocks of a inside b; report runs >= min_run."""
    idx = collections.defaultdict(list)
    for i in range(0, len(a) - 15, 16):
        blk = a[i:i + 16]
        if skip_uniform and blk.count(blk[0]) == 16:
            continue                     # uniform blocks self-match trivially
        idx[blk].append(i)
    matched = set()
    for j in range(0, len(b) - 15, 16):
        for i in idx.get(b[j:j + 16], ()):
            if a is b and i == j:
                continue
            matched.add(i)
    mb = sorted(matched)
    runs = []
    if mb:
        s = p = mb[0]
        for x in mb[1:]:
            if x == p + 16:
                p = x
                continue
            runs.append((s, p + 16 - s))
            s = p = x
        runs.append((s, p + 16 - s))
    print(f"{label_a}: {len(matched)} blocks matched in {label_b} "
          f"({len(matched) * 16 / len(a) * 100:.1f}% of {label_a})")
    big = sorted((r for r in runs if r[1] >= min_run), key=lambda r: -r[1])
    print(f"runs >= {min_run:#x} bytes: {len(big)}")
    for s, ln in big[:top]:
        print(f"  {label_a} {s:#010x} len={ln:#x}")
    return matched


def cmd_join(args):
    a, b = read(args.a), read(args.b)
    same = sum(1 for i in range(0, min(len(a), len(b)) - 15, 16)
               if a[i:i + 16] == b[i:i + 16])
    print(f"same-offset identical blocks: {same}/{min(len(a), len(b)) // 16}")
    block_join(a, b, args.a, args.b, args.min_run, args.top or 10)


def cmd_selfjoin(args):
    d = read(args.file)
    block_join(d, d, args.file, args.file + " (self)", args.min_run,
               args.top or 10, skip_uniform=True)


# ---------------------------------------------------------------- diff

def cmd_diff(args):
    a, b = read(args.a), read(args.b)
    n = min(len(a), len(b))
    diffs = [i for i in range(n) if a[i] != b[i]]
    print(f"{len(diffs)} differing bytes of {n}")
    ranges = []
    if diffs:
        s = p = diffs[0]
        for x in diffs[1:]:
            if x <= p + args.merge:
                p = x
                continue
            ranges.append((s, p))
            s = p = x
        ranges.append((s, p))
    print(f"{len(ranges)} ranges (merge {args.merge} B)")
    if args.regions:
        for lo, hi, name in args.regions:
            cnt = sum(1 for s, p in ranges if lo <= s < hi)
            span = sum(p - s + 1 for s, p in ranges if lo <= s < hi)
            print(f"  {name}: {cnt} ranges, {span} bytes")
    for s, p in ranges[:args.top or 20]:
        print(f"  {s:#x}..{p:#x}")


def parse_region(s):
    lo, hi, name = s.split(",", 2)
    return int(lo, 0), int(hi, 0), name


# ---------------------------------------------------------------- carray

def cmd_carray(args):
    txt = read(args.path).decode("utf-8", "replace")
    out = {}
    for m in re.finditer(r"(\w+BINDATA_LABEL\w*_data)\[\]\s*=\s*\{(.*?)\};",
                         txt, re.S):
        words = [int(x, 16) for x in
                 re.findall(r"0x([0-9a-fA-F]+)\s*ULL", m.group(2))]
        out[m.group(1)] = b"".join(struct.pack("<Q", w) for w in words)
    for name, data in out.items():
        short = name.split("LABEL_")[1].replace("_data", "")
        digest = hashlib.sha256(data).hexdigest()[:12]
        print(f"{short:16s} {len(data):#10x}  sha256:{digest}")
        if args.outdir:
            import pathlib
            pathlib.Path(args.outdir).mkdir(parents=True, exist_ok=True)
            (pathlib.Path(args.outdir) / f"{short}.bin").write_bytes(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("bindata", help="extract rm.bindata.bin from fwimage")
    p.add_argument("fwimage")
    p.add_argument("--out")
    p.set_defaults(fn=cmd_bindata)

    p = sub.add_parser("join", help="aligned-16B block join of two files")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--min-run", type=lambda x: int(x, 0), default=0x4000)
    p.add_argument("--top", type=int)
    p.set_defaults(fn=cmd_join)

    p = sub.add_parser("selfjoin", help="duplicated runs inside one file")
    p.add_argument("file")
    p.add_argument("--min-run", type=lambda x: int(x, 0), default=0x1000)
    p.add_argument("--top", type=int)
    p.set_defaults(fn=cmd_selfjoin)

    p = sub.add_parser("diff", help="localize differing bytes")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--merge", type=int, default=8)
    p.add_argument("--region", dest="regions", type=parse_region,
                   action="append", metavar="LO,HI,NAME")
    p.add_argument("--top", type=int)
    p.set_defaults(fn=cmd_diff)

    p = sub.add_parser("carray", help="convert generated C arrays to binary")
    p.add_argument("path")
    p.add_argument("--outdir")
    p.set_defaults(fn=cmd_carray)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
