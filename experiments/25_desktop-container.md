# The desktop InfoROM container

## Summary

**The idea.**

- The public 5080-mobile sample proved the 1916 KB nvflash image carries an
  InfoROM island ([the mobile
  sample](23_public-inforom-record.md#232-corroboration-and-a-blackwell-sample));
  a desktop 5090 image settles whether the layout holds, whether stock
  objects are populated, and whether the `HLK` license object rides in the
  same region.
- I decoded a Founder's Edition RTX 5090 ROM (TechPowerUp VGABIOS entry
  276704, `98.02.2E.00.03`, 1,961,983 B, MD5 matching the published hash)
  and diffed it against the mobile sample and our own cards' readings.

**What it found.**

- The desktop island is byte-identical in layout to the mobile one —
  `ROM\x01` directory at `0x1d1000`, the same seven objects at the same
  offsets, 112 differing bytes confined to the `BRD`/`OBD` fields
  ([25.1](#251-the-fe-island-and-the-healthy-object-set)).
- Blank objects are the AIB-normal state: two vendor-matched reference
  dumps (ZOTAC `250114` — the same BIOS family as our `41:00.0` card —
  and Inno3D `250310`) both ship the identical blank island our cards
  read, while the one Founder's Edition dump carries programmed `BRD`/
  `OBD` (serial, board part numbers). AIB identity lives in the vBIOS-head
  metadata instead — our PROM head already carried the ZOTAC/InnoVISION
  part and board IDs at `0x36a40`
  ([25.1](#251-the-fe-island-and-the-healthy-object-set)).
- The `HLK` object is **not** in the saved image at all — no hit anywhere,
  and the directory lists seven objects without it. Since our cards'
  battery answers `HLK` v2.0 present, the license object lives outside the
  object region, in a zone `--save` excludes — the same exclusion that
  dropped the CCC device certificate on the 5080-laptop repair
  ([25.2](#252-the-license-zone-is-not-in-saves)).

**What it did not find.**

- The license-zone container bytes. Software reads its *content* state
  (`--rdhlk`: empty) but not its bytes; the clip dump keeps exactly that
  job.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 25.1 | [The FE island and the healthy object set](#251-the-fe-island-and-the-healthy-object-set) | Same layout; FE populated, our cards blank |
| 25.2 | [The license zone is not in saves](#252-the-license-zone-is-not-in-saves) | No `HLK` in the image; license lives outside the object region |

## 25.1 The FE island and the healthy object set

**Question.** Does the desktop 1916 KB image carry the same InfoROM
island, and are stock objects populated?

**Why.**

- The mobile sample was a wiped card; a healthy desktop image is the
  reference for what "stock" should look like — including whether our own
  cards' blank readings are normal.

**Method.**

- Offline. Signature scan and ROM-directory parse of the FE image
  (`analysis-tmp/../276704.rom`, moved with the other samples), diffed
  against the mobile island and against our cards' `--rdobd`/`--rdoem`
  readings from [the nvflash run](24_nvflash-read.md#242-the-stock-objects-are-factory-blank).

**Observed data.**

```text
FE 98.02.2E.00.03 (TPU 276704, md5 verified):
  island 0x1d1000, ROM\x01 dir, 7 objects — offsets identical to mobile
  IMG v1  "G005.0000.98.01"
  BRD v3  38 B nonzero
  OBD v2.1  81 B nonzero: "Generic" marketing, serial 1320325061083,
    board P/N S161-0609-600, date 2446, NVIDIA P/N 900-1G144-2530-000
  OEM/BBO/CGP/PTD: zeroed
ZOTAC 250114 + Inno3D 250310 (vendor-matched reference dumps):
  same island, same 7 objects — BRD/OBD/OEM/BBO/CGP/PTD all blank
  (OBD reads "Generic", serial 0), IMG alive, no HLK anywhere
  Inno3D image ends exactly at the island end (0x1d2dd0) — trailing FF
  trimmed; ZOTAC keeps the FF tail like the FE
our cards (exp 24.2): identical to the two AIB dumps
```

**Result.**

- **Answer:** the desktop container matches the mobile layout byte for
  byte outside the per-board fields. The object split is by vendor class:
  the one FE dump ships programmed `BRD`/`OBD` (NVIDIA's factory CSV
  flow), while every AIB dump — ZOTAC, Inno3D, the MSI mobile card, and
  our own two — ships blank objects, with AIB board identity living in
  the vBIOS-head metadata instead. Our cards are normal for their class,
  not wiped.
- **What we learned:**
  - The object region's stock state is now known per class: AIB cards
    carry `IMG` alive plus six blank objects; FE adds `BRD`/`OBD` data.
  - Our cards' blank `OBD` is still a usable per-card oracle: any InfoROM
    write (a license install, an RMA reflash) changes bytes that are
    otherwise constant across the whole AIB fleet.
- **Related:** [the nvflash read](24_nvflash-read.md#242-the-stock-objects-are-factory-blank)
  for our cards' side of the comparison.

## 25.2 The license zone is not in saves

**Question.** Is the `HLK` object inside the saved InfoROM region?

**Why.**

- The battery says our cards carry `HLK` v2.0; if the object sat in the
  saved region, the FE image would show it and the whole container story
  would close with software alone.

**Method.**

- Offline. Whole-image scan for `HLK` (any variant), the battery
  signatures, `LU` markers; directory enumeration.

**Observed data.**

```text
whole-image hits: IMG\x01\x00, OBD\x02\x01, OEM\x01\x00, ROM\x01, PTD only
HLK (any bytes): 0     \x00LU\x00: 0     ULF/UPR/LIC/CCC zones: 0
directory lists 7 objects; region free space after PTD is empty
```

**Result.**

- **Answer:** no — the license object is outside the object region, in a
  protected zone the save flow does not include, matching the CCC-zone
  exclusion documented on the 5080-laptop repair and the GA100 layout
  where the `LU` license region sat apart from the object area.
- **What we learned:**
  - The license zone's content state is software-readable (`--rdhlk`:
  empty on stock), its bytes are not; the hardware read's remaining scope
  is exactly that zone plus the full flash map.
  - Any future `--wrhlk`/certificate install targets a separate flash
  region from the objects nvflash rewrites in normal operation — license
  installs and object updates do not collide.
- **Related:** [the FS layer](22_inforom-filesystem-layer.md) covers the
  object region only; [the base state](21_inforom-base-state.md) for the
  battery that first named `HLK`.
