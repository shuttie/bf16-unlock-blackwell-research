# The debugger class and the FECS ucode: what the host can read

## Summary

**The idea.**

- JTAG was the first target. The public production-debug controls gate it with
  secure-debug fuses and signed unlock tokens (`JtagUnlock`, `NvJtagControl`,
  `HardwareUnlock`); no public GeForce JTAG success exists. The GB202 class
  list instead exposes `GT200_DEBUGGER` (`0x83de`), the host-facing SM debugger
  class.
- The FEAT read and the dropped write are in [the register-write
  group](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it).
  This group covers the class exposure, the spaces the RM path could not read,
  and the vBIOS FECS/GPCCS bodies.

**What it found.**

- The class is in the 117-class list, and CUDA allocates it under the device
  with the CUDA client and a `BLACKWELL_COMPUTE_B` (`0xcec0`) child
  ([the class](#101-the-class-is-exposed-and-allocatable)).
- The debugger reads the GR-context space and the `0x137000` block; the RM path
  rejected the per-context read. There is no FEAT-selector mirror; the only
  rate register is the inert `0x504204 = 5`
  ([the context and descriptor
  spaces](#102-the-context-and-descriptor-spaces-read)).
- `0x137200` reads `0xc120048a`; the FECS log pairs it with `0x14252215` and
  the refusal
  [`0xbadf5128`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)
  ([the same record](#102-the-context-and-descriptor-spaces-read)).
- The four vBIOS bodies are extracted. The two target-`0x01` bodies share a
  plaintext FUC header and differ at the `+0x08` field (the likely code size);
  the target-`0x0E` body carries the PLM data; the code is encrypted
  ([the bodies](#103-the-vbios-fecsgpccs-bodies)).

**What it did not find.**

- No FEAT write path. The benign write returns success and the
  [PLM](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
  drops it ([the write
  test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- No Heavy Secure memory read. The FSP and GSP apertures return the same
  sentinels as the host path
  ([the sentinels](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)).
- No FECS/GPCCS plaintext. The FUC5 field layout and the app/target-to-loader
  map are open ([the bodies](#103-the-vbios-fecsgpccs-bodies)).
- No selector copy in the GR-context space; the `0x504204` write remains inert
  ([the context and descriptor
  spaces](#102-the-context-and-descriptor-spaces-read)).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 10.1 | [The class is exposed and allocatable](#101-the-class-is-exposed-and-allocatable) | `0x83de` in the 117-class list |
| 10.2 | [The context and descriptor spaces read](#102-the-context-and-descriptor-spaces-read) | `0x504xxx` and `0x137000` live |
| 10.3 | [The vBIOS FECS/GPCCS bodies](#103-the-vbios-fecsgpccs-bodies) | FUC headers, encrypted code |

## 10.1 The class is exposed and allocatable

**Question.** Is `GT200_DEBUGGER` exposed on GB202, and how does a valid debugger
object get created?

**Why.**

- The JTAG pads are gated: production parts carry secure-debug fuses and
  signed unlock tokens, and no public GeForce JTAG success exists. The class
  list is the cheap alternative check.
- A debugger object needs a compute or 3D class object whose parent is a
  channel. The CUDA driver builds that context at `cuCtxCreate`.
- What it would give: a host-facing debug object, or proof the class is absent
  or blocked.

**Method.**

- Tools: a userspace RM probe for the class list and the allocation ladder, and
  an `LD_PRELOAD` hook that logs the CUDA driver's `NV_ESC_RM_ALLOC` and
  `NV_ESC_RM_CONTROL` calls.
- Target: `41:00.0`, idle, stock driver.
- Steps:
  - Allocate a client, device, and subdevice; query
    `NV0080_CTRL_CMD_GPU_GET_CLASSLIST`.
  - Allocate `GT200_DEBUGGER` with `hClass3dObject` NULL, then with the
    subdevice handle.
  - Run `cuInit`/`cuCtxCreate` under the logger and capture the sequence the
    CUDA driver uses for its own debugger object.
- Args used:
```text
GET_CLASSLIST        0x00800201
GT200_DEBUGGER       0x000083de
alloc                hAppClient=caller hClass3dObject=NULL | subdevice
```

**Observed data.** The class list reports 117 classes and includes `0x83de`.
Both incomplete debugger allocations return `0x36`
(`NV_ERR_INVALID_OBJECT_PARENT`); the constructor is reached, and the missing
piece is the compute object.

The capture shows the hierarchy the driver uses:

```text
device              0x5c00000a  parent client
channel group       0x5c00001d  class 0xa06c  parent device
channel             0x5c000024  class 0xc96f  parent group
compute             0x5c000025  class 0xcec0  parent channel
debugger            0x5c00007f  class 0x83de  parent device
  params            0x00000000  hAppClient=<CUDA client>  hClass3dObject=0x5c000025
```

The class list also carries `FERMI_VASPACE_A` (`0x90f1`),
`BLACKWELL_CHANNEL_GPFIFO_A` (`0xc96f`), and `BLACKWELL_COMPUTE_B`
(`0xcec0`).

**Result.**

- **Answer:** the class is exposed and host-allocatable; a valid object needs a
  compute class object under a channel.
- **What we learned:**
  - `GT200_DEBUGGER` is one of the 117 classes on GB202.
  - An incomplete allocation reaches the constructor and fails with
    `NV_ERR_INVALID_OBJECT_PARENT`; a missing class would fail earlier.
  - The CUDA driver allocates its own debugger under the device with the CUDA
    client and a `BLACKWELL_COMPUTE_B` child; that object is usable.
  - Rebuilding the context from scratch needs the channel's GPFIFO, userd, and
    notifier memory. I used the driver's object instead.
- **Related:**
  - [The FEAT read and the dropped
    write](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it).
  - [The per-context
    rejection](../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel).

## 10.2 The context and descriptor spaces read

**Question.** Can the debugger read the GR-context space and the `0x137000`
block that the RM path rejected, and is there a selector copy or a rate lever
there?

**Why.**

- `GR_CTX`, `TPC`, `SM`, and `QUAD` returned `0x1f` with every subdevice route
  ([the per-context
  probe](../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).
  The debugger object has the channel context the RM path lacked.
- The GSP log showed a refused PL2 access at `0x137200`
  ([the sentinel
  analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis));
  the debugger may read the register and its block.
- What it would give: a per-context read path, or proof the space is live but
  not a selector.

**Method.**

- Tool: the same `LD_PRELOAD` hook;
  `NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS` (`0x83de031d`) on the driver's debugger
  object.
- Target: `41:00.0`, idle.
- Steps:
  - Read `0x504000`–`0x5042ff` with `regType=GR_CTX` (`0x01`); read
    `0x504240`–`0x5042cc`.
  - Read `0x137000`–`0x137fff` with `regType=GLOBAL`.
  - Read `0x137200` with the `GR_CTX`, `TPC`, `SM`, and `QUAD` types.
  - Read the FSP, GSP, and SEC2 apertures as controls.
- Args used:
```text
read  type=GR_CTX  00504000..005042ff
read  type=GR_CTX  00504240..005042cc
read  type=GLOBAL  00137000..00137fff
read  type=GR_CTX  00137200
read  type=GLOBAL  008f0000 008f03d0 001113d0 008403c4
```

**Observed data.** The GR-context reads succeed. The known
[`SM_ISSUE_RATE_MODIFIER`](../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)
is `0x504204 = 5`; the space has no copy of `READOUT_1 = 0xc36180`
([the readout decode](../specs/03_register-map.md#readout-decode)). The values
include:

| Offset | Value | Note |
|---|---|---|
| `0x00504204` | `5` | the inert rate modifier |
| `0x00504048` | `0x10202e00` | context identity |
| `0x0050404c` | `0x001002b9` | context identity |
| `0x00504100` | `0xffffffcf` | PLM, write PL2+PL3 |
| `0x00504180`–`0x005041fc` | `0xbadf1002` | 32 dwords, not in the sentinel table |
| `0x00504240` … `0x00504280` | `0x42` × 8 | 8-byte stride |
| `0x00504264` / `0x00504270` / `0x00504288` | `0x20` / `0x4045` / `0x45` | table anomalies |
| `0x005042cc` | `0xffffffcf` | PLM, write PL2+PL3 |

The `TPC`, `SM`, and `QUAD` reads at `0x504204` return `regStatus=2`
(invalid type); `GR_CTX` succeeds.

The secure apertures did not open: `FSP 0x8f0000` and `0x8f03d0` read
`0xbadf5620`, `GSP 0x1113d0` reads `0xbadfffff`, and `SEC2 0x8403c4` reads
`0xb0f` ([the sentinels](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)).

The `0x137000` block is readable and structured:

- A `0x30`-byte entry pattern: the triples `0x16`, `0x14b01`, `0x41` at
  `0x137000`, `0x137030`, `0x137060`, `0x1370d0`, `0x137130`, with
  `0xbadf5040` gaps.
- `0x137100`–`0x13711c`: `0x400` × 8.
- `0x137200 = 0xc120048a`, `0x137204 = 0x178`, `0x137208 = 1`,
  `0x13720c = 0x5590c834`, `0x137210 = 0x08759a39`, `0x137214 = 0x80000400`.
- `0x1377e0`–`0x137fff` carries the PLMs: `0xfffffb8f` (write PL3 only),
  `0xfffffbcf` (write PL2+PL3), `0xfffffbff`, and the `0x84eb8f`/`0x84ebcf`
  variants.
- `0x137f20 = 0x130f5985`, `0x137f24 = 1`, `0x137f28 = 2`.

The GSP log record `0x20471930` in the FECS handler carries
`[0, 0x137200, 0, 0x14252215, 0xbadf5128]`: the access at `0x137200` was
refused, and the record pairs it with `0x14252215`
([the sentinel](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)).

**Result.**

- **Answer:** both spaces are readable through the debugger; neither carries a
  selector copy or a rate lever.
- **What we learned:**
  - `GR_CTX` reads the space the subdevice path rejected; `TPC`/`SM`/`QUAD`
    still return an invalid-type status.
  - The only rate register in the space is the inert `0x504204 = 5`; the
    `0x504240` table is an 8-byte-stride mask table, not the selector.
  - `0x504100` and `0x5042cc` are PLMs with write PL2+PL3; the `0xbadf1002`
    sentinel marks a protected or undecodable sub-block.
  - `0x137200` is a privilege-protected FECS/GR register, not a FEAT word. It
    reads `0xc120048a`; the FECS log pairs it with `0x14252215` and the refusal
    `0xbadf5128`.
- **Related:**
  - [The per-context
    rejection](../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel).
  - [The FEAT read and
    write](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it).
  - [The FECS bodies](#103-the-vbios-fecsgpccs-bodies).
- **Open question:** what descriptor `0x137200` belongs to, and what the
  `0x30`-byte entry pattern enumerates; the FECS ucode should name both.

## 10.3 The vBIOS FECS/GPCCS bodies

**Question.** Which vBIOS microcode bodies are the FECS/GPCCS consumer, and what
do their headers expose?

**Why.**

- The vBIOS carries four encrypted ucode images, the likely FECS/GPCCS consumer
  ([the microcode table](../specs/05_vbios-and-devinit.md#microcode-table)).
- The FMC key search targeted the FMC and the SEC2 booter, not these bodies
  ([the key
  search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).
- What it would give: the shapes to map to the GSP-RM loaders and the first
  structural test of the FUC5 container.

**Method.**

- Tools: a byte-level extractor and entropy/repeat counter.
- Target: the card's 1 MiB flash dump; the 2 MiB aperture was compared and is
  not a linear copy.
- Steps:
  - Extract the four body ranges from the microcode table
    ([the table](../specs/05_vbios-and-devinit.md#microcode-table)).
  - Compute entropy, repeated 16-byte blocks, and zero blocks.
  - Parse the first `0x30` bytes of each body as little-endian words.
- Args used:
```text
body app07/tgt06  0x6fdf0-0x8fff0
body app19/tgt01  0x90040-0xb1b40
body app15/tgt01  0xb1c80-0xb7780
body app23/tgt0e  0xb780c-0xd5a0c
```

**Observed data.**

| Body | Length | Entropy | First words |
|---|---:|---:|---|
| `app07`/`tgt06` | `0x20200` | 7.999 | no plaintext header |
| `app19`/`tgt01` | `0x21b00` | 7.999 | `01 00 35 00 a7 47 00 00` |
| `app15`/`tgt01` | `0x5b00` | 7.992 | `01 00 35 00 a7 47 00 00` |
| `app23`/`tgt0e` | `0x1e200` | 6.496 | `01 00 1d 00 f4 09 04 00` |

The two target-`0x01` bodies share the header and differ at `+0x08`
(`0x17eb0` for `app19`, `0x57c0` for `app15`); both read `0x4bd` at `+0x0c` and
`0x1100` at `+0x10`. `app23` has a different header (`0x1d`
header size) and the plaintext data tail: `0x10000` bytes of encrypted code, a
`0x7f4`-byte header, and `0xda0c` bytes of data at entropy 2.818, carrying the
`0xFFFFFB8F`/`0xFFFFFBFF` PLM data
([the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)).

The 2 MiB aperture is not the linear image: at the same offsets `app07` and
`app19` are sparse (entropy 3.995 and 4.748) and `app23`'s data tail is
high-entropy. The 1 MiB dump is the image the table describes.

**Result.**

- **Answer:** the two target-`0x01` bodies are the likely FECS/GPCCS pair, and
  their headers are plaintext; the code is encrypted.
- **What we learned:**
  - `app19` and `app15` share the FUC header (`01 00 35 00 a7 47 00 00`) and
    differ mainly at `+0x08`, the likely code-size field.
  - `app23` is the PLM-bearing image; its plaintext data tail matches the
    documented PLM values.
  - `app07` has no plaintext header.
  - The FUC header is version 1, header size `0x35`, with `0x47a7` and the
    code/data fields; the exact FUC5 field layout is not in the open source.
- **Related:**
  - [The microcode table](../specs/05_vbios-and-devinit.md#microcode-table).
  - [The key
    search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).
- **Open question:** the app/target-to-loader map in the GSP-RM, and whether the
  encrypted bodies share the FMC key family.
