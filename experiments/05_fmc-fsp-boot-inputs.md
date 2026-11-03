# FMC and FSP boot inputs

## Summary

**The idea.**

- The chain-of-trust ([COT](../specs/01_boot-chain.md#cot-v2)) message is the host-built boot request the FSP (the
  security processor that runs first out of reset) consumes: FMC address, [FRTS](../specs/07_memory-and-host-access.md#wpr-and-frts-layout)
  layout, SHA-384, P-384 key, and signature.
- [`WprMeta`](../specs/01_boot-chain.md#wprmeta) is the 256-byte host descriptor the [FMC](../specs/04_firmware-formats.md#fmc-container) (the first-stage mutable
  firmware) consumes on a cold boot; [GSP-RM](../specs/04_firmware-formats.md#gsp-rm-image) is the main GPU firmware that runs
  after it.
- FRTS is the firmware runtime state region inside the write-protected VRAM
  region ([WPR](../specs/07_memory-and-host-access.md#wpr-and-frts-layout)); [GSCI](../specs/01_boot-chain.md#terms) is the post-boot query that returns the WPR layout.
- This group varies one host field per boot and reads the structured FSP/FMC
  error code or the GSCI layout.
- What it would give: a host-controlled field that moves the protected layout,
  bypasses authentication, or exposes the decrypted boot image.

**What it found.**

- The FSP [requires exactly 1 MB of
  FRTS](#055-frts-size-control-boots-larger-refused) and a [128K-aligned
  base](#057-misaligned-frts-base-draws-0xd6), but accepts a
  [placement window of at least 1 GiB](#0510-placement-window-reaches-1-gib).
- The [COT offset positions the whole
  WPR](#059-cot-offset-positions-the-whole-layout) 1:1.
- [`WprMeta.magic` is enforced](#0511-wprmeta-magic-enforced-verified-accepted);
  the [`verified` flag is inert](#0515-verified-does-not-bypass-image-verification).
- The COT [hash](#0516-cot-hash-authenticated-auth-failure-wedges) and
  [key](#0518-cot-public-key-anchored) are authenticated; the
  [FMC image is bound to the hash](#0519-fmc-container-read-back-and-tampered).
- The [heap request is honoured
  downward](#0513-heap-size-request-honoured-downward); a
  [16 MiB request wedges](#0514-16-mib-heap-request-wedges-the-boot).
- The [FEAT](../specs/03_register-map.md#feat-bank) bank is [final before the FMC](#0517-feat-bank-final-before-the-fmc);
  the [re-lock is GPU-side devinit](#0521-plm-re-lock-is-autonomous-devinit),
  with no FSP register activity at the transition.
- The [vBIOS](../specs/05_vbios-and-devinit.md#where-it-sits) [plaintext tables carry no FEAT
  address](#0522-vbios-devinit-table-scan), and the devinit tables are
  authenticated.
- The [bootloader buffer is not decrypted in
  place](#0524-bootloader-buffer-not-decrypted-in-place), the
  [FB route is shut](#0525-fb-route-shut), and the
  [non-WPR heap holds no RM objects](#0526-non-wpr-heap-holds-no-rm-objects).

**What it did not find.**

- No [host-controlled length or offset reaches a pre-auth
  copy](#0523-wprmeta-bootloader-description-and-images).
- No [plaintext FEAT write route](#0522-vbios-devinit-table-scan).
- No [decrypted boot image in host
  memory](#0524-bootloader-buffer-not-decrypted-in-place).
- No [host-supplied rate value](#051-host-side-boot-and-static-info-instrumentation).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 05.1 | [Host-side boot and static-info instrumentation](#051-host-side-boot-and-static-info-instrumentation) | Host does not supply selectors |
| 05.2 | [Patched GSP-RM image rejected by the FMC](#052-patched-gsp-rm-image-rejected-by-the-fmc) | Image authenticated before execution |
| 05.3 | [Boot-input baseline and the ordinary FMC path](#053-boot-input-baseline-and-the-ordinary-fmc-path) | Baseline matches production |
| 05.4 | [FRTS size rejected by the FSP](#054-frts-size-rejected-by-the-fsp) | Half size draws 0xd9 |
| 05.5 | [FRTS size control boots, larger refused](#055-frts-size-control-boots-larger-refused) | Exactly 1 MB required |
| 05.6 | [A relocated FRTS base boots](#056-relocated-frts-base-boots) | Offset is not pinned |
| 05.7 | [Misaligned FRTS base draws 0xd6](#057-misaligned-frts-base-draws-0xd6) | Misalignment rejected, not rounded |
| 05.8 | [Second accepted base and units correction](#058-second-accepted-base-and-units-correction) | Offset is from FB end |
| 05.9 | [COT offset positions the whole layout](#059-cot-offset-positions-the-whole-layout) | Whole WPR translates 1:1 |
| 05.10 | [Placement window reaches 1 GiB](#0510-placement-window-reaches-1-gib) | No range check observed |
| 05.11 | [WprMeta magic enforced; verified accepted](#0511-wprmeta-magic-enforced-verified-accepted) | Magic enforced, flag inert |
| 05.12 | [WprMeta and COT sizes disagree](#0512-wprmeta-and-cot-sizes-disagree) | No cross-check, inert |
| 05.13 | [Heap-size request is honoured downward](#0513-heap-size-request-honoured-downward) | Heap grows downward exactly |
| 05.14 | [16 MiB heap request wedges the boot](#0514-16-mib-heap-request-wedges-the-boot) | Hard wedge, not a refusal |
| 05.15 | [Verified does not bypass image verification](#0515-verified-does-not-bypass-image-verification) | No change to verification |
| 05.16 | [COT hash authenticated; auth failure wedges](#0516-cot-hash-authenticated-auth-failure-wedges) | Hash authenticated, WPR2 left up |
| 05.17 | [FEAT bank final before the FMC](#0517-feat-bank-final-before-the-fmc) | Neither FMC nor GSP-RM writes |
| 05.18 | [The COT public key is anchored](#0518-cot-public-key-anchored) | Key route closed, 0x1db |
| 05.19 | [FMC container read back and tampered](#0519-fmc-container-read-back-and-tampered) | Bound to hash, 0x33 |
| 05.20 | [FEAT bank across boots and FLR](#0520-feat-bank-across-boots-and-flr) | Power-cycle only; inert |
| 05.21 | [PLM re-lock is autonomous devinit](#0521-plm-re-lock-is-autonomous-devinit) | Re-lock is GPU-side |
| 05.22 | [The vBIOS devinit table scan](#0522-vbios-devinit-table-scan) | No plaintext FEAT address |
| 05.23 | [WprMeta bootloader description and images](#0523-wprmeta-bootloader-description-and-images) | No pre-auth copy |
| 05.24 | [Bootloader buffer not decrypted in place](#0524-bootloader-buffer-not-decrypted-in-place) | Ciphertext left in host memory |
| 05.25 | [The FB route is shut](#0525-fb-route-shut) | WPR returns 0xbad0ac00 |
| 05.26 | [Non-WPR heap holds no RM objects](#0526-non-wpr-heap-holds-no-rm-objects) | Header and random span only |

## 05.1 Host-side boot and static-info instrumentation

**Question.** Does the host supply the nine GR selector values at boot?

**Why.**

- If the host sets them, a driver patch or registry value could change the rate.
- What it would give: a host-side lever, or a clear no.

**Method.**

- Tool: `tools/driver-harness/load_patched.sh` builds the open modules at exact
  tag 595.91.07 with `NV_PRINTF` calls in `kgraphicsLoadStaticInfo_KERNEL`
  (V1/V2), `kgspSetupLibosInitArgs_IMPL`, and `_kgspSetupGspFmcArgs_GH100`.
- Target: both cards, root; the stock DKMS modules are kept as recovery.
- Steps: build, add the prints, load the built modules. Secure Boot is disabled
  and vermagic matches.
- Args used:
```bash
sudo tools/driver-harness/load_patched.sh
dmesg | grep 'BF16:'
```

**Observed data.** dmesg at module load, before any CUDA context:

```text
NVRM: GPU0 kgraphicsLoadStaticInfo_KERNEL: BF16: KGR SM issue rate modifier grIdx=0:
  imla0=0 fmla16=0 dp=0 fmla32=3 ffma=0 imla1=3 imla2=3 imla3=0 imla4=3
NVRM: GPU0 kgraphicsLoadStaticInfo_KERNEL: BF16: KGR SM issue rate modifier V2 grIdx=0 size=10
```

The libos init args print as `kind=1 loc=1 id8=%#x pa=%#llx size=%#llx`; the
printer does not expand `%#x` in this codebase. `GSP_ARGUMENTS_CACHED` has no
rate field.

**Result.**

- **Answer:** no. The host does not supply the nine selector values.
- **What we learned:**
  - The GSP returns them at boot; the FMC boot parameters contain only registry
    keys and descriptor/address fields.
  - The `%#x` printer bug is in the instrumented print, not the boot path.
- **Related:**
  - The [FEAT-bank timing](#0517-feat-bank-final-before-the-fmc) shows the
    selectors are fixed before the FMC.
  - The [re-lock experiment](#0521-plm-re-lock-is-autonomous-devinit) brackets
    the GPU-side writer.

## 05.2 Patched GSP-RM image rejected by the FMC

**Question.** Does the FMC execute a host-patched GSP-RM image?

**Why.**

- A four-byte patch is the cheapest way to run custom code in the GSP.
- If accepted, it is a [PL2](../specs/02_privilege-and-rate-control.md)
  code-execution lever.
- What it would give: PL2 code execution, or proof of image authentication.

**Method.**

- Tool: `tools/driver-harness/run_gsp_patch_test.sh` installs a patched
  `gsp_ga10x.bin` and loads the instrumented modules; the COT and every layout
  field stay stock.
- Target: both cards.
- Patch: replace the first instruction of `FUN_ram_015ffae8` with `ret`
  (`jalr x0, 0(ra)` = `0x00008067`). Flat `0x015ffae8` maps to `.fwimage` offset
  `0x5ffae8` and ELF file offset `0x5ffb28`; original bytes `39 71 06 fc`,
  patched to `67 80 00 00`. The rest of the image is unchanged.
- Args used:
```bash
sudo tools/driver-harness/run_gsp_patch_test.sh
```

**Observed data.** Both cards, every attempt:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
Max GSP-RM boot attempts exceeded: 4/4
RmInitAdapter failed! (0x62:0x55:2168)
```

**Result.**

- **Answer:** no. A four-byte change is rejected before execution.
- **What we learned:**
  - The FMC authenticates the GSP-RM image.
  - The harness restores the original firmware and reloads the stock driver;
    both cards return without a reboot.
- **Related:**
  - The [`verified` flag test](#0515-verified-does-not-bypass-image-verification)
    shows the check is independent of `WprMeta`.
  - The [container binding](#0519-fmc-container-read-back-and-tampered) shows the
    image is bound to the COT hash.

## 05.3 Boot-input baseline and the ordinary FMC path

**Question.** What does the ordinary boot path send, and does it match production?

**Why.**

- Every oracle run needs a baseline for the COT hash, key, signature, and
  `WprMeta`.
- What it would give: the stock values the rest of the group compares against.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 0` with the inert hook in
  `bf16_boot_instr.patch`; context dumps off.
- Target: both cards, root; build is exact 595.91.07.
- `BF16_COT_VARY` selects one field immediately before
  `kfspSendAndReadMessage`: 1 size, 2 offset, 3 boot-args pointer, 4 FMC
  pointer, 5 hash flip; 0 is inert.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 0
```

**Observed data.** Baseline dmesg from card 0:

```text
BF16: WprMeta magic=0xdc3aae21371a60b3 rev=1 flags=0x0 bootCount=0
BF16: COT hash=ee0988fea62832c4b2fe90d87e2f6104 key=18f18b040f9cebbba4d4a65ef519731d sig=606f48f28ed1339f39e4ba1f48933327
```

The dmesg line prints the first 16 bytes as little-endian u32 words. The full
production artifacts are:

```text
c04 SHA-384
fe8809eec43228a6d890feb204612f7e07196711c1ac4c377ed3a2940a859b31
0db9247b61ab9a74d4b48a7435b4cf8f

c04 P-384 public key (97-byte uncompressed point)
048bf118bbeb9c0f5ea6d4a41d7319f53d0ce2b9817428a30de88c997405e2ef00
8a6ab4bf2edf7cf32e97ea34992b86af9df9a14898a9898b37402edac7040b45
a5fedebbe83b1a1c2de1ca6babba01411729349503da52b73a81907170c0bb04

c04 signature (96-byte r || s)
f2486f609f33d18e1fbae4392733934897ccde53688ed4e4d184a6b09ead8c5c
1dd6c530fe595bce9e7eedf6738e112716a6c21baee9a13b1fbc89593a4aff8b
6ed9b76a26cfcf6d280341321d4e843b885c346efd4710d15a1183eaeff93db8
```

The dmesg words match the file bytes when each 32-bit word is read little-endian:
`fe8809ee` prints as `ee0988fe`, and so on.

**Result.**

- **Answer:** the baseline is the production container
  `GspRmFmcGfwProdSigned_GB202` (`c04`, 287,304 bytes) and its production P-384
  key.
- **What we learned:**
  - The ordinary path uses the production-signed FMC.
  - The dmesg print is little-endian; the COT hash and key match the file bytes.
- **Related:**
  - The [size oracle](#054-frts-size-rejected-by-the-fsp) and
    [offset oracle](#056-relocated-frts-base-boots) vary this baseline.

## 05.4 FRTS size rejected by the FSP

**Question.** What does the FSP check in the FRTS size?

**Why.**

- The FRTS size is host-controlled; a smaller region could move the protected
  layout.
- What it would give: a size check to map, or a way to shrink the region.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 1 0x80000` halves the COT
  [`frtsVidmemSize`](../specs/01_boot-chain.md#cot-v2); every other field is stock.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 1 0x80000
```

**Observed data.**

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
FSP boot cmds failed. RM cannot boot.
```

The retry recomputed [`frtsVidmemOffset`](../specs/01_boot-chain.md#cot-v2) to `0x10520000` and failed the same way.
The run also exposed a driver lifetime bug: `kfspCleanupBootState_IMPL` destroyed
the engine-lifetime `pPollEvent`; the retry scheduled and destroyed the freed
event and oopsed in `hrtimer_active` (NULL `hrtimer.base`). The fix moves the
destroy into `kfspStateDestroy_IMPL` (NULL-guarded).

**Result.**

- **Answer:** the FSP rejects a half-size FRTS region with [`0xd9`](../specs/08_errors-and-logging.md#boot-error-codes).
- **What we learned:**
  - `0xd9` is an FSP size check, not an FMC result.
  - The oops is a driver lifetime bug, fixed in the tree used by later records.
- **Related:**
  - The [1 MB control and 2 MB refusal](#055-frts-size-control-boots-larger-refused)
    isolate the value.
  - The [alignment check](#057-misaligned-frts-base-draws-0xd6) uses `0xd6`.

## 05.5 FRTS size control boots, larger refused

**Question.** Is `0xd9` attributable to the size value or to the placement plumbing?

**Why.**

- The half-size run also recomputed the offset.
- A 1 MB control and a 2 MB run separate the two variables.
- What it would give: proof the FSP keys on the size value.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 1 0x100000` (control) and
  `0x200000` (upper bound).
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 1 0x100000
sudo tools/driver-harness/fmc_oracle.sh 1 0x200000
```

**Observed data.** Control boot:

```text
[drm] Initialized nvidia-drm 0.0.0 for 0000:c1:00.0 on minor 1
[drm] Initialized nvidia-drm 0.0.0 for 0000:41:00.0 on minor 2
```

No `FSP response reported error` line. The COT was byte-for-byte the baseline
apart from per-boot addresses.

Upper bound:

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
```

16 sends on GPU0, 8 on GPU1, all `0xd9`. The driver cycled placements
`0x1b40000`, `0x10520000`, `0x1ef00000`, `0x2d8e0000`; the code was the same at
each.

**Result.**

- **Answer:** `0xd9` is attributable to the size value, not the plumbing. The FSP
  requires exactly 1 MB.
- **What we learned:**
  - The control boots both minors with no error.
  - The event-lifetime fix held over a 24-send failure path.
- **Related:**
  - The [half-size run](#054-frts-size-rejected-by-the-fsp) and the
    [alignment run](#057-misaligned-frts-base-draws-0xd6) complete the code map.

## 05.6 Relocated FRTS base boots

**Question.** Does the FSP pin the FRTS offset to the stock value?

**Why.**

- The COT offset is host-controlled.
- If the FSP accepts a relocated base, the host can place the protected region.
- What it would give: a placement lever, or proof the offset is pinned.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 2 0x10520000`, aligned, in range,
  stock size.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 2 0x10520000
```

**Observed data.** Both cards boot; one COT send per card; no error line; both
minors come up. The COT hash is unchanged:

```text
BF16: COT hash=ee0988fea62832c4b2fe90d87e2f6104 ...
```

**Result.**

- **Answer:** no. The FSP accepts a relocated aligned base.
- **What we learned:**
  - The offset is not pinned to the stock [`0x1b40000`](../specs/01_boot-chain.md#cot-v2).
  - Acceptance is not consumption; the [layout test](#059-cot-offset-positions-the-whole-layout)
    proves the moved value is used.
- **Related:**
  - The [misaligned case](#057-misaligned-frts-base-draws-0xd6) draws `0xd6`.
  - The [second accepted base](#058-second-accepted-base-and-units-correction)
    fixes the units.

## 05.7 Misaligned FRTS base draws 0xd6

**Question.** Does the FSP round a misaligned FRTS base?

**Why.**

- The FSP might align the host value silently or reject it.
- The answer separates the size check from the alignment check.
- What it would give: a second error code and a model of the parser.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 2 0x10520001`, the
  [relocated FRTS base](#056-relocated-frts-base-boots) plus one byte.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 2 0x10520001
```

**Observed data.**

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd6
```

24 sends, 24 × `0xd6` (16 on GPU0, 8 on GPU1); no boot, no Xid, no oops; stock
restored and both cards listed.

**Result.**

- **Answer:** the FSP rejects rather than rounds.
- **What we learned:**
  - The two codes separate the checks:

| COT state | Code |
|---|---|
| `frtsVidmemSize != 0x100000` | `0xd9` |
| offset misaligned | `0xd6` |
| offset aligned and accepted | none |

- **Related:**
  - The [size check](#054-frts-size-rejected-by-the-fsp) and the
    [accepted base](#056-relocated-frts-base-boots) define the two sides.

## 05.8 Second accepted base and units correction

**Question.** What are the units of `frtsVidmemOffset`, and is there a second
accepted base?

**Why.**

- The first relocated base did not say whether the value is absolute or from the
  FB end.
- What it would give: a correct layout model and another accepted base.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 2 0x10500000` with the extended
  post-boot GSCI print.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 2 0x10500000
```

**Observed data.**

```text
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7d8920000 frts=0x7e5900000
```

The host's mapped `WprMeta` still reads `frts{off=0x0}`; it does not show
the patch that the ACR (the loader that runs before the FMC) applies.

**Result.**

- **Answer:** both cards boot. `frtsVidmemOffset` is from the end of FB, not an
  absolute address, aligned up to 128K:

| Value | Meaning |
|---|---|
| stock `0x1b40000` | 27.25 MiB from the end |
| `0x10520000` | 261.1 MiB from the end |
| `0x10500000` | 261.0 MiB from the end |
| `0x10520001` | same, misaligned → `0xd6` |

- **What we learned:**
  - The accepted base is 233.75 MiB below the driver's own end-reserve estimate,
    so the FSP does not enforce that policy.
  - The GSCI value is an absolute FB offset for the WPR block.
- **Related:**
  - The [whole-layout test](#059-cot-offset-positions-the-whole-layout) supplies
    the stock control.

## 05.9 COT offset positions the whole layout

**Question.** Does the COT offset position the whole GSP-RM WPR or only the FRTS
region?

**Why.**

- If the whole WPR moves, the host controls the location of the boot image and
  heaps.
- What it would give: a layout lever and a predictive model.

**Method.**

- Tool: stock control versus `tools/driver-harness/fmc_oracle.sh 2 0x10500000`,
  both with the extended GSCI print.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 0
sudo tools/driver-harness/fmc_oracle.sh 2 0x10500000
```

**Observed data.**

```text
# stock
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7e72e0000 frts=0x7f42c0000
# moved
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7d8920000 frts=0x7e5900000
```

| Field | Stock | Moved | Δ |
|---|---:|---:|---:|
| GSCI `nonWprHeap` | `0x7e72e0000` | `0x7d8920000` | `0xE9C0000` |
| GSCI `frts` | `0x7f42c0000` | `0x7e5900000` | `0xE9C0000` |
| COT offset delta | none | none | `0xE9C0000` |

The three deltas are identical to the byte. The layout translates 1:1 with the
host value:

- `GSP_frts_abs = FB_end − COT_offset − 0xA200000` in both runs.
- `GSP_frts_abs − nonWprHeap = 0xCFE0000` in both runs.
- Stock WPR spans 189.25–397.1 MiB from the FB end; the moved one
  423.0–630.9 MiB.

The pre-overwrite `WprMeta` fields read `0x0` on both cards: the host's mapped
copy does not reflect the ACR's patch, so the GSCI query is the only post-boot
layout source.

**Result.**

- **Answer:** the COT offset positions the whole GSP-RM WPR, not just the FRTS
  region.
- **What we learned:**
  - The three deltas match to the byte.
  - The GSCI query is the only post-boot layout source.
- **Related:**
  - The [1 GiB placement test](#0510-placement-window-reaches-1-gib) extends the
    window.
  - The [heap-size test](#0513-heap-size-request-honoured-downward) moves the
    other end of the block.
- **Open question:** what the FMC writes into FRTS is not shown by this
  experiment.

## 05.10 Placement window reaches 1 GiB

**Question.** How wide is the FRTS placement window?

**Why.**

- The FSP accepted 261 MiB from the FB end; the upper bound is unknown.
- What it would give: the usable placement range and a predictive model.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 2 0x40000000`, 1 GiB from the FB
  end.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 2 0x40000000
```

**Observed data.**

```text
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7a8e20000 frts=0x7b5e00000
```

| Published field | Prediction | Measured |
|---|---:|---:|
| GSCI `frts` | `0x7b5e00000` | `0x7b5e00000` |
| GSCI `nonWprHeap` | `0x7a8e20000` | `0x7a8e20000` |

The WPR spans 1.16–1.37 GiB from the FB end. Both values match the model to the
byte.

**Result.**

- **Answer:** the window is at least 1 GiB, with no observed range check in
  either direction.
- **What we learned:**
  - The model predicts both published fields to the byte.
- **Related:**
  - The [layout model](#059-cot-offset-positions-the-whole-layout) supplies the
    prediction.
- **Open question:** granularity below 128K and the small end of the window are
  untested.

## 05.11 WprMeta magic enforced; verified accepted

**Question.** Is [`WprMeta.magic`](../specs/01_boot-chain.md#wprmeta) enforced, and does a preset `verified` flag do
anything?

**Why.**

- `WprMeta` is host-filled; an unchecked magic or a trusted `verified` bit would
  be a host bypass.
- What it would give: a parser bypass, or proof the fields are checked.

**Method.**

- Tool: `tools/driver-harness/wpr_oracle.sh 1` (bad magic) and
  `wpr_oracle.sh 3` (`verified = 0xa0a0a0a0a0a0a0a0`).
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/wpr_oracle.sh 1
sudo tools/driver-harness/wpr_oracle.sh 3
```

**Observed data.** Bad magic:

```text
BF16: WprMeta magic=0xdeadbeefdeadbeef rev=1 flags=0x12 bootCount=0
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x827, additional info=0x0
```

Boot failed 4/4 per card. Each failed attempt moves the COT base by `0xE9C0000`
(`0x1b40000` → `0x10520000` → `0x1ef00000` → `0x2d8e0000`), and `WprMeta.flags`
reads `0x12` from the second attempt on.

Field 3, both cards:

```text
BF16: WprMeta radix3Elf{addr=0x18e400000 size=72830976} bootloader{addr=0x1c3a80000 size=290816}
  gspFw{start=0x0 heapOff=0x0 heapSize=0x8700000} nonWpr{off=0x0 size=0x300000}
  frts{off=0x0 size=0x100000} wprEnd=0x0 fbSize=0x0 verified=0xa0a0a0a0a0a0a0a0
```

**Result.**

- **Answer:** magic is enforced ([`0x827`](../specs/08_errors-and-logging.md#boot-error-codes)); a preset `verified` reaches the FMC but
  has no visible effect on initial boot.
- **What we learned:**
  - Failed attempts move the COT base by `0xE9C0000`.
  - `flags` changes to `0x12` after the first failed attempt.
- **Related:**
  - The [image-check test](#0515-verified-does-not-bypass-image-verification)
    tests the bypass directly.

## 05.12 WprMeta and COT sizes disagree

**Question.** Does the FMC cross-check [`WprMeta.frtsSize`](../specs/01_boot-chain.md#wprmeta) against the COT?

**Why.**

- Two host fields describe the same region; a missing cross-check would be a
  layout discrepancy.
- What it would give: a second size lever, or proof the struct field is
  decorative.

**Method.**

- Tool: `tools/driver-harness/wpr_oracle.sh 5`, `WprMeta.frtsSize = 0x200000`
  while the COT keeps `0x100000`.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/wpr_oracle.sh 5
```

**Observed data.**

```text
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7e72e0000 frts=0x7f42c0000
# no FSP or FMC error; both cards boot
```

**Result.**

- **Answer:** no cross-check. The FMC accepts the disagreement and builds the
  layout from the COT value.
- **What we learned:**
  - `WprMeta.frtsSize` is decorative on this path.
  - The COT value is authoritative.
- **Related:**
  - The [size oracle](#054-frts-size-rejected-by-the-fsp) varies the COT value;
    this record varies the struct field.

## 05.13 Heap-size request honoured downward

**Question.** Is the host [`gspFwHeapSize`](../specs/01_boot-chain.md#wprmeta) request honoured?

**Why.**

- The heap is part of the protected layout and is host-sized.
- What it would give: a live layout lever and a model of the block.

**Method.**

- Tool: `tools/driver-harness/wpr_oracle.sh 6 0x10000000`, 256 MiB requested
  versus the stock 135 MiB.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/wpr_oracle.sh 6 0x10000000
```

**Observed data.**

```text
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7df9e0000 frts=0x7f42c0000
```

| Field | Stock | This run | Δ |
|---|---:|---:|---:|
| `gspFwHeapSize` | `0x8700000` | `0x10000000` | `0x7900000` (121 MiB) |
| GSCI `frts` | `0x7f42c0000` | `0x7f42c0000` | 0 |
| GSCI `nonWprHeap` | `0x7e72e0000` | `0x7df9e0000` | `0x7900000` |
| WPR span | 207.875 MiB | 328.875 MiB | 121 MiB |

**Result.**

- **Answer:** yes. The extra request is honoured to the byte.
- **What we learned:**
  - The top stays anchored to the COT base and the block grows downward.
  - `span = 0xCFE0000 + (gspFwHeapSize − 0x8700000)`.
- **Related:**
  - The [16 MiB wedge](#0514-16-mib-heap-request-wedges-the-boot) is the lower
    bound failure.

## 05.14 16 MiB heap request wedges the boot

**Question.** What happens below GSP-RM's minimum heap size?

**Why.**

- The FMC honoured a larger request without a sanity check.
- The lower direction may be a wedge or a structured refusal.
- What it would give: the safe range and the failure mode.

**Method.**

- Tool: `tools/driver-harness/wpr_oracle.sh 6 0x1000000`, a 16 MiB heap request.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/wpr_oracle.sh 6 0x1000000
```

**Observed data.**

```text
GspStatusQueueInit: msgqRxLink failed: -7, nvStatus 0x00000065, retries: 2697191
Assertion failed: Call timed out [NV_ERR_TIMEOUT] ... @ kernel_gsp_gh100.c:1190
_kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
RmInitAdapter failed! (0x62:0x40:2168)
```

Both cards failed identically; the stock restore reported `No devices found.`

**Result.**

- **Answer:** the FMC accepts the COT and applies the layout without a sanity
  check against GSP-RM's minimum. The failure is a hard wedge, not a structured
  refusal.
- **What we learned:**
  - One reboot per point below the minimum; bisect from above.
  - [WPR2](../specs/01_boot-chain.md#failure-modes) stays up after the timeout.
- **Related:**
  - The [larger request](#0513-heap-size-request-honoured-downward) sets the
    formula.

## 05.15 Verified does not bypass image verification

**Question.** Does a preset [`WprMeta.verified`](../specs/01_boot-chain.md#wprmeta) bypass the GSP-RM image check?

**Why.**

- `verified` is host-filled and reads like a trust bit.
- What it would give: a host bypass of image authentication, or proof the flag is
  inert.

**Method.**

- Tool: `tools/driver-harness/wpr_verified_patch_test.sh` installs the
  [patched GSP-RM](#052-patched-gsp-rm-image-rejected-by-the-fmc), presets
  `WprMeta.verified`, and keeps the COT stock.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/wpr_verified_patch_test.sh
```

**Observed data.**

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
# 16 occurrences over four attempts per card; the verified flag was preset each time
```

**Result.**

- **Answer:** no. The FMC refuses the image on every attempt, both cards.
- **What we learned:**
  - The flag does not change the image check.
  - Recovery is clean, unlike the [first patch test](#052-patched-gsp-rm-image-rejected-by-the-fmc):
    firmware is restored before the stock restore.
- **Related:**
  - The [magic test](#0511-wprmeta-magic-enforced-verified-accepted) shows the
    flag reaches the FMC.
- **Open question:** a resume-path use of `verified` is not excluded.

## 05.16 COT hash authenticated; auth failure wedges

**Question.** Is the COT hash authenticated?

**Why.**

- The COT hash is host-supplied; if unchecked, a host could bind a different
  image.
- What it would give: proof of authentication and a new error code.

**Method.**

- Tool: `tools/driver-harness/fmc_oracle.sh 5` flips one bit in `hash384[0]`;
  image, key, signature, and layout stay stock.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fmc_oracle.sh 5
```

**Observed data.**

```text
BF16: COT hash=ee0988ffa62832c4b2fe90d87e2f6104 ...
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x377
```

One send per card; every retry then hit `unexpected WPR2 already up`; the stock
restore found no devices.

**Result.**

- **Answer:** yes. The COT hash is authenticated with [`0x377`](../specs/08_errors-and-logging.md#boot-error-codes).
- **What we learned:**
  - Size, alignment, and magic rejections restore cleanly; an auth failure
    leaves WPR2 up.
  - The FSP arms WPR2 before authenticating.
  - Code map after this run: [`0x83d`](../specs/08_errors-and-logging.md#boot-error-codes), `0xd9`, `0xd6`, `0x827`, `0x377`, `0xaff`.
- **Related:**
  - The [key anchor](#0518-cot-public-key-anchored) is a distinct code
    (`0x1db`).
  - The [container binding](#0519-fmc-container-read-back-and-tampered) binds the
    image to this hash.

## 05.17 FEAT bank final before the FMC

**Question.** Does the mutable boot chain (FMC or GSP-RM) write the FEAT bank?

**Why.**

- The selectors must be written by something; if the FMC or GSP-RM does it, a
  mutable-firmware patch could change the rate.
- What it would give: the writer's privilege level, or proof the write is
  earlier.

**Method.**

- Tool: `tools/driver-harness/feat_preboot.sh` builds 595.91.07 with
  `BF16_FEAT_PREBOOT=1` and samples `0x823800`–`0x823824` at two hooks.
  Read-only; root.
- Hooks: pre-FMC in `kgspSetupGspFmcArgs_GH100` (FSP executed, COT not sent, FMC
  does not exist) and post-boot in `_kgspSetFwWprLayoutOffset` (after
  `GET_GSP_STATIC_INFO`; GSP-RM up).
- Args used:
```bash
sudo tools/driver-harness/feat_preboot.sh
```

**Observed data.** Both cards, both points:

```text
GPU0 (c1:00.0) pre-FMC   = fffffb8f fffffb8f 01000380 00888888 002a2aaa 00000233 00c36180 54226037 00026005 00000003
GPU0 (c1:00.0) post-boot = fffffb8f fffffb8f 01000380 00888888 002a2aaa 00000233 00c36180 54226037 00026005 00000003
GPU1 (41:00.0) pre-FMC   = fffffb8f fffffb8f 01000280 00888888 002a2aaa 00000233 00c36180 21240001 00000002 00000003
GPU1 (41:00.0) post-boot = fffffb8f fffffb8f 01000280 00888888 002a2aaa 00000233 00c36180 21240001 00000002 00000003
```

The per-card [`SS0`](../specs/03_register-map.md#ss0-and-ss1)/`SS1` and the [`0x823808`](../specs/03_register-map.md#feat-bank) bit-8 difference are already present
before the FMC runs.

**Result.**

- **Answer:** no. Neither the FMC nor GSP-RM writes the bank.
- **What we learned:**
  - The writer is pre-driver, a GPU-side devinit action.
  - The rate selectors are fixed before any mutable firmware executes.
- **Related:**
  - The [boot-to-boot test](#0520-feat-bank-across-boots-and-flr) separates warm
    and cold boots.
  - The [re-lock test](#0521-plm-re-lock-is-autonomous-devinit) brackets the
    GPU-side actor.

## 05.18 COT public key anchored

**Question.** Is the COT `publicKey` field host-authoritative?

**Why.**

- If the host can substitute the key, it can sign a custom FMC.
- What it would give: a custom-FMC route, or proof the key is anchored.

**Method.**

- Tool: `tools/driver-harness/cotkey/gen_cot_key.py` generates a secp384r1 pair
  and signs the 48-byte SHA-384 of the stock container.
  `tools/driver-harness/fmc_oracle.sh 6` overwrites only `publicKey` and
  `signature` immediately before the FSP send. The private key stays local.
- Target: both cards, root.
- First reproduce the production verification: `openssl pkeyutl -verify
  -pkeyopt digest:sha384` accepts the stock hash against the stock
  key/signature, and `openssl dgst -sha384 -verify` accepts the whole container.
- Args used:
```bash
python3 tools/driver-harness/cotkey/gen_cot_key.py
sudo tools/driver-harness/fmc_oracle.sh 6
```

**Observed data.**

```text
BF16: COT self-signed key=04f20be3 sig=65bb6753
BF16: COT hash=ee0988fea62832c4b2fe90d87e2f6104 key=e30bf20469d9cb03818547adc45eed75 sig=5367bb6542b510288f7aa4c8fcb324c1
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x1db
```

One send per card; every retry then hit `unexpected WPR2 already up`, then
`RmInitAdapter failed! ([0x62](../specs/08_errors-and-logging.md#nv-status-codes):0x40:2168)`. The driver maps [`0x1db`](../specs/08_errors-and-logging.md#boot-error-codes) to
[`NV_ERR_GENERIC`](../specs/08_errors-and-logging.md#nv-status-codes) (`0x40`) because it is not in `kern_fsp_retval.h`.

**Result.**

- **Answer:** no. `0x1db` is distinct from the `0x377` hash failure. A
  self-consistent pair dies before the hash/signature check, so the key is
  validated separately and against something the host cannot supply.
- **What we learned:**
  - The COT key-substitution route is closed.
  - The GSP-RM `.fwsignature_gb20x` is `0x1000` bytes: a 20-byte header
    (`0x00020001`, size `0x8c8`, count `0x0c`, `0x0101`, stride `0x200`) and four
    384-byte high-entropy blocks on a `0x200` stride. It has no SHA-384 of
    `.fwimage`, no valid P-384 point at any `0x04` candidate, and no block shared
    across the ten chip sections; only the header is constant.
  - The resume path re-sends the existing `pCotPayload` and keeps the mapped
    image on `KGSP_BOOT_MODE_SR_RESUME`; it does not re-read the firmware file.
- **Related:**
  - The [hash test](#0516-cot-hash-authenticated-auth-failure-wedges) is the
    adjacent check.
  - The [suspend/resume experiments](../experiments/06_sr-resume.md) cover the
    restored state.
- **Open question:** whether the key is fused or inside the FMC is not confirmed.

## 05.19 FMC container read back and tampered

**Question.** Is the host-copied FMC container readable or decryptable in place,
and is the COT hash bound to the image bytes?

**Why.**

- `kfspSetupGspImages` copies the container into unprotected sysmem at
  `COT.gspFmcSysmemOffset`; if the FSP decrypts in place, the FMC corpus is
  readable at PL0.
- The driver copies the hash/signature/key verbatim and never checks them; if
  secure firmware trusts the hash without binding it to the image, a corrupted
  ciphertext byte becomes a plaintext bit flip in Heavy Secure (HS) code.
- What it would give: the FMC plaintext, or proof of binding.

**Method.**

- Tool: `tools/driver-harness/fmc_buffer_probe.sh` sets the dump/tamper defines,
  rebuilds 595.91.07, loads the instrumented modules, captures dmesg, and
  restores stock in the trap.
- `bf16DumpFmcBuffer()` maps the FMC memdesc read-only and writes it at `copy`
  (after `bindataWriteToBuffer`), `postsend` (after the FSP response), and
  `release` (before the memdesc is freed, so it also fires on the refused path).
- `BF16_FMCTAMPER` changes one byte after copy-in, leaving the COT stock.
- Tamper modes: ciphertext `0x1048`, plaintext body size at `0x04` (not run),
  plaintext magic at `0x00`.
- Args used:
```bash
sudo tools/driver-harness/fmc_buffer_probe.sh dump
sudo tools/driver-harness/fmc_buffer_probe.sh tamper 1
sudo tools/driver-harness/fmc_buffer_probe.sh tamper 3
```

**Observed data.** The buffer is never touched. All six dumps (three points × two
cards) share one SHA-256:

```text
copy     6e88068fcb276ca3800b2fb154fa3228ccd1f2a9493945d8cfd9da527123e290
postsend 6e88068fcb276ca3800b2fb154fa3228ccd1f2a9493945d8cfd9da527123e290
release  6e88068fcb276ca3800b2fb154fa3228ccd1f2a9493945d8cfd9da527123e290
```

The header reads `00480403 00046200 00000000 00037000 00000000 0000e800 00000104
00000000` (LE dwords), and the tail `[0x46248, 0x47000)` is zero. The FSP does not
decrypt in place and does not scrub.

Tamper with the COT stock:

| Change | FSP response | WPR2 |
|---|---|---|
| ciphertext `0x1048` `0xee`→`0xef` | [`0x33`](../specs/08_errors-and-logging.md#boot-error-codes) (task `0x1`, cmd `0x14`) | left up |
| header `0x00` `0x03`→`0x02` | `0x33` | left up |

The tampered dump has SHA-256
`81b05d6e69829bc678e8724bd3782695697e84f49dcfdd46c85e32b9b4a3fd4f`, and `cmp`
against the stock container finds exactly one byte. Mode 2 was not run: the
body-size field is inside the same container, so both explanations predict
`0x33`.

**Result.**

- **Answer:** the FSP does not decrypt the container in place. The image is bound
  to the COT hash, header included, and a corruption draws `0x33`.
- **What we learned:**
  - The order is: verify the signature over the claimed hash, then bind the image
    to that hash.
  - The container is not a pre-auth parser surface.
  - A corrupted ciphertext byte never reaches the decrypted image.
- **Related:**
  - The [hash test](#0516-cot-hash-authenticated-auth-failure-wedges) flips the
    claimed hash and gets `0x377`.
  - The [bootloader buffer test](#0524-bootloader-buffer-not-decrypted-in-place)
    repeats the check for `GspRmBoot`.
- **Open question:** a TOCTOU window between the hash read and the decrypt read
  is not characterised.

## 05.20 FEAT bank across boots and FLR

**Question.** What writes `SS0`/`SS1` across boots, and how does reset affect
them?

**Why.**

- The boot-to-boot `SS0` movement means a mutable pre-FMC writer exists.
- The bank's reset behavior can be separated from its power-on initialization.
- What it would give: the writer's domain, or proof it is power-cycle-tied.

**Method.**

- Tool: `tools/driver-harness/featbank_writer_probe.sh` reads only
  `0x823800`–`0x823824` plus controls ([`PMC_BOOT_0`](../specs/03_register-map.md#chip-wpr-and-boot-targets), WPR2, FSP scratch/status,
  GSP engine/reset [PLM](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm), the bank's read/write permission mask) through BAR0. It writes one CSV row per sample.
- Target: both cards, root.
- Samples: early boot (`pre`, before `systemd-udev-trigger`), post-driver, 60 s
  (`late`), and shutdown, across five cold power cycles and two warm reboots.
  `41:00.0` was additionally FLR'd with the driver unbound and rebound. PCIe
  link speed/width is recorded at every sample. The cycle order for the last
  four boots was **W W C C**.
- Args used:
```bash
sudo tools/driver-harness/featbank_writer_probe.sh selftest
sudo tools/driver-harness/featbank_writer_probe.sh flr 0000:41:00.0
```

**Observed data.** In every boot `pre == post == late == shutdown`; the SS words
were invariant for the whole boot, including a 7.5 h run and its shutdown sample.
Across boots:

| boot | cycle | `41:00.0` SS0 / 808 | `c1:00.0` SS0 / SS1 |
|---|---|---|---|
| `e13ba871` | cold | `0x21240001` / `0x01000280` | `0x54226037` / `0x00026005` |
| `2e47071d` | cold | `0x20240001` / `0x00000080` | `0x54224037` / `0x00026005` |
| `1bccdffa` | cold | `0x20260041` / `0x01000280` | `0x54226037` / `0x00026005` |
| `f76038a2` | warm | `0x20260041` / `0x01000280` | `0x54226037` / `0x00026005` |
| `6114b0ad` | warm | `0x20260041` / `0x01000280` | `0x54226037` / `0x00026005` |
| `a3fa7a97` | cold | `0x21265047` / `0x01000280` | `0x54225037` / `0x00026005` |
| `31ea4a44` | cold | `0x21265043` / `0x01000280` | `0x54226037` / `0x00024005` |

The words changed only across cold power cycles; both warm reboots reproduced the
prior values exactly. `0x823808` moved once (`41:00.0` `0x01000280` → `0x00000080`).
[`FEAT_READOUT_1`](../specs/03_register-map.md#readout-decode) was `0x00c36180` in every sample, and every nibble of every SS
word stayed below 8 (no override enable). Link speed/width was constant
`16.0 GT/s x16`, so the moving bits do not track link training.

With `41:00.0` unbound and FLR'd, SS0/SS1/`0x823808`/`READOUT_1` persisted
unchanged while WPR2 reset and the GSP became inaccessible. [`FEAT_OVR_PLM`](../specs/03_register-map.md#write-gate)
(`0x823800`/[`0x823804`](../specs/03_register-map.md#write-gate)) changed from `0xfffffb8f` to `0x80842bcf` and was restored
to `0xfffffb8f` after the rebind. [`0x80842bcf`](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) decodes as read mask `0xf`, write
mask `0xc` (PL2+[PL3](../specs/02_privilege-and-rate-control.md)), source-enable `0x80842`; `0xfffffb8f` is read-all /
write-PL3.

**Result.**

- **Answer:** the SS words are initialized at GPU power-on by a source with a
  fixed per-card base and a small variable component.
- **What we learned:**
  - They are not written by the driver, the FMC, GSP-RM, the host POST, or the
    warm-boot path.
  - The FLR leaves them outside its reset domain but resets the PLM, which the
    boot path re-locks.
  - The words are inert: every nibble stays below 8.
- **Related:**
  - The [pre-FMC sampler](#0517-feat-bank-final-before-the-fmc) fixes the timing.
  - The [re-lock test](#0521-plm-re-lock-is-autonomous-devinit) names the reset
    behavior.

## 05.21 PLM re-lock is autonomous devinit

**Question.** What re-locks the PLM after an FLR?

**Why.**

- The FLR leaves the PLM at [`0x80842bcf`](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm), which admits PL2 writes.
- If the host or GSP-RM does the re-lock, the timing is a lever; if a GPU-side
  devinit does it, the window is closed before the host can use it.
- What it would give: the re-lock bracket, or a usable window.

**Method.**

- Tool: `tools/driver-harness/feat_preboot_flr.sh` builds 595.91.07 with
  `BF16_FEAT_PREBOOT=1`, `BF16_FEAT_NVPROBE=1`, and `BF16_FEAT_RMINIT=1`. It
  unbinds, FLRs, and rebinds `41:00.0`, then reads the 10 FEAT words at each
  attach bracket.
- Brackets: `nv_pci_probe` (after `pci_enable_device`/BAR0 request),
  `nv-pre-set-master`/`nv-post-set-master`, `nv_start_device-entry` (first open),
  `nv-pre-rm-init`, `RmInitAdapter` entry, `rm-gpu-got`, `kgspInitRm_IMPL` entry,
  before `_kgspBootGspRm`, `_kgspBootGspRm` entry,
  `kgspPrepareForBootstrap_GH100` entry, and `kgspSetupGspFmcArgs_GH100`
  (pre-COT). The post-boot hook fires after GSP-RM. `nvidia-smi` triggers the
  first open.
- Args used:
```bash
sudo tools/driver-harness/feat_preboot_flr.sh 0000:41:00.0
```

**Observed data.**

```text
BF16: FEAT [nv_pci_probe]          = 80842bcf 80842bcf 01000280 00888888 ...
BF16: FEAT [nv-pre-set-master]     = 80842bcf 80842bcf 01000280 00888888 ...
BF16: FEAT [nv-post-set-master]    = 80842bcf 80842bcf 01000280 00888888 ...
BF16: FEAT [nv_start_device-entry] = fffffb8f fffffb8f 01000280 00888888 ...
```

Every later bracket (`nv-pre-rm-init`, `rmInit-entry`, `rm-gpu-got`, `initRm-entry`,
pre-FMC, post-boot) read `0xfffffb8f`; SS0/SS1/`0x823808`/`READOUT_1` did not
change at any point. The module-load control (before the unbind) was already
`0xfffffb8f`.

**Result.**

- **Answer:** the FLR's `0x80842bcf` is re-locked inside the ~3 s after the PCI
  probe and before the first open, with no host code executing.
- **What we learned:**
  - The COT, the FMC, and GSP-RM do not do the re-lock.
  - The host is [PL0](../specs/02_privilege-and-rate-control.md) and neither PLM value admits L0 writes.
  - The writer is a GPU-side master acting on the enabled function, using the
    reset mask's L2 permission. PMU devinit is the leading candidate (PL2). The
    [FLR poll](../experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)
    sees no FSP core, scratch, engine, or PLM movement at the re-lock, so the
    FSP is excluded on the visible registers; the PMU or a hardware latch
    remains.
- **Related:**
  - The [boot-to-boot test](#0520-feat-bank-across-boots-and-flr) separates the
    SS domain.
  - The [vBIOS scan](#0522-vbios-devinit-table-scan) closes the plaintext-table
    route.
- **Open question:** the exact devinit that performs the re-lock is not named.
  The [FLR poll](../experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)
  leaves the PMU or a hardware latch; [engine-map
  completion](../IDEAS.md#engine-map-completion) is where the actor is named.

## 05.22 vBIOS devinit table scan

**Question.** Is the pre-lock FEAT writer table-driven by plaintext vBIOS
devinit tables?

**Why.**

- The [re-lock test](#0521-plm-re-lock-is-autonomous-devinit) leaves a GPU-side
  devinit as the writer.
- If its writes come from plaintext vBIOS tables, a custom-VBIOS no-flash route
  could become a PL2 lever.
- What it would give: a host-side table lever, or proof the tables are
  authenticated.

**Method.**

- Tool: `tools/vbios-tools/devinit_scan.py`. It parses the ROM chain with the
  NPDE override, finds the BIT and the `0x70` token, parses the 35-entry PMU
  lookup table and the v6 descriptors, then scans every byte for FEAT addresses
  in both endiannesses and the eight `DEVINIT_USE_*` flag forms.
- It also scans every devinit opcode whose 32-bit address lands in
  `0x823800`–`0x8238FF`; u32/u64 register-address lists in
  `0x820000`–`0x824000`; and the known PLM values, mapping each hit to its ucode
  body.
- Target: the card's own vBIOS dump.
- Args used:
```bash
sudo tools/vbios-tools/prom_read_raw <bdf> <out>
python3 -I tools/vbios-tools/devinit_scan.py <out>
```

**Observed data.** The 2 MiB aperture scan:

```text
== FEAT address literals (raw and devinit-flag forms)
  none
== devinit opcodes with an address in 0x823800-0x8238ff
  none
== register-address list runs (FUSE 0x820000-0x824000)
  stride 8 @0x9b8e5..0x9bb1d n=72 min=0x820800 max=0x8221a4 FEAT=False
== anchor values
  PLM_locked 0xfffffb8f n=4  ['0x10c0e8', '0x12032c', '0x12142c', '0x12f0e8']
  PLM_bit10  0xfffffbff n=7
  Ada_FEAT   0xffffff8f n=9
  Ada_FBPA   0xffffff0f n=7
  poison     0xbadf5040 n=10701
  sentinel   0xbadf1100 n=241883
== anchor ownership by ucode body
  PLM_locked 0xfffffb8f ['app0x23/tgt0x0e']
```

Layout of the 1 MiB image (the 2 MiB aperture is the same image at `+0x38000`):

| Item | Value |
|---|---|
| Images | PciAt `0x0` (0xFA00), EFI `0xFA00` (0x18000), FwSec `0x27A00` (0xFA00), FwSec `0x37400` |
| EFI correction | `0x18000` |
| BIT | `0xDF0`, 20 tokens |
| `0x70` token | data `0x10C1` → table pointer `0x4CE9D` → table `0x64E9D` |
| Ucode table | version 1, header 6, stride 6, 35 entries |
| Real images | `0x07`/tgt `0x06` (`0x6FDA0`, body `0x6FDF0`–`0x8FFF0`), `0x19`/tgt `0x01` (`0x8FFF0`, body `0x90040`–`0xB1B40`), `0x15`/tgt `0x01` (`0xB1C30`, body `0xB1C80`–`0xB7780`), `0x23`/tgt `0x0E` (`0xB77BC`, body `0xB780C`–`0xD5A0C`) |
| Placeholders | `0x18`/tgt `0x01` (`0xD6104`) and `0x24`/tgt `0x0F` (`0xE3304`) both read [`0xBADF1100`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) |

All four real descriptors are v6, size `0x50`, encrypted bit set, body entropy
8.0. App `0x23`'s body is 64 KiB encrypted code (`0xB780C`–`0xC780C`), a ~2 KiB
header (`0xC780C`–`0xC8000`), then plaintext data (`0xC8000`–`0xD5A0C`, entropy
2–3) with a [`0xBADF5040`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) poison field and the PLM values.

The GSP-RM string table carries the DEVINIT authentication errors:

```text
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_HEADER_DATA_NOT_PRESENT
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_SIGNATURE_TYPE_MISMATCH
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_DERIVEHWKEY_DOAESECB_NOT_IN_HSMODE
NV_UDE_ERR_DEVINIT_AUTHENTICATE_DATA_PATCHER_...
NV_UDE_ERR_DEVICE_ID_WITH_DEVINIT_SCRIPTS_MISMATCH
NV_UDE_ERR_UCODE_DMEM_VERIFICATION_FAILED
```

**Result.**

- **Answer:** no plaintext FEAT address or devinit opcode exists in the image.
- **What we learned:**
  - Zero FEAT address literals in the 1 MiB image or the 2 MiB aperture, on
    either card, in either endianness, raw or OR'd with
    `0x20000000`/`0x40000000`/`0x80000000`.
  - Zero devinit opcodes with a FEAT address. `0x6E`, `0x7A`, `0x48`, `0x47`,
    `0x10`–`0x13`, `0x20`–`0x23`, `0x2C`, `0x58`, `0x91` were tested.
  - One register-address list: a 72-entry 64-bit table at `0x638E5`
    (`0x820800`–`0x8221A4`, the FUSE/strap block). No FEAT entry.
  - The PLM values are in app `0x23`/target `0x0E` only:
    `0xFFFFFB8F` (4 hits), `0xFFFFFBFF` (7), `0xFFFFFF8F` (9), `0xFFFFFF0F`
    (7), all inside `0xB780C`–`0xD5A0C`. The other three bodies are encrypted
    throughout.
  - The DEVINIT tables and scripts are signed and authenticated in HS mode with
    AES-ECB, bound to the device ID, and the ucode DMEM is verified. A plaintext
    edit fails authentication.
  - The no-flash custom-VBIOS route changes what the host driver parses, not
    what the GPU's HS firmware authenticates from flash.
- **Related:**
  - The [re-lock test](#0521-plm-re-lock-is-autonomous-devinit) leaves the
    encrypted actor.
  - The [firmware-format spec](../specs/04_firmware-formats.md) covers the
    container.
- **Open question:** the encrypted app `0x23` code is not decrypted; it could
  still target the FEAT block at runtime.

## 05.23 WprMeta bootloader description and images

**Question.** Does the FMC consume the host bootloader description or a
host-controlled length before authenticating?

**Why.**

- `sysmemAddrOfBootloader`, [`sizeOfBootloader`](../specs/01_boot-chain.md#wprmeta), and the in-image offsets are
  host-filled, plus a 4 KB signature buffer.
- A host-controlled length or offset in a copy/parse ahead of the check would be
  the GB202 analogue of the Ada `BooterLoadUcode` bug.
- What it would give: a pre-auth primitive, or proof the fields are checked.

**Method.**

- Tool: `tools/driver-harness/wpr_oracle.sh` fields 8–16 vary one `WprMeta`
  field per module reload.
- `tools/driver-harness/boot_tamper_run.sh` flips one ciphertext byte in
  `pGspRmBootUcodeImage` with every other field stock.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/wpr_oracle.sh 8 0x47001
sudo tools/driver-harness/wpr_oracle.sh 12 0xffffffff
sudo tools/driver-harness/boot_tamper_run.sh
```

**Observed data.** Stock layout on card 0:

```text
BF16: WprMeta radix3Elf{addr=0x139600000 size=72830976}
  bootloader{addr=0x1a1900000 size=290816 cOff=0xf200 dOff=0xa00 mOff=0x0}
  sig{addr=0x19b276000 size=0x1000} gspFw{start=0x0 heapOff=0x0 heapSize=0x8700000}
  nonWpr{off=0x0 size=0x300000} frts{off=0x0 size=0x100000}
  wprEnd=0x0 fbSize=0x0 verified=0x0
```

The field matrix, one field per run:

| Field (oracle #) | Value | Result |
|---|---|---|
| `sizeOfBootloader` (8) | `0x47001` | **[`0x82e`](../specs/08_errors-and-logging.md#boot-error-codes)** on both cards; the value is misaligned |
| `sysmemAddrOfBootloader` (9) | none | not run |
| `bootloaderCodeOffset` (10) | `0xffffffff` | boots; unchecked or unused |
| `bootloaderDataOffset` (11) | `0xffffffff` | boots; unchecked or unused |
| `bootloaderManifestOffset` (12) | `0xffffffff` | **[`0x885`](../specs/08_errors-and-logging.md#boot-error-codes)** on both cards; the value is out of range |
| `sysmemAddrOfSignature` (13) | none | not run |
| `sizeOfSignature` (14) | `0x100000` | boots; the verifier uses a fixed 0x1000 parse |
| `sysmemAddrOfRadix3Elf` (15) | none | not run |
| `sizeOfRadix3Elf` (16) | `0x100000` | **[`0xaff`](../specs/08_errors-and-logging.md#boot-error-codes)**, info `0xb`; bound into authentication |

The address fields and the aligned manifest sweep were run later in [the parser
group](09_fmc-cold-boot-parsers.md). The `sizeOfBootloader` check is 4 KiB
alignment, and an aligned non-zero manifest offset draws `0x841`; the `0x885`
here is an out-of-range refusal.

The error lines:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x82e, additional info=0x0
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x885, additional info=0x0
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
```

**Result.**

- **Answer:** no. The FMC validates the bootloader size and manifest offset,
  ignores the code/data offsets and the signature size, and binds the GSP-RM
  image size into authentication.
- **What we learned:**
  - Flipping the first ciphertext byte (`0x84`→`0x85`) is refused with
    `0xaff`/info `0xb` on all four attempts; the untampered second card boots.
  - No host-controlled length or offset reaches a pre-authentication copy.
- **Related:**
  - The [patched-image test](#052-patched-gsp-rm-image-rejected-by-the-fmc) uses
    the same image check.
  - The [container binding](#0519-fmc-container-read-back-and-tampered) covers
    the FMC container.

## 05.24 Bootloader buffer not decrypted in place

**Question.** Does the FMC decrypt the host-supplied `GspRmBoot` image in place?

**Why.**

- The image sits in unprotected sysmem at [`WprMeta.sysmemAddrOfBootloader`](../specs/01_boot-chain.md#wprmeta).
- If the FMC decrypts in place, the 290,816-byte HS plaintext is readable at PL0
  after boot.
- What it would give: the cheapest decrypted-firmware route, or proof it stays
  ciphertext.

**Method.**

- Tool: `tools/driver-harness/bootbuf_dump.sh` builds 595.91.07 with
  `BF16_BOOTDUMP=1`, loads the instrumented modules, triggers a normal boot,
  restores stock in the trap, and dumps `pGspRmBootUcodeImage` at
  `kgspPopulateWprMeta_GH100` (pre-COT) and `_kgspSetFwWprLayoutOffset`
  (post-boot).
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/bootbuf_dump.sh
```

**Observed data.**

```text
gpu0: size 290816/290816 entropy 7.9835/7.9835 sha256 f5f63a71bb17b07d/f5f63a71bb17b07d diff_bytes 0
gpu1: size 290816/290816 entropy 7.9835/7.9835 sha256 f5f63a71bb17b07d/f5f63a71bb17b07d diff_bytes 0
```

The compare output prints the first 16 hex digits of SHA-256. Both sample points
and both cards agree.

**Result.**

- **Answer:** no. The FMC does not decrypt the bootloader in place and does not
  scrub it.
- **What we learned:**
  - It leaves the stock ciphertext, matching the FMC container.
  - No host-side plaintext is produced; the decrypted image lives in protected
    memory or FB.
- **Related:**
  - The [FMC container test](#0519-fmc-container-read-back-and-tampered) repeats
    the check.
  - The [FB route test](#0525-fb-route-shut) covers the remaining memory route.

## 05.25 FB route shut

**Question.** Can a host FB read reach the decrypted bootloader?

**Why.**

- The earlier model put the boot image at runtime VA `0xefd00000`, hence PA
  `0x5dd00000` (subtracting the GSP-RM `+0x92000000` offset), outside the WPR.
- [The BAR1 probe](../experiments/08_assessment-and-cross-checks.md) had failed
  its positive control.
- What it would give: the boot image, or proof the host cannot read it.

**Method.**

- Tool: `tools/driver-harness/fb_capture.sh` in three runs, each triggered by
  `nvidia-smi`/`nvidia-drm` opening the GPUs (`NVreg_GpuInitOnProbe=0`).
- Steps:
  1. BAR1 mapping at `kgspPopulateWprMeta_GH100` (before the COT); the hook
     published the translation for `0x01000000`, `0x5DC00000`, and `0x181C0000`.
  2. BAR0 PRAMIN window read in `_kgspSetFwWprLayoutOffset`: 64 KiB at BAR0
     `0x700000`, base moved with `kbusSetBAR0WindowVidOffset` and restored.
  3. WPR read over `[frts − 0x50000, frts)` and FRTS, with the non-WPR heap at
     GSCI `nonWprHeapOffset` as the control.
- Target: `41:00.0`, root; stock restored in a trap.
- Args used:
```bash
sudo tools/driver-harness/fb_capture.sh
```

**Observed data.** BAR1 does not exist during the boot:

```text
FBMAP gpu=0 static=0 start=0x0 size=0x0 aperture=0x0
BUG: kernel NULL pointer dereference, address: 0000000000000000
RIP: dmaAllocMapping_GM107+0xfd/0x2300
Call Trace: bf16FbMapRanges -> kgspPopulateWprMeta_GH100 -> kgspInitRm_IMPL
```

`kbusInitBar1` is called from `kbusStatePostLoad` in `gpuStateLoad`, after
`kgspInitRm`. The oops killed the loading thread; the machine was rebooted before
the next run.

The BAR0 window works. Post-boot, the window write lands and reads back:
`want=0x100 after=0x100` for PA `0x01000000`, `want=0x5dd0 after=0x5dd0`,
`want=0x7e72e after=0x7e72e`. The non-WPR heap control at `0x7e72e0000` returns
**58,707 nonzero bytes, entropy 7.6408**, identical on both cards.

Through that window:

```text
fb_nwpr_gpu0_7e72e0000.bin   size=0x10000 nz=58707 ent=7.6408 head=02000200200000001a00000000010000
fb_boot1_gpu0_5dd00000.bin   size=0x48000 nz=0 ent=-0.0000 head=00000000000000000000000000000000
fb_boot2_gpu0_181d0000.bin   size=0x48000 nz=0 ent=-0.0000 head=00000000000000000000000000000000
fb_elf_gpu0_1000000.bin      size=0x10000 nz=0 ent=-0.0000 head=00000000000000000000000000000000
fb_frts_gpu0_7f42c0000.bin   size=0x10000 nz=49152 ent=2.0000 head=00acd0ba00acd0ba...
fb_wprbin_gpu0_7f4270000.bin size=0x50000 nz=245760 ent=2.0000 head=00acd0ba00acd0ba...
```

`0x01000000`, `0x5dd00000`, and `0x181d0000` read zero. The WPR range returns the
repeating dword [`0xbad0ac00`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) (entropy exactly 2.0, three nonzero bytes per dword).

**Result.**

- **Answer:** no. The FB/BAR1 route is closed by hardware.
- **What we learned:**
  - [BAR1](../specs/07_memory-and-host-access.md#bar0-and-bar1) does not exist during the boot: offsets are BAR1-VAS offsets, not FB
    physical addresses, and the VAS is not built when the HS boot runs.
  - Do not repeat the mapping before `gpuStateLoad`; it oopses on a NULL PTE
    array.
  - The BAR0 window is the working host FB path.
  - The candidate PAs are empty: `0x01000000`, `0x5dd00000`, `0x181d0000`.
  - The boot image is inside the WPR at `frts − sizeOfBootloader` = `0x7f4279000`;
    every host read of that range returns `0xbad0ac00`.
- **Related:**
  - The [non-WPR heap analysis](#0526-non-wpr-heap-holds-no-rm-objects) uses the
    same window.

## 05.26 Non-WPR heap holds no RM objects

**Question.** Does the 3 MiB GSP-RM [non-WPR heap](../specs/07_memory-and-host-access.md#the-non-wpr-heap) contain the live RM objects
behind the FEAT method, the config object, and the GR context/ucode descriptor?

**Why.**

- The [FB route test](#0525-fb-route-shut) gave a working host read of unprotected
  FB.
- If the RM objects live there, a host read could expose the selector method.
- What it would give: the RM object layout, or proof it is in the WPR.

**Method.**

- Tool: `tools/driver-harness/fb_capture.sh` dumps the whole 3 MiB heap plus
  three 64 KiB windows (below the start, the start, and one window past the end)
  through the [BAR0 window](#0525-fb-route-shut), both cards, immediately after
  GSP-RM is up.
- `tools/driver-harness/fbread_analyze.py` mines it offline: pointer census by
  region, ASCII/UTF-16 strings, known handler runtime VAs, FEAT constants.
- Target: both cards, root.
- Args used:
```bash
sudo tools/driver-harness/fb_capture.sh
python3 -I tools/driver-harness/fbread_analyze.py <run-dir>
```

**Observed data.**

```text
fb_heap_gpu0_7e72e0000.bin  size=0x300000 nz=1686643 ent=5.2825
fb_heap_gpu1_7e72e0000.bin  size=0x300000 nz=1686643 ent=5.2825
pointers: code=3324 distinct=3324 data=6569 heap/stack=26490
ascii strings: 2757, utf16 strings: 0
```

Both cards are byte-identical, SHA-256
`dacca64feb98a6adf61836ff71ed2860b02bb4513e21b7807638f875de142c52`. Structure by
block:

| Range | Content |
|---|---|
| `+0x000000`–`+0x010000` | 64 KiB structured header (90% nonzero, entropy 7.64) |
| `+0x010000`–`+0x1A10A2` | `0x1910A2` bytes of uniform random (entropy 7.999–8.000), one 8,288-byte zero hole at `blob+0x18F000` |
| `+0x1A10A2`–`+0x300000` | zero |

The 64 KiB prefix equals an independently read 64 KiB window at the same PA, so
the read path is consistent. There is no object structure: 3,324 dwords fall in
the code VA range and every one is distinct (the chance rate for the random
span), the 16-byte block histogram is 102,149 distinct values in 102,666 blocks,
and none of the eight known handler runtime VAs (`FUN_ram_0160f1bc` =
`0x934801bc`, `FUN_ram_01c1f378` = `0x93a90378`, …) appears anywhere in the 3 MiB.

**Boundary.** The WPR sentinel `0xbad0ac00` starts at `0x7e75e0000`, exactly
`nonWprHeapOffset + 0x300000`: the published non-WPR heap size is the whole heap,
and the WPR starts at `0x7e75e0000`. The 64 KiB window below the published start
also holds data (6,766 nonzero bytes), so the start is an allocation boundary, not
the edge of FB. The captured GSP log corroborates the region
(`INIT id=0x20187640 args=[0x7e72e0000, 0x300000]`).

**Result.**

- **Answer:** no. The 3 MiB non-WPR heap is not where GSP-RM's RM objects live.
- **What we learned:**
  - It holds a small structured header and one ~1.6 MiB high-entropy allocation
    of unknown provenance (deterministic across both cards in this boot, not
    object memory), and is otherwise zero.
  - The RM objects are allocated from the WPR heap (`gspFwHeapOffset`, 135 MiB),
    inside the protected region; host reads return the sentinel.
  - A runtime view would need GSP-RM cooperation (an RPC that reads or copies its
    heap) or a PL3 primitive.
- **Related:**
  - The [FB route test](#0525-fb-route-shut) proves the window.
- **Open question:** what the high-entropy allocation is.

