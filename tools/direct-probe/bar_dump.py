#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only BAR0 dump of the FEAT bank, the FUSE block, and the GR rate word.

Unlike hw_probe, this opens resource0 read-only and maps it without PROT_WRITE.
That is enough for a register dump and works on a host where the PCI sysfs files
are mounted read-only. No write path exists in this script.

Usage:
    python3 bar_dump.py <bdf> [--repeats N] [--out FILE]

Example:
    python3 bar_dump.py 0000:23:00.0 --repeats 3 --out bars.json
"""
import argparse
import json
import mmap
import os
import struct
import time

# (name, BAR0 byte offset, size in bytes)
REGIONS = [
    ("feat", 0x823800, 0x100),
    ("fuse", 0x820000, 0x1000),
    ("gr_rate", 0x504204, 0x4),
]

# A page scan here can wedge the card; refuse to start inside it.
HAZARD_LO, HAZARD_HI = 0x300000, 0x400000


def read_region(map_obj, base, size):
    return [
        struct.unpack_from("<I", map_obj, base + 4 * i)[0]
        for i in range(size // 4)
    ]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("bdf", help="PCI BDF, e.g. 0000:41:00.0")
    ap.add_argument("--repeats", type=int, default=3,
                    help="read each region this many times (default 3)")
    ap.add_argument("--out", help="write the raw values as JSON")
    args = ap.parse_args()

    path = f"/sys/bus/pci/devices/{args.bdf}/resource0"
    fd = os.open(path, os.O_RDONLY | os.O_SYNC)
    bar = mmap.mmap(fd, 0x1000000, offset=0, access=mmap.ACCESS_READ)

    report = {"bdf": args.bdf, "timestamp_unix": time.time(),
              "repeats": args.repeats, "regions": {}}

    for name, base, size in REGIONS:
        if base < HAZARD_HI and base + size > HAZARD_LO:
            raise SystemExit(f"{name}: refusing the hazardous 0x300000-0x400000 aperture")
        samples = [[0] * (size // 4) for _ in range(args.repeats)]
        for r in range(args.repeats):
            samples[r] = read_region(bar, base, size)
            time.sleep(0.2)
        dwords = []
        print(f"## {name} {base:#x}..{base + size - 1:#x}")
        for i in range(size // 4):
            values = [s[i] for s in samples]
            stable = "stable" if len(set(values)) == 1 else "UNSTABLE"
            print(f"{base + 4 * i:#010x}  "
                  + " ".join(f"{v:#010x}" for v in values)
                  + f"  {stable}")
            dwords.append({"offset": base + 4 * i, "values": values})
        report["regions"][name] = {"base": base, "size": size, "dwords": dwords}

    bar.close()
    os.close(fd)
    if args.out:
        with open(args.out, "w") as stream:
            json.dump(report, stream, indent=1)
        print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
