#!/usr/bin/env python3
"""Read-only peek at FB offsets through BAR1 (no register writes, no driver calls).

The 5090 exposes a 32 GiB BAR1 (ReBAR), so any FB offset is directly addressable.
This tells us whether the firmware's WPR / FRTS region is host-readable or blocked.

Usage:
  sudo fb_peek.py <bdf> <off_hex>[,<off_hex>...] [len_hex]

Example (stock GSP layout):
  sudo fb_peek.py 0000:41:00.0 0x1000000,0x7e72e0000,0x7f0000000,0x7f42c0000

Offsets must be 4 KiB aligned.  Read-only: opens resource1 O_RDONLY and maps
PROT_READ.  A blocked WPR read typically returns 0xFFFFFFFF (or a BADF sentinel);
a readable region shows real data.
"""
import sys, os, mmap, math, collections

def entropy(b):
    if not b:
        return 0.0
    c = collections.Counter(b)
    n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c.values())

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    bdf = sys.argv[1]
    offs = [int(x, 16) for x in sys.argv[2].split(",")]
    ln = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x1000
    path = f"/sys/bus/pci/devices/{bdf}/resource1"
    fd = os.open(path, os.O_RDONLY)
    for off in offs:
        if off % 4096:
            print(f"{off:#x}: not 4K aligned, skipped")
            continue
        try:
            m = mmap.mmap(fd, ln, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
        except Exception as e:
            print(f"{off:#x}: mmap failed: {e}")
            continue
        b = m[:ln]
        nz = sum(1 for x in b if x)
        ff = sum(1 for x in b if x == 0xFF)
        print(f"{off:#012x}: ent={entropy(b):.3f} nonzero={nz}/{ln} ff={ff}/{ln} "
              f"head={b[:32].hex()}")
        asci = "".join(chr(c) if 32 <= c < 127 else "." for c in b[:64])
        print(f"              asc {asci}")
        m.close()
    os.close(fd)
    return 0

if __name__ == "__main__":
    sys.exit(main())
