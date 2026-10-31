# GB202 register map

## At a glance

- **Scope.** The GB202 register blocks: chip and boot targets, FUSE/OTP, FEAT,
  FECS, SM/GR, GSP Falcon, PRISCV, FSP, SEC2, PMU/CMS2, and the bad-read
  sentinels.
- **Bench.** Two RTX 5090s (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  and one RTX PRO 6000 Blackwell reference (same GB202 die, `10de:2bb1`,
  615.71.09). All offsets are BAR0 byte offsets; the 5090 values are stock
  unless the row says per-card, per-boot, or unresolved.
- **Evidence.** Measured values link to the experiment that produced them.
  Cross-part values come from the public survey in [the external
  corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus),
  except the PRO 6000 column, which is measured ([the reference
  dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump));
  fields described as analogy are carried over from Ada/Ampere.
- **Terms.** PL0, PL2, and PL3 are the host, GSP-RM, and boot-firmware privilege
  levels; a PLM is a per-block read/write permission mask; EMEM is external
  memory; ICD is the in-circuit debugger. The boot-chain and privilege specs
  define the rest.

**The short version.**

- The FUSE shadow is read-only from PL0 and PL2; a PLM value is not a
  writability oracle.
- The FEAT bank has one write gate, `FEAT_OVR_PLM`, and it admits PL3 writes
  only.
- A PRO 6000 reads all-zero selectors and all-zero arithmetic speed fuses; its
  FEAT bank keeps the same PL3-only write gate.
- `SM_ISSUE_RATE_MODIFIER` is writable but reasserted at context init and inert.
- FECS has a writable doorbell (`0x409800`) but no selector field.
- The GSP Falcon and PRISCV blocks expose EMEM and a live ICD; the ICD reads the
  RM code segment, not secure memory.
- FSP is not a debug-port target; SEC2 is present but empty on GB20x.

**In this spec.**

- [Chip, WPR, and boot targets](#chip-wpr-and-boot-targets): `PMC_BOOT_0`, WPR,
  and the Ada payload targets.
- [FUSE and OTP](#fuse-and-otp): the fuse block, the page-0 mask, and cross-part
  fuse values.
  - [Cross-part fuse values](#cross-part-fuse-values)
- [FEAT bank](#feat-bank): the rate-control bank, its write gate, the readout
  decode, and per-card state.
  - [Write gate](#write-gate)
  - [Readout decode](#readout-decode)
  - [SS0 and SS1](#ss0-and-ss1)
  - [Other FEAT words](#other-feat-words)
  - [Cross-part FEAT values](#cross-part-feat-values)
- [FECS](#fecs): PLMs and the `0x409800` doorbell.
- [SM and GR](#sm-and-gr): the writable rate modifier, the `0x137000`
  privilege block, the admitted GR window, and the space above it.
- [GSP Falcon](#gsp-falcon): the Falcon block and its EMEM window.
- [PRISCV](#priscv): the RISC-V block, its partitions, and the ICD.
- [FSP](#fsp): the FSP block and the PFSP EMEM channels.
- [SEC2](#sec2): the SEC2 memory windows.
- [PMU and CMS2](#pmu-and-cms2): the remaining blocks.
- [Bad-read sentinels](#bad-read-sentinels): the `0xBADF` values and their
  classes.
- [Evidence map](#evidence-map)
- [Limits and open questions](#limits-and-open-questions)

Related specs and tools:

- [Privilege and rate control](02_privilege-and-rate-control.md)
- [Boot chain](01_boot-chain.md)
- [GSP RISC-V and PRISCV](06_gsp-riscv-and-priscv.md)
- [Memory and host access](07_memory-and-host-access.md)
- [Errors and logging](08_errors-and-logging.md)
- [Register access](../tools/register-access/) for the driver-mediated map
- [Direct probe](../tools/direct-probe/) for raw BAR0 reads

## Chip, WPR, and boot targets

| Offset | Name | Value / note |
|---|---|---|
| `0x00000000` | `PMC_BOOT_0` | `0x1b2000a1` on `41:00.0` |
| `0x001fa824` / `0x001fa828` | WPR2 low/high | firmware reservation |
| `0x001fa7cc` / `0x001fa7c4` | `WPR_CFG` / WPR PLM | Ada payload targets |
| `0x009a0148` | FBPA PLM | Ada payload target |
| `0x00840000` | SEC2 block | secure boot engine |

The `PMC_BOOT_0` value and the WPR targets are from [the boot-input
baseline](../experiments/05_fmc-fsp-boot-inputs.md#053-boot-input-baseline-and-the-ordinary-fmc-path)
and [the cold-boot/FLR
comparison](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr);
the Ada targets are carried over from Ada/Ampere. The boot-time WPR/FRTS layout
is in [memory and host access](../specs/07_memory-and-host-access.md); the boot
flow that consumes these registers is in [boot chain](01_boot-chain.md).

## FUSE and OTP

Block `0x820000`–`0x8207ff`.

| Offset | Name | Value / note |
|---|---|---|
| `0x00820000` | `FUSECTRL` | fuse controller |
| `0x00820040` | `FUSE_EN_SW_OVERRIDE` | software override enable; `1` on consumer Ampere, `0` on A100/170HX; not read on GB202 |
| `0x0082007c` | `DISABLE_FUSE_PROGRAM` | fuse programming disable |
| `0x00820084` | `FUSE_DIS_SW_OVR` | `1` on the sampled Ampere parts; not read on GB202 |
| `0x008200d0`, `d8`, `dc`, `f8` | PLM-shaped | `0xfffffb8f` (read all / write L3) |
| `0x008200d4`, `e8`, `ec`, `f0` | PLM-shaped | `0xfffffbfc` (read L2–L3 / write all) |
| `0x008200e0`, `e4`, `f4` | PLM-shaped | `0x00800b8f` (read all / write L3) |
| **`0x008200fc`** | `FUSE_SS_PLM` (page-0 mask) | **`0xfffffbff`**; reads as write-all, but it is not the effective gate |
| `0x00820224` | `FUSE_SS_DP` | `0` |
| `0x0082038c` | `SECURE_FEAT_OVR_QUADRO_WR_SEC` | Quadro secure write; `1` on the sampled Ampere parts; not read on GB202 |
| `0x008203f0` | `FUSE_FEAT_OVR_DIS` / `OPT_FEATURE_FUSES_OVERRIDE_DISABLE` | `0`; the override is not permanently disabled |
| `0x0082059c` | `FUSE_SS_FFMA` | `0` |
| `0x0082074c` | `OPT_SECURE_GSP` / `..._DEBUG_DIS` | `1`; writes dropped from PL0 and PL2 |
| `0x008207d4` | `FUSE_SS_FMLA16` | `0` |
| **`0x008207d8`** | **`FUSE_SS_FMLA32`** | **`3`**; writes dropped from PL0 and PL2 |
| `0x008207dc` | `FUSE_SS_IMLA0` | `0` |
| `0x008207e0` | `FUSE_SS_IMLA1` | `3` |
| `0x008207e4` | `FUSE_SS_IMLA2` | `3` |
| `0x008207e8` | `FUSE_SS_IMLA3` | `0` |
| `0x008207ec` | `FUSE_SS_IMLA4` | `3` |

The fuse shadow is soft-read-only from both PL0 and PL2, even where the PLM says
otherwise; a PLM value is not a writability oracle. See [the fuse and rate-modifier
test](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier).

The override-enable fuses were not read on the 5090 or the PRO 6000. On Ampere
consumer parts `FUSE_EN_SW_OVERRIDE` reads `1`, `FUSE_DIS_SW_OVR` reads `1`, and
`FUSE_FEAT_OVR_DIS` reads `0`; on A100 and the 170HX `FUSE_EN_SW_OVERRIDE` reads
`0`. The cross-part survey reads the override path as architecturally available
but requiring Falcon HS ([the external
cross-check](../experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).

Sentinel `0xBADF510C` clusters at `0x820158`–`0x8201ec`, `0x8204a8`–`0x8204b0`,
and `0x820578`; page 4 `0x824100`–`0x8241cc` reads a uniform `0x00000002`, and
`0x8240fc` is a sentinel ([the sentinel
analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis)).

### Cross-part fuse values

| Fuse | A100 | Consumer Ampere | GB202 / GB203M | PRO 6000 |
|---|---:|---:|---:|---:|
| `FUSE_SS_FMLA32` | **0** | `1` | **`3`** | **`0`** |
| `FUSE_SS_IMLA4` | **0** | `1` | **`3`** | **`0`** |
| `FUSE_SS_IMLA2` | **0** | `0` | **`3`** | **`0`** |
| `FUSE_SS_IMLA1` | **0** | `0` | **`3`** | **`0`** |
| all other `FUSE_SS_*` | **0** | `0` | `0` | **`0`** |

The A100, Consumer Ampere, and GB203M values come from a public cross-part
survey reproduced in [the external
corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus);
the PRO 6000 column is measured ([the reference
dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
A100 is a full-rate part and reads zero on every arithmetic speed fuse; both PRO
6000s read the same zeros on GB202. Consumer Ampere reads `1` on
`FMLA32`/`IMLA4`; Ada reads `1` on `FMLA32`/`IMLA4` and `IMLA2`. The consumer
GB202 reads `3` on `FMLA32`/`IMLA1`/`IMLA2`/`IMLA4`. The Blackwell code→rate law
is not proven for the nonzero values; see [privilege and rate
control](../specs/02_privilege-and-rate-control.md).

## FEAT bank

Block `0x823800`–`0x8238b0`.

| Offset | Name | GB202 value / note |
|---|---|---|
| `0x00823800` | `FEAT_OVR_ECC_PLM` | `0xfffffb8f`; alias or second copy of the PLM (unresolved) |
| `0x00823804` | `FEAT_OVR_PLM` | `0xfffffb8f`; read all / **write L3 only** |
| `0x00823808` | `FEAT_OVR_QUADRO` | `0x01000280` (`41:00.0`) / `0x01000380` (`c1:00.0`); per-card bit 8, classification not rate |
| `0x0082380c` | `FEAT_OVR_ECC` | `0x00888888`; consumer-GA10x stock ECC override; writes dropped |
| `0x00823810` | `FEAT_OVR_ECC_1` | `0x002a2aaa` |
| `0x00823814` | `FEAT_READOUT_0` | `0x00000233`; bit 16 = ECC enablement (0 here) |
| `0x00823818` | `FEAT_READOUT_1` | `0x00c36180`; eight 3-bit selectors plus DP |
| `0x0082381c` | `FEAT_OVR_SM_SS0` | `0x21240001` (`41:00.0`) / `0x54226037` (`c1:00.0`); runtime state |
| `0x00823820` | `FEAT_OVR_SM_SS1` | `0x00000002` (`41:00.0`) / `0x00026005` (`c1:00.0`); runtime state |
| `0x00823824` / `28` / `2c` | `FEAT_OVR_ROW_REMAP` / `FEAT_READOUT_2` / `FEAT_OVR_ECC_2` | `3` / `1` / `0xa`; identical to the RTX 3090 Ti triple |
| `0x00823840` / `44` | counters | `8` / `3` |
| `0x008238b0` | ID/version | `0x12800541` |

Unimplemented offsets: `0x823858`, `0x823874`, `0x823898`, `0x82389c`, `0x8238b8`
and above return `0xBADF5040`. The bank map and the failed write are from [the
whole-bank test](../experiments/01_software-register-writes.md#013-the-whole-feat-bank-shares-one-gate);
the `0x82380c` identity is from [the external
corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus).

The CUDA debugger class (`GT200_DEBUGGER`, `0x83de`) reads the same words and
its FEAT write is dropped by the same gate ([the debugger
test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).

The 5090 values above are the stock consumer map. The measured PRO 6000 reads
the same `0x823800`/`0x823804` PLMs (`0xfffffb8f`) and `0x82380c`
(`0x00888888`); the words that differ are in [the cross-part
table](#cross-part-feat-values). Its ID at `0x8238b0` is per-card:
`0x1c5f331f` on one card and `0x0db4b1c3` on the second
([the reference
dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

### Write gate

`FEAT_OVR_PLM` is the gate for the whole bank. The field layout matches NVIDIA's
public Falcon v4 register header, including
`WRITE_PROTECTION_ONLY_LEVEL3_ENABLED 0x00000008` and
`SOURCE_ENABLE_ALL_SOURCES_ENABLED 0x000fffff`
([dev_falcon_v4.h](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/inc/swref/published/nvswitch/ls10/dev_falcon_v4.h)).
The FEAT block is not a Falcon register file, so the match removes the
field-name guess without proving the bank is a Falcon PLM.

| Bits | Field | `0xfffffb8f` | Ada `0xffffff8f` |
|---|---|---|---|
| `3:0` | `READ_PROTECTION` | `0xf` (all levels) | same |
| `7:4` | `WRITE_PROTECTION` | `0x8` (L3 only) | same |
| `8` | `READ_VIOLATION` | report error | same |
| `9` | `WRITE_VIOLATION` | report error | same |
| `10` | `SOURCE_READ_CONTROL` | `0` = lowered | `1` = blocked |
| `11` | `SOURCE_WRITE_CONTROL` | `1` = blocked | same |
| `31:12` | `SOURCE_ENABLE` | `0xfffff` (all 20 sources) | same |

The only gate is the write mask, `[7:4] = 8`, i.e. PL3. There is no removed source
and no hidden source-enable field. Bit 10 differs from Ada in the read-side
control, not the writer. See [the mask
decode](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only).

### Readout decode

`FEAT_READOUT_1 = 0x00c36180` packs eight 3-bit fields plus DP:

| Field | Bits | Stock value |
|---|---:|---:|
| `imla0` | `2:0` | `0` |
| `fmla16` | `5:3` | `0` |
| `fmla32` | `9:7` | **`3`** |
| `ffma` | `12:10` | `0` |
| `imla1` | `15:13` | **`3`** |
| `imla2` | `18:16` | **`3`** |
| `imla3` | `21:19` | `0` |
| `imla4` | `24:22` | **`3`** |
| DP | `30:28` | `0` |

A PRO 6000 reads `0x00000000`: every field is zero. That is the measured
full-rate reference for this decode ([the reference
dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

Bit 6 is the alternate ninth byte, not an unexplained gap ([the static
FEAT/FSP pass](../experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp)).
The decoder is a per-chip HAL method that reads fuse HAL offset `0x3818`; the
GB202 implementation constant is `0x02`, outside the `{5..9}` twin set, so the
`0x3818` decoder is installed ([the HAL
decoder](../experiments/07_plaintext-corpus.md#078-the-decoder-is-installed-by-the-hal)).

### SS0 and SS1

The two words are runtime state, not per-part fuses:

| Card | `SS0` samples across cold boots | `SS1` samples |
|---|---|---|
| `41:00.0` | `0x21240001`, `0x20240001`, `0x20260041`, `0x21265047`, `0x21265043` | `0x00000002`, `0x00000006` |
| `c1:00.0` | `0x54226037`, `0x54224037`, `0x54225037`, `0x54226037` | `0x00026005`, `0x00024005` |
| PRO 6000 card A | `0x56664061` (one boot) | `0x00075005` |
| PRO 6000 card B | `0x00544047` (one boot) | `0x00000001` |

Every nibble has bit 3 clear on the 5090 samples and on the PRO 6000 snapshot, so
the override-enable fields are off and the fused selectors are in force. The
words are invariant within a boot and across warm
reboots; they move only across cold power cycles. They are already final before
the FMC runs, as [the FEAT-bank boot
test](../experiments/05_fmc-fsp-boot-inputs.md#0517-feat-bank-final-before-the-fmc)
and [the cold-boot/FLR
comparison](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)
show. The two PRO 6000 snapshots are one power-on each; the words differ across
cards, so a same-card cold-boot spread is still unsampled ([the reference
dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

An FLR leaves `SS0`/`SS1`, `0x823808`, and `READOUT_1` unchanged, but resets the
PLM pair to `0x80842bcf` (write mask L2+L3). A GPU-side devinit re-locks it to
`0xfffffb8f` before the first open ([the re-lock
test](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)).

### Other FEAT words

- `0x82380c = 0x00888888` is `FEAT_OVR_ECC`, the stock consumer ECC override, not
  a speed payload ([the external
  corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus)).
- `0x823810 = 0x002a2aaa` is `FEAT_OVR_ECC_1`.
- `0x823824/28/2c = 3/1/0xa` are `FEAT_OVR_ROW_REMAP`/`FEAT_READOUT_2`/
  `FEAT_OVR_ECC_2`, static feature words, not counters.
- The PRO 6000 reads `0xaa2a2aaa` at `0x823810` and `0x022aaaaa` at `0x82382c`.
  Those track its ECC feature set, not the rate selector.

### Cross-part FEAT values

| Register | Offset | GB202 | Consumer GA10x | A100 | RTX 3090 Ti | PRO 6000 (GB202) |
|---|---|---:|---:|---:|---:|---:|
| `FEAT_OVR_ECC_PLM` | `0x823800` | `0xfffffb8f` | `0xffffff8f` | `0xffffff8f` | `0xffffff8f` | `0xfffffb8f` |
| `FEAT_OVR_PLM` | `0x823804` | `0xfffffb8f` | `0xffffff8f` | `0xffffff8f` | `0xffffff8f` | `0xfffffb8f` |
| `FEAT_OVR_QUADRO` | `0x823808` | `0x01000280` / `0x01000380` | varies | `0x00000080`–`0x01100080` | `0x01000383` | `0x01900888` |
| `FEAT_OVR_ECC` | `0x82380c` | `0x00888888` | `0x00888888` | `0x00000100`–`0x00110111` | `0x00888888` | `0x00888888` |
| `FEAT_OVR_ECC_1` | `0x823810` | `0x002a2aaa` | `0x002aaaaa` | `0x00100400`–`0x00104104` | `0x00aaaaaa` | `0xaa2a2aaa` |
| `FEAT_READOUT_0` | `0x823814` | `0x00000233` | `0x00000233` | `0xef8ff100` | `0x00000233` | `0x00000300` |
| `FEAT_READOUT_1` | `0x823818` | `0x00c36180` | `0x00400080` | **`0x00000000`** | `0x00400080` | **`0x00000000`** |
| `FEAT_OVR_SM_SPD` | `0x82381c` | per-card | varies | varies | `0x30403100` | `0x56664061` (one boot) |
| `FEAT_OVR_SM_SPD_1` | `0x823820` | per-card | varies | varies | `0x00000004` | `0x00075005` (one boot) |
| `FEAT_OVR_ROW_REMAP` | `0x823824` | `0x3` | `0x1` | `0x0`/`0x1` | `0x3` | `0x3` |
| `FEAT_READOUT_2` | `0x823828` | `0x1` | `0x0` | `0x7` | `0x1` | `0x1` |
| `FEAT_OVR_ECC_2` | `0x82382c` | `0xa` | `0x8`/`0xa` | `0x0`/`0x1` | `0xa` | `0x022aaaaa` |

The GB202, Consumer GA10x, A100, and RTX 3090 Ti values are from the public
cross-part survey reproduced in [the external
corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus);
the PRO 6000 column is measured on card A ([the reference
dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump));
a second card reads the same `READOUT_1` and PLM/fuse values and differs in its
runtime and per-card words. The A100 SXM4 40 GB is the only `0x823800` outlier
at `0x0000abcf`. The A100 and the two PRO 6000s are the full-rate references:
`FEAT_READOUT_1 = 0` with every arithmetic fuse at `0`.

## FECS

Block `0x409000`–`0x409fff`.

The block is a sparse GR/FECS register/PLM block, not the Falcon core. 789 of
1024 dwords are `0xBADF5040`; the IMEM/DMEM ports at `0x409180`/`0x4091c0` return
sentinels; implemented registers begin around `0x409400`. See [the live FECS
probe](../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes).

The twelve standard FALCON offsets at this base (`0x000`, `0x004`, `0x040`,
`0x0f0`, `0x0f4`, `0x100`, `0x104`, `0x10c`, `0x198`, `0x19c`, `0x3c0`, `0x40c`)
return `0xBADF5040` except `0x40940c = 0x7ff`, so the block is not a falcon core
([the falcon probe](../experiments/11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).

| Offset | Name | Value / note |
|---|---|---|
| `0x00409600` / `624` / `65c` / `660` / `688` / `6d0` / `438` | FECS PLMs | `0x409660 = 0xfffffbef`; `0x409688 = 0xffffffcf`; `0x409438 = 0xffffffef`; `0x4096d0 = 0xffffffff`; writes dropped |
| `0x00409638` | implemented | `5` |
| `0x00409664` / `668` | selector/readout copies | `0xBADF5040`; unimplemented |
| `0x00409500` | command data | `0`; carries address/size words for context commands |
| `0x00409504` | command ID | `0xBADF5545`; read-blocked (PRI `0xBADF55`) |
| `0x00409700`–`784` | adjacent config | `0x30`, `0x40001010`, `0x8097cbff`, `0x658bba81`, … under the open `0x4096d0` PLM |
| `0x00409800` | command status/payload | **GSP-writable**; polled at `0x9800 + 4*param` |
| `0x00409b00` / `04` | DP/companion readout | `0x007e0f0a` in the first probe; `0x80000130` through the debugger class later; state-dependent |
| `0x00409b74` / `b7c` | implemented | `0xe8` / `0xfffffbff`, PLM-shaped |
| `0x00409b78` | implemented | `0` |

Probe summary:

| Probe | Host | GSP | Meaning |
|---|---:|---:|---|
| `0x409668` | `0xbadf5040` | `0xbadf5040` | unimplemented |
| `0x409660` | `0xfffffbef` | `0xfffffbef` | PLM: read all / write L1–L3 |
| `0x409688` | `0xffffffcf` | `0xffffffcf` | PLM: read all / write L2–L3, source bit 10 set |
| `0x409438` | `0xffffffef` | `0xffffffef` | PLM: read all / write L1–L3, source bit 10 set |
| `0x4096d0` | `0xffffffff` | `0xffffffff` | read/write all |
| **`0x409800`** | `1` | `1` | GSP-writable doorbell/status |
| `0x409b00` / `04` | `0x007e0f0a` | `0x007e0f0a` | DP/companion readout pair; a later debugger read returned `0x80000130` |
| `0x409b78` / `0x409638` | `0` / `5` | `0` / `5` | implemented |

The `0x409800` write lands because it sits under the fully open `0x4096d0` block;
the FECS PLM writes are silently dropped. The command protocol and the context
path are in [privilege and rate control](../specs/02_privilege-and-rate-control.md) and
the [FECS and GR context experiments](../experiments/03_fecs-and-gr-context.md).

## SM and GR

| Offset | Name | Value / note |
|---|---|---|
| `0x00504100` | GR PLM | `0xffffffcf`; read all / write PL2+PL3 |
| `0x00504180`–`0x5041fc` | GR window | `0xbadf1002`; FECS PRI timeout |
| `0x00504204` | `SM_ISSUE_RATE_MODIFIER` | `5`; writable from PL0/PL2, reasserted at context init, inert |
| `0x00829668` | candidate twin-getter base | `0xBADF1100`; outside the decodable window |
| `0x00009668` | candidate absolute offset | `0xBADF5040`; decodable, unimplemented |

The debugger-class sweep of `0x504000`–`0x5042ff` found no FEAT-selector mirror.
`0x504204` is the only rate register and it is inert; `0x504100` is the PLM
above; `0x504180`–`0x5041fc` return the timeout sentinel ([the debugger
test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).

`SM_ISSUE_RATE_MODIFIER` is the one rate-related register that is genuinely
writable, but it is reasserted at CUDA context creation and does not change the
measured rate. See [the fuse and rate-modifier
test](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier).
No host or GSP-RM code writes it; the value 5 comes from firmware/devinit or a
context restore.

### GR privilege block at 0x137000

| Offset | Name | Value / note |
|---|---|---|
| `0x000137000` | block | `0x30`-stride table |
| `0x000137200` | privilege register | `0xc120048a`; PL2 access refused with `0xbadf5128`; not FEAT |

The FECS log record `0x20471930` attempted `0x137200` with `0x14252215` and was
refused with `0xbadf5128` ([the sentinel
analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis)),
so the register is in the FECS/GR privilege space, not the FEAT bank. The exact
function is still open.

### GR window at 0x140000

The GSP-RM `gr_fecs` register filter admits `0x409b00`, `0x409b78`, and the
`0x140000`–`0x17ffff` range. The window is empty apart from a `0x10` marker at
each `0x2000` page start and a `0x100`-byte header at `0x140000`: `0x10`,
`0x70`, `0xc840`, `0x44`, two `0x49a40a0a`/`0xff053977` pairs, then
`0xffffffff` and `0x40000099`. The page at `0x17f000` is all zero. See [the GR
window probe](../experiments/11_falcon-and-gr-window-probe.md#112-the-admitted-gr-window-is-empty).

### GR space above the window

The space above `0x17ffff` is decode refusals, small blocks, one per-card
table, and a 2 MiB ROM window ([the GR
map](../experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom)):

| Range | Content |
|---|---|
| `0x180000`–`0x19d000` | `0xBADF1002`/`0xBADF1100` alternating in `0x2000` windows |
| `0x19e000`–`0x1bffff` | `0xBADF1100` |
| `0x1c0000`–`0x1c4fff` | `0x4c`-byte header, then `0xBADF5040` |
| `0x1c5000`–`0x1c7fff` | `0xBADF1100` |
| `0x1c8000`–`0x1cbcff` | `0xBADF1301` |
| `0x1cd000`–`0x1d6fff` | `0xBADF5040`, zero pages at `0x1d0000` and `0x1d4000`, `0x804407` at `0x1ce000`, `0x1d2000`, `0x1d6000` |
| `0x1d7000`–`0x1e2000` | `0xBADF5040` |
| `0x1e3000`–`0x1ef000` | `0xBADF1100` |
| `0x1f2000`–`0x1f3fff` | the per-card table below |
| `0x1f4000`–`0x1f5fff` | `0xffffffff` |
| `0x1f6000`–`0x1ff000` | markers; `0x7e59e2c` at `0x1f9000`, `0x80000000` at `0x1fe000` on card 0 |
| `0x200000`–`0x22bfff` | `0xBADF1002` |
| `0x22c000`–`0x22f9ff` | `0xBADF202B` |
| `0x230000`–`0x2fffff` | markers, with `0xffffffcc` words between `0x290000` and `0x2b5000` |
| `0x300000`–`0x4fffff` | the 2 MiB vBIOS PROM image, byte for byte |
| `0x500000` | `0x87fc029f`, `0x08000000`, `0x00010000`, then `0xBADF5040` |

The ROM window is the same aperture that holds the flash at BAR0 + `0x300000`
([where the flash sits](../specs/05_vbios-and-devinit.md#where-it-sits)). A dense
read of `0x310000` looks like memory because the vBIOS carries the encrypted
ucode bodies; the words match the PROM dump exactly. The debugger's GLOBAL read
is therefore a BAR0 read, not a separate GR address space.

### The per-card table at 0x1f2000

The block at `0x1f2000`–`0x1f3fff` is 32 records of `0x100` bytes with one
layout. Each record returns values at fixed word offsets and `0xBADF5040` at
`+0x28`–`0x38`, `+0x70`–`0x78`, `+0xa8`–`0xb8`, and `+0xf0`–`0xf8`; `+0xfc`
reads `3`. Record 0 is header-like (`0x1000`, `0x1000000`, `0xe000f096`,
`0xc0003600`, `0xf4278000`, `0x8`, `0x7`, `0x18390d`, `0x10005`) and has a few
runtime words; records 1–31 carry per-card values
([the block](../experiments/11_falcon-and-gr-window-probe.md#115-the-0x1f2000-block-is-a-per-card-table)).

- 1,155 non-zero words; 567 differ between the two local cards.
- The body is identical across a driver reload, so it is fused or built at
  init. A reboot test is missing.
- The sampled per-card words are not in either vBIOS dump or the GSP image, and
  the FEAT bank shares only generic constants.
- GLOBAL and `GR_CTX` read the same words; `TPC`, `SM`, and `QUAD` return
  `regStatus 2`.

The semantics are open. Nothing in the block matches a known rate, PLM, or
FEAT field.

## GSP Falcon

Block `0x110000`–`0x110d4c`.

| Offset | Name | Value / note |
|---|---|---|
| `0x00110008` | `IRQSTAT` | `0` |
| `0x001100f4` | `HWCFG2` | `0x818787f7`; bit 10 = RISC-V core |
| `0x00110108` | `HWCFG` | `0x80420100` |
| `0x0011012c` | `HWCFG1` | `0xc2101136`; bits 21:25 = 1 → 512-byte EMEM blocks |
| `0x00110180`+ | `IMEMC/D(i)` | `0xBADF5610`; no IMEM window on the RISC-V GSP |
| `0x001101c0`+ | `DMEMC/D(i)` | `0xBADF5610`; no DMEM window |
| `0x001103c0` | `FALCON_ENGINE` | `0x00000200` (deasserted); host-blocked while PRIV-locked |
| `0x001103c4` | `RESET_PRIV_LEVEL_MASK` | `0x00000f00`; level-0 enables clear |
| `0x00110abc` | EMEM geometry | `0x20` → 32 × 256 B = 8 KB |
| `0x00110ac0`–`0x110afc` | `EMEMC/D(0..7)` | 8 KB window; all zero at runtime |
| `0x00110b84` | GSP PLM | `0xffffff8f`; read all / write L3 only |

The debugger class reads `0x1100f0 = 0xf00` and `HWCFG2 = 0x818787f7`, and gets
`0xBADF5610` from `CPUCTL`, `BOOTVEC`, `DMACTL`, and `MAILBOX_TEST`. The core
control block stays host-unreadable ([the falcon
probe](../experiments/11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).

The Falcon block ends at `0x110d4c`; `0x110d50`–`0x110ffc` is unimplemented.
The PRISCV block starts at `0x111004` ([the PRISCV
map](../experiments/04_hs-sec2-fsp-memory.md#043-priscv-block-is-split-per-master)).
EMEM is real PL2-reachable storage and holds nothing; the FMC plaintext never
leaves Heavy Secure ([the GSP EMEM
test](../experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty)).
The debug entry points in the shipped driver are inert stubs returning
`NV_ERR_NOT_SUPPORTED`.

## PRISCV

Block `0x111000`–`0x1117ff`; offsets are relative to the base.

Values are the GSP (PL2) view unless marked host; "host-blocked" means
`0xBADF5720`.

| Offset | Name | Value / note |
|---|---|---|
| `0x00111004`–`0x111094` | core state | GSP-only; includes address-like values and a 16-byte run at `0x11106c` |
| `0x00111128` | PLM-shaped | `0x00000f00` |
| `0x001111a8`–`0x1111e4` | host-only table | 16 × `0x00000002` |
| `0x00111320` | PLM | `0xffffff8f`; read all / write L3 only |
| `0x00111324` | PLM | `0xffffff0f`; read all / write none |
| `0x00111328` | PLM | `0xffffffff`; read/write all |
| **`0x00111388`** | `PRISCV_CPUCTL` | `0x00000180`; halt `[4]=0`, active `[7]=1` |
| `0x001113d0`–`dc` | `ICD_CMD` / `ADDR0` / `ADDR1` / `+3dc` | host `0` (not blocked); GSP `0xbadfffff` |
| `0x001113e0`–`e8` | ICD data / reserved | `0` to both |
| **`0x001113ec`** | `PRISCV_RPC` | GSP `0x01404f66`; host `0x9300xxxx`, changes between reads |
| `0x00111400` | host-only control | host `0x51100000`; GSP `0xbadf5610` |
| `0x00111404`–`410` | trace registers (inferred) | GSP `0x003f0000` / `0x3c000000` / `0x0100287c` / `0`; host-blocked |
| `0x00111420`–`430` | `PRIV_ERR_STAT` / `ADDR` / `ADDR_HI` / `HUB_ERR_STAT` | `0`; `PRIV_ERR_INFO` is `0xbadf5040` |
| `0x00111514` / `51c` / `550` | PLMs | `0xffffff0f` / `0xffffffff` / `0xffffffff` |
| **`0x00111528`** / `52c` | `IRQMASK` / `IRQDEST` | `0x810490d2` / `0x010800d0` |
| `0x00111534` | `IRQDELEG` | `0xbadf5610`; no port |
| `0x00111700` | `FAULT_CONTAINMENT_SRCSTAT` | `0` |
| `0x00111f00`–`12c` | 4 × {`0x00000f00`, `0`, `0x11111111`} | `0x11111111` is an L0-read/write PLM shape |
| `0x00111f80`–`1ac` | 4 × {`0x00000f00`, `0x04000000`, `0`} | `0x111fb0`–`0x113ffc` is `0xBADF5040` |
| `0x00111610`+ | host-only pattern | `0x83bbbbbb`, `0x8bb9bbbb`, `0xbbbbbbbb`, `0x01000330` |

The block is partitioned per master. Over 512 common offsets:

| Class | Count | Example |
|---|---:|---|
| Same value to host and GSP | 66 | `CPUCTL 0x111388 = 0x180`; PLMs `0x111300`–`0x111328`; IRQ `0x111528/52c` |
| Differ | 199 | core state `0x111004`–`0x111094`: GSP reads values, host gets `0xBADF5720` |
| Host-only | 69 | `0x1111a8`–`0x1111e4` (16 × `0x2`), `0x111610+` (`0xbb` fill), ICD `0x1113d0+` |
| GSP-only | 80 | GSP-side `0x1113ec = 0x01404f66`; trace `0x111404`–`0x111410` host-blocked |

ICD behavior ([the live
ICD](../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port),
[the boot-window
test](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked)):

- `0x1113d0`–`0x1113dc` are host-writable at PL0; `ADDR0/1` and `CMD` retain
  writes and the engine executes.
- While the core runs, `RSTAT` completes; `RREG`, `RCSR`, and `RDM` are rejected
  with `CMD[14]=1` and `RDATA=0xbadfbadf`.
- `CMD=0` (`STOP`) halts the core; `CPUCTL` moves `0x2a0` → `0x380`, but
  `CPUCTL[4]` stays clear.
- With the core halted, `RPC` returns `0x93002ebc`, `ra` `0x93002ea6`, `sp`
  `0xa3003ed0`; `RDM` reads the 14.4 MB RM code segment at
  `0x01000000`–`0x01DCD000` (tested to `0x01B40000`).
- The data segment (`0x04000000`), the boot image (`0xEFD00000`), the WPR/FRTS,
  and `0x5DD00000`/`0x181D00000` are refused.
- During the HS boot window `CMD` and the host PC mirror read `0xbadf5620` until
  about 155 ms after the COT response; after boot the aperture is the RM code
  segment only.

The ICD command encoding and the full host/GSP split are in
[GSP RISC-V and PRISCV](../specs/06_gsp-riscv-and-priscv.md).

## FSP

Block `0x8f0000`–`0x8f3fff`.

The FSP block has no PRISCV core interface. A full 16 KB sweep finds no
`CPUCTL`/`RPC`/ICD engine at the Falcon+`0x3d0` or `+0x1000` placements; the FSP
is not a debug-port target ([the boot-window
test](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked)).

| Offset | Name | Value / note |
|---|---|---|
| `0x008f0108` | RISC-V `HWCFG` | `0x80420100` |
| `0x008f0180` / `1c0` | FSP core IMEM/DMEM | `0xBADF5620` |
| `0x008f0320` / `032c` / `0330` / `0334` | scratch / version | `0x9f` / `0x0a` / `9` / `0x44c` |
| `0x008f03c0` | `FALCON_ENGINE` | `0x00000200` |
| `0x008f03c4` | FSP PLM | `0x00040bff` (read all / write all; source bit 10 set) |
| `0x008f0a58` / `5c` | core status/config | `0x6624b970` / `3` |
| `0x008f0a64` / `68` | core config | `0xffffffff` / `0x111` |
| **`0x008f0a90`** | FSP core PLM | **`0xffffff8f`**; read all / write L3 only |
| `0x008f0aa0` / `a4` | PLM-shaped pair | `0x00804bff` / `0x0001fffe` |
| `0x008f0ab0`–`abc` | unidentified constant | `e81dc861 98216d8b 803e5471 9e870bdf` |
| `0x008f0ac0`–`adc` | core EMEM ch0–3 control/data | ch0 `0x5536c785`/`0x6fd593dc`; ch1 `0xc79705f3`/`0x8f7a6cc2`; ch2 `0x5792ea26`/`0xf7cd4b7b`; ch3 `0xc1c4c375`/`0x21fa03ab` |
| `0x008f0ae0`–`aec` | core EMEM ch4–5 | `0` |
| `0x008f0af0`–`afc` | core EMEM ch6–7 | `0xBADF5620` |
| `0x008f2ac0` / `c4` | PFSP EMEM ch0 | MCTP/NVDM transport; host-driven |
| `0x008f2ac8`–`2afc` | PFSP EMEM ch1–7 | host: ch4–7 `0xBADF5720`, ch1–3 zero/`0xdead5ed0`; GSP: ch1/2/4/6/7 `0xBADF5723`, ch3/5 zero/`0xdead5ed0` |

The debugger class reads `HWCFG2 = 0x8182a721`, `ENGINE_RESET = 0x200`, and
`MAILBOX0 = 0`; the standard `CPUCTL`, `BOOTVEC`, `DMACTL`, and `MAILBOX_TEST`
offsets return `0xBADF5620` ([the falcon
probe](../experiments/11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).

The FSP command surface and the boot inputs that reach it are in
[boot chain](../specs/01_boot-chain.md). The core EMEM port is only readable as the
firmware-selected word per channel; the pointer cannot be moved ([the FSP EMEM
test](../experiments/04_hs-sec2-fsp-memory.md#042-fsp-emem-pointer-writes-are-dropped)).

## SEC2

Block `0x840000`–`0x840fff`.

| Offset | Name | Value / note |
|---|---|---|
| `0x00840180` / `184` | DMEM port | host `0xBADF5720`, GSP `0xBADF5723` |
| `0x008401c0` / `1c4` | DMEM control/data | `AINCR` works; first 8 KB zero |
| `0x008403c4` | SEC2 PLM | `0x00000b0f` (read all / write none) |
| `0x00840ac0` / `ac4` | EMEM | `0x02000040` / `0`; empty |

The debugger class reads `CPUCTL = 0x10` (halted), `MAILBOX0 = 0xd8693000`, and
`ENGINE_RESET = 0x200`; `BOOTVEC` and `DMACTL` return `0xBADF5723`, so the boot
vector stays blocked ([the falcon
probe](../experiments/11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).

The SEC2 image that carried the older stack overflow does not ship for GB20x
([the shipped
components](../experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package));
the residual surface is in [boot chain](../specs/01_boot-chain.md).

## PMU and CMS2

| Offset | Name | Value / note |
|---|---|---|
| `0x0010a000` | PMU guess | all `0xBADF5040`; wrong base |
| `0x008aa374` / `378` | OOBHUB CMS2 indirect read | 448/8192 nonzero, repeating 128-dword block |

The debugger class reads all twelve standard FALCON offsets at `0x10a000` as
`0xBADF5040`, confirming the base is wrong ([the falcon
probe](../experiments/11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).

The PMU devinit is the leading candidate for the pre-lock FEAT writes, but its
BAR0 base is not identified; that link is an analogy to Ada/Ampere. The writer
timing is in [privilege and rate control](../specs/02_privilege-and-rate-control.md).

## Bad-read sentinels

Bits `[31:8]` are the PRI-ringstation error code; the low byte is undecoded. The
field layout is public; the observed instances are from [the sentinel
analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis).

| Value | PRI family | Observed when |
|---|---|---|
| `0xBADF1002` | `0xBADF10` `FECS_PRI_TIMEOUT` | GR register access at `0x504180`–`0x5041fc` |
| `0xBADF5040` | `0xBADF50` `FECS_PRI_CLIENT_ERR` | offset not implemented |
| `0xBADF5610` | `0xBADF56` (not public) | no such Falcon port (GSP IMEM/DMEM) |
| `0xBADF5620` | `0xBADF56` (not public) | FSP core port present but inaccessible |
| `0xBADF5720` | `0xBADF57` (not public) | present but blocked to this caller (host) |
| `0xBADF5723` | `0xBADF57` (not public) | present but blocked to the GSP |
| `0xBADF510C` | `0xBADF51` generic client/privilege error | fuse-block instance; not fuse-specific |
| `0xBADF5128` | `0xBADF51` generic client/privilege error | refused PL2 access at BAR0 `0x137200` |
| `0xBADF4100` | `0xBADF41` PRI decode/access error | refused access to GSP `HWCFG2` `0x1100f4` |
| `0xBADF5545` | `0xBADF55` (not public) | FECS command-ID register read-blocked |
| `0xBADF1100` | `0xBADF11` `FECS_PRI_DECODE` | address not decodable |
| `0xBADF1301` | `0xBADF13` (not public) | GR space `0x1c8000`–`0x1cbc00` |
| `0xBADF202B` | `0xBADF20` (not public) | GR space `0x22c000`–`0x22f800` |
| `0xBADFFFFF` | `0xBADFFF` (not public) | GSP-master read of the four PRISCV ICD registers; the host reads `0` there |

Three failure classes are distinguishable: decode (`0xBADF11xx`, `0xBADF41xx`),
client error (`0xBADF50xx`, `0xBADF51xx`), and refused/blocked (`0xBADF57xx`).
`0xBADF1002` is a timeout family, separate from decode.
The `0xBADF56xx` values and the `0xBADF5720`/`0xBADF5723` pair show that the low
byte also encodes the caller or engine. `0xBADF51` is a family, not a fuse
marker: the low byte is `0x0c` at the fuse block and `0x28` at `0x137200`
([the sentinel
analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis)).
The error-code taxonomy is in
[errors and logging](../specs/08_errors-and-logging.md).

## Evidence map

| Block | Experiments | Tool |
|---|---|---|
| FUSE / FEAT | [FEAT bank gate](../experiments/01_software-register-writes.md#013-the-whole-feat-bank-shares-one-gate), [fuse and rate modifier](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier), [mask decode](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only), [cross-part corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus), [PRO 6000 reference](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump), [FEAT across boots](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr), [re-lock](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit) | [Register access](../tools/register-access/), [Direct probe](../tools/direct-probe/), [Issue-rate probe](../tools/issue-rate-probe/) |
| FECS / SM | [live FECS probe](../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes), [rate modifier](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier), [debugger test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it) | [Register access](../tools/register-access/) |
| Debugger / external | [debugger test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it), [external cross-check](../experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem) | [Register access](../tools/register-access/), offline |
| GSP Falcon / PRISCV | [GSP EMEM](../experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty), [PRISCV map](../experiments/04_hs-sec2-fsp-memory.md#043-priscv-block-is-split-per-master), [live ICD](../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port), [boot window](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked) | [Register access](../tools/register-access/), [Direct probe](../tools/direct-probe/), [Driver harness](../tools/driver-harness/) |
| FSP / SEC2 | [live FECS/SEC2 probe](../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes), [FSP EMEM](../experiments/04_hs-sec2-fsp-memory.md#042-fsp-emem-pointer-writes-are-dropped), [boot window](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked) | [Register access](../tools/register-access/), [Direct probe](../tools/direct-probe/) |
| Sentinels | [sentinel analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis) | [GSP-RM tools](../tools/gsp-rm-tools/), [Driver harness](../tools/driver-harness/) |

## Limits and open questions

- Values are stock on GB202 unless marked otherwise. Per-card values are from
  `41:00.0` and `c1:00.0`; per-boot values are from the sampled cold boots. The
  PRO 6000 values are measured on two cards, one power-on each.
- The FEAT block is not documented in the public headers. The field layout
  matches the Falcon v4 PLM header; the FEAT block's use of that layout is an
  analogy, not a FEAT-specific definition.
- The zero endpoint of the readout→rate mapping is measured on two PRO 6000s:
  all-zero selectors with all-zero fuses and full rate. The nonzero values are
  still unproven: `FMLA32 = 3` yet the measured penalty is about 2×, not the
  public enum's 1/8; INT8 is full rate with `IMLA1/2/4 = 3`.
- The full-rate encoding is measured on two PRO 6000s: all-zero selectors and
  all-zero arithmetic speed fuses, with the same PL3-only write gate. The
  `SS0`/`SS1` override payload format remains inferred; the PRO snapshots are one
  power-on per card, and the words differ across cards.
- Open: whether `0x823800` is an alias or a second PLM; the exact meaning of
  `0x8238b0` (`0x12800541` on the 5090, `0x1c5f331f` and `0x0db4b1c3` on two PRO
  6000s); the real PMU BAR0 base; the 16-byte constant at `0x8f0ab0`; the
  128-dword CMS2 table; whether the SEC2 DMEM is larger than 8 KB or masked.
- The exact function of `0x137200` is open; the value and the refused PL2 access
  place it in the FECS/GR privilege block, not the FEAT bank.
- The override-enable fuses (`0x820040`, `0x820084`, `0x8203f0`) are unread on
  GB202; their Ampere values are cross-part data.
