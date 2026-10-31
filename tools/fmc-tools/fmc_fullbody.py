#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""fmc_fullbody.py - validate every FMC first-block hit against the whole body.

For each hit, decrypt the complete c09 body in the hit's mode and test whether
it is a valid zstd/gzip/xz/ELF/nvfw image.  A first-block magic alone is not
enough; a real key must make the whole body parse.

Usage:
  python3 -I fmc_fullbody.py --hits fmc_hits_all.txt --container c09...bin
"""
from __future__ import annotations
import argparse
import io
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fmc_key_test as ft
import fmc_hits_test as ht

try:
    import zstandard
except ImportError:
    zstandard = None


def nvfw_ok(b: bytes) -> tuple[bool, str]:
    if len(b) < 0x100:
        return False, ""
    magic, hdr_off, data_off, data_size = struct.unpack_from("<4I", b, 0)
    if magic != 0x10DE:
        return False, ""
    if not (0 < hdr_off < 0x1000 and 0x40 <= data_off < len(b) and
            0 < data_size <= len(b) and data_off + data_size <= len(b) + 0x1000):
        return False, ""
    hs = struct.unpack_from("<9I", b, hdr_off)
    sig_off, sig_size, patch_loc, patch_sig, num_sig, meta_off, meta_size, load_off, _ = hs
    if not (sig_off < len(b) and sig_size < 0x1000 and patch_loc < len(b) and
            num_sig < 16 and 0 < load_off < len(b)):
        return False, "hs"
    load = struct.unpack_from("<5I", b, load_off)
    c_off, c_size, d_off, d_size, napp = load
    if not (c_off < len(b) and c_size <= len(b) and d_off < len(b) and
            d_size <= len(b) and napp <= 8):
        return False, "load"
    return True, "nvfw hdr=%#x data=%#x+%#x code=%#x+%#x apps=%d" % (
        hdr_off, data_off, data_size, c_off, c_size, napp)


def validate(b: bytes, a: int) -> tuple[bool, str]:
    if a == 0xFD2FB528:
        if zstandard is None:
            return False, "zstd-nomodule"
        try:
            with zstandard.ZstdDecompressor().stream_reader(io.BytesIO(b)) as r:
                out = r.read(1 << 26)
            return True, "zstd %d" % len(out)
        except Exception:
            return False, "zstd"
    if a == 0x00088B1F:
        try:
            out = zlib.decompress(b, 31)
            return True, "gzip %d" % len(out)
        except Exception:
            return False, "gzip"
    if a == 0x587A37FD:
        try:
            out = lzma.decompress(b)
            return True, "xz %d" % len(out)
        except Exception:
            return False, "xz"
    if a == 0x464C457F:
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b)
            p = f.name
        try:
            r = subprocess.run(["readelf", "-h", p], capture_output=True)
            return (r.returncode == 0), "elf"
        finally:
            os.unlink(p)
    if a == 0x10DE:
        return nvfw_ok(b)
    if a == 0x3B1D14F0:
        return False, "newfmt " + b[:32].hex()
    if a == 0x00480403:
        return False, "nested-fmc " + b[:32].hex()
    if a == 0x5746564E:
        return False, "nvfw-tlv " + b[:32].hex()
    return False, ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hits", required=True)
    ap.add_argument("--container", default=ft.CONTAINERS["c09-dbg-gb202"])
    ap.add_argument("--outdir", default=os.environ.get("FMC_OUT", "fmc_dec"))
    a = ap.parse_args()
    d = open(a.container, "rb").read()
    if d[:4] != b"\x03\x04\x48\x00":
        print("not an FMC container", file=sys.stderr)
        return 1
    body = d[0x48:]
    os.makedirs(a.outdir, exist_ok=True)

    seen = set()
    n = 0
    good = 0
    for line in open(a.hits):
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            mode = int(parts[0]); key = bytes.fromhex(parts[1]); p0 = bytes.fromhex(parts[3])
        except ValueError:
            continue
        if len(key) != 16 or len(p0) < 16:
            continue
        if not ht.header_ok(p0):
            continue
        a32 = int.from_bytes(p0[0:4], "little")
        trials = [("ecb", None), ("cbc", bytes(16))] if mode == 0 else [("ctr", bytes(16))]
        for m, iv in trials:
            tag = (key, m, a32)
            if tag in seen:
                continue
            seen.add(tag)
            n += 1
            try:
                pt = ft.decrypt(body, key, m, iv)
            except Exception:
                continue
            ok, why = validate(pt, a32)
            if ok:
                good += 1
                out = os.path.join(a.outdir, "fmc_%s_%s_%08x.bin" % (key.hex(), m, a32))
                open(out, "wb").write(pt)
                print("VALID key=%s mode=%s magic=%08x %s -> %s" %
                      (key.hex(), m, a32, why, out))
            elif why and not why.startswith(("zstd", "gzip", "xz", "elf")):
                print("note key=%s mode=%s %s" % (key.hex(), m, why))
    print("tested=%d valid=%d" % (n, good))
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
