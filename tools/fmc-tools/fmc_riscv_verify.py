#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""fmc_riscv_verify.py - validate FMC RISC-V-oracle hits against the whole code.

The oracle scores only the first few blocks.  A correct key must make the
*entire* code component decode as RISC-V: the container layout is
[code][data][manifest 0xa00] (measured 2026-10-28), so the first
codeSize bytes of the body are one compiled RISC-V image.

For each hit line `mode key rank p0 score` (mode 0 = ECB, 1 = CBC-zero,
2 = CTR-zero) this decrypts the full code component, walks every instruction
with correct 16/32-bit alignment, and reports the invalid-instruction fraction,
the longest invalid run, and direct branch targets outside the image.  Random
plaintext decodes ~9% invalid; compiled RISC-V is ~0.03% invalid.

Usage:
  python3 fmc_riscv_verify.py --hits HITS --container C09 \
      [--cross C11] [--outdir DIR]
"""
from __future__ import annotations

import argparse
import collections
import os
import struct
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

OP32 = {0x37, 0x17, 0x6f, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x0f, 0x73,
        0x2f, 0x07, 0x27, 0x53, 0x43, 0x47, 0x4b, 0x4f, 0x0b, 0x2b, 0x5b,
        0x7b, 0x1b, 0x3b}
BRANCH32 = {0x63, 0x6f}
BRANCH16 = {0x2, 0x5, 0x6, 0x7}   # c.jal/c.j/c.beqz/c.bnez (quadrant 1 funct3)

# Acceptance: compiled code is ~0.03-0.5% invalid (literal pools included);
# random is ~9%.  Over ~2e5 instructions the two are separated by >100 sigma.
BAD_FRAC_MAX = 0.01
PREFIX_BAD_FRAC_MAX = 0.01
PREFIX_BYTES = 0x2000


def rvc_ok(h: int) -> bool:
    q = h & 3
    f = (h >> 13) & 7
    if q == 0:
        if f == 4:
            return False
        if f == 0:
            nz = ((h >> 7) & 0xf) | (((h >> 11) & 3) << 4) | (((h >> 5) & 1) << 6)
            return nz != 0
        return True
    if q == 1:
        if f == 3:
            rd = (h >> 7) & 0x1f
            nz = (((h >> 12) & 1) << 5) | ((h >> 2) & 0x1f)
            if rd == 0:
                return False
            if rd == 2 and nz == 0:
                return False
        return True
    if q == 2:
        return True
    return True


def walk(b: bytes, lo: int, hi: int):
    """Decode [lo, hi); return (good, bad, max_bad_run, bad_targets)."""
    o = lo
    good = bad = cur = maxrun = badtar = 0
    n = hi
    while o + 2 <= n:
        h = struct.unpack_from("<H", b, o)[0]
        if (h & 3) == 3:
            if o + 4 > n:
                break
            w = struct.unpack_from("<I", b, o)[0]
            ok = (w & 0x7f) in OP32
            if ok and (w & 0x7f) in BRANCH32:
                # JAL imm[20|10:1|11|19:12]; BRANCH imm[12|10:5|4:1|11]
                if (w & 0x7f) == 0x6f:
                    imm = (((w >> 31) & 1) << 20) | (((w >> 12) & 0xff) << 12) | \
                          (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3ff) << 1)
                    imm = imm - (1 << 21) if imm & (1 << 20) else imm
                else:
                    imm = (((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | \
                          (((w >> 25) & 0x3f) << 5) | (((w >> 8) & 0xf) << 1)
                    imm = imm - (1 << 13) if imm & (1 << 12) else imm
                t = o + imm
                if t & 1 or t < 0 or t >= hi:
                    badtar += 1
            o += 4
        else:
            ok = rvc_ok(h)
            q = h & 3
            f = (h >> 13) & 7
            if ok and q == 1 and f in (0x2, 0x5):
                imm = (((h >> 12) & 1) << 11) | (((h >> 8) & 1) << 10) | \
                      (((h >> 9) & 3) << 8) | (((h >> 6) & 1) << 7) | \
                      (((h >> 7) & 1) << 6) | (((h >> 2) & 1) << 5) | \
                      (((h >> 11) & 1) << 4) | (((h >> 3) & 7) << 1)
                imm = imm - (1 << 12) if imm & (1 << 11) else imm
                t = o + imm
                if t & 1 or t < 0 or t >= hi:
                    badtar += 1
            o += 2
        if ok:
            good += 1
            if cur:
                maxrun = max(maxrun, cur)
                cur = 0
        else:
            bad += 1
            cur += 1
    maxrun = max(maxrun, cur)
    return good, bad, maxrun, badtar


def decrypt(body: bytes, key: bytes, mode: int, hdr_iv: bytes) -> bytes:
    if mode == 0:
        c = Cipher(algorithms.AES(key), modes.ECB())
    elif mode == 1:
        c = Cipher(algorithms.AES(key), modes.CBC(bytes(16)))
    elif mode == 2:
        c = Cipher(algorithms.AES(key), modes.CTR(bytes(16)))
    elif mode == 3:
        c = Cipher(algorithms.AES(key), modes.CBC(hdr_iv))
    elif mode == 4:
        c = Cipher(algorithms.AES(key), modes.CTR(bytes(15) + b"\x01"))
    else:
        raise ValueError(mode)
    d = c.decryptor()
    return d.update(body) + d.finalize()


def parse_container(path: str):
    d = open(path, "rb").read()
    if d[:4] != b"\x03\x04\x48\x00":
        raise SystemExit("not an FMC container: " + path)
    body_size, code_size, data_size = struct.unpack_from("<3I", d, 4)[0], \
        struct.unpack_from("<I", d, 0x0C)[0], struct.unpack_from("<I", d, 0x14)[0]
    return d, body_size, code_size, data_size


def check(code: bytes):
    g, b, run, badtar = walk(code, 0, len(code))
    frac = b / max(1, g + b)
    pg, pb, prun, pbt = walk(code, 0, min(PREFIX_BYTES, len(code)))
    pfrac = pb / max(1, pg + pb)
    ok = frac <= BAD_FRAC_MAX and pfrac <= PREFIX_BAD_FRAC_MAX
    return ok, frac, run, badtar, pfrac


MODE_NAME = {0: "ecb", 1: "cbc-zero", 2: "ctr-zero",
             3: "cbc-hdr", 4: "ctr-one"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hits", required=True)
    ap.add_argument("--container", required=True)
    ap.add_argument("--cross", default=None,
                    help="second container that should use the same debug key")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    d, body_size, code_size, data_size = parse_container(a.container)
    body = d[0x48:]
    if len(body) < code_size:
        raise SystemExit("container body shorter than code_size")
    if a.outdir:
        os.makedirs(a.outdir, exist_ok=True)
    cross = None
    if a.cross:
        cd, _cb, ccode, _cdat = parse_container(a.cross)
        cross = (cd[0x48:], ccode, cd[:16])
        print("cross container %s code=%#x" % (a.cross, ccode))

    rows = []
    for line in open(a.hits):
        p = line.split()
        if len(p) < 4:
            continue
        rows.append((int(p[0]), bytes.fromhex(p[1]),
                     int(p[2]), bytes.fromhex(p[3]),
                     int(p[4]) if len(p) > 4 else 0))

    print("%d hit lines; container %s body=%#x code=%#x data=%#x" %
          (len(rows), a.container, body_size, code_size, data_size))
    valid = naccepted = 0
    for mode, key, rank, p0, score in rows:
        if mode not in MODE_NAME:
            continue
        code = decrypt(body[:code_size], key, mode, d[:16])
        ok, frac, run, badtar, pfrac = check(code)
        msg = ("mode=%-8s rank=%-14d score=%-7d bad=%.5f prefix_bad=%.5f "
               "maxrun=%d btargets=%d" %
               (MODE_NAME[mode], rank, score, frac, pfrac, run, badtar))
        if ok:
            naccepted += 1
            extra = ""
            if cross is not None:
                cbody, ccode_size, chdr = cross
                cc = decrypt(cbody[:min(ccode_size, 0x1000)], key, mode, chdr)
                cg, cb, crun, _ = walk(cc, 0, len(cc))
                cfrac = cb / max(1, cg + cb)
                extra = " cross_bad(4K)=%.4f" % cfrac
            print("VALID   key=%s %s%s" % (key.hex(), msg, extra))
            valid += 1
            if a.outdir:
                with open(os.path.join(a.outdir, "%s_%s.bin" %
                                       (key.hex(), MODE_NAME[mode])), "wb") as f:
                    f.write(code)
        else:
            print("reject  key=%s %s" % (key.hex(), msg))
    print("done: %d/%d hits pass the full-code RISC-V check" % (valid, len(rows)))
    return 0 if valid or not rows else 0


if __name__ == "__main__":
    sys.exit(main())
