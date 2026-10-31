#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""fmc_key_test.py - try a candidate AES key against the GB202 FMC containers.

The FMC container is a 0x48-byte plaintext header followed by an encrypted
body.  The body's mode is not public: the observed body has entropy 7.999, no
repeated 16-byte ECB blocks, and no nonce.  That is consistent with ECB over a
compressed plaintext, or CBC/CTR/XTS with a fixed IV/counter.  This tool tries
the plausible modes and scores the first bytes for a known structure.

Read-only: the containers are files; no GPU access.

Usage:
  python3 -I fmc_key_test.py --key hexkey [--bytes 4096]
  python3 -I fmc_key_test.py --selftest

Default container directory: ./containers (override with FMC_CONTAINERS);
c04 (prod GB202), c09 (debug GB202), c11 (0x30500 debug variant).
"""
from __future__ import annotations
import argparse
import math
import os
import struct
import sys
from collections import Counter

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError:
    print("install python3-cryptography", file=sys.stderr)
    raise SystemExit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTAINERS_DIR = os.environ.get("FMC_CONTAINERS", os.path.join(HERE, "containers"))
CONTAINERS = {
    "c04-prod-gb202": os.path.join(CONTAINERS_DIR, "c04_0058f598_046200.bin"),
    "c09-dbg-gb202": os.path.join(CONTAINERS_DIR, "c09_00691480_046200.bin"),
    "c11-dbg-030500": os.path.join(CONTAINERS_DIR, "c11_00706338_030500.bin"),
}

MAGICS = [
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"\x1f\x8b", "gzip"),
    (b"\x04\x22\x4d\x18", "lz4-frame"),
    (b"\x02\x21\x4c\x18", "lz4-legacy"),
    (b"\xfd\x37\x7a\x58\x5a\x00", "xz"),
    (b"\x7f\x45\x4c\x46", "ELF"),
    (b"\xde\x10", "nvfw-10de"),
    (b"\x4e\x56\x46\x57", "NVFW"),
    (b"\x03\x04\x48\x00", "fmc-header"),
]
SIZES = {0x37000, 0x46200, 0xE800, 0x30A00, 0x25800, 0xA800,
         0xFA00, 0x18000, 0x1000, 0x10000}


def entropy(b: bytes) -> float:
    if not b:
        return 0.0
    c = Counter(b)
    n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def score(pt: bytes) -> tuple[int, list[str]]:
    s = 0
    why: list[str] = []
    head = pt[:0x1000]
    for magic, name in MAGICS:
        if head.startswith(magic):
            s += 40
            why.append("magic " + name + " @0")
        elif magic in head[:0x20]:
            s += 30
            why.append("magic " + name + " in first 0x20")
    for off in (0, 4, 8, 12):
        if off + 4 <= len(pt):
            v = struct.unpack_from("<I", pt, off)[0]
            if v in SIZES:
                s += 20
                why.append("size %#x @%d" % (v, off))
    # a header normally has some zero dwords; code/compressed data does not.
    zeros = sum(1 for i in range(0, min(len(head), 0x100), 4)
                if head[i:i + 4] == b"\x00\x00\x00\x00")
    if zeros >= 2:
        s += min(zeros, 8)
        why.append("%d zero dwords in first 0x100" % zeros)
    printable = sum(1 for c in head[:0x40] if 32 <= c < 127 or c == 0)
    if printable >= 28:
        s += 5
        why.append("printable/zero first 0x40")
    if len(head) >= 0x100:
        e = entropy(head[:0x100])
        if e < 7.0:
            s += 5
            why.append("entropy(first 0x100)=%.2f" % e)
    return s, why


def decrypt(body: bytes, key: bytes, mode: str, iv: bytes | None) -> bytes:
    alg = algorithms.AES(key)
    if mode == "ecb":
        m = modes.ECB()
    elif mode == "cbc":
        m = modes.CBC(iv or bytes(16))
    elif mode == "ctr":
        m = modes.CTR(iv or bytes(16))
    else:
        raise ValueError(mode)
    dec = Cipher(alg, m).decryptor()
    return dec.update(body) + dec.finalize()


def run_key(key: bytes, containers: dict[str, str], nbytes: int) -> list[tuple]:
    out = []
    for name, path in containers.items():
        if not os.path.isfile(path):
            continue
        d = open(path, "rb").read()
        if d[:4] != b"\x03\x04\x48\x00" or len(d) < 0x48:
            continue
        body = d[0x48:0x48 + nbytes]
        hdr = d[:0x48]
        ivs = {"zero": bytes(16), "hdr": hdr[:16]}
        for mode in ("ecb", "cbc", "ctr"):
            ivset = {"-": None} if mode == "ecb" else ivs
            for ivname, iv in ivset.items():
                try:
                    pt = decrypt(body, key, mode, iv)
                except Exception as e:
                    continue
                s, why = score(pt)
                out.append((s, name, mode, ivname, why, pt[:16].hex()))
    out.sort(key=lambda x: -x[0])
    return out


def selftest() -> int:
    # FIPS-197 C.1
    key = bytes(range(16))
    pt = bytes.fromhex("00112233445566778899aabbccddeeff")
    want = bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a")
    got = Cipher(algorithms.AES(key), modes.ECB()).encryptor().update(pt)
    if got != want:
        print("selftest: AES FIPS FAILED", file=sys.stderr)
        return 1
    # Synthetic FMC body: a plausible header + zeros, encrypted in each mode.
    plain = bytes.fromhex("de10") + bytes(14) + struct.pack("<I", 0x46200) + bytes(0x6c)
    for mode, iv in (("ecb", None), ("cbc", bytes(16)), ("ctr", bytes(16))):
        if mode == "ecb":
            e = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
        else:
            m = modes.CBC(iv) if mode == "cbc" else modes.CTR(iv)
            e = Cipher(algorithms.AES(key), m).encryptor()
        enc = e.update(plain) + e.finalize()
        back = decrypt(enc, key, mode, iv)
        if back != plain:
            print("selftest: round-trip failed for", mode, file=sys.stderr)
            return 1
        s, why = score(back)
        if s < 50:
            print("selftest: score too low for", mode, s, why, file=sys.stderr)
            return 1
    print("selftest: AES FIPS OK; ECB/CBC/CTR round-trip and scoring OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", help="16-byte key as 32 hex characters")
    ap.add_argument("--key-file", help="file with 16 raw bytes or 32 hex characters")
    ap.add_argument("--bytes", type=lambda x: int(x, 0), default=0x1000)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.key_file:
        raw = open(a.key_file, "rb").read(129)
        key = raw[:16] if len(raw) == 16 else bytes.fromhex(raw.decode().strip())
    elif a.key:
        key = bytes.fromhex(a.key.strip())
    else:
        ap.error("--key or --key-file required")
    if len(key) != 16:
        ap.error("key must be 16 bytes")
    print("key =", key.hex(), "(not written)")
    rows = run_key(key, CONTAINERS, a.bytes)
    if not rows:
        print("no containers found")
        return 1
    print("%4s %-16s %-4s %-5s %s" % ("score", "container", "mode", "iv", "why"))
    for s, name, mode, ivname, why, first in rows[:12]:
        print("%4d %-16s %-4s %-5s %s  first=%s" %
              (s, name, mode, ivname, "; ".join(why) or "-", first))
    return 0


if __name__ == "__main__":
    sys.exit(main())
