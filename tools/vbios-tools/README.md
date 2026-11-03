# vBIOS tools: dump and parse the board ROM

Read-only dumpers and parsers for the GB202 board vBIOS. The tools locate the
image behind the card's PROM aperture, dump it, parse the PCI image chain, BIT
and microcode table, and scan the plaintext for FEAT/FUSE/devinit references.

## At a glance

- **What it does.** Locates and dumps the board ROM, then parses the PCI image
  chain, BIT (BIOS Information Table), and Falcon microcode table, and scans the
  plaintext for rate-register and devinit references.
- **Access.** Read-only. The C tools open `resource0` read-only and `mmap` it
  `PROT_READ`; no register writes.
- **Inputs.** A live card with root, or a local 1 MiB image / 2 MiB aperture
  dump. No firmware or ROM ships here.
- **Outputs.** Raw dumps, the PCI/BIT/microcode parse, and the devinit scan.

**The short version.**

- The vBIOS image sits at BAR0 + `0x338000` behind a `0x38000` head; the full
  PROM aperture is 2 MiB at BAR0 + `0x300000`. See [where the vBIOS
  sits](../../specs/05_vbios-and-devinit.md#where-it-sits).
- `vbios_read` writes the 1 MiB image; `prom_read_raw` writes the 2 MiB
  aperture.
- `parse_flash.py` walks the PCI image chain, BIT tokens, FwSec images, and the
  microcode table.
- `devinit_scan.py` applies the `0x18000` EFI correction and follows the `0x70`
  token; it is the authoritative microcode-table parser.
- The plaintext scan finds no FEAT address. The only PLM values are in app
  `0x23` data, as the [plaintext-layer
  scan](../../specs/05_vbios-and-devinit.md#what-the-plaintext-layer-does-not-contain)
  records.

**In this file.**

- [Layout](#layout)
- [Build](#build)
- [Dump](#dump)
- [Parse](#parse)
- [Input format](#input-format)
- [Example output](#example-output)
- [Safety and access](#safety-and-access)
- [Terms](#terms)
- [Related](#related)

## Layout

| File | What it does |
|---|---|
| `vbios_probe.c` | Reads the PROM head at `0x1400` and the window at `0x300000`, then scans BAR0 for the ROM signature. |
| `vbios_read.c` | Dumps the vBIOS image at BAR0 + `0x338000`, or the first `0x55AA` hit. |
| `prom_read_raw.c` | Dumps any range of the 2 MiB [PROM aperture](../../specs/05_vbios-and-devinit.md#where-it-sits). |
| `parse_flash.py` | Walks the [PCI image chain](../../specs/05_vbios-and-devinit.md#pci-image-chain), [BIT](../../specs/05_vbios-and-devinit.md#bit), FwSec images, and [microcode table](../../specs/05_vbios-and-devinit.md#microcode-table). |
| `bit_tokens.py` | Decodes and classifies every BIT token; diffs two dumps. |
| `devinit_scan.py` | Scans for devinit opcodes, register-address lists, and FEAT/PLM anchors. |

## Build

```bash
gcc -O2 -Wall -o vbios_probe vbios_probe.c
gcc -O2 -Wall -o vbios_read vbios_read.c
gcc -O2 -Wall -o prom_read_raw prom_read_raw.c
chmod +x parse_flash.py bit_tokens.py devinit_scan.py
```

The Python tools use only the standard library. All tools are read-only; the C
tools open `resource0` read-only and `mmap` it `PROT_READ`.

## Dump

The BDF is an argument, not a hardcoded default.

```bash
sudo ./vbios_probe 0000:41:00.0 300000 100000
sudo ./vbios_read 0000:41:00.0 flash_41.bin
sudo ./prom_read_raw 0000:41:00.0 prom_full_41.bin
```

- `vbios_probe <bdf> [start_hex] [len_hex]` reads the PROM head at `0x1400` and the
  window at `0x300000`, and scans the given range for the 8-byte ROM prefix.
- `vbios_read <bdf> <out> [off_hex] [size_hex]` defaults to `0x338000`/`0x100000`.
- `prom_read_raw <bdf> <out> [off_hex] [size_hex]` defaults to the whole 2 MiB
  aperture (`0x300000`/`0x200000`) and clamps at the aperture end.

## Parse

```bash
python3 -I parse_flash.py flash_41.bin
python3 -I bit_tokens.py flash_41.bin [other.bin]
python3 -I devinit_scan.py flash1m_41.bin [other.bin]
```

`parse_flash.py` expects a standalone image that starts with `0x55AA`. For the
whole 2 MiB aperture, point it at the image offset or use `devinit_scan.py`,
which applies the [EFI-image
correction](../../specs/05_vbios-and-devinit.md#pci-image-chain) itself.
`bit_tokens.py` and `devinit_scan.py` accept either a 1 MiB image or the 2 MiB
aperture.

`devinit_scan.py` is the authoritative ucode-table parser: it applies the
`0x18000` EFI correction before following the [`0x70`
token](../../specs/05_vbios-and-devinit.md#microcode-table). `parse_flash.py` is
useful for the image chain and BIT; its FALCON_DATA path assumes the table
pointer is already image-relative.

## Input format

- `vbios_read` writes a 1 MiB image beginning at the vBIOS `0x55AA` signature.
- `prom_read_raw` writes the 2 MiB aperture: a `0x38000` head, the image at
  `0x38000`, and the [`0xBADF1100`
  sentinel](../../specs/05_vbios-and-devinit.md#where-it-sits) from `0x138000` to
  `0x200000`.
- The vBIOS image on this board starts at BAR0 + `0x338000`, not at the aperture
  base. The head before it (`0x300000`–`0x338000`, the `0x38000` head) is 99.66%
  identical between the two cards; 790 bytes differ, mostly board metadata.
- No firmware or ROM dump ships with this repository.

## Example output

Image chain and BIT from a 1 MiB dump:

```text
== flash_41.bin: 1048576 bytes (0x100000), entropy=6.26
   head: 55 aa 7d eb 4b 37 34 30 30 e9 4c 19 77 cc 56 49  |U.}.K7400.L.w.VIDEO|

== PCI image chain
  @0x000000 PciAt  size=0x00fa00 last=0 vid:did=10de:2b85
  @0x00fa00 EFI    size=0x018000 last=1 vid:did=0000:0000

== BIT
  header @ 0xdf0: hdr=12 tokSize=6 tokens=20
```

The 2 MiB aperture:

```text
0x000000-0x038000  head: 4cc0 tag, NVFW at +0x1000, encrypted blob, board metadata
0x038000-0x138000  vBIOS image
0x138000-0x200000  not flash: 0xBADF1100 sentinel
```

`devinit_scan.py` on the 1 MiB image:

```text
  token 0x70 v2: data@0x10c1 -> table ptr 0x4ce9d -> 0x64e9d
  ucode table: ver=1 hsize=6 esize=6 entries=35 descVer=1
    entry  5 app=0x07 tgt=0x06 desc=0x6fda0 v6 sv=0x50 enc=1 body=0x6fdf0..0x8fff0
    entry 22 app=0x18 tgt=0x01 desc=0xd6104 (invalid: hdr=0xbadf1100)
    entry 23 app=0x19 tgt=0x01 desc=0x8fff0 v6 sv=0x50 enc=1 body=0x90040..0xb1b40
    entry 24 app=0x15 tgt=0x01 desc=0xb1c30 v6 sv=0x50 enc=1 body=0xb1c80..0xb7780
    entry 32 app=0x23 tgt=0x0e desc=0xb77bc v6 sv=0x50 enc=1 body=0xb780c..0xd5a0c
    entry 34 app=0x24 tgt=0x0f desc=0xe3304 (invalid: hdr=0xbadf1100)

== FEAT address literals (raw and devinit-flag forms)
  none

== devinit opcodes with an address in 0x823800-0x8238ff
  none

== register-address list runs (FUSE 0x820000-0x824000)
  stride 8 @0x638e5..0x63b1d n=72 min=0x820800 max=0x8221a4 FEAT=False
```

The four real images are `0x07`/target `0x06`, `0x19`/`0x01`, `0x15`/`0x01`,
and `0x23`/`0x0E`. The `0x18`/`0x01` and `0x24`/`0x0F` entries point at
`0xBADF1100` and are placeholders. App `0x23` carries the plaintext data tail
`0xC8000`–`0xD5A0C`; the other bodies are encrypted throughout. See the
[microcode-table
decode](../../specs/05_vbios-and-devinit.md#microcode-table).

The PLM anchors are owned by app `0x23`/target `0x0E`:

```text
== anchor ownership by ucode body
  PLM_locked 0xfffffb8f  ['app0x23/tgt0x0e']
  PLM_bit10  0xfffffbff  ['app0x23/tgt0x0e']
  Ada_FEAT   0xffffff8f  ['app0x23/tgt0x0e']
  Ada_FBPA   0xffffff0f  ['app0x23/tgt0x0e']
```

Those values are PLM (privilege-level mask) encodings; the [register
map](../../specs/03_register-map.md#feat-bank) decodes them.

## Safety and access

Read-only: no register writes. Read through the known-good `0x338000` window.
Do not page-scan BAR0 `0x300000`–`0x400000` while the driver owns the card; a
read-only scan there coincided with a GSP fault and a required reboot, as the
[memory hazards](../../specs/07_memory-and-host-access.md#bar0-and-bar1) record.
`prom_read_raw` is safe inside the 2 MiB aperture; `vbios_probe`'s range scan is
the hazardous call.

## Terms

- **BDF**: PCI bus/device/function, e.g. `0000:41:00.0`.
- **PROM aperture**: the 2 MiB flash window at BAR0 + `0x300000`.
- **PROM head**: the first `0x38000` bytes before the image; `0x1400` starts the
  encrypted blob.
- **[BIT](../../specs/05_vbios-and-devinit.md#bit)**: BIOS Information Table.
- **[FwSec](../../specs/05_vbios-and-devinit.md#pci-image-chain)**: firmware-security
  image in the PCI ROM chain.
- **[ucode](../../specs/05_vbios-and-devinit.md#microcode-table)**: Falcon microcode.
- **PLM**: privilege-level mask; see the [register map](../../specs/03_register-map.md#feat-bank).

## Related

- [The vBIOS has no FEAT address](../../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)
- [The full PROM has no FEAT table](../../experiments/07_plaintext-corpus.md#079-the-full-prom-has-no-feat-table)
- [The vBIOS devinit-table scan](../../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)
- [vBIOS and devinit spec](../../specs/05_vbios-and-devinit.md)
- [Register map spec](../../specs/03_register-map.md)
- [Direct probe](../direct-probe/)
