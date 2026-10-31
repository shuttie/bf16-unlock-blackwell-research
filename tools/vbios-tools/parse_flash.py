#!/usr/bin/env python3
"""Parse an NVIDIA vBIOS flash image: PCI image chain, BIT table, FwSec ucode.

Layout:
  - PciAt (0x00), EFI (0x03), FwSec (0xE0) image types
  - BIT header, token, and ucode-table structures
"""
import math
import struct
import sys
from collections import Counter

BIT_ID = 0xB8FF
BIT_SIG = b"BIT\x00"
FALCON_DATA = 0x70
APPID_FWSEC_DBG = 0x45
APPID_FWSEC_PROD = 0x85
APPID_FIRMWARE_SEC_LIC = 0x05
IMAGE_TYPES = {0x00: "PciAt", 0x03: "EFI", 0xE0: "FwSec"}


def entropy(b):
    if not b:
        return 0.0
    c = Counter(b)
    n = len(b)
    return -sum(v / n * math.log2(v / n) for v in c.values())


def printable(b, n=48):
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b[:n])


def walk_images(d):
    """Walk the PCI expansion ROM chain the way the driver locates ROMs."""
    out = []
    off = 0
    while off + 0x30 < len(d):
        if d[off:off + 2] != b"\x55\xaa":
            out.append({"off": off, "error": "no 0x55AA"})
            break
        pci = struct.unpack_from("<H", d, off + 0x18)[0]
        p = off + pci
        if d[p:p + 4] != b"PCIR":
            out.append({"off": off, "error": f"no PCIR at {p:#x}"})
            break
        img_len = struct.unpack_from("<H", d, p + 0x10)[0]
        code_type = d[p + 0x14]
        indicator = d[p + 0x15]
        dev = struct.unpack_from("<HH", d, p + 4)
        out.append({
            "off": off, "size": img_len * 512, "type": code_type,
            "type_name": IMAGE_TYPES.get(code_type, f"0x{code_type:02x}"),
            "last": bool(indicator & 0x80), "vid": dev[0], "did": dev[1],
            "pcir": p, "indicator": indicator,
        })
        if indicator & 0x80:
            break
        off += img_len * 512
    return out


def find_bit(d):
    for a in range(len(d) - 12):
        if d[a:a + 2] == b"\xff\xb8" and d[a + 2:a + 6] == BIT_SIG:
            hsize = d[a + 8]
            if sum(d[a:a + hsize]) & 0xFF == 0:
                return a
    return None


def parse_bit(d, base):
    hsize = d[base + 8]
    tsize = d[base + 9]
    count = d[base + 10]
    tokens = []
    for i in range(count):
        o = base + hsize + i * tsize
        tid, ver = struct.unpack_from("<2B", d, o)
        size, ptr = struct.unpack_from("<2H", d, o + 2)
        tokens.append({"idx": i, "off": o, "id": tid, "ver": ver,
                       "size": size, "ptr": ptr})
    return {"base": base, "hsize": hsize, "tsize": tsize, "count": count,
            "tokens": tokens}


