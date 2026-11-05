# The inforom filesystem layer

## Summary

**The idea.**

- The InfoROM is not a flat array: the 595 plaintext names a filesystem layer
  (`_inforomFsReadFile`, `_inforomFsWriteFile`, sector and block management),
  and the [base state](21_inforom-base-state.md) showed GSP-RM parsing the
  image at boot. Resolving that layer offline names the InfoROM's geometry
  and turns any future flash dump into a decode instead of a search.
- I walked the decompiled 595 image from the object-battery control down
  through the mount path to the flash-read primitive, with Ghidra
  disassembly where the decompiler lost the indirect calls.

**What it found.**

- The mount function is `FUN_ram_016b0c6c`: it reads an `0x80`-byte
  filesystem header at InfoROM offset `0`, takes the total FS size from it
  (fixed `0x5000` — 20 KiB — for filesystem version 1), walks every sector
  with the per-sector checker, then walks a linked list of file entries and
  registers each file
  ([22.1](#221-the-mount-function-and-the-filesystem-geometry)).
- The read primitive is `FUN_ram_016bc838(dev, off, len, buf)`, a tail-call
  through a platform-dispatched HAL slot (`dev->gpu(+0x2150)->hal(+0x5c0)`
  then vtable `+0x28`); the per-sector metadata window is `0x70` bytes at
  sector offset `+0x10`
  ([22.2](#222-the-read-primitive-and-the-platform-dispatch)).
- The last hop — the HAL implementation that would carry the InfoROM's
  absolute flash base — ends at a load-time relocation: the vtable pointer
  stored in the image is not a valid address until boot fixes it up
  ([22.3](#223-the-relocation-blocks-the-flash-base)).

**What it did not find.**

- The InfoROM's absolute flash offset. It is not an immediate in any
  inforom-module function; it lives behind the relocated HAL table, so
  static analysis of the shipped image cannot recover it. A dump does not
  need it — the battery's version bytes give exact object signatures to
  scan for ([22.3](#223-the-relocation-blocks-the-flash-base)).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 22.1 | [The mount function and the filesystem geometry](#221-the-mount-function-and-the-filesystem-geometry) | `0x80`-byte header, `0x5000` FS, per-sector walk, file list |
| 22.2 | [The read primitive and the platform dispatch](#222-the-read-primitive-and-the-platform-dispatch) | `FUN_ram_016bc838`; three HAL variants; `0x70` bytes at `+0x10` per sector |
| 22.3 | [The relocation blocks the flash base](#223-the-relocation-blocks-the-flash-base) | Base not statically recoverable; dump does not need it |

## 22.1 The mount function and the filesystem geometry

**Question.** How is the InfoROM image laid out, and what does GSP-RM read
first?

**Why.**

- The InfoROM is a flash region none of the dumps cover; the mount code is
  the only description of its contents that ships in the firmware.

**Method.**

- Offline. The FS functions were located through their assert-name strings
  (`refscan.py` over the symbol range `0x01e74b00`–`0x01e9c260`), then read
  from the decompiled dump; the navigation helper is
  `analysis-tmp/c36/work/fwalk.py` with the function index
  `funcline.json`.
- Args used:
```bash
python3 -I analysis-tmp/c36/work/fwalk.py show 016b0c6c
```

**Observed data.**

```text
FUN_ram_016b0c6c(dev, ...)                    # mount
  buf = alloc(0x80)
  read(dev, 0, 0x80, buf)                     # FUN_ram_016bc838: FS header
  fs_version = *(u32 *)(dev + 8)              # platform-chosen
  if fs_version == 1:  total = 0x5000         # 20 KiB fixed
  else:                total = *(u32 *)(hdr + 8)
  for off in 0 .. total step *(u32 *)(dev+0xb0):   # sector size
      FUN_ram_016afe94(dev, off)              # per-sector check
  walk file-entry list:  id = u16 @ entry+0x1c, version = u8 @ entry+0x1f
      skip entries with entry_flag(+8) == 1
FUN_ram_016afcc8(dev, sector, buf)            # sector metadata reader
  read(dev, sector + 0x10, 0x70)              # 0x70-byte window at +0x10
```

**Result.**

- **Answer:** the InfoROM is a small filesystem — an `0x80`-byte header, a
  total size around 20 KiB, sectors of a size the platform picks, and a
  linked list of file entries carrying a file id and version. The objects
  the battery saw are files in this filesystem.
- **What we learned:**
  - The per-sector layout has a metadata window at `+0x10` (`0x70` bytes) —
    the sector header proper, with payload after it.
  - The file-entry version byte (`+0x1f`) is what the object battery
    reports — the version in 21.1 came through this exact field.
- **Related:** [the base state](21_inforom-base-state.md#211-the-object-battery)
  fixed which files exist; the registry census there supplies each object's
  packed layout.

## 22.2 The read primitive and the platform dispatch

**Question.** How does the FS layer reach flash, and where does the
platform variation enter?

**Why.**

- The read path's shape decides whether a software read exists for the host
  (it does not, if the path ends in a GSP-only HAL) and what a hardware dump
  must match.

**Method.**

- Offline. Ghidra disassembly of the read wrapper (the decompiler loses the
  tail-call through the vtable); the platform dispatcher was found by
  locating the store into the HAL slot.

**Observed data.**

```text
FUN_ram_016bc838(dev, off, len, buf):
  gpu   = *(dev + 0x2150)
  hal   = *(gpu + 0x5c0)          # platform slot
  vt    = *hal
  jump  *(vt + 0x28)              # read(off, len, buf)  [tail call]

platform dispatcher FUN_ram_01af8006 stores one of:
  &DAT_ram_016a3034 | FUN_ram_01ae4d64 (stub) | &DAT_ram_016a0e10
  | &LAB_ram_016a4a80             # chosen by platform bitfield + variant
write twin: FUN_ram_016bc000; sector ops: 0x016afe94 check,
  0x016afdb0 flush (RW-file paths at dev+0xb8/0xd8/0xe8)
```

**Result.**

- **Answer:** the FS layer never touches a register; every access is a
  virtual call into a platform HAL installed by the dispatcher, with three
  inforom variants. The host cannot enter this path — it exists only inside
  GSP-RM.
- **What we learned:**
  - The write twin and the RW-file flush paths confirm the card rewrites
    the region in normal operation, matching the wear-limit string.
  - The three variants are why the FS version byte (`dev+8`) exists —
    different platform families ship different FS revisions.
- **Related:** [the memory hazards](../specs/07_memory-and-host-access.md#bar0-and-bar1)
  already rule out the host reaching GSP-side state.

## 22.3 The relocation blocks the flash base

**Question.** Can the InfoROM's absolute flash offset be read out of the
shipped image?

**Why.**

- A hardware dump could target the region directly if the base were known,
  and a software full-flash read path, if one exists, would carry the same
  constant.

**Method.**

- Offline. The HAL structs (`0x016a3034`, `0x016a0e10`) were dereferenced
  from the raw image bytes at `VA - 0x01000000`; every function in the
  inforom and HAL modules was scanned for immediates in flash-offset range
  (`0x138000`–`0x2000000`).

**Observed data.**

```text
qword at 0x016a3034 (raw image) = 0xfc5ee0daf8a27119   # not a pointer
qword at 0x016a0e10 (raw image) = 0xf8dae92271353571    # not a pointer
(VA-to-file mapping verified: 0x016bc838 decodes to the exact
 c.addi sp,-0x10 prologue Ghidra shows)
immediates 0x138000..0x2000000 in inforom/HAL modules: none
```

**Result.**

- **Answer:** no — the HAL table pointers are fixed up at load time, so the
  image bytes do not carry them, and no function in the modules holds the
  base as an immediate.
- **What we learned:**
  - A flash dump does not need the base: the exact object signatures from
    [the battery](21_inforom-base-state.md#211-the-object-battery) —
    `IMG\x01\x00`, `OBD\x02\x01`, `OEM\x01\x00`, `HLK\x02\x00` (type,
    version, subversion) — plus the `0x80`-byte FS header and the
    `+0x10`-offset `0x70`-byte sector windows identify the region anywhere
    in the dump, and the registry census decodes every standard object
    around it.
  - What would finish the base statically: processing the image's
    relocation records, or one runtime read of the resolved table — the
    latter sits inside WPR2, which host reads cannot reach.
- **Related:** [the base state](21_inforom-base-state.md#212-the-registry-and-the-filesystem-layer-in-the-plaintext)
  holds the decode table; the hardware read joins [the HULK certificate
  path](../IDEAS.md#hulk-certificate-path).
