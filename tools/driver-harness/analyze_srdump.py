#!/usr/bin/env python3
"""Analyze BF16 SR suspend-image dumps (read-only)."""
import sys, hashlib, struct, re

def load(p):
    with open(p, 'rb') as f:
        return f.read()

def zero_frac(b, chunk=1 << 20):
    z = sum(1 for i in range(0, len(b), chunk) if not any(b[i:i+chunk]))
    return z, len(b) // chunk

def find_u64(b, v, limit=8):
    pat = struct.pack('<Q', v)
    out, i = [], 0
    while len(out) < limit:
        j = b.find(pat, i)
        if j < 0:
            break
        out.append(j)
        i = j + 1
    return out

def find_u32(b, v, limit=8):
    pat = struct.pack('<I', v)
    out, i = [], 0
    while len(out) < limit:
        j = b.find(pat, i)
        if j < 0:
            break
        out.append(j)
        i = j + 1
    return out

def strings(b, minlen=6, limit=25):
    return [m.group().decode('latin1') for m in re.finditer(rb'[\x20-\x7e]{%d,}' % minlen, b)][:limit]

def main():
    p0, p1 = sys.argv[1], sys.argv[2]
    b0, b1 = load(p0), load(p1)
    print(f"size0={len(b0)} size1={len(b1)}")
    print("sha0", hashlib.sha256(b0).hexdigest()[:32])
    print("sha1", hashlib.sha256(b1).hexdigest()[:32])
    z, n = zero_frac(b0)
    print(f"zero 1MiB chunks: {z}/{n}")
    # magic searches
    magics = {
        'WprMeta 0xdc3aae21371a60b3': 0xdc3aae21371a60b3,
        'SRMeta 0x8a3bb9e6c6c39d93': 0x8a3bb9e6c6c39d93,
        'ELF \\x7fELF': None,
    }
    for k, v in magics.items():
        if v is None:
            j = b0.find(b'\x7fELF')
            print(f"{k}: first={j if j>=0 else None}")
        else:
            print(f"{k}: {find_u64(b0, v)}")
    # interesting 32-bit values
    vals = {
        'FEAT_READOUT_1 0x00c36180': 0x00c36180,
        'SS0-A 0x54226037': 0x54226037,
        'SS0-B 0x21240001': 0x21240001,
        '0x00888888': 0x00888888,
        'COT hash w0 0xee0988fe': 0xee0988fe,
        'magic lo 0xc6c39d93': 0xc6c39d93,
        'magic hi 0x8a3bb9e6': 0x8a3bb9e6,
    }
    for k, v in vals.items():
        print(f"{k}: {find_u32(b0, v)}")
    # per-chunk diff between the two cards
    chunk = 1 << 20
    diffchunks = 0
    for i in range(0, len(b0), chunk):
        if b0[i:i+chunk] != b1[i:i+chunk]:
            diffchunks += 1
    print(f"chunks differing between cards: {diffchunks}/{len(b0)//chunk}")
    # first 512 bytes and a few strings
    print("first 256 bytes:", b0[:256].hex())
    print("strings[:15]:", strings(b0))
    # sample bytes at a few offsets
    for off in (0, 0x1000, 0x69000, 0x100000, 0x1000000, 0x4000000, 0x8000000, 0xc000000):
        if off < len(b0):
            print(f"@{off:#x}: {b0[off:off+32].hex()}")

if __name__ == '__main__':
    main()
