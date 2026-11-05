# The nvflash read of the stock 5090s

## Summary

**The idea.**

- The public record ([the tool
  surface](23_public-inforom-record.md#231-the-tool-surface-and-its-blackwell-rejection))
  says nvflash carries object-level InfoROM commands and that Blackwell
  rejects some of them (`0x9F`). One read-only run answers, for our own two
  cards, which side of that gate each command lands on — and whether the
  `HLK` slot holds anything.
- I ran nvflash 5.867.0 (linux x64, TechPowerUp mirror, SHA-256 verified
  against the pinned hash) over both cards with a strictly read-mostly
  command set.

**What it found.**

- The base condition closes: `--rdhlk` executes the license read
  successfully on both cards and returns **zero bytes of certificate data**
  — the `HLK` object exists (version 2.0, [the
  battery](21_inforom-base-state.md#211-the-object-battery)) but the slot
  ships **empty**. The metadata block agrees: `License Placeholder: Not
  Present` ([24.1](#241-the-read-matrix)).
- Object reads work and return blank data: OBD is the factory template
  (`MarketingName: Generic`, serial `0`), OEM is 504 zero bytes — identical
  on both cards ([24.2](#242-the-stock-objects-are-factory-blank)).
- The gate splits by direction: reads succeed; the one write-path command
  in the set (`--backupinforom`) is rejected by the GSP (`Error code from
  uproc 01: 0x9F`), and whole-ROM `--save` reads its metadata but writes a
  0-byte image — the Blackwell nvflash bug the forums already
  reported ([24.1](#241-the-read-matrix)).

**What it did not find.**

- No certificate bytes (there are none), no ROM image (the 0-byte `--save`
  bug), and no ECID (`--ecid`: not supported on this GPU — a datacenter-part
  feature).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 24.1 | [The read matrix](#241-the-read-matrix) | Reads pass; writes `0x9F`; `--save` 0-byte; `--rdhlk` empty |
| 24.2 | [The stock objects are factory blank](#242-the-stock-objects-are-factory-blank) | OBD template, OEM zeros, identical cards |

## 24.1 The read matrix

**Question.** Which InfoROM commands does nvflash 5.867 get through on a
stock GB202, and what does the license read return?

**Why.**

- The public `0x9F` report covered one mobile card and one command class;
  our cards and the full object set had not been tried. The `--rdhlk`
  result is the base condition of the whole HULK path.

**Method.**

- Live, one sudo run of `analysis-tmp/c36/run_nvflash_read.sh` (2026-11-04,
  driver `595.91.07` loaded). Tool: nvflash 5.867.0 linux x64 from the
  TechPowerUp mirror flow, `sha256 73ab51e1…c80301` verified against the
  download page and the AUR PKGBUILD. Commands per adapter: `--ecid`,
  `--save`, `--backupinforom`, `--rdhlk`, `--rdulf`, `--rdupr`, `--rdobd`,
  `--rdoem`, `--rdccc`. All reads; `--backupinforom` is nominally a
  backup-region *write* (included as the gate probe — see the result), and
  it was aborted at its confirmation prompt by the script's closed stdin
  before the GPU rejected its read phase with `0x9F`; no write occurred.
- Args used:
```bash
sudo ./analysis-tmp/c36/run_nvflash_read.sh
```

**Observed data.**

```text
adapter <0> 10DE,2B85,19DA,1761 41:00.0   adapter <1> 10DE,2B85,1771,2059 c1:00.0
                     adapter 0            adapter 1            note
--ecid               not supported        not supported        rc 2
--save               rc 0, 0-byte file    rc 0, 0-byte file    metadata read OK
--backupinforom      0x9F from uproc 01   0x9F from uproc 01   write path, GSP-rejected
--rdhlk              rc 0, 0-byte .cert   rc 0, 0-byte .cert   "License Data saved"
--rdulf              not supported        not supported        rc 15
--rdupr              "License image is    "License image is    rc 0
                     not present"         not present"
--rdobd              298-byte CSV         298-byte CSV         identical md5
--rdoem              504-byte bin         504-byte bin         identical md5
--rdccc              needs .der ext       needs .der ext       not retried; metadata
                                                               says CEC blob absent

--save metadata (both cards):
  InfoROM Version    G005.0000.98.01
  InfoROM Backup     Not Present
  License Placeholder Not Present
  CEC OTA-signed Blob Not Present
  vBIOS 98.02.2E.00.AF (41) / 98.02.2E.40.53 (c1), Build Number 35336810 both
```

**Result.**

- **Answer:** on stock GB202 the object reads pass the GSP and return
  blank data; the license read succeeds and the slot is **empty**; write
  paths are refused (`0x9F`); whole-ROM save is broken in this build
  (metadata without image bytes — the 2026 forum report reproduced on our
  cards).
- **What we learned:**
  - The base state is complete: machinery alive, `HLK` object present at
    v2.0, **no certificate installed**, no license placeholder, no backup
    image, no CEC blob. An admitted certificate has an empty slot to land
    in and nothing to displace.
  - The read/write asymmetry maps the GSP gate precisely — the same gate
    the [debug-token](https://docs.rs/nv-redfish) world enforces elsewhere.
  - `--rdulf` "not supported on this GPU" versus `--rdupr` "not present"
    separates unsupported commands from absent objects — the same
    discrimination the RM battery made with `OBJECT_NOT_FOUND`.
  - 5.867 is the newest build that exists anywhere (checked Nov 2026:
    TechPowerUp still lists it as latest, two independent 2026 catalog
    checks agree, and the ASUS RTX-50 updater package ships 5.867.0
    itself), so the 0-byte `--save` and the `0x9F` rejections are
    properties of the current vendor toolchain, not version lag — both are
    independently reproduced by others in 2026. The only Blackwell
    progress is around it: GPU-Z 2.63.0+ (Windows) can save RTX 50 BIOS
    images, and community patches build on the same 5.867 base for
    flashing only.
- **Related:** [the base state](21_inforom-base-state.md#211-the-object-battery)
  is now read from both sides (RM and vendor tool); [the FS
  layer](22_inforom-filesystem-layer.md) describes the container the slot
  lives in.

## 24.2 The stock objects are factory blank

**Question.** What do the readable objects actually contain?

**Why.**

- The 5080-mobile sample showed a wiped InfoROM (headers intact, payloads
  zeroed); whether stock desktop cards carry programmed board data or a
  blank template decides what a hardware dump can add.

**Method.**

- Offline decode of the run artifacts (`obd_*.csv`, `oem_*.bin`).

**Observed data.**

```text
obd_1.csv (298 B, identical on both cards):
  BoardBuildDate,0,   MarketingName,Generic,   BoardSerialNumber,0,
  MemoryManufacturer/PartID/DateCode empty, Board*PartNumber empty,
  VbiosFactoryVersion,0000000000
oem_1.bin = oem_0.bin: 504 bytes, all 0x00 (the OEM v1 object minus its
  8-byte header, fully unprogrammed)
```

**Result.**

- **Answer:** the desktop 5090s ship the same shape as the wiped mobile
  sample: object headers present, payload blank. `MarketingName: Generic`
  is the template default the MODS factory flow complains about — these
  boards left the factory without InfoROM programming.
- **What we learned:**
  - The 5080-mobile "wipe" and our stock cards are indistinguishable at
    the object level — the mobile card's G-Sync loss more likely traces to
    the missing per-board objects than to a signature-bearing license.
  - The remaining payload a hardware dump could add is the container
    template (FS/sector structure around the empty objects) and the full
    flash map — not object data.
- **Related:** [the FS layer](22_inforom-filesystem-layer.md); [the mobile
  sample](23_public-inforom-record.md#232-corroboration-and-a-blackwell-sample).
