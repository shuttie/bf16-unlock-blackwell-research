#!/usr/bin/env python3
"""Wider search for NVIDIA test key 37 given the KAT AES-ECB(k,0)=717d1494eaca317ff106195258b38377."""
import itertools
from Crypto.Cipher import AES

KAT = bytes.fromhex('717d1494eaca317ff106195258b38377')
ZERO = bytes(16)
MD5_LE = bytes.fromhex('0123456789abcdeffedcba9876543210')
MD5_BE = bytes.fromhex('67452301efcdab8998badcfe10325476')

SBOX = None
def key_expansion(key):
    """AES-128 key expansion, returns 44 words as list of 4-byte tuples."""
    RCON = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]
    sbox = AES_SBOX
    w = [list(key[i*4:i*4+4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i-1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [sbox[b] for b in t]
            t[0] ^= RCON[i//4 - 1]
        w.append([w[i-4][j] ^ t[j] for j in range(4)])
    return w

# generate the AES S-box
def gen_sbox():
    p = q = 1
    sbox = [0]*256
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xFF
        if q & 0x80: q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1: break
    sbox[0] = 0x63
    return sbox
AES_SBOX = gen_sbox()

def test(k, label):
    if len(k) != 16: return None
    if AES.new(k, AES.MODE_ECB).encrypt(ZERO) == KAT:
        return label, k
    return None

SHIFTROWS = [0,5,10,15,4,9,14,3,8,13,2,7,12,1,6,11]
INVSHIFTROWS = [0,13,10,7,4,1,14,11,8,5,2,15,12,9,6,3]

def candidates():
    for bn, base in (('le', MD5_LE), ('be', MD5_BE)):
        # key schedule words
        sch = key_expansion(base)
        for i in range(11):
            blk = b''.join(bytes(w) for w in sch[i*4:i*4+4])
            yield f'{bn} schedule rk{i}', blk
            yield f'{bn} schedule rk{i} wordrev', b''.join(bytes(w) for w in sch[i*4:i*4+4][::-1])
            yield f'{bn} schedule rk{i} byterev', blk[::-1]
        # known permutations
        yield f'{bn} shiftrows', bytes(base[i] for i in SHIFTROWS)
        yield f'{bn} invshiftrows', bytes(base[i] for i in INVSHIFTROWS)
        # global nibble-string transformations
        hx = ''.join(f'{b:02x}' for b in base)
        for r in range(32):
            s = hx[r:]+hx[:r]
            yield f'{bn} hexrot{r}', bytes.fromhex(s)
        yield f'{bn} hexrev', bytes.fromhex(hx[::-1])
        yield f'{bn} nibblerev', bytes(int(hx[::-1][i:i+2],16) for i in range(0,32,2))
        # sorted / interleaved
        yield f'{bn} sorted', bytes(sorted(base))
        yield f'{bn} interleave', base[0::2]+base[1::2]
        yield f'{bn} deinterleave', base[::2]+base[1::2]
        # xor / add constants
        for c in range(256):
            yield f'{bn} xor{c:02x}', bytes(b ^ c for b in base)
            yield f'{bn} add{c:02x}', bytes((b + c) & 0xFF for b in base)
        # all per-byte nibble-swap masks
        for mask in range(1 << 16):
            k = bytes((((b & 0xF) << 4) | (b >> 4)) if (mask >> i) & 1 else b
                      for i, b in enumerate(base))
            yield f'{bn} nibmask{mask:04x}', k

if __name__ == '__main__':
    n = 0
    for label, k in candidates():
        n += 1
        r = test(k, label)
        if r:
            print('FOUND:', r[0], r[1].hex()); break
    else:
        print(f'no match among {n} candidates')
