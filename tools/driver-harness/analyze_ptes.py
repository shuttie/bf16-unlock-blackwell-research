#!/usr/bin/env python3
"""Parse the plaintext radix3 head and compare state ciphertext across boots."""
import sys, struct, collections

DATA_OFF = 0x69000
PAGE = 0x1000
ENTRIES = 512

def load(p):
    with open(p, 'rb') as f:
        return f.read()

def head_report(tag, b):
    head = b[:DATA_OFF]
    root = struct.unpack_from('<%dQ' % ENTRIES, head, 0)
    l1 = struct.unpack_from('<%dQ' % ENTRIES, head, PAGE)
    nz_root = [(i, v) for i, v in enumerate(root) if v]
    nz_l1 = [(i, v) for i, v in enumerate(l1) if v]
    l2 = []
    for page in range(2, DATA_OFF // PAGE):
        l2.extend(struct.unpack_from('<%dQ' % ENTRIES, head, page * PAGE))
    nz = [v for v in l2 if v]
    print(f"[{tag}] root nonzero={[(i,hex(v)) for i,v in nz_root][:4]} n={len(nz_root)}")
    print(f"[{tag}] l1   nonzero={[(i,hex(v)) for i,v in nz_l1][:4]} n={len(nz_l1)}")
    print(f"[{tag}] l2 entries={len(l2)} nonzero={len(nz)}")
    if nz:
        print(f"[{tag}] first={[hex(v) for v in nz[:6]]}")
        print(f"[{tag}] last ={[hex(v) for v in nz[-4:]]}")
        al = sum(1 for v in nz if v % PAGE == 0)
        print(f"[{tag}] 4k-aligned={al}/{len(nz)} min={hex(min(nz))} max={hex(max(nz))}")
        d = collections.Counter(nz[i+1] - nz[i] for i in range(len(nz) - 1))
        print(f"[{tag}] delta top={[(hex(k), c) for k, c in d.most_common(4)]}")
    return [v for v in nz]

def main():
    a, b = sys.argv[1], sys.argv[2]
    ba, bb = load(a), load(b)
    pa = head_report("card0", ba)
    pb = head_report("card1", bb)
    print("PTE lists identical:", pa == pb)
    # cross-boot ciphertext: compare against optional third file (previous run)
    if len(sys.argv) > 3:
        old = load(sys.argv[3])
        da, do = ba[DATA_OFF:], old[DATA_OFF:]
        n = min(len(da), len(do))
        eq = sum(1 for i in range(0, n, 4096) if da[i:i+4096] == do[i:i+4096])
        print(f"cross-boot: equal 4K pages {eq}/{n//4096}")
    # same-run card compare over the whole file
    eqb = sum(1 for i in range(0, len(ba), 4096) if ba[i:i+4096] == bb[i:i+4096])
    print(f"within-run equal 4K pages: {eqb}/{len(ba)//4096}")

if __name__ == '__main__':
    main()
