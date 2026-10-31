#!/usr/bin/env python3
"""devinit_scan.py - static scan of an NVIDIA vBIOS image for devinit tables,
register-address lists and FEAT/FUSE references.

Read-only file analysis; no GPU access.

Layout:
  - devinit opcode encoding and address flags
  - BIT header and 6-byte tokens
  - vBIOS image chain, FwSec, and PMU lookup table
  - Falcon ucode table header and descriptor structures
  - adjust = first FwSec - PciAt size

Usage:
  python3 -I devinit_scan.py <vbiOS image> [<other image>]

The second image is only used for a byte diff summary.  Scripts live in
scripts/; the images are passed as arguments and never executed.
"""
import math
import struct
import sys
from collections import Counter

BIT_ID = 0xB8FF
BIT_SIG = b"BIT\x00"
FALCON_DATA = 0x70
ADDR_MASK = 0x0FFFFFFF
ADDR_FLAGS = (0x00000000, 0x20000000, 0x40000000, 0x60000000,
              0x80000000, 0xA0000000, 0xC0000000, 0xE0000000)

FEAT = {
    "FEAT_OVR_ECC_PLM": 0x823800,
    "FEAT_OVR_PLM": 0x823804,
    "0x823808": 0x823808,
    "0x82380c": 0x82380C,
    "0x823810": 0x823810,
    "FEAT_READOUT_0": 0x823814,
    "FEAT_READOUT_1": 0x823818,
    "SS0": 0x82381C,
    "SS1": 0x823820,
    "0x823824": 0x823824,
}
FUSE_LO, FUSE_HI = 0x820000, 0x824000

ANCHORS = {
    "PLM_locked 0xfffffb8f": 0xFFFFFB8F,
    "PLM_reset  0x80842bcf": 0x80842BCF,
    "PLM_bit10  0xfffffbff": 0xFFFFFBFF,
    "Ada_FEAT   0xffffff8f": 0xFFFFFF8F,
    "Ada_FBPA   0xffffff0f": 0xFFFFFF0F,
    "T1         0x0884cb8f": 0x0884CB8F,
    "T2         0x0884cbcf": 0x0884CBCF,
    "T3         0x0085cb8f": 0x0085CB8F,
    "poison     0xbadf5040": 0xBADF5040,
    "sentinel   0xbadf1100": 0xBADF1100,
}

# devinit opcodes: value -> (name, fixed operand bytes, array?)
# Only the direct-address forms carry a 32-bit address at +1.  The stream /
# uncoupled forms also carry the address at +1; arrays carry startreg at +1.
OPCODES = {
    0x6E: ("INIT_NV_REG", 12),            # addr32 mask32 data32
    0x7A: ("INIT_ZM_REG", 8),             # addr32 data32
    0x48: ("INIT_SETBITS_NV_REG", 8),     # addr32 data32
    0x47: ("INIT_RESETBITS_NV_REG", 8),   # addr32 data32
    0x77: ("INIT_ZM_WREG", 6),            # addr32 data16
    0x10: ("INIT_NV_REG_STREAM", 8),      # addr32 mask32
    0x11: ("INIT_ZM_REG_STREAM", 4),      # addr32
    0x12: ("INIT_SETBITS_NV_REG_STREAM", 4),
    0x13: ("INIT_RESETBITS_NV_REG_STREAM", 4),
    0x20: ("INIT_NV_REG_UNCOUPLED", 9),   # addr32 mask32 offset8
    0x21: ("INIT_ZM_REG_UNCOUPLED", 5),   # addr32 offset8
    0x22: ("INIT_SETBITS_NV_REG_UNCOUPLED", 5),
    0x23: ("INIT_RESETBITS_NV_REG_UNCOUPLED", 5),
    0x2C: ("INIT_NV_REG_READ", 5),        # addr32 offset8
    0x58: ("INIT_REG_ARRAY", 5),          # startreg32 count8, then N data32
    0x91: ("INIT_ZM_REG_REITERATE", 5),   # addr32 count8, then N data32
    0x74: ("INIT_TIME", 2),
    0x57: ("INIT_TIME_MSEC", 2),
    0x55: ("INIT_POLL", 2),
    0x56: ("INIT_POLL_NV", 2),
    0x6B: ("INIT_SUB", 1),
    0x5B: ("INIT_SUB_DIRECT", 2),
    0x75: ("INIT_CONDITION", 1),
    0x72: ("INIT_RESUME", 0),
    0x33: ("INIT_REPEAT", 1),
    0x36: ("INIT_END_REPEAT", 0),
    0x6A: ("INIT_JUMP", 1),
    0x5C: ("INIT_JUMP_DIRECT", 2),
    0x89: ("INIT_JUMP_REL", 1),
    0x71: ("INIT_DONE", 0),
    0x5D: ("INIT_DONE_CONDITION", 0),
    0xFF: ("EOL", 0),
}


