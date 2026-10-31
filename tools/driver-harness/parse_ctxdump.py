#!/usr/bin/env python3
"""Parse BF16CTX dmesg lines into binary context-buffer dumps.

Usage: parse_ctxdump.py <dmesg.txt> <outdir>
"""
import os
import re
import sys

HDR = re.compile(
    r"BF16: ctxdump (\S+) seq=(\d+) size=(\d+) phys=(\S+)"
    r"(?: dump=(\d+)| map_status=(\S+))"
)
HEX = re.compile(
    r"BF16CTX (\S+) (\d+) ([0-9a-fA-F]+):\s+((?:[0-9a-fA-F]{8}\s*)+)"
)


def main():
    dmesg, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    meta = {}      # (tag, seq) -> dict
    blobs = {}     # (tag, seq) -> bytearray
    order = []

    with open(dmesg, "r", errors="replace") as f:
        for line in f:
            m = HDR.search(line)
            if m:
                tag, seq, size, phys = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
                dump = int(m.group(5)) if m.group(5) else 0
                key = (tag, seq)
                if key not in blobs:
                    order.append(key)
                    blobs[key] = bytearray(dump)
                meta[key] = {
                    "size": size,
                    "phys": phys,
                    "dump": dump,
                    "map_status": m.group(6),
                }
                continue

            m = HEX.search(line)
            if not m:
                continue
            tag, seq = m.group(1), int(m.group(2))
            key = (tag, seq)
            off = int(m.group(3), 16)
            words = m.group(4).split()
            if key not in blobs:
                order.append(key)
                blobs[key] = bytearray(off + 4 * len(words))
            buf = blobs[key]
            need = off + 4 * len(words)
            if len(buf) < need:
                buf.extend(b"\0" * (need - len(buf)))
            for i, w in enumerate(words):
                buf[off + 4 * i:off + 4 * i + 4] = bytes.fromhex(w)[::-1]

    summary = []
    for key in order:
        tag, seq = key
        buf = bytes(blobs[key])
        info = meta.get(key, {})
        name = "ctxdump_%s_%d.bin" % (tag, seq)
        path = os.path.join(outdir, name)
        with open(path, "wb") as f:
            f.write(buf)
        nz = sum(1 for b in buf if b)
        first = buf[:64].hex()
        summary.append(
            "%-6s seq=%-3d size=%-12s dumped=%-6d nonzero=%-6d phys=%-14s map=%-6s %s"
            % (tag, seq, info.get("size", "?"), len(buf), nz,
               info.get("phys", "?"), info.get("map_status", "-"), first)
        )
        print("%-6s seq=%-3d -> %s (%d bytes, %d nonzero)"
              % (tag, seq, path, len(buf), nz))

    if not summary:
        print("no BF16CTX records found")
        return 1

    text = "\n".join(summary) + "\n"
    with open(os.path.join(outdir, "summary.txt"), "w") as f:
        f.write(text)
    print()
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
