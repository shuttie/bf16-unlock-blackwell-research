#!/usr/bin/env python3
"""app23_decode.py - decode the app 0x23 / target 0x0E vBIOS data tail.

Read-only analysis of local vBIOS dumps; no GPU access, nothing executes.

Stages:
  1. Parse the ucode table (reuse devinit_scan.py coordinates), dump the
     app 0x23 descriptor fields.
  2. Segment the plaintext tail: value classes, stride autocorrelation.
  3. Per-card calibration: the dwords that differ between the two cards.
  4. Check live FEAT-bank values (SS0/SS1/READOUT/ID) against the tail and
     the calibration set.

Usage:
  python3 -I app23_decode.py <flash1m_a.bin> <flash1m_b.bin>
"""
import math
import struct
import sys
from collections import Counter

# Image coordinates in the 1 MiB dump (devinit_scan.py output, card 41).
DESC = 0xB77BC
BODY = 0xB780C
BODY_END = 0xD5A0C
TAIL = 0xC8000          # plaintext data start
HDR2 = 0xC780C          # ~2 KiB header between code and data

# Measured live FEAT values (docs/specs/03_register-map.md).
LIVE = {
    "PLM_pair":      [0xFFFFFB8F],
    "QUADRO_41":     [0x01000280],
    "QUADRO_c1":     [0x01000380],
    "OVR_ECC":       [0x00888888],
    "OVR_ECC_1":     [0x002A2AAA],
    "READOUT_0":     [0x00000233],
    "READOUT_1":     [0x00C36180],
    "SS0_41":        [0x21240001, 0x20240001, 0x20260041,
                      0x21265047, 0x21265043],
    "SS0_c1":        [0x54226037, 0x54224037, 0x54225037, 0x54226037],
    "SS1_41":        [0x00000002, 0x00000006],
    "SS1_c1":        [0x00026005, 0x00024005],
    "SS0_proA":      [0x56664061],
    "SS1_proA":      [0x00075005],
    "SS0_proB":      [0x00544047],
    "SS1_proB":      [0x00000001],
    "ID_5090":       [0x12800541],
    "PLM_flr_reset": [0x80842BCF],
}
TAIL_TABLES = [0xE8300, 0xE9400]
FAR_ANCHOR = 0xF70E8


def dwords(d, start, end):
    n = (end - start) // 4
    return [struct.unpack_from("<I", d, start + 4 * i)[0] for i in range(n)]


def hexrow(vals, base, i, n=8):
    chunk = vals[i:i + n]
    return "%08x: %s" % (base + 4 * i,
                         " ".join("%08x" % v for v in chunk))


