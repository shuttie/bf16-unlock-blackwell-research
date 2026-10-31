#!/usr/bin/env python3
"""Second pass: zero map, entropy, headers, per-card structure."""
import sys, math, struct, collections

CH = 1 << 20

def load(p):
    with open(p, 'rb') as f:
        return f.read()

def ent(b):
    if not b:
        return 0.0
    c = collections.Counter(b)
    n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c.values())

def main():
    p0, p1 = sys.argv[1], sys.argv[2]
    b0, b1 = load(p0), load(p1)
    nch = len(b0) // CH
    z0 = [not any(b0[i:i+CH]) for i in range(0, len(b0), CH)]
    z1 = [not any(b1[i:i+CH]) for i in range(0, len(b1), CH)]
    print("chunks", nch, "zero0", sum(z0), "zero1", sum(z1),
          "same_zero_mask", z0 == z1)
    # contiguous nonzero spans
    spans, start = [], None
    for i, z in enumerate(z0):
        if not z and start is None:
            start = i
        if z and start is not None:
            spans.append((start, i)); start = None
    if start is not None:
        spans.append((start, nch))
    print("nonzero spans (MiB):", spans[:12], "..." if len(spans) > 12 else "")
    # entropy per chunk for the first few nonzero chunks
    ent_vals = []
    for i in range(nch):
        if not z0[i]:
            ent_vals.append((i, ent(b0[i*CH:(i+1)*CH]), b0[i*CH:(i+1)*CH][:16].hex()))
            if len(ent_vals) >= 8:
                break
    print("entropy samples (chunk, bits/byte, first16):")
    for e in ent_vals:
        print("  ", e)
    # full entropy of the first nonzero chunk and of a later one
    nz = [i for i in range(nch) if not z0[i]]
    if nz:
        for i in (nz[0], nz[len(nz)//2], nz[-1]):
            print(f"chunk {i} entropy {ent(b0[i*CH:(i+1)*CH]):.4f}")
    # compression/encryption headers at the first nonzero byte
    first = next((i for i in range(len(b0)) if b0[i]), None)
    print("first nonzero byte at", hex(first) if first is not None else None)
    if first is not None:
        print("bytes there:", b0[first:first+32].hex())
    magics = {
        'zstd': bytes.fromhex('28b52ffd'), 'gzip': bytes.fromhex('1f8b'),
        'lz4': bytes.fromhex('04224d18'), 'xz': bytes.fromhex('fd377a585a00'),
    }
    for k, m in magics.items():
        print(k, "first=", b0.find(m))
    # context of the single 0x00888888 hit
    pat = struct.pack('<I', 0x00888888)
    j = b0.find(pat)
    print("0x00888888 at", hex(j) if j >= 0 else None)
    if j >= 0:
        s = max(0, j - 64)
        print("  ctx:", b0[s:j+64].hex())
    # per-card byte-level agreement inside nonzero chunks
    eq = 0
    for i in range(nch):
        if not z0[i]:
            a, b = b0[i*CH:(i+1)*CH], b1[i*CH:(i+1)*CH]
            eq += sum(1 for x, y in zip(a, b) if x == y)
    print("equal bytes inside card0-nonzero chunks:", eq)

if __name__ == '__main__':
    main()
