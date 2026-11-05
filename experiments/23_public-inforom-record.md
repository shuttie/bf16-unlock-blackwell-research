# The public InfoROM record

## Summary

**The idea.**

- Before the hardware read, survey what the public record already knows
  about InfoROM: the object formats, the tools that read or write it, the
  HULK license machinery, and practical flash-dump knowledge for modern
  GeForce boards.
- Four web sweeps over the sources below (470 results reviewed, validation:
  technical substance only), compiled in
  `analysis-tmp/c36/exa-inforom-research-2026-11-04.md`.

**What it found.**

- nvflash has had a first-class InfoROM surface all along — object
  read/write for OBD/OEM/ULF/UPR/HLK/CCC, whole-image save/repair, and the
  signed-license flow `--licreq … USER_FW_MOD` → `--wrhlk` — but on
  Blackwell every InfoROM subcommand is rejected (`0x9F`, GSP-gated)
  ([23.1](#231-the-tool-surface-and-its-blackwell-rejection)).
- Independent corroboration of our own readings: a 1050 Ti `--compare`
  printed an InfoROM of length exactly `0x5000`; GA100 puts the region at
  the top of flash outside the signed range; and a public RTX 5080-mobile
  nvflash dump carries Blackwell InfoROM filesystem headers — a sample to
  validate our decode offline ([23.2](#232-corroboration-and-a-blackwell-sample)).
- The lineage is public and named — GB200-era Redfish unlock tokens carry
  `NvlinkGlobalHulk`/`PxucGlobalHulk` subtypes, a US patent describes the
  architecture, and one real `USER_FW_MOD` attempt failed in firmware —
  but the `3AES` scheme, any BCRT2X/CERT20 field layout, and the Lapsus
  certs' byte structure remain unpublished; `UL_GLOB`/`LIC`/`ULF`/`UPR` as
  on-card objects appear nowhere public
  ([23.2](#232-corroboration-and-a-blackwell-sample)).

**What it did not find.**

- No third-party InfoROM parser, no published cert bytes, no working
  Blackwell InfoROM write path (community consensus: SPI write-back on the
  5090 does not work; verification runs on the GPU).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 23.1 | [The tool surface and its Blackwell rejection](#231-the-tool-surface-and-its-blackwell-rejection) | nvflash reads/writes every object; Blackwell returns `0x9F` |
| 23.2 | [Corroboration and a Blackwell sample](#232-corroboration-and-a-blackwell-sample) | `0x5000` length, top-of-flash layout, a 5080-mobile dump; `3AES`/BCRT2X/`UL_GLOB` still novel |

## 23.1 The tool surface and its Blackwell rejection

**Question.** Can existing software read the `HLK` slot, and what happens
on Blackwell?

**Why.**

- A software read beats a clip dump if it works; a documented rejection is
  the cheapest possible negative.

**Method.**

- Web survey (Exa, four sweeps). Sources: the nvflash help dump
  (pastebin.com/ytsncjEV and its mirrors), `notfromstatefarm/nvflash`
  issue #28 (50-series flashing mechanics, nvflash 5.867 from an ASUS
  updater EXE), the Level1Techs RTX 5080-laptop thread 248856, the NVIDIA
  developer-forums thread 263910 (a real `USER_FW_MOD` license attempt),
  `WillyBilly06/NVFLASH` issue #3, the VLab `iromflsh` factory-workflow
  posts.

**Observed data.**

```text
nvflash object ops: --rdobd/--wrobd --rdoem/--wroem --rdulf/--wrulf
  --rdhlk/--wrhlk/--rmhlk ("install unlock license into EEPROM")
  --rdupr/--wrupr --rdccc/--wrccc  | image ops: --save <f>.ifr
  --flashinforom --backupinforom --recoverinforom --repairfs
  --mergeinforom --reallocateglob --ignoreinforom
license flow: --licreq=LicenseRequest.bin USER_FW_MOD
  -> --wrhlk=License.hulk -> --license=License.hulk vbios.rom
Blackwell: every InfoROM subcommand -> Error 0x9F (command rejected);
  firmware verification now runs on the GPU itself
USER_FW_MOD attempt (dev forums 263910): PMU refused devinit on a modded
  vBIOS "because certificate check"; --licreq failed (error 7)
VLab: factory iromflsh merges .ifr + OBD CSV into a ROM before flashing;
  a whole-chip SPI swap did NOT clear a MODS OBD error
```

**Result.**

- **Answer:** the vendor's own toolchain reads and writes the slot on older
  parts, the request-sign-install flow is user-facing in principle, and on
  Blackwell the door is closed at the GSP — exactly the boundary our other
  results found.
- **What we learned:** the `0x9F` rejection is itself evidence the InfoROM
  partition is deliberately guarded on Blackwell, and `--repairfs` plus
  `--reallocateglob` independently confirm the filesystem model this
  project reversed from the firmware.
- **Related:** [the FS layer](22_inforom-filesystem-layer.md) is the thing
  nvflash's `--repairfs` repairs; [the base state](21_inforom-base-state.md)
  is what `--rdhlk` would return on an older part.

## 23.2 Corroboration and a Blackwell sample

**Question.** Does anything public already match, extend, or preempt our
format readings?

**Why.**

- Every independently-published constant that matches our reversing is a
  correctness check on it; every absence marks ground only this record
  covers.

**Method.**

- Web survey. Sources: overclockers.com thread 799535 (1050 Ti
  `--compare` output), the nvlight GA100 gist (pinned locally in
  `analysis-tmp/c38/dl`), the nova driver VBIOS docs, the NVIDIA developer
  forums thread 366444 (RTX 5080 mobile, attached `RM203.rom` dump), the
  nv-redfish `TokenSubType` schema, US Patent 11880466, the
  open-gpu-kernel-modules `kernel_gsp_fwsec.c`, and the vGPU unlock record
  (`DualCoder/vgpu_unlock`, HN 26754351, `bird/vgpu-unlock-blackwell`).

**Observed data.**

```text
1050 Ti nvflash --compare: "Final InfoROM offset 0x00039600 (0x0003A000)
  with length 0x00005000"        <- matches FS v1 size 0x5000 (exp 22.1)
GA100 layout: InfoROM 0xC0000-0xFFFFF, unsigned, license region 0xFE000
nova docs: IFR header recipe (0xAA55 sentinel, v3 TOTAL_DATA_SIZE+4096,
  "RFRD" directory, ROM base BAR0+0x300000)
RTX 5080 mobile dump (dev forums 366444): InfoROM FS headers intact
  (OEM, OBD, PTD), payloads zeroed, image version G005.0000.98.01
  — same image family as our 5090s; attachment downloadable
Redfish TokenSubType: NvlinkGlobalHulk, PxucGlobalHulk, EccUnlock,
  Bar0decouplerUnlock, I2cVregUnlock, JtagEnable (99 subtypes, GB200 era)
US Patent 11880466: signed license certs, SKU/ECID, virtual fuses +
  register-bit modifications, security-processor verify
bird/vgpu-unlock-blackwell (GB202, 595.58.03): GRID and consumer drivers
  ship byte-identical nv-kernel.o and gsp_ga10x.bin; GSP dies on fused-off
  VF PRIV regs (0x111424 reads 0xBADF)
absent from public record: 3AES scheme, BCRT2X/CERT20 layouts, Lapsus
  cert bytes, UL_GLOB/LIC/ULF/UPR as on-card objects, any vGPU<->InfoROM
  linkage (all public vGPU licensing is host/guest-side)
```

**Result.**

- **Answer:** the public record corroborates our sizes and layout, supplies
  one downloadable Blackwell InfoROM sample to validate the decode against,
  and leaves the certificate format and the usage-limit objects exactly
  where this project found them — unpublished.
- **What we learned:**
  - The 5080-mobile dump is the cheapest possible decode validator: same
    image family (`G005.0000.98.01`), headers intact, zeroed payloads —
    and it names a `PTD` object type our registry census did not have.
  - The HULK lineage runs unbroken from the GA100 license region through
    nvflash's object commands to GB200 Redfish tokens, which ties the
    [debug-token gating](https://docs.rs/nv-redfish) memory into this path.
  - The GB202 vGPU work independently confirms the driver-blob identity
    across GRID/consumer builds and adds a fused VF-privilege register
    (`0x111424`) worth a read on our cards.
- **Related:** [the HULK certificate path](../IDEAS.md#hulk-certificate-path)
  carries the next runs; the full bibliography is in
  `analysis-tmp/c36/exa-inforom-research-2026-11-04.md`.
