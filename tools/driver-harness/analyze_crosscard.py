#!/usr/bin/env python3
"""Cross-card and run-to-run differential analysis of BF16 context dumps.

Reads binary context images and reports word-aligned differences, classified by
shape (address-like, poison/fill, selector-shaped, other). Read-only.
"""
import struct
import sys
from collections import Counter

POISON = 0xADDEADDE
FILLS = {0xADDEADDE, 0x88888888, 0xDEAD5ED0, 0xDEADBEEF}

def load(path):
    with open(path, 'rb') as f:
        return f.read()

def words(b):
    n = len(b) // 4
    return struct.unpack_from('<%dI' % n, b, 0)

def is_addr_like(v):
    # Observed physical/virtual address ranges in these dumps.
    return (0x100000000 <= v < 0x900000000) or (0x7d000000 <= v < 0x80000000) \
        or (0x140000000 <= v < 0x144000000) or (0x0c000000 <= v < 0x80000000 and (v & 0xfff) == 0)

def sel_fields(v):
    return [(v >> s) & 7 for s in (0, 3, 6, 9, 12, 15, 18, 21, 24, 28)]

def diff_words(a, b):
    wa, wb = words(a), words(b)
    same_len = len(wa) == len(wb)
    n = min(len(wa), len(wb))
    d = [(i * 4, wa[i], wb[i]) for i in range(n) if wa[i] != wb[i]]
    return same_len, d, len(wa)

def classify(va, vb):
    if va == POISON or vb == POISON:
        return 'poison'
    if va == 0 or vb == 0:
        return 'zero-vs-nonzero'
    if is_addr_like(va) or is_addr_like(vb):
        return 'address-like'
    sa, sb = sel_fields(va), sel_fields(vb)
    ndiff = sum(1 for x, y in zip(sa, sb) if x != y)
    if ndiff == 1 and max(max(sa), max(sb)) <= 7:
        return 'selector-1field'
    if ndiff >= 2:
        return 'selector-multifield'
    return 'other'

def report(name_a, name_b, a, b):
    same_len, d, nwords = diff_words(a, b)
    print(f'\n### {name_a}  vs  {name_b}')
    print(f'len_a={len(a)} len_b={len(b)} same_len={same_len} words={nwords} diff_words={len(d)}')
    if not same_len:
        print('  *** length mismatch ***')
    cls = Counter(classify(va, vb) for _, va, vb in d)
    print('  classes:', dict(cls))
    # Runs of consecutive differing words.
    runs = []
    for off, va, vb in d:
        if runs and off == runs[-1][1] + 4:
            runs[-1][1] = off
            runs[-1][2] += 1
        else:
            runs.append([off, off, 1])
    print(f'  diff runs={len(runs)}; first 40 runs (start-end, words):')
    for s, e, c in runs[:40]:
        print(f'    0x{s:06x}-0x{e:06x}  {c}')
    sel = [(o, va, vb) for o, va, vb in d if classify(va, vb).startswith('selector')]
    print(f'  selector-shaped diffs={len(sel)}; first 40:')
    for o, va, vb in sel[:40]:
        print(f'    0x{o:06x}  {va:#010x} -> {vb:#010x}   '
              f'{sel_fields(va)} -> {sel_fields(vb)}')
    other = [(o, va, vb) for o, va, vb in d if classify(va, vb) == 'other']
    print(f'  other diffs={len(other)}; first 40:')
    for o, va, vb in other[:40]:
        print(f'    0x{o:06x}  {va:#010x} -> {vb:#010x}')
    return d

def main():
    d = {}
    for arg in sys.argv[1:]:
        tag, path = arg.split('=', 1)
        d[tag] = load(path)
    keys = list(d)
    if len(keys) == 2:
        report(keys[0], keys[1], d[keys[0]], d[keys[1]])
        return
    # All pairs.
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            report(keys[i], keys[j], d[keys[i]], d[keys[j]])

if __name__ == '__main__':
    main()
