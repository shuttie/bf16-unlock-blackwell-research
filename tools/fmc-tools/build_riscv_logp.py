#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""build_riscv_logp.py - build the 16-bit parcel log-probability table used by
the FMC RISC-V-validity oracle.

The FMC container body layout was measured (2026-10-28): the
encrypted body is [code][data][manifest 0xa00], and the code component of the
GB202 FMC is byte-identical to the first 0x37000 bytes of the code component of
the matching GspRmBoot image.  The body therefore starts with RISC-V code, not
with a container magic.  The previous first-block oracle filtered for magics and
could discard the correct key.

This tool trains a marginal language model over 16-bit instruction parcels
(RISC-V is 16-bit aligned; RV32 instructions occupy two consecutive parcels) on
the plaintext GSP-RM code segment, quantizes log2 p to half-bits and writes a
65536-byte int8 table.  The CUDA oracle sums eight table entries per 16-byte
block; a true code block scores far above a random block, and a run over the
whole 16! key space can gate on the first block and verify a longer window only
for the survivors.

Nothing here touches hardware.

Usage:
  python3 build_riscv_logp.py \
      --fw gsp_fwimage.bin \
      --out riscv_logp_q.bin
"""
from __future__ import annotations

import argparse
import collections
import glob
import math
import os
import re
import struct
import sys

POOL = bytes([0x01, 0x10, 0x23, 0x32, 0x45, 0x54, 0x67, 0x76,
              0x89, 0x98, 0xab, 0xba, 0xcd, 0xdc, 0xef, 0xfe])


ELF_MAGIC = b"\x7fELF\x02\x01\x01\x00"


def find_loaded_elf(fw: bytes):
    """Locate the ELF image that is loaded at 0x01000000.

    The .fwimage wrapper carries 11 embedded ELF64 headers; only the one at
    0x18F000 is the loaded GSP-RM image (the earlier ones are metadata).
    """
    best = None
    pos = 0
    while True:
        elf = fw.find(ELF_MAGIC, pos)
        if elf < 0:
            break
        pos = elf + 1
        phoff, = struct.unpack_from("<Q", fw, elf + 0x20)
        phentsize, phnum = struct.unpack_from("<HH", fw, elf + 0x36)
        for i in range(phnum):
            off = elf + phoff + i * phentsize
            p_type, = struct.unpack_from("<I", fw, off)
            p_offset, p_vaddr, _paddr, p_filesz, _memsz, _align = \
                struct.unpack_from("<QQQQQQ", fw, off + 8)
            # Several small ELFs also map 0x01000000; the loaded GSP-RM image
            # is the largest one (0x18F000, 0xDCD000 bytes).
            if p_type == 1 and p_vaddr == 0x01000000:
                if best is None or p_filesz > best[2]:
                    best = (elf, p_offset, p_filesz)
    if best is None:
        raise SystemExit("no loaded ELF found (no PT_LOAD at 0x01000000)")
    return best


def extract_code(fw: bytes) -> bytes:
    """Return the loaded GSP-RM code segment (p_vaddr 0x01000000)."""
    elf, p_offset, p_filesz = find_loaded_elf(fw)
    start = elf + p_offset
    return fw[start:start + p_filesz]


def build_table(code: bytes):
    # Drop the embedded ELF header (first page) and any trailing partial parcel.
    c = code[0x1000:]
    c = c[:len(c) // 2 * 2]
    parcels = struct.unpack("<%dH" % (len(c) // 2), c)
    cnt = collections.Counter(parcels)
    total = len(parcels)
    # +1 smoothing over 65536 outcomes: unseen parcels get a small probability.
    probs = [(cnt[i] + 1) / (total + 65536) for i in range(65536)]
    logp = [math.log2(p) for p in probs]
    q = [max(-128, min(127, int(round(x * 2)))) for x in logp]
    return q, logp, total, cnt


def score(block: bytes, q) -> int:
    return sum(q[x] for x in struct.unpack("<%dH" % (len(block) // 2), block))


def function_starts(root: str):
    pat = re.compile(r"^/\* ==== ram:([0-9a-f]+)  FUN_ram_([0-9a-f]+)")
    addrs = set()
    for f in glob.glob(os.path.join(root, "out/modules_v2/mod_*.c")):
        with open(f, "r", errors="ignore") as fh:
            for line in fh:
                m = pat.match(line)
                if m:
                    addrs.add(int(m.group(2), 16))
    return sorted(addrs)


def moments(q):
    cnt = collections.Counter(q)
    mean = sum(v * k for v, k in cnt.items()) / 65536.0
    var = sum((v - mean) ** 2 * k for v, k in cnt.items()) / 65536.0
    return mean, math.sqrt(var)


def gauss_tail(sigmas: float) -> float:
    return 0.5 * math.erfc(sigmas / math.sqrt(2.0))


def calibrate(q, code, starts, nblocks: int):
    mean, sd = moments(q)
    nparcels = nblocks * 8        # 8 parcels per 16-byte block
    nbytes = nblocks * 16
    vals = []
    for a in starts:
        off = a - 0x01000000
        if 0 <= off and off + nbytes <= len(code):
            vals.append(score(code[off:off + nbytes], q))
    vals.sort()
    n = len(vals)
    mu = nparcels * mean
    rmax = nparcels ** 0.5 * sd
    print("window %d bytes (%d blocks): real n=%d min=%d p0.5=%d p2=%d "
          "p5=%d med=%d" %
          (nbytes, nblocks, n, vals[0], vals[max(0, n // 200)],
           vals[max(0, n // 50)], vals[max(0, n // 20)], vals[n // 2]))
    for sig in (6, 7, 8, 9, 10, 12):
        T = mu + sig * rmax
        real = sum(1 for v in vals if v > T) / n
        print("  %2.0f sd: Tq=%8.0f (T=%8.0f bits) realpass=%.5f "
              "rand=%.2e hits/4.2e13=%.3g" %
              (sig, T, T / 2.0, real, gauss_tail(sig),
               gauss_tail(sig) * 4.2e13))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fw", default=os.environ.get("FWIMAGE", "gsp_fwimage.bin"))
    ap.add_argument("--out", default=os.environ.get("LOGP", "riscv_logp_q.bin"))
    ap.add_argument("--starts", default=os.environ.get("STARTS", ""))
    ap.add_argument("--no-calibrate", action="store_true")
    a = ap.parse_args()
    if not a.no_calibrate and not a.starts:
        print("no --starts directory; skipping calibration", file=sys.stderr)
        a.no_calibrate = True

    fw = open(a.fw, "rb").read()
    code = extract_code(fw)
    q, logp, total, cnt = build_table(code)
    ent = -sum((v / total) * math.log2(v / total) for v in cnt.values())
    print("code segment %d bytes; training parcels %d; entropy %.3f bits" %
          (len(code), total, ent))

    with open(a.out, "wb") as f:
        f.write(bytes((x + 256) & 0xff for x in q))
    print("wrote %s (%d bytes)" % (a.out, os.path.getsize(a.out)))

    if not a.no_calibrate:
        starts = function_starts(a.starts)
        # Entry point of the GSP-RM image, as an extra real-code sample.
        elf, _p_off, _p_sz = find_loaded_elf(fw)
        entry, = struct.unpack_from("<Q", fw, elf + 0x18)
        for nblocks in (1, 8, 32, 64):
            calibrate(q, code, starts, nblocks)
        off = entry - 0x01000000
        print("GSP-RM entry block score: %d (%s)" %
              (score(code[off:off + 16], q), code[off:off + 16].hex()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