def entropy(b):
    if not b:
        return 0.0
    c = Counter(b)
    n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def printable(b, n=32):
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b[:n])


def find_bit(d):
    for a in range(len(d) - 12):
        if d[a:a + 2] == b"\xff\xb8" and d[a + 2:a + 6] == BIT_SIG:
            hsize = d[a + 8]
            if 8 <= hsize <= 64 and sum(d[a:a + hsize]) & 0xFF == 0:
                return a
    return None


def image_base(d, bit):
    """Nearest preceding 0x55AA with a PCIR pointer: the PciAt image start."""
    a = bit
    while a > 0:
        a = d.rfind(b"\x55\xaa", 0, a)
        if a < 0:
            return 0
        p = a + struct.unpack_from("<H", d, a + 0x18)[0]
        if p + 0x18 <= len(d) and d[p:p + 4] == b"PCIR":
            return a
    return 0


def walk_images(d, base):
    """Walk the expansion ROM chain from base.  Returns (images, adjust).

    The PCIR length and last-image bit can be overridden by the NPDE
    extension (rev 0x100/0x101), exactly as s_locateExpansionRoms does.
    """
    out = []
    off = base
    for _ in range(8):
        if off + 0x30 > len(d):
            break
        sig = struct.unpack_from("<H", d, off)[0]
        if sig not in (0xAA55, 0x4E56, 0xBB77):
            break
        if sig != 0xAA55:
            # VN/BB77 images are not PCIR images; stop with the size unknown.
            out.append({"pos": off, "size": 0, "type": 0xE0, "last": 1})
            break
        pci = struct.unpack_from("<H", d, off + 0x18)[0]
        p = off + pci
        if d[p:p + 4] != b"PCIR":
            break
        length = d[p + 0x10]
        if not length:
            break
        size = length * 512
        ctype = d[p + 0x14]
        last = d[p + 0x15] & 0x80
        npde = (p + struct.unpack_from("<H", d, p + 0x0A)[0] + 15) & ~15
        if npde + 10 <= len(d) and d[npde:npde + 4] == b"NPDE":
            ext_rev = struct.unpack_from("<H", d, npde + 4)[0]
            ext_len = struct.unpack_from("<H", d, npde + 6)[0]
            if ext_rev in (0x100, 0x101) and ext_len >= 10:
                sub = struct.unpack_from("<H", d, npde + 8)[0] * 512
                if ext_len > 10:
                    last = d[npde + 10] & 0x80
                elif sub < size:
                    last = 0
                if sub:
                    size = sub
        out.append({"pos": off, "size": size, "type": ctype, "last": last})
        if last:
            break
        off += size
    pciat = next((x for x in out if x["type"] == 0), None)
    fwsec = next((x for x in out if x["type"] == 0xE0), None)
    adjust = 0
    if pciat and fwsec:
        adjust = (fwsec["pos"] - base) - pciat["size"]
    return out, adjust


def parse_bit(d, bit):
    hsize, tsize, count = d[bit + 8], d[bit + 9], d[bit + 10]
    toks = []
    for i in range(count):
        o = bit + hsize + i * tsize
        if o + 6 > len(d):
            break
        tid, ver = d[o], d[o + 1]
        size, ptr = struct.unpack_from("<HH", d, o + 2)
        toks.append({"id": tid, "ver": ver, "size": size, "ptr": ptr, "off": o})
    return hsize, tsize, count, toks


