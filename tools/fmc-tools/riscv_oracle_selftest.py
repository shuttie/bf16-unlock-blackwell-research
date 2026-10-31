#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""riscv_oracle_selftest.py - end-to-end controls for the FMC RISC-V oracle.

Builds synthetic FMC containers whose code component is real RISC-V code (from
the plaintext GSP-RM), encrypted with the known permutation POOL (rank 0 of the
lexicographic 16! enumeration) in ECB, CBC-zero and CTR-zero.  For each mode it
runs the GPU oracle over exactly rank 0 and checks for the matching hit mode
(0 = ECB, 1 = CBC, 2 = CTR), then runs the full-code verifier and requires it to
accept.  A random-plaintext container under the same key must produce no hit.

Usage:
  python3 riscv_oracle_selftest.py --bin ./key37_cuda
"""
from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

POOL = bytes([0x01, 0x10, 0x23, 0x32, 0x45, 0x54, 0x67, 0x76,
              0x89, 0x98, 0xab, 0xba, 0xcd, 0xdc, 0xef, 0xfe])
HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.environ.get("FWIMAGE", "")
LOGP = os.environ.get("LOGP", os.path.join(HERE, "riscv_logp_q.bin"))
VERIFY = os.path.join(HERE, "fmc_riscv_verify.py")
CODE = 0x37000
DATA = 0xE800
MAN = 0xA00
BODY = CODE + DATA + MAN
HIT_MODE = {"ecb": 0, "cbc": 1, "ctr": 2, "cbc-hdr": 3, "ctr1": 4}
VERIFY_MODE = {0: "ecb", 1: "cbc-zero", 2: "ctr-zero",
               3: "cbc-hdr", 4: "ctr-one"}


def code_segment() -> bytes:
    fw = open(FW, "rb").read()
    magic = b"\x7fELF\x02\x01\x01\x00"
    best = None
    pos = 0
    while True:
        elf = fw.find(magic, pos)
        if elf < 0:
            break
        pos = elf + 1
        phoff, = struct.unpack_from("<Q", fw, elf + 0x20)
        es, n = struct.unpack_from("<HH", fw, elf + 0x36)
        for i in range(n):
            o = elf + phoff + i * es
            t, = struct.unpack_from("<I", fw, o)
            po, pv, _pp, pf, _pm, _al = struct.unpack_from("<QQQQQQ", fw, o + 8)
            if t == 1 and pv == 0x01000000 and (best is None or pf > best[2]):
                best = (elf, po, pf)
    if best is None:
        raise SystemExit("no loaded ELF")
    return fw[best[0] + best[1]: best[0] + best[1] + best[2]]


def encrypt(body: bytes, mode: str, hdr: bytes) -> bytes:
    if mode == "ecb":
        c = Cipher(algorithms.AES(POOL), modes.ECB())
    elif mode == "cbc":
        c = Cipher(algorithms.AES(POOL), modes.CBC(bytes(16)))
    elif mode == "ctr":
        c = Cipher(algorithms.AES(POOL), modes.CTR(bytes(16)))
    elif mode == "cbc-hdr":
        c = Cipher(algorithms.AES(POOL), modes.CBC(hdr[:16]))
    elif mode == "ctr1":
        c = Cipher(algorithms.AES(POOL), modes.CTR(bytes(15) + b"\x01"))
    else:
        raise ValueError(mode)
    e = c.encryptor()
    return e.update(body) + e.finalize()


def make_container(code: bytes, mode: str, path: str) -> None:
    hdr = bytearray(0x48)
    struct.pack_into("<4I", hdr, 0, 0x00480403, BODY, 0, CODE)
    struct.pack_into("<I", hdr, 0x14, DATA)
    struct.pack_into("<I", hdr, 0x18, 0x104)
    struct.pack_into("<I", hdr, 0x20, 0x2801)
    body = bytearray(BODY)
    body[:len(code)] = code
    ct = encrypt(bytes(body), mode, bytes(hdr))
    with open(path, "wb") as f:
        f.write(bytes(hdr) + ct)


def run_oracle(binpath: str, container: str, blocks: int, outdir: str):
    os.makedirs(outdir, exist_ok=True)
    cmd = [binpath, "--device", "0", "--fmc-riscv", "--fmc", container,
           "--start", "0", "--count", "1", "--chunks", "1",
           "--riscv-blocks", str(blocks), "--logp", LOGP]
    r = subprocess.run(cmd, cwd=outdir, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        raise SystemExit("oracle run failed")
    hits = []
    hpath = os.path.join(outdir, "fmc_hits.txt")
    if os.path.exists(hpath):
        for line in open(hpath):
            p = line.split()
            if len(p) >= 5:
                hits.append((int(p[0]), p[1], int(p[2]), p[3], int(p[4])))
    return hits


def run_verifier(hits_path: str, container: str, outdir: str):
    r = subprocess.run([sys.executable, "-I", VERIFY, "--hits", hits_path,
                        "--container", container, "--outdir", outdir],
                       capture_output=True, text=True)
    valid = []
    for line in r.stdout.splitlines():
        if line.startswith("VALID"):
            # VALID   key=<hex> mode=<name> ...
            p = line.split()
            key = p[1].split("=", 1)[1]
            mode = p[2].split("=", 1)[1]
            valid.append((mode, key))
    return valid, r.stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(HERE, "key37_cuda"))
    ap.add_argument("--blocks", type=int, default=8)
    ap.add_argument("--tmp", default=os.environ.get("TMPDIR", os.path.join(HERE, "selftest_tmp")))
    a = ap.parse_args()
    if not FW or not os.path.exists(FW):
        print("set FWIMAGE to the extracted GSP-RM .fwimage", file=sys.stderr)
        return 2
    os.makedirs(a.tmp, exist_ok=True)

    code = code_segment()
    entry_off = 0x01A0F3DA - 0x01000000
    if entry_off + CODE > len(code):
        raise SystemExit("entry window outside the code segment")
    real = code[entry_off:entry_off + CODE]

    fails = 0
    # The two CBC IV hypotheses differ only in block 0, so the true key can
    # legitimately hit both (the header IV is a small mask).  The control
    # requires the correct mode to be present for the rank-0 key and the
    # verifier to accept that mode.
    for mode in ("ecb", "cbc", "ctr", "cbc-hdr", "ctr1"):
        cpath = os.path.join(a.tmp, "synth_%s_rank0.bin" % mode)
        make_container(real, mode, cpath)
        odir = os.path.join(a.tmp, mode)
        hits = run_oracle(a.bin, cpath, a.blocks, odir)
        want = HIT_MODE[mode]
        got_modes = {h[0] for h in hits}
        good = (hits and all(h[1] == POOL.hex() and h[2] == 0 for h in hits)
                and want in got_modes)
        print("%s: hits=%s want-mode=%d -> %s" %
              (mode, hits, want, "OK" if good else "FAIL"))
        if not good:
            fails += 1
            continue
        valid, out = run_verifier(os.path.join(odir, "fmc_hits.txt"), cpath,
                                  os.path.join(odir, "dec"))
        ok = any(m == VERIFY_MODE[want] and k == POOL.hex() for m, k in valid)
        print("   verifier valid=%s -> %s" % (valid, "OK" if ok else "FAIL"))
        if not ok:
            fails += 1
            print(out, file=sys.stderr)

    # Negative control: same key, random plaintext, ECB.
    bpath = os.path.join(a.tmp, "synth_random_rank0.bin")
    make_container(os.urandom(CODE), "ecb", bpath)
    hits = run_oracle(a.bin, bpath, a.blocks, os.path.join(a.tmp, "random"))
    print("random: hits=%s -> %s" % (hits, "OK" if not hits else "FAIL"))
    if hits:
        fails += 1

    print("selftest %s" % ("PASS" if not fails else "FAIL (%d)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
