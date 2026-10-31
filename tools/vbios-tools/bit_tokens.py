#!/usr/bin/env python3
"""Decode the vBIOS BIT token table and classify each token's data.

The driver decodes only BIT tokens 0x42 (BIOSDATA) and 0x70 (FALCON_DATA).
Everything else in the BIT is plaintext but undecoded; this tool dumps and
classifies those tokens and can diff two dumps (two cards or two flash regions).

Usage:
  bit_tokens.py <dump> [other_dump]

Read-only: pure file analysis.
"""
import sys, struct, math, collections

BIT_SIG = b"BIT\x00"
TOKEN_KNOWN = {
    0x42: "BIOSDATA (driver-decoded)",
    0x70: "FALCON_DATA (driver-decoded)",
}
FEATISH = {
    "PLM 0x823804": 0x823804, "READOUT 0x823818": 0x823818,
    "SS0 0x82381c": 0x82381c, "SS1 0x823820": 0x823820,
    "0x82380c": 0x82380c, "FMLA32 0x8207d8": 0x8207d8,
    "MOD 0x504204": 0x504204,
}

def entropy(b):
    if not b:
        return 0.0
    c = collections.Counter(b)
    n = len(b)
    return -sum(v / n * math.log2(v / n) for v in c.values())

def ascii_of(b):
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b)

def find_bits(d):
    out = []
    for a in range(len(d) - 12):
        if d[a:a+2] == b"\xff\xb8" and d[a+2:a+6] == BIT_SIG:
            hsize = d[a + 8]
            if 8 <= hsize <= 64 and sum(d[a:a+hsize]) & 0xFF == 0:
                out.append(a)
    return out

def image_base(d, bitbase):
    """Nearest preceding 0x55AA with a valid PCIR: the vBIOS image start."""
    a = bitbase
    while a > 0:
        a = d.rfind(b"\x55\xaa", 0, a)
        if a < 0:
            break
        if a + 0x1a > len(d):
            continue
        p = a + struct.unpack_from("<H", d, a + 0x18)[0]
        if d[p:p+4] == b"PCIR":
            return a
    return 0

def parse_bit(d, base, name):
    imgbase = image_base(d, base)
    print(f"  (vBIOS image base 0x{imgbase:x}; BIT is image+0x{base-imgbase:x})")
    hsize, tsize, count = d[base+8], d[base+9], d[base+10]
    print(f"\n== BIT @ {name}+0x{base:x}: hdr={hsize} tokSize={tsize} tokens={count}")
    toks = []
    for i in range(count):
        o = base + hsize + i * tsize
        if o + 6 > len(d):
            break
        tid, ver = d[o], d[o+1]
        if tsize >= 8:
            size, ptr = struct.unpack_from("<HH", d, o+2)
        else:
            size, ptr = struct.unpack_from("<HH", d, o+2)
        toks.append((tid, ver, size, ptr))
    for tid, ver, size, ptr in toks:
        doff = imgbase + ptr
        data = d[doff:doff+size] if (size and ptr and doff + size <= len(d)) else b""
        kind = classify(d, data)
        note = TOKEN_KNOWN.get(tid, "")
        print(f"  tok 0x{tid:02x} v{ver} size=0x{size:03x} ptr=0x{ptr:06x}"
              f"  {kind}" + (f"  [{note}]" if note else ""))
        if data:
            hexs = data[:96].hex()
            text = ascii_of(data[:96])
            print(f"      hex {hexs}")
            print(f"      asc {text}")
            for p in pointer_targets(d, data, imgbase)[:6]:
                print(f"      -> img+0x{p-imgbase:06x} (file 0x{p:06x}): {d[p:p+32].hex()}")
    return toks

def pointer_targets(d, data, imgbase=0):
    """Values in a token's data that look like offsets into the image."""
    vals = []
    n = len(data) // 4
    for i in range(n):
        v = struct.unpack_from("<I", data, i*4)[0]
        t = imgbase + v
        if 0x100 <= v < 0x200000 and t + 32 <= len(d):
            vals.append(t)
    return vals

def classify(d, data):
    if not data:
        return "empty"
    printable = sum(1 for c in data[:64] if 32 <= c < 127 or c == 0)
    if printable >= 0.9 * min(len(data), 64) and len(data) >= 4:
        txt = ascii_of(data[:48]).strip(".")
        if txt:
            return f"text: {txt!r}"
    ptrs = pointer_targets(d, data)
    if len(ptrs) >= max(2, len(data) // 16):
        return f"pointer-table ({len(ptrs)} candidate offsets)"
    # small-int table
    return "table"

def scan_feat(d, label):
    print(f"\n== FEAT/register constants in {label}")
    for name, v in FEATISH.items():
        for endian, tag in (("<", "LE"), (">", "BE")):
            pat = struct.pack(endian + "I", v)
            hits = []
            i = 0
            while len(hits) < 4:
                j = d.find(pat, i)
                if j < 0:
                    break
                hits.append(hex(j))
                i = j + 1
            if hits:
                print(f"  {name} {tag}: {hits}")

def main():
    p = sys.argv[1]
    d = open(p, "rb").read()
    pad = b"\xff" * 4096
    ffpages = sum(1 for i in range(0, len(d), 4096) if d[i:i+4096] == pad)
    print(f"== {p}: {len(d)} bytes, entropy={entropy(d):.3f}, 0xFF pages={ffpages}")
    bits = find_bits(d)
    if not bits:
        print("  no BIT header found")
    for b in bits:
        parse_bit(d, b, p.split('/')[-1])
    scan_feat(d, p)

    if len(sys.argv) > 2:
        q = sys.argv[2]
        e = open(q, "rb").read()
        print(f"\n== compare {p} vs {q}")
        n = min(len(d), len(e))
        diff = [(i, d[i], e[i]) for i in range(n) if d[i] != e[i]]
        print(f"  differing bytes: {len(diff)} of {n}")
        if diff:
            runs = []
            start = prev = diff[0][0]
            for i, _, _ in diff[1:]:
                if i != prev + 1:
                    runs.append((start, prev))
                    start = i
                prev = i
            runs.append((start, prev))
            print(f"  diff runs: {len(runs)}; first 12: "
                  + ", ".join(f"0x{a:x}-0x{b:x}" for a, b in runs[:12]))
            for r in runs[:6]:
                a = r[0]
                print(f"    0x{a:x}: {d[a:a+24].hex()}  vs  {e[a:a+24].hex()}")

if __name__ == "__main__":
    main()
