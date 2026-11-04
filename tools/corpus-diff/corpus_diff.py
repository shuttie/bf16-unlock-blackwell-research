#!/usr/bin/env python3
"""corpus_diff.py - cross-version corpus diff over the GSP-RM libos images.

Splits each fwimage into manifest modules (name slot + u64 offset at +0x28,
u64 size at +0x30, manifest-base relative), then compares modules and
printable strings across driver versions.

Read-only file analysis; no GPU access, no network.

Usage:
  python3 -I corpus_diff.py split <fwimage>            # module table
  python3 -I corpus_diff.py compare <a> <b> <la> <lb>  # module + string delta
"""
import hashlib
import re
import struct
import sys

NAME_RE = re.compile(rb"[a-zA-Z0-9_.\-]{4,40}\x00")


def manifest(fw):
    """Return (base, {name: (offset, size, name_file_offset)}).

    Record layout: NUL-terminated name padded to 8 bytes, then u64 flags,
    u64 reserved, u64 align, u64 offset, u64 size, u64 count, u64 entryptr.
    Short names (rm.elf) shift every field by 8 against a 16-byte name slot,
    so fields are read relative to the padded name end.
    """
    kern = fw.find(b"\x7fELF", 0x1000)
    lo = max(0, kern - 0x8000)
    area = fw[lo:kern]
    mods = {}
    for m in NAME_RE.finditer(area):
        no = m.start() + lo
        raw = m.group()
        name = raw[:-1].decode()
        if not name.endswith((".elf", ".bin")):
            continue
        pad = (len(raw) + 7) & ~7          # padded name width
        f = no + pad                        # field base
        align, off, size = struct.unpack_from("<QQQ", fw, f + 0x10)
        mods[name] = (off, size, no)
    # base from the first kernel_* entry
    for name in sorted(mods):
        off, size = mods[name][:2]
        if name.startswith("kernel_") and size:
            base = kern - off
            return base, mods, kern
    return 0, mods, kern


def strings(data, minlen=6):
    out = set()
    for m in re.finditer(rb"[ -~]{%d,}" % minlen, data):
        out.add(m.group().decode())
    return out


def cmd_split(path):
    fw = open(path, "rb").read()
    base, mods, kern = manifest(fw)
    print("manifest base %#x, first ELF %#x, %d modules" % (base, kern, len(mods)))
    for name in sorted(mods, key=lambda n: mods[n][0]):
        off, size, no = mods[name]
        if not size:
            print("  %-22s (no extent)" % name)
            continue
        s, e = base + off, base + off + size
        if e > len(fw):
            print("  %-22s %#x+%#x BEYOND FILE" % (name, off, size))
            continue
        ext = fw[s:e]
        dig = hashlib.sha256(ext).hexdigest()[:16]
        zero = ext.count(0) / len(ext)
        print("  %-22s file %#010x +%#9x  sha %s  zero=%.2f" %
              (name, s, size, dig, zero))


def cmd_compare(pa, pb, la, lb):
    fa = open(pa, "rb").read()
    fb = open(pb, "rb").read()
    ba, ma, _ = manifest(fa)
    bb, mb, _ = manifest(fb)
    print("== module extents: %s vs %s" % (la, lb))
    for name in sorted(set(ma) | set(mb)):
        ea, eb = ma.get(name), mb.get(name)
        if not ea or not eb:
            print("  %-22s only in %s" % (name, la if ea else lb))
            continue
        oa, sa, _ = ea
        ob, sb, _ = eb
        if not sa and not sb:
            continue
        exta = fa[ba + oa:ba + oa + sa] if sa else b""
        extb = fb[bb + ob:bb + ob + sb] if sb else b""
        ha = hashlib.sha256(exta).hexdigest()[:12] if sa else "-"
        hb = hashlib.sha256(extb).hexdigest()[:12] if sb else "-"
        same = "same" if exta == extb else "CHANGED"
        print("  %-22s %9d -> %9d  %s %s %s" %
              (name, sa, sb, ha, hb, same))
    # strings per module for modules present in both with extents
    SEC = re.compile(r"UDE|DEVINIT|WPR|SR[A-Z_]|COT|PLM|FUSE|OVERRIDE|SPEED|"
                     r"FALCON|UCODE|SECURE|AUTHENTI|KEY|JTAG|SIGN|SEC2|"
                     r"FMC|BINDATA|ENCRYPT|DECRYPT|PROTECT|PRIV|PERM|HANG|"
                     r"BOOT|TLS|SBACION|SCRUB|VAULT|LS_MODE|HSMODE", re.I)
    print("\n== per-module string deltas (present-in-both modules)")
    for name in sorted(set(ma) & set(mb)):
        oa, sa, _ = ma[name]
        ob, sb, _ = mb[name]
        if not sa or not sb:
            continue
        exta = fa[ba + oa:ba + oa + sa]
        extb = fb[bb + ob:bb + ob + sb]
        if exta == extb:
            continue
        sta, stb = strings(exta), strings(extb)
        new = stb - sta
        gone = sta - stb
        print("  %-22s strings %d -> %d  +%d/-%d" %
              (name, len(sta), len(stb), len(new), len(gone)))
        sec_new = sorted(s for s in new if SEC.search(s))
        sec_gone = sorted(s for s in gone if SEC.search(s))
        print("     security-namespace: +%d/-%d" % (len(sec_new), len(sec_gone)))
        for s in sec_new:
            print("     + %s" % s[:130])
        for s in sec_gone:
            print("     - %s" % s[:130])
    # whole-image string sets for the cross-check
    print("\n== whole-image string-set deltas")
    sta, stb = strings(fa), strings(fb)
    print("  %s: %d strings; %s: %d strings; +%d/-%d" %
          (la, len(sta), lb, len(stb), len(stb - sta), len(sta - stb)))


def cmd_headers(paths):
    """FMC container header census: magic, sizes, flags, tail bytes."""
    print("%-28s %-9s %8s %8s %7s %6s %6s %4s %s" %
          ("label", "magic", "body", "code", "data", "flags", "const",
           "+a00", "sha256"))
    for spec in paths:
        label, path = spec.split("=", 1)
        d = open(path, "rb").read()
        magic = d[0:4].hex()
        body = struct.unpack_from("<I", d, 4)[0]
        code = struct.unpack_from("<I", d, 0xC)[0]
        data = struct.unpack_from("<I", d, 0x14)[0]
        flags = struct.unpack_from("<I", d, 0x18)[0]
        const = struct.unpack_from("<I", d, 0x20)[0]
        tailz = d[0x24:0x48] == b"\0" * 0x24
        ok = "OK" if body == code + data + 0xA00 else "BAD"
        print("%-28s %-9s %8x %8x %7x %6x %6x %4s %s%s" %
              (label, magic, body, code, data, flags, const, ok,
               hashlib.sha256(d).hexdigest()[:12],
               "" if tailz else " TAIL=%s" % d[0x24:0x48].hex()))


if __name__ == "__main__":
    if sys.argv[1] == "split":
        cmd_split(sys.argv[2])
    elif sys.argv[1] == "compare":
        cmd_compare(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif sys.argv[1] == "headers":
        cmd_headers(sys.argv[2:])
