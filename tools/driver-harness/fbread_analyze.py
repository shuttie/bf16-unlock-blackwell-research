#!/usr/bin/env python3
"""Mine the E75 non-WPR heap dump (read-only).

Input: a directory with fb_heap_gpuN_<pa>.bin (and the small window dumps).
Output: a text report on stdout/--out.

The non-WPR heap is unprotected GSP-RM memory.  The GSP-RM address model is
runtime VA = link VA + 0x92000000, and file offset = link VA - 0x00E71000, so a
runtime code pointer P lives at file offset P - 0x93071000 in gsp_fwimage.bin.
"""
import glob
import os
import re
import struct
import sys

CODE_LO, CODE_HI = 0x93000000, 0x95000000
DATA_LO, DATA_HI = 0x95000000, 0x99000000
STACK_LO, STACK_HI = 0xA0000000, 0xB0000000
FILE_BIAS = 0x93071000  # runtime VA -> file offset in gsp_fwimage.bin

MAGICS = {
    0x00003818: "FEAT readout offset 0x3818",
    0x00823800: "FEAT bank base",
    0x0082381C: "SS0 address",
    0x00823820: "SS1 address",
    0xFFFFFB8F: "post-lock FEAT_OVR_PLM",
    0x80842BCF: "reset FEAT_OVR_PLM",
    0x00000004: "value 4 (fmla32=?)",
    0x00000005: "value 5 (SM issue-rate modifier?)",
}

# Known GSP-RM functions from E58, as runtime VAs (ghidra file addr - 0x18F000
# + 0x92000000).  Finding one in the heap shows which live object references
# it -- e.g. the FEAT write method should sit at obj+0x938.
TARGETS = {
    0x934801BC: "FUN_ram_0160f1bc (FEAT write method, obj+0x938)",
    0x93A90378: "FUN_ram_01c1f378 (registration/initializer)",
    0x93AD1868: "FUN_ram_01c60868 (writes 0x381c/0x3820)",
    0x93470AE8: "FUN_ram_015ffae8 (GB202 getter, 0x3818)",
    0x93470BD0: "FUN_ram_015ffbd0 (twin bit-6 reader)",
    0x93486A40: "FUN_ram_01615a40 (DP selector reader)",
    0x93FDE680: "FUN_ram_0216d680 (registry consumer 1)",
    0x93FF0718: "FUN_ram_0217f718 (registry consumer 2)",
}

STRINGS = [b"SpeedSelect", b"speed_select", b"RMOverride", b"fmla", b"FMLA",
           b"BF16", b"FP32", b"issue_rate", b"IssueRate", b"0x3818"]


def entropy(b):
    import math
    c = [0] * 256
    for x in b:
        c[x] += 1
    n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c if v)


def ascii_strings(b, minlen=6):
    return [(m.start(), m.group().decode("ascii"))
            for m in re.finditer(rb"[ -~]{%d,}" % minlen, b)]


def utf16_strings(b, minlen=6):
    out = []
    for m in re.finditer(rb"(?:[ -~]\x00){%d,}" % minlen, b):
        out.append((m.start(), m.group().decode("utf-16le", "replace")))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    d = sys.argv[1]
    outpath = sys.argv[2] if len(sys.argv) > 2 else None
    lines = []

    def say(s=""):
        lines.append(s)

    for p in sorted(glob.glob(os.path.join(d, "fb_heap_gpu*_*.bin"))):
        b = open(p, "rb").read()
        say("=" * 78)
        say("%s  size=0x%x nz=%d ent=%.4f" % (
            os.path.basename(p), len(b), len(b) - b.count(0), entropy(b)))
        n = len(b) // 4
        dw = struct.unpack("<%dI" % n, b)

        # Pointer census
        code = {}
        data = 0
        stack = 0
        for i, v in enumerate(dw):
            if CODE_LO <= v < CODE_HI:
                code[v] = code.get(v, 0) + 1
            elif DATA_LO <= v < DATA_HI:
                data += 1
            elif STACK_LO <= v < STACK_HI:
                stack += 1
        say("pointers: code=%d distinct=%d data=%d heap/stack=%d" % (
            sum(code.values()), len(code), data, stack))
        top = sorted(code.items(), key=lambda kv: -kv[1])[:12]
        for v, c in top:
            say("   code 0x%08x x%-4d file=0x%x" % (v, c, v - FILE_BIAS))

        # Strings
        ss = ascii_strings(b)
        su = utf16_strings(b)
        say("ascii strings: %d, utf16 strings: %d" % (len(ss), len(su)))
        for off, s in ss[:60]:
            say("   +0x%06x %r" % (off, s[:100]))
        for off, s in su[:20]:
            say("   +0x%06x u16 %r" % (off, s[:80]))

        # Target strings
        for pat in STRINGS:
            for off, s in ss:
                if pat.decode("ascii").lower() in s.lower():
                    say("HIT %r at +0x%x (ascii): %r" % (pat, off, s[:120]))
            for off, s in su:
                if pat.decode("ascii").lower() in s.lower():
                    say("HIT %r at +0x%x (utf16): %r" % (pat, off, s[:120]))

        # Known handler references: live objects and their vtables.
        for i, v in enumerate(dw):
            if v in TARGETS:
                lo = max(0, i - 8)
                hi = min(n, i + 9)
                ctx = " ".join("%08x" % x for x in dw[lo:hi])
                say("TARGET %s at +0x%x (obj+0x938 -> obj=0x%x)" % (
                    TARGETS[v], i * 4, max(0, i * 4 - 0x938)))
                say("   ctx: %s" % ctx)

        # Magic constants
        for i, v in enumerate(dw):
            if v in MAGICS and v not in (0x00000004, 0x00000005):
                lo = max(0, i - 6)
                hi = min(n, i + 7)
                ctx = " ".join("%08x" % x for x in dw[lo:hi])
                say("MAGIC %s at +0x%x: %s" % (MAGICS[v], i * 4, ctx))

        # Value census for small ints of interest
        for val in (4, 5, 6, 0x3818, 0x381C, 0x3820):
            c = dw.count(val)
            if c:
                say("value 0x%x: %d occurrences" % (val, c))

    text = "\n".join(lines)
    if outpath:
        open(outpath, "w").write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
