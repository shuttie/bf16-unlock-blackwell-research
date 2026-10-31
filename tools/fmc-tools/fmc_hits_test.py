#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""fmc_hits_test.py - validate FMC first-block oracle hits.

Reads lines `mode keyhex rank p0hex` from the GPU oracle, decrypts the first
bytes of the container body with the corresponding mode, scores the plaintext
for FMC headers, and runs the full fmc_key_test on high scorers.

Usage:
  python3 -I fmc_hits_test.py --hits fmc_hits.txt --container c09...bin
"""
from __future__ import annotations
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fmc_key_test as ft

SIZES = {
    0x37000, 0x46200, 0xE800, 0x30A00, 0x25800, 0xA800,
    0xFA00, 0x18000, 0x1000, 0x10000, 0x3EC00, 0x2FC00,
    0x33D00, 0x2E800, 0x30500, 0x28600,
}

# The FMC is an ELF32 (nova-core); its first block is the 16-byte ELF ident,
# a full known-plaintext block.  Accept the class/data/osabi variants.
ELF_IDENTS = set()
for _cls in (1, 2):
    for _data in (1, 2):
        for _osabi in (0, 3):
            ELF_IDENTS.add(bytes([0x7f, 0x45, 0x4c, 0x46, _cls, _data, 1,
                                  _osabi, 0, 0, 0, 0, 0, 0, 0, 0]))


def header_ok(p: bytes) -> bool:
    """Full first-block header check: magic plus a plausible second field."""
    if len(p) < 16:
        return False
    a = int.from_bytes(p[0:4], "little")
    b = int.from_bytes(p[4:8], "little")
    S = SIZES
    if a == 0x5746564E:                 # NVFW
        return b in S or b < 0x100000
    if a == 0x00480403:                 # 03 04 48 00 FMC container
        return b in S
    if a == 0x000010DE:                 # nvfw_bin_hdr: magic, hdr_off, data_off, data_sz
        c = int.from_bytes(p[8:12], "little")
        d = int.from_bytes(p[12:16], "little")
        return 0 < b < 0x1000 and 0 < c < 0x100000 and (d in S or 0 < d < 0x100000)
    if a == 0x3B1D14F0:                 # nvfw new format
        return b < 0x100000 or b in S
    if a == 0x00088B1F:                 # 1f 8b 08 00 gzip, mtime 0
        return p[4:8] == b"\x00\x00\x00\x00"
    if a == 0xFD2FB528:                 # zstd, FHD reserved bit clear
        return (p[4] & 0x08) == 0
    if a == 0x184D2204:                 # lz4 frame, version 01, reserved clear
        return (p[4] >> 6) == 1 and (p[4] & 0x02) == 0
    if a == 0x184C2102:                 # lz4 legacy + block size
        return b in S or b < 0x100000
    if a == 0x587A37FD:                 # xz 6-byte magic
        return p[4:6] == b"\x5a\x00"
    if a == 0x464C457F:                 # exact 16-byte ELF ident
        return p in ELF_IDENTS
    if a in S and (b in S or b == 0):
        return True
    if a == 0 and b == 0:
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hits", required=True)
    ap.add_argument("--container", default=ft.CONTAINERS["c09-dbg-gb202"])
    ap.add_argument("--bytes", type=lambda x: int(x, 0), default=0x1000)
    ap.add_argument("--top", type=int, default=20)
    a = ap.parse_args()

    d = open(a.container, "rb").read()
    if d[:4] != b"\x03\x04\x48\x00":
        print("not an FMC container", file=sys.stderr)
        return 1
    body = d[0x48:]

    rows = []
    n = 0
    for line in open(a.hits):
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            mode = int(parts[0])
            key = bytes.fromhex(parts[1])
        except ValueError:
            continue
        if len(key) != 16:
            continue
        rank, p0 = parts[2], parts[3]
        try:
            p0b = bytes.fromhex(p0)
        except ValueError:
            continue
        if not header_ok(p0b):
            continue
        n += 1
        if mode == 0:
            for m, iv in (("ecb", None), ("cbc", bytes(16))):
                try:
                    pt = ft.decrypt(body[:a.bytes], key, m, iv)
                except Exception:
                    continue
                s, why = ft.score(pt)
                rows.append((s, m, key, rank, p0, why, pt[:16].hex()))
        else:
            try:
                pt = ft.decrypt(body[:a.bytes], key, "ctr", bytes(16))
            except Exception:
                continue
            s, why = ft.score(pt)
            rows.append((s, "ctr", key, rank, p0, why, pt[:16].hex()))

    rows.sort(key=lambda x: -x[0])
    print("hits=%d tested=%d" % (n, len(rows)))
    for s, m, key, rank, p0, why, first in rows[:a.top]:
        print("%4d %-3s %s rank=%s p0=%s first=%s %s" %
              (s, m, key.hex(), rank, p0, first, "; ".join(why) or "-"))

    seen = set()
    for s, m, key, rank, p0, why, first in rows[:a.top]:
        if s < 20 or key in seen:
            continue
        seen.add(key)
        print("\n== full fmc_key_test for %s (mode %s score %d)" % (key.hex(), m, s))
        for r in ft.run_key(key, ft.CONTAINERS, 0x1000)[:6]:
            print("   %4d %-16s %-4s %-5s %s first=%s" % r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
