# The InfoROM base state

## Summary

**The idea.**

- The HULK certificate path sources its certificates from InfoROM
  `UL_GLOB`/`HLK` objects, and no dump covers the InfoROM
  ([the sourcing](20_hulk-cert-machinery.md#202-the-vbios-is-not-the-source)).
  The parsed image lives inside GSP-RM behind WPR2, so the one software
  reader that can answer for the card is the RM itself.
- I queried the RM's InfoROM controls on both cards — the whole-image
  version, the whole-image verify, and a per-object-type battery that
  includes the HULK family — and censused the RM plaintext's inforom object
  registry and filesystem layer offline.

**What it found.**

- The license slot ships on stock: both cards answer `HLK` version 2.0
  present, and the stock image carries exactly four objects — `IMG` 1.0,
  `OBD` 2.1, `OEM` 1.0, `HLK` 2.0. Every other type, the `UL_GLOB` family
  and a `ZZZ` control included, returns `OBJECT_NOT_FOUND`
  ([21.1](#211-the-object-battery)).
- The RM's static registry names 23 object formats, none of them a HULK
  type, so the battery is answered from the image directory parsed at boot;
  the plaintext also names the InfoROM's own filesystem layer
  (`_inforomFsReadFile`, `_inforomFsWriteFile`, sector and block
  management) — the offline handle for the read path to flash
  ([21.2](#212-the-registry-and-the-filesystem-layer-in-the-plaintext)).
- No raw bytes came back: the packaged dump paths serve no inforom
  component, and the whole-image verify control is not supported on GB202
  ([21.3](#213-the-dump-paths-that-come-back-empty)).

**What it did not find.**

- The `HLK` object's bytes. The parsed copy sits behind WPR2 and the raw
  flash region is outside the PROM window, so the slot contents wait on the
  filesystem layer's flash offset plus a dump, or on a hardware flash read.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 21.1 | [The object battery](#211-the-object-battery) | `HLK` 2.0 on both cards; four objects total |
| 21.2 | [The registry and the filesystem layer in the plaintext](#212-the-registry-and-the-filesystem-layer-in-the-plaintext) | 23 formats, no HULK type; the FS layer is named |
| 21.3 | [The dump paths that come back empty](#213-the-dump-paths-that-come-back-empty) | No inforom component; verify not supported |

## 21.1 The object battery

**Question.** Which InfoROM objects does a stock 5090 carry, and is the HULK
license slot among them?

**Why.**

- The certificate path's base condition is the stock InfoROM state: whether
  `HLK` exists at all, and whether a usage-limit global (`UL_GLOB`) sits
  beside it. The GA100 record found the license region on shipping boards,
  but nothing said Blackwell retail cards carry the slot.
- `NV2080_CTRL_CMD_GPU_GET_INFOROM_OBJECT_VERSION` takes the three-character
  on-flash object type from the 8-byte object header
  ([the header](#212-the-registry-and-the-filesystem-layer-in-the-plaintext)),
  so a battery over candidate type names is an existence oracle the RM
  answers from the card.

**Method.**

- Live, read-only. `inforom_probe` (`analysis-tmp/c36/work/`) allocates one
  RM client/device/subdevice — the same ioctl plumbing as
  [register access](../tools/register-access/README.md) — and issues
  `0x20800156` (image version), `0x208f1105` (whole-image verify), and
  `0x2080014b` (object version) over the battery `IMG OBD OEM ECC PWR GLOB
  CFG DEM NVL UL_ HLK LIC ULF UPR BCR ZZZ`. The control numbers and the
  params come from the pinned 610.43.03 tree (`ctrl2080gpu.h`,
  `ctrl208fgpu.h`).
- The wrapper `analysis-tmp/c36/run_inforom.sh` adds the `nvidia-smi` and
  `/proc` version blocks and the `nvidia-debugdump` run
  ([21.3](#213-the-dump-paths-that-come-back-empty)). Run 2026-11-04,
  driver `595.91.07` open, both cards; run directory
  `analysis-tmp/c36/out/inforom_20261104_172412/`.
- Args used:
```bash
sudo ./analysis-tmp/c36/run_inforom.sh
```

**Observed data.**

```text
image version (0x20800156): G005.0000.98.01              both cards
verify (0x208f1105):        0x56 NV_ERR_NOT_SUPPORTED    both cards

object battery (0x2080014b), identical on both cards:
  IMG  OK  ver 1 sub 0        OBD  OK  ver 2 sub 1
  OEM  OK  ver 1 sub 0        HLK  OK  ver 2 sub 0
  ECC PWR GLOB CFG DEM NVL UL_ LIC ULF UPR BCR ZZZ: 0x57 (OBJECT_NOT_FOUND)

nvidia-smi -q: Image Version G005.0000.98.01; "OEM Object" 2.1 (the value
  equals the OBD version — a legacy label); ECC Object N/A; Power
  Management Object N/A
```

**Result.**

- **Answer:** the license slot is provisioned on retail silicon. The stock
  image lists exactly `IMG` 1.0, `OBD` 2.1, `OEM` 1.0, and `HLK` 2.0 —
  nothing else exists, so there is no `UL_GLOB` and no ECC or power object
  on this SKU.
- **What we learned:**
  - `0x57` is `NV_ERR_OBJECT_NOT_FOUND` (`nvstatuscodes.h`), returned even
    for the `ZZZ` control — the control answers from the image directory
    parsed at boot, not from a static type list, so the four-object answer
    is a property of the card, not of the RM's vocabulary.
  - The battery is a cheap repeatable oracle: any license-slot state change
    (a certificate install, a vendor unlock) shows up as a version bump or
    a new type row.
  - `nvidia-smi` corroborates the absences independently (ECC and power
    `N/A`) and displays no `HLK` line at all — its vocabulary predates the
    object.
- **Related:** [the HULK certificate path](../IDEAS.md#hulk-certificate-path)
  carries the next reads; [the cluster](20_hulk-cert-machinery.md#201-the-certificate-cluster-in-the-rm-plaintext)
  named the slot this battery hit.

## 21.2 The registry and the filesystem layer in the plaintext

**Question.** Does the 595 RM plaintext carry the inforom object registry
and read path well enough to resolve the InfoROM's flash location offline?

**Why.**

- 21.1's `HLK` hit needs an interpretation: is `HLK` part of the RM's
  static object vocabulary, or did the RM read it off the card?
- The raw `HLK` bytes are reachable only through the layer that reads the
  InfoROM from flash. If that layer is named in the plaintext, its mount
  point names the flash offset a hardware dump should target.

**Method.**

- Offline. A census of `3s2bwb…` inforom packed-struct format strings (the
  format alphabet is `inforom/types.h` in the pinned 610.43.03 tree) over
  the registry band, a whole-image scan for HULK-family type tokens outside
  the FWSECLIC error-string cluster, and a symbol-string dump of the
  inforom layer.
- Args used:
```bash
python3 -I analysis-tmp/c36/work/registry_scan.py
```

**Observed data.**

```text
23 format strings in 0x00f3e000..0x00f46000; type tokens in band:
  NVL EEN RPR RRL IMG PBL DEM SEN OBD OEM PPO OCT (+ HWPM perf names)
the DEM format is 3s2bwbd2w4096x8d, 4144 B packed (matches ifrdem.h V1_00)
HULK-family tokens outside the FWSECLIC cluster: none in any readable band
  (the raw 0x02xxxxxx+ hits sit inside encrypted regions)
filesystem symbols at 0x00e74b18..0x00e9c250:
  _inforomCleanSector _inforomFsReadFile _inforomFileGetNodeAtOffset
  _inforomFsInsertFile _inforomFsAddBlock _inforomFsGetNewBlockOffset
  _inforomFsWriteFile _inforomFsWriteRWFile
decompiled dump: FUN_ram_016b1400 logs s__inforomFsReadFile; the mount
  layer is function-table driven around FUN_ram_016abe4c
adjacent strings: "Non-fatal violation of provisioned InfoROM wear limit"
  (0x00f4aee3); NV_UCODE_ERR_CODE_GFWIMAGEPARSER_INFOROM_BLOCK_NOT_PRESENT
  (0x00ef39a9)
```

**Result.**

- **Answer:** the RM's static registry has no HULK type, so the `HLK`
  answer in 21.1 is card-sourced; and the InfoROM is a small filesystem —
  files, nodes, blocks, sectors — whose read/write layer is present and
  named in the readable plaintext.
- **What we learned:**
  - The registry census doubles as a decode table for a future dump: every
    standard object's packed layout is in the band, and the FS layer means
    the InfoROM region is structured (files at node offsets, RW files),
    not a flat object array like the GA100 vBIOS license slots.
  - The function-table-driven mount layer (`FUN_ram_016abe4c` and
    neighbors) is the offline target that names the flash base and the
    sector size; resolving it turns a hardware dump from a search into a
    decode.
- **Related:** [the GSP-RM tools](../tools/gsp-rm-tools/README.md) hold the
  Ghidra path to those functions.

## 21.3 The dump paths that come back empty

**Question.** Do the packaged diagnostic paths hand back raw InfoROM bytes?

**Why.**

- `nvdump.h` defines an `ENG_INFOROM` dump component, and
  `nvidia-debugdump --dumpall` is the shipped client for it. If the GSP
  serves the component, the raw objects arrive with no flash access.

**Method.**

- Live, read-only: `nvidia-debugdump --dumpall` inside the wrapper; offline:
  zip census and protobuf string scan over the per-GPU `rm_*.pb`.

**Observed data.**

```text
dump.zip: system_info.pb error_data.pb nvlog.log rm_00.pb rm_01.pb
  debug_buffers_0{0,1}.pb (2 B) nvlog.gpu00{0,1}.log (1,378,684 B each)
rm_00.pb / rm_01.pb: no inforom strings, no ENG_INFOROM payload
verify-inforom control: 0x56 NV_ERR_NOT_SUPPORTED on GB202 GSP
nvlog rings: archived in analysis-tmp/c36/dd_extract/
```

**Result.**

- **Answer:** no raw InfoROM bytes from the packaged paths; the component is
  either unimplemented in GSP-RM or filtered from external builds.
- **What we learned:** the nvlog files in the same zip are the standard GSP
  log rings and are kept for a decode pass — if boot-time records survived
  the ring wrap, the inforom and HULK init trace is in them.
- **Related:** [the log decoder](../tools/gsp-rm-tools/README.md) consumes
  such rings through a manifest.
