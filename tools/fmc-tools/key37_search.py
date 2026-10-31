#!/usr/bin/env python3
"""Search for NVIDIA's test AES key (index 37) as a permutation of the MD5 IV.

Known-answer test from the GA100 work:
    AES-128-ECB(key37, 0x00*16) == 717d1494eaca317ff106195258b38377
"""
import itertools, struct
from Crypto.Cipher import AES

KAT = bytes.fromhex('717d1494eaca317ff106195258b38377')
ZERO = bytes(16)
MD5_LE = bytes.fromhex('0123456789abcdeffedcba9876543210')   # IV as stored (little-endian words)
MD5_BE = bytes.fromhex('67452301efcdab8998badcfe10325476')   # canonical hex order

def check(key, label):
    if len(key) == 16:
        c = AES.new(key, AES.MODE_ECB).encrypt(ZERO)
    elif len(key) == 24:
        c = AES.new(key, AES.MODE_ECB).encrypt(ZERO)
    elif len(key) == 32:
        c = AES.new(key, AES.MODE_ECB).encrypt(ZERO)
    else:
        return None
    if c == KAT:
        return label, key
    return None

def candidates():
    bases = [('md5le', MD5_LE), ('md5be', MD5_BE)]
    for bn, base in bases:
        words = [base[i:i+4] for i in range(0, 16, 4)]
        # word permutations x per-word byte reversal x global reversal
        for perm in itertools.permutations(range(4)):
            for revmask in range(16):
                ws = []
                for j, idx in enumerate(perm):
                    w = words[idx]
                    ws.append(w[::-1] if (revmask >> j) & 1 else w)
                body = b''.join(ws)
                for glob in (False, True):
                    k = body[::-1] if glob else body
                    yield (f'{bn} wordperm={perm} revmask={revmask:#x} rev={glob}', k)
        # cyclic rotations
        for r in range(16):
            yield (f'{bn} rot={r}', base[r:]+base[:r])
        # nibble swap variants
        nib = bytes(((b & 0x0f) << 4) | (b >> 4) for b in base)
        yield (f'{bn} nibbleswap', nib)
        yield (f'{bn} nibbleswap+rev', nib[::-1])
    # ascii forms
    yield ('ascii hex le 256', b'0123456789abcdeffedcba9876543210')
    yield ('ascii hex be 256', b'67452301efcdab8998badcfe10325476')
    yield ('ascii 16', b'0123456789ABCDEF')
    yield ('ascii 16 lower', b'0123456789abcdef')
    # key-index flavoured
    for idx in (0x25, 37):
        for pos in range(16):
            k = bytearray(MD5_LE); k[pos] = idx
            yield (f'md5le byte{pos}=0x{idx:02x}', bytes(k))
        yield (f'md5le xor 0x{idx:02x}', bytes(b ^ idx for b in MD5_LE))
        yield (f'md5le +0x{idx:02x}', bytes((b + idx) & 0xff for b in MD5_LE))

if __name__ == '__main__':
    n = 0
    for label, key in candidates():
        n += 1
        r = check(key, label)
        if r:
            print('FOUND', r[0], r[1].hex())
            break
    else:
        print(f'no match among {n} candidates')