def main():
    a = open(sys.argv[1], "rb").read()
    b = open(sys.argv[2], "rb").read()

    print("== descriptor @%#x (0x50 bytes)" % DESC)
    desc = a[DESC:DESC + 0x50]
    for i in range(0, 0x50, 4):
        v = struct.unpack_from("<I", desc, i)[0]
        print("  +%02x: %08x" % (i, v))
    hdr = struct.unpack_from("<I", desc, 0)[0]
    print("  hdr=%#x -> ver_avail=%d enc=%d descVer=%d descSize=%#x" %
          (hdr, hdr & 1, (hdr >> 2) & 1, (hdr >> 8) & 0xFF, hdr >> 16))
    for off in (0x04, 0x08, 0x0C, 0x10, 0x14, 0x18):
        print("  field +%02x = %#x" % (off,
              struct.unpack_from("<I", desc, off)[0]))

    print("\n== ~2 KiB header @%#x..%#x" % (HDR2, TAIL))
    h = a[HDR2:TAIL]
    hc = Counter(h)
    print("  entropy=%.2f" %
          (-sum((v / len(h)) * math.log2(v / len(h)) for v in hc.values())))
    for i in range(0, min(len(h), 0x100), 4):
        v = struct.unpack_from("<I", h, i)[0]
        if v:
            print("  +%03x: %08x" % (i, v))

    print("\n== tail @%#x..%#x dword census" % (TAIL, BODY_END))
    tail = a[TAIL:BODY_END]
    vals = dwords(a, TAIL, BODY_END)
    c = Counter(vals)
    print("  dwords=%d distinct=%d" % (len(vals), len(c)))
    for v, n in c.most_common(16):
        print("    %08x  n=%d" % (v, n))

    # stride autocorrelation: fraction of dwords equal to the one k slots
    # later, for k in 1..64
    print("\n== stride autocorrelation (top 12)")
    scores = []
    for k in range(1, 65):
        if len(vals) <= k:
            break
        same = sum(1 for i in range(len(vals) - k) if vals[i] == vals[i + k])
        scores.append((same / (len(vals) - k), k))
    for s, k in sorted(scores, reverse=True)[:12]:
        print("  stride %2d: %.3f" % (k, s))

    # region map: classify 0x400-byte windows
    print("\n== window classes (0x400 B)")
    for w in range(TAIL, BODY_END, 0x400):
        win = a[w:w + 0x400]
        if not win:
            break
        n = len(win) // 4
        ws = dwords(a, w, w + n * 4)
        poison = sum(1 for v in ws if v == 0xBADF5040)
        zero = sum(1 for v in ws if v == 0)
        ent = -sum((v / len(win)) * math.log2(v / len(win))
                   for v in Counter(win).values())
        cls = ("poison" if poison > n * 0.5 else
               "zero" if zero > n * 0.5 else
               "data" if ent < 4 else "mixed")
        print("  %#08x-%08x ent=%.2f %s poison=%d zero=%d" %
              (w, w + len(win), ent, cls, poison, zero))

    print("\n== per-card calibration dwords (41 vs c1, tail and beyond)")
    n = min(len(a), len(b))
    diffs = []
    for off in range(TAIL, min(0x100000, n), 4):
        va = struct.unpack_from("<I", a, off)[0]
        vb = struct.unpack_from("<I", b, off)[0]
        if va != vb:
            diffs.append((off, va, vb))
    print("  differing dwords: %d" % len(diffs))
    for off, va, vb in diffs:
        print("    %#08x: %08x / %08x" % (off, va, vb))

    print("\n== live FEAT values vs tail (both cards, tail..0x100000)")
    for name, live_vals in LIVE.items():
        hits = []
        for lv in live_vals:
            pat = struct.pack("<I", lv)
            for tag, d in (("41", a), ("c1", b)):
                i = TAIL
                while True:
                    j = d.find(pat, i)
                    if j < 0:
                        break
                    hits.append((tag, j, lv))
                    i = j + 1
        cal = [(off, va, vb) for off, va, vb in diffs
               if va in live_vals or vb in live_vals]
        print("  %-14s %s%s" % (name,
              "hits=%s" % ([(t, hex(o)) for t, o, _ in hits[:6]])
              if hits else "none",
              " calibration-match=%s" % [(hex(o), hex(x), hex(y))
                                         for o, x, y in cal] if cal else ""))

    # mask test: AND and OR of each card's SS0 samples vs calibration dwords
    print("\n== SS0/SS1 mask test")
    for card, ss_key, ss1_key in (("41", "SS0_41", "SS1_41"),
                                  ("c1", "SS0_c1", "SS1_c1")):
        for key in (ss_key, ss1_key):
            samples = LIVE[key]
            andv = samples[0]
            orv = samples[0]
            for s in samples[1:]:
                andv &= s
                orv |= s
            matches = [(off, va, vb) for off, va, vb in diffs
                       if va in (andv, orv) or vb in (andv, orv)]
            print("  %s %s: AND=%08x OR=%08x calibration hits=%s" %
                  (card, key, andv, orv,
                   [(hex(o), hex(x), hex(y)) for o, x, y in matches]
                   if matches else "none"))

    print("\n== tail tables")
    for t in TAIL_TABLES + [FAR_ANCHOR & ~0xFF]:
        print("  around %#x:" % t)
        for i in range(-4, 12):
            off = t + 4 * i
            if 0 <= off < len(a) - 4:
                print("    %08x: %08x" % (off,
                      struct.unpack_from("<I", a, off)[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