def parse_ucode(d, table_off, label=""):
    if table_off + 6 > len(d):
        print(f"  {label}table offset {table_off:#x} beyond image")
        return
    ver, hsize, esize, count, dver, dsize = struct.unpack_from("<6B", d, table_off)
    print(f"  {label}Falcon ucode table @ {table_off:#x}: version={ver} "
          f"hdr={hsize} entry={esize} count={count} descVer={dver} descSize={dsize}")
    if ver != 1 or hsize < 6 or esize < 6:
        print("    (unexpected header, stopping)")
        return
    for e in range(count):
        o = table_off + hsize + e * esize
        if o + 6 > len(d):
            break
        appid, target = struct.unpack_from("<2B", d, o)
        descptr = struct.unpack_from("<I", d, o + 2)[0]
        print(f"    entry {e}: appID={appid:#04x} target={target:#04x} "
              f"descPtr={descptr:#08x}")
        if appid not in (APPID_FWSEC_PROD, APPID_FWSEC_DBG, APPID_FIRMWARE_SEC_LIC):
            continue
        if descptr + 4 > len(d):
            print("      descPtr beyond image")
            continue
        vdesc = struct.unpack_from("<I", d, descptr)[0]
        dversion = (vdesc >> 8) & 0xFF
        dsize = (vdesc >> 16) & 0x7FFF
        encrypted = (vdesc >> 2) & 1
        print(f"      vDesc={vdesc:#010x} version={dversion} size={dsize} "
              f"encrypted={encrypted}")
        if dversion == 2:
            (hdr, stored, unc, virtentry, iface, imem_phys, imem_load, imem_virt,
             imem_sec, imem_secsz, dmem_off, dmem_phys, dmem_load, alti,
             altd) = struct.unpack_from("<15I", d, descptr)
            print(f"      V2 stored={stored:#x} uncompressed={unc:#x} "
                  f"entry={virtentry:#x} iface={iface:#x}")
            print(f"      IMEM phys={imem_phys:#x} load={imem_load:#x} "
                  f"virt={imem_virt:#x} sec={imem_sec:#x}+{imem_secsz:#x}")
            print(f"      DMEM off={dmem_off:#x} phys={dmem_phys:#x} load={dmem_load:#x}")
            body = descptr + dsize
            imem = d[body:body + max(imem_load, 0)]
            dmem = d[body + imem_load:body + imem_load + max(dmem_load, 0)]
            for name, blob in (("IMEM", imem), ("DMEM", dmem)):
                if blob:
                    print(f"      {name}: {len(blob)} bytes entropy={entropy(blob):.3f} "
                          f"|{printable(blob)}|")
        elif dversion == 3:
            (hdr, stored, pkc, iface, imem_phys, imem_load, imem_virt, dmem_phys,
             dmem_load, engmask, ucode_id, sigcount, sigvers, resv) = \
                struct.unpack_from("<9I1H2B2H", d, descptr)
            print(f"      V3 stored={stored:#x} pkcoff={pkc:#x} iface={iface:#x}")
            print(f"      IMEM phys={imem_phys:#x} load={imem_load:#x} virt={imem_virt:#x}")
            print(f"      DMEM phys={dmem_phys:#x} load={dmem_load:#x}")
            print(f"      engineMask={engmask:#06x} ucodeId={ucode_id} "
                  f"signatureCount={sigcount} sigVersions={sigvers:#06x}")
            body = descptr + dsize
            imem = d[body:body + max(imem_load, 0)]
            dmem = d[body + imem_load:body + imem_load + max(dmem_load, 0)]
            for name, blob in (("IMEM", imem), ("DMEM", dmem)):
                if blob:
                    print(f"      {name}: {len(blob)} bytes entropy={entropy(blob):.3f} "
                          f"|{printable(blob)}|")
            # per-engine signed ucode blocks follow the raw IMEM/DMEM
            cur = body + imem_load + dmem_load
            print(f"      data after IMEM+DMEM at {cur:#x}")


def main():
    path = sys.argv[1]
    d = open(path, "rb").read()
    print(f"== {path}: {len(d)} bytes ({len(d):#x}) entropy={entropy(d):.2f}")
    print(f"   head: {d[:16].hex(' ')}  |{printable(d, 32)}|")

    print("\n== PCI image chain")
    for img in walk_images(d):
        if "error" in img:
            print(f"  @{img['off']:#08x} ERROR: {img['error']}")
            continue
        print(f"  @{img['off']:#08x} {img['type_name']:6s} size={img['size']:#08x} "
              f"last={int(img['last'])} vid:did={img['vid']:04x}:{img['did']:04x}")

    print("\n== BIT")
    bit = find_bit(d)
    if bit is None:
        print("  not found")
    else:
        info = parse_bit(d, bit)
        print(f"  header @ {bit:#x}: hdr={info['hsize']} tokSize={info['tsize']} "
              f"tokens={info['count']}")
        for t in info["tokens"]:
            print(f"    {t['idx']:2d} id={t['id']:#04x} ver={t['ver']} "
                  f"size={t['size']:#06x} ptr={t['ptr']:#06x}")
        for t in info["tokens"]:
            if t["id"] == FALCON_DATA and t["ver"] == 2:
                tbl = struct.unpack_from("<I", d, t["ptr"])[0]
                print(f"\n  FALCON_DATA token -> ucode table ptr {tbl:#x}")
                parse_ucode(d, tbl)

    print("\n== 0xE0 FwSec images (scan for image headers)")
    for a in range(0, len(d) - 0x40, 4):
        if d[a:a + 2] != b"\x55\xaa":
            continue
        pci = struct.unpack_from("<H", d, a + 0x18)[0]
        p = a + pci
        if p + 0x18 <= len(d) and d[p:p + 4] == b"PCIR" and d[p + 0x14] == 0xE0:
            ln = struct.unpack_from("<H", d, p + 0x10)[0] * 512
            print(f"  FwSec image @ {a:#08x} len={ln:#x} last={int(bool(d[p+0x15] & 0x80))} "
                  f"head={d[a:a+16].hex(' ')} |{printable(d[a+2:a+34])}|")


if __name__ == "__main__":
    main()
