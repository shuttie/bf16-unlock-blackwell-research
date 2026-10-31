#!/usr/bin/env python3
"""Try to find NVIDIA's test AES key.

Two oracles:
  1. KAT: AES-ECB(k, 0x00*16) == 717d1494eaca317ff106195258b38377
  2. Entropy: decrypting a real debug blob with the right key drops H from ~8.0 to ~6.
"""
import argparse, collections, itertools, math, os
from Crypto.Cipher import AES

KAT = bytes.fromhex('717d1494eaca317ff106195258b38377')
MD5_LE = bytes.fromhex('0123456789abcdeffedcba9876543210')
MD5_BE = bytes.fromhex('67452301efcdab8998badcfe10325476')

def H(b):
    c = collections.Counter(b); n = len(b)
    return -sum(v/n*math.log2(v/n) for v in c.values()) if n else 0

def families():
    yield 'zero', bytes(16)
    yield 'fips197', bytes.fromhex('000102030405060708090a0b0c0d0e0f')
    yield 'md5repeated', bytes.fromhex('0123456789abcdef'*2)
    yield 'md5repeated_rev', bytes.fromhex('fedcba9876543210'*2)
    for bn, base in (('le', MD5_LE), ('be', MD5_BE)):
        # per-word byte permutations x word permutations
        words = [base[i:i+4] for i in range(0, 16, 4)]
        perms = list(itertools.permutations(range(4)))
        for wperm in perms:
            for bperms in itertools.product(perms, repeat=4):
                k = b''.join(bytes(words[wperm[j]][i] for i in bperms[j]) for j in range(4))
                yield f'{bn} wp{wperm} bp{bperms}', k
        for c in (0x37, 0x25):
            yield f'{bn} xor{c:02x}', bytes(b ^ c for b in base)
            yield f'{bn} add{c:02x}', bytes((b + c) & 0xFF for b in base)
        yield f'{bn} rot8', base[8:]+base[:8]
        yield f'{bn} swapnibbles', bytes((b >> 4) | ((b & 0xF) << 4) for b in base)

def main(argv=None):
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--container", default=os.environ.get(
        "FMC_CONTAINER", os.path.join(here, "containers", "c09_00691480_046200.bin")))
    a = ap.parse_args(argv)
    img = open(a.container, "rb").read()[0x48:0x48+0x1000]
    best = []
    n = 0
    for label, k in families():
        if len(k) != 16:
            continue
        n += 1
        c = AES.new(k, AES.MODE_ECB)
        if c.encrypt(bytes(16)) == KAT:
            print('KAT MATCH:', label, k.hex()); return
        h = H(c.decrypt(img))
        best.append((h, label, k.hex()))
        if n % 500000 == 0:
            print(f'  {n} candidates, best H so far {min(best)[0]:.3f}')
    best.sort()
    print(f'tested {n} candidates; best decryption entropies:')
    for h, label, k in best[:5]:
        print(f'  H={h:.3f} {label} {k}')

if __name__ == '__main__':
    main()