def parse_ucode(d, table, adjust, base):
    if table + 6 > len(d):
        return None
    ver, hsize, esize, count, dver, dsize = struct.unpack_from("<6B", d, table)
    out = {"table": table, "ver": ver, "hsize": hsize, "esize": esize,
           "count": count, "dver": dver, "dsize": dsize, "entries": []}
    if ver != 1 or hsize < 6 or esize < 6:
        return out
    for i in range(count):
        o = table + hsize + i * esize
        if o + 6 > len(d):
            break
        app, target = d[o], d[o + 1]
        dp = struct.unpack_from("<I", d, o + 2)[0]
        if not any((app, target, dp)):
            continue
        desc = base + adjust + dp
        ent = {"i": i, "app": app, "target": target, "desc": desc}
        if desc + 80 <= len(d):
            hdr = struct.unpack_from("<I", d, desc)[0]
            stored = struct.unpack_from("<I", d, desc + 4)[0]
            vsize = hdr >> 16
            version = (hdr >> 8) & 0xFF
            encrypted = (hdr >> 2) & 1
            body = desc + vsize
            body_end = body + ((stored + 255) & ~255)
            ent.update({"hdr": hdr, "vsize": vsize, "version": version,
                        "encrypted": encrypted, "stored": stored,
                        "body": body, "body_end": body_end})
            valid = (1 <= version <= 8 and 44 <= vsize <= 0x1000 and
                     0 < stored < 0x100000 and body < len(d) and
                     body_end <= len(d) + 0xFF)
            ent["valid"] = valid
            if valid:
                im = d[body:min(body + 0x10000, len(d))]
                ent["ent_head"] = entropy(im)
            else:
                ent["body"] = None
                ent["body_end"] = None
        out["entries"].append(ent)
    return out


def scan_literals(d, name):
    hits = []
    for label, addr in FEAT.items():
        for flags in ADDR_FLAGS:
            v = addr | flags
            for endian in ("<", ">"):
                pat = struct.pack(endian + "I", v)
                i = 0
                while True:
                    j = d.find(pat, i)
                    if j < 0:
                        break
                    hits.append((j, label, v, "LE" if endian == "<" else "BE"))
                    i = j + 1
    return hits


def scan_opcodes(d):
    hits = []
    for i in range(len(d) - 13):
        op = OPCODES.get(d[i])
        if not op:
            continue
        label, n = op
        addr = struct.unpack_from("<I", d, i + 1)[0]
        if (addr & ADDR_MASK) < FUSE_LO or (addr & ADDR_MASK) >= FUSE_HI:
            continue
        if (addr & ADDR_MASK) < 0x823800 or (addr & ADDR_MASK) >= 0x823900:
            continue
        nbytes = n
        if label in ("INIT_REG_ARRAY", "INIT_ZM_REG_REITERATE"):
            count = d[i + 5]
            nbytes = 5 + 4 * count
        hits.append((i, label, addr, nbytes))
    return hits


def scan_lists(d):
    """Runs of register addresses (u32 or u64) in the FUSE/FEAT range.

    The tables are not necessarily aligned, so scan every byte and group
    hits that advance by the value width.
    """
    runs = []
    for width in (4, 8):
        fmt = "<Q" if width == 8 else "<I"
        cur = []
        for i in range(0, len(d) - width):
            v = struct.unpack_from(fmt, d, i)[0]
            if FUSE_LO <= v < FUSE_HI:
                if cur and i != cur[-1][0] + width:
                    if len(cur) >= 3:
                        runs.append((width, cur))
                    cur = []
                cur.append((i, v))
        if len(cur) >= 3:
            runs.append((width, cur))
    return runs


def scan_anchors(d):
    out = []
    for label, v in ANCHORS.items():
        pat = struct.pack("<I", v)
        offs = []
        i = 0
        while True:
            j = d.find(pat, i)
            if j < 0:
                break
            offs.append(j)
            i = j + 1
        out.append((label, v, offs))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    d = open(path, "rb").read()
    print("== %s: %d bytes (%#x), entropy=%.2f" %
          (path, len(d), len(d), entropy(d)))
    bit = find_bit(d)
    if bit is None:
        print("  no BIT header found")
        return 1
    base = image_base(d, bit)
    images, adjust = walk_images(d, base)
    print("  BIT @%#x  image base @%#x  adjust(EFI correction)=%#x" %
          (bit, base, adjust))
    for im in images:
        print("    image @%#x size=%#x type=%#x last=%d" %
              (im["pos"], im["size"], im["type"], bool(im["last"])))
    hsize, tsize, count, toks = parse_bit(d, bit)
    print("  BIT: header=%d stride=%d tokens=%d" % (hsize, tsize, count))
    ucode = None
    for t in toks:
        if t["id"] == FALCON_DATA and t["ver"] == 2:
            ptr = struct.unpack_from("<I", d, base + t["ptr"])[0]
            table = base + adjust + ptr
            print("  token 0x70 v2: data@%#x -> table ptr %#x -> %#x" %
                  (base + t["ptr"], ptr, table))
            ucode = parse_ucode(d, table, adjust, base)
    if ucode:
        print("  ucode table: ver=%d hsize=%d esize=%d entries=%d descVer=%d" %
              (ucode["ver"], ucode["hsize"], ucode["esize"],
               ucode["count"], ucode["dver"]))
        for e in ucode["entries"]:
            if not e.get("body"):
                print("    entry %2d app=%#04x tgt=%#04x desc=%#x "
                      "(invalid: hdr=%#x stored=%#x)" %
                      (e["i"], e["app"], e["target"], e["desc"],
                       e.get("hdr", 0), e.get("stored", 0)))
                continue
            tail = d[e["body"]:min(e["body"] + 0x10000, len(d))]
            print("    entry %2d app=%#04x tgt=%#04x desc=%#x v%d sv=%#x "
                  "enc=%d body=%#x..%#x ent(head)=%.2f" %
                  (e["i"], e["app"], e["target"], e["desc"], e["version"],
                   e["vsize"], e["encrypted"], e["body"], e["body_end"],
                   entropy(tail)))

    print("\n== FEAT address literals (raw and devinit-flag forms)")
    hits = scan_literals(d, path)
    if not hits:
        print("  none")
    for off, label, v, endian in hits[:40]:
        print("  %#08x %-18s %#010x %s ctx=%s" %
              (off, label, v, endian, d[max(0, off - 8):off + 12].hex(" ")))

    print("\n== devinit opcodes with an address in 0x823800-0x8238ff")
    ops = scan_opcodes(d)
    if not ops:
        print("  none")
    for off, label, addr, n in ops[:40]:
        print("  %#08x %-30s addr=%#010x len=%#x" % (off, label, addr, n))

    print("\n== register-address list runs (FUSE 0x820000-0x824000)")
    runs = scan_lists(d)
    if not runs:
        print("  none")
    for width, r in runs[:20]:
        addrs = [v for _, v in r]
        feat = any(0x823800 <= a < 0x823900 for a in addrs)
        print("  stride %d @%#x..%#x n=%d min=%#x max=%#x FEAT=%s" %
              (width, r[0][0], r[-1][0], len(r), min(addrs), max(addrs), feat))

    print("\n== anchor values")
    for label, v, offs in scan_anchors(d):
        if offs:
            print("  %-24s %#010x  n=%d  %s" %
                  (label, v, len(offs), [hex(x) for x in offs[:10]]))
    if ucode:
        print("\n== anchor ownership by ucode body")
        for label, v, offs in scan_anchors(d):
            if not offs:
                continue
            owners = []
            for off in offs:
                for e in ucode["entries"]:
                    if e.get("body") and e["body"] <= off < e["body_end"]:
                        owners.append("app%#04x/tgt%#04x" % (e["app"], e["target"]))
            if owners:
                print("  %-24s %s" % (label, sorted(set(owners))))

    if len(sys.argv) > 2:
        other = open(sys.argv[2], "rb").read()
        n = min(len(d), len(other))
        diff = sum(1 for i in range(n) if d[i] != other[i])
        print("\n== diff vs %s: %d differing bytes of %d" %
              (sys.argv[2], diff, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
