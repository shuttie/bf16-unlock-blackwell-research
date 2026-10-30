# FMC / FSP boot inputs

This group covers the host-built inputs consumed by secure firmware at boot: the
COT message, the `WprMeta` descriptor, the bootloader description, and the FMC
container. It also covers the vBIOS devinit tables and the memory routes used to
look for the decrypted boot image. Most records are oracle runs: one field is
varied per boot, and the structured error code or layout delta is measured.

## Hardware and tools

- 2× RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07, Linux, CUDA 13.
- `deviceId 1` is `41:00.0`; `deviceId 0` is `c1:00.0`.
- Oracle harness: [driver harness](../tools/driver-harness/) — `fmc_oracle.sh`,
  `wpr_oracle.sh`, `boot_tamper_run.sh`, `bootbuf_dump.sh`, `fmc_buffer_probe.sh`,
  `feat_preboot.sh`, `feat_preboot_flr.sh`, `fb_capture.sh`, `fbread_analyze.py`.
- vBIOS scan: [vBIOS tools](../tools/vbios-tools/) — `devinit_scan.py`,
  `prom_read_raw`.
- Container work: [FMC tools](../tools/fmc-tools/) — container extraction and
  signature verification.

## Inputs

The harness needs your own copies of:

- `nvidia.ko` and `gsp_ga10x.bin` from the 595.91.07 driver package;
- the FMC and bootloader images from the same package;
- the `GspRmBoot` image from the driver bindata;
- a vBIOS dump from the card under test.

None of these are redistributed. The tool READMEs give the extraction steps. The
driver source is the NVIDIA open kernel modules at tag 595.91.07.

## Setup

1. Check out the open kernel modules at tag 595.91.07 and apply the harness patch
   `tools/driver-harness/bf16_boot_instr.patch`, plus the record-specific patch.
2. Build with `make clean && make modules -j`.
3. Disable Secure Boot or sign the built modules. Keep the stock DKMS modules as
   recovery.
4. Load the instrumented modules, run the record, and restore the stock driver in
   a trap. Most failure paths leave WPR2 armed; reboot before the next attempt.
5. Record whether the boot was cold or warm. A warm reboot preserves the FEAT
   words; a cold power cycle re-initializes them.

## Terms

- **COT**: chain-of-trust message the host sends to the FSP. It carries the FMC
  address, FRTS layout, SHA-384, P-384 key, and signature.
- **WprMeta**: 256-byte host-filled boot descriptor consumed by the FMC on a cold
  boot.
- **FRTS**: firmware runtime state region inside the WPR.
- **WPR**: write-protected VRAM region holding firmware, boot image, and heaps.
- **PL0 / PL2 / PL3**: host / GSP-RM / heavy-secure privilege levels.
- **PLM**: per-block read/write permission mask.
- **GSCI**: the GSP static-info query that returns the post-boot WPR layout.
- **ACR**: the authenticated code region loader that patches `WprMeta` before the
  FMC runs.
- **HS**: heavy secure.
- **Oracle**: a harness that changes one boot field per run and captures the
  structured error code.

<a id="e14"></a>
## E14 · Host-side boot and static-info instrumentation

*2026-10-25 · Revision 13b · status: negative for host-supplied rate*

**Instrument.** `tools/driver-harness/load_patched.sh` builds the open modules at
exact tag 595.91.07 with `NV_PRINTF` calls in `kgraphicsLoadStaticInfo_KERNEL`
(V1/V2), `kgspSetupLibosInitArgs_IMPL`, and `_kgspSetupGspFmcArgs_GH100`. Root;
the stock DKMS modules are kept as recovery.

**Method.** Build, add the prints, load the built modules. Secure Boot is disabled
and vermagic matches.

**Observed data.** dmesg at module load, before any CUDA context:

```text
NVRM: GPU0 kgraphicsLoadStaticInfo_KERNEL: BF16: KGR SM issue rate modifier grIdx=0:
  imla0=0 fmla16=0 dp=0 fmla32=3 ffma=0 imla1=3 imla2=3 imla3=0 imla4=3
NVRM: GPU0 kgraphicsLoadStaticInfo_KERNEL: BF16: KGR SM issue rate modifier V2 grIdx=0 size=10
```

The libos init args print as `kind=1 loc=1 id8=%#x pa=%#llx size=%#llx`; the
printer does not expand `%#x` in this codebase. `GSP_ARGUMENTS_CACHED` has no rate
field.

**Result.** The host does not supply the nine selector values. The GSP returns them
at boot; the FMC boot params contain only registry keys and descriptor/address
fields.

**Reproduce.**
1. Build the tree at 595.91.07 and add the `BF16:` prints.
2. `sudo tools/driver-harness/load_patched.sh`.
3. `dmesg | grep 'BF16:'`; expect the KGR lines above and no rate field in the FMC
   boot params.

**Limits.** Shows the host receives the nine values from the GSP at load time. It
does not show who programmed the GSP side.

<a id="e15"></a>
## E15 · A patched GSP-RM image is rejected by the FMC

*2026-10-25 · Revision 13c · status: CLOSED-MEASURED*

**Instrument.** `tools/driver-harness/run_gsp_patch_test.sh` installs a patched
`gsp_ga10x.bin` and loads the instrumented modules; the COT and every layout field
stay stock.

**Method.** Replace the first instruction of `FUN_ram_015ffae8` with `ret`
(`jalr x0, 0(ra)` = `0x00008067`). Flat `0x015ffae8` maps to `.fwimage` offset
`0x5ffae8` and ELF file offset `0x5ffb28`; the original bytes are `39 71 06 fc`,
patched to `67 80 00 00`. The rest of the image is unchanged.

**Observed data.** Both cards, every attempt:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
Max GSP-RM boot attempts exceeded: 4/4
RmInitAdapter failed! (0x62:0x55:2168)
```

**Result.** A four-byte change is rejected before execution. The harness restores
the original firmware and reloads the stock driver; both cards return without a
reboot.

**Reproduce.**
1. Copy the firmware and patch `39 71 06 fc` to `67 80 00 00` at ELF offset
   `0x5ffb28`.
2. Install the image and run the harness; expect `0xaff`/info `0xb` four times per
   card.
3. Restore the original firmware in the same step; the harness does this in a trap.

**Limits.** The check that rejects the image is not identified here. The result is
that the FMC authenticates the GSP-RM image before execution.

<a id="e28"></a>
## E28 · Boot-input baseline and the ordinary FMC path

*2026-10-26 · Revision 27 · read-only · status: baseline*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 0` with the inert hook in
`tools/driver-harness/bf16_boot_instr.patch`; the run disables context dumps. Build
is exact 595.91.07; root.

**Method.** Two prints and a one-field COT override hook. `BF16_COT_VARY` selects
one field immediately before `kfspSendAndReadMessage` (1 size, 2 offset, 3
boot-args pointer, 4 FMC pointer, 5 hash flip); 0 is inert.

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

**Result.** The hash bytes match the production `GspRmFmcGfwProdSigned_GB202`
container `c04` (287,304 bytes), and the key is its production P-384 key. The
ordinary boot path uses the production-signed FMC.

**Reproduce.**
1. Build the tree with `BF16_COT_VARY=0`.
2. `sudo tools/driver-harness/fmc_oracle.sh 0`; capture dmesg.
3. Expect the same COT hash and key on both cards.

**Limits.** Baseline only; no field is varied. The FMC identity is as shipped in
this driver build.

<a id="e29"></a>
## E29 · First COT oracle: FRTS size rejected by the FSP (`0xd9`)

*2026-10-26 · Revision 28 · status: FSP validation mapped*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 1 0x80000` halves the COT
`frtsVidmemSize`; every other field is stock.

**Observed data.**

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
FSP boot cmds failed. RM cannot boot.
```

The retry recomputed `frtsVidmemOffset` to `0x10520000` and failed the same way.

**Result.** The FSP rejects a half-size FRTS region. The run also exposed a driver
lifetime bug: `kfspCleanupBootState_IMPL` destroyed the engine-lifetime
`pPollEvent`; the retry scheduled and destroyed the freed event and oopsed in
`hrtimer_active` (NULL `hrtimer.base`). The fix moves the destroy into
`kfspStateDestroy_IMPL` (NULL-guarded).

**Reproduce.**
1. `sudo tools/driver-harness/fmc_oracle.sh 1 0x80000`.
2. Expect `0xd9` from the FSP, not from the FMC.
3. Use the fixed tree; the original oops is a driver bug, not a firmware result.

**Limits.** Maps the size check. The oops is a driver lifetime bug.

<a id="e30"></a>
## E30 · FRTS size: the control boots, a larger size is refused

*2026-10-26 · Revision 29 · status: size check closed*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 1 0x100000` (control) and
`tools/driver-harness/fmc_oracle.sh 1 0x200000` (upper bound).

**Observed data.** Control boot:

```text
[drm] Initialized nvidia-drm 0.0.0 for 0000:c1:00.0 on minor 1
[drm] Initialized nvidia-drm 0.0.0 for 0000:41:00.0 on minor 2
```

No `FSP response reported error` line. The COT was byte-for-byte the baseline apart
from per-boot addresses.

Upper bound:

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
```

16 sends on GPU0, 8 on GPU1, all `0xd9`. The driver cycled placements `0x1b40000`,
`0x10520000`, `0x1ef00000`, `0x2d8e0000`; the code was the same at each.

**Result.** `0xd9` is attributable to the size value, not the plumbing. The FSP
requires exactly 1 MB. The event-lifetime fix held over a 24-send failure path.

**Reproduce.**
1. Run the control, confirm both minors and no `FSP response` line.
2. Run the upper bound, count `0xd9` lines; expect 24 total.
3. No oops should appear.

**Limits.** The rejection is keyed to the size value, not the placement.

<a id="e31"></a>
## E31 · A relocated FRTS base boots

*2026-10-26 · Revision 30 · status: offset is not pinned*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 2 0x10520000` — aligned,
in-range, stock size.

**Observed data.** Both cards boot; one COT send per card; no error line; both
minors come up. The COT hash is unchanged:

```text
BF16: COT hash=ee0988fea62832c4b2fe90d87e2f6104 ...
```

**Result.** The FSP does not pin the offset to the stock value. Acceptance is not
consumption; the layout test is [E33](#e33--a-second-accepted-base-and-the-from-end-units-correction)/[E34](#e34--the-cot-offset-positions-the-whole-gsp-rm-layout).

**Reproduce.**
1. `sudo tools/driver-harness/fmc_oracle.sh 2 0x10520000`.
2. Expect a clean boot on both cards and one COT send per card.

**Limits.** The FSP accepts the offset. Consumption is proven in [E33](#e33--a-second-accepted-base-and-the-from-end-units-correction)/[E34](#e34--the-cot-offset-positions-the-whole-gsp-rm-layout).

<a id="e32"></a>
## E32 · A misaligned base draws `0xd6`

*2026-10-26 · Revision 31 · status: alignment check mapped*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 2 0x10520001` — the [E31](#e31--a-relocated-frts-base-boots) base
plus one byte.

**Observed data.**

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd6
```

24 sends, 24 × `0xd6` (16 on GPU0, 8 on GPU1); no boot, no Xid, no oops; stock
restored and both cards listed.

**Result.** The FSP rejects rather than rounds. The two codes separate the checks:

| COT state | Code |
|---|---|
| `frtsVidmemSize != 0x100000` | `0xd9` |
| offset misaligned | `0xd6` |
| offset aligned and accepted | — |

**Reproduce.**
1. `sudo tools/driver-harness/fmc_oracle.sh 2 0x10520001`.
2. Expect `0xd6` on every send and a clean module restore.

**Limits.** The FSP rejects a misaligned base; it does not round it.

<a id="e33"></a>
## E33 · A second accepted base, and the from-end units correction

*2026-10-26 · Revision 32 · status: model corrected*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 2 0x10500000` with the extended
post-boot GSCI print.

**Observed data.**

```text
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7d8920000 frts=0x7e5900000
```

The pre-ACR `WprMeta` still reads `frts{off=0x0}`; the host's mapped copy does not
show the ACR's patch.

**Result.** Both cards boot. `frtsVidmemOffset` is from the end of FB, not an
absolute address, aligned up to 128K:

| Value | Meaning |
|---|---|
| stock `0x1b40000` | 27.25 MiB from the end |
| `0x10520000` | 261.1 MiB from the end |
| `0x10500000` | 261.0 MiB from the end |
| `0x10520001` | same, misaligned → `0xd6` |

The accepted base is 233.75 MiB below the driver's own end-reserve estimate, so the
FSP does not enforce that policy. The GSCI value is an absolute FB offset for the
WPR block; [E34](#e34--the-cot-offset-positions-the-whole-gsp-rm-layout) supplies the stock control.

**Reproduce.**
1. `sudo tools/driver-harness/fmc_oracle.sh 2 0x10500000`.
2. Expect the GSCI line above; compare with the stock [E34](#e34--the-cot-offset-positions-the-whole-gsp-rm-layout) line.

**Limits.** Corrects the units. Consumption is proven in [E34](#e34--the-cot-offset-positions-the-whole-gsp-rm-layout).

<a id="e34"></a>
## E34 · The COT offset positions the whole GSP-RM layout

*2026-10-26 · Revision 33 · status: consumption proven*

**Instrument.** Stock control versus `tools/driver-harness/fmc_oracle.sh 2
0x10500000`, both with the extended GSCI print.

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
| COT offset delta | — | — | `0xE9C0000` |

The three deltas are identical to the byte. The layout translates 1:1 with the host
value:

- `GSP_frts_abs = FB_end − COT_offset − 0xA200000` in both runs.
- `GSP_frts_abs − nonWprHeap = 0xCFE0000` in both runs.
- Stock WPR spans 189.25–397.1 MiB from the FB end; the moved one 423.0–630.9 MiB.

The pre-overwrite `WprMeta` fields read `0x0` on both cards: the host's mapped copy
does not reflect the ACR's patch, so the GSCI query is the only post-boot layout
source.

**Result.** The COT offset positions the whole GSP-RM WPR, not just the FRTS
region.

**Reproduce.**
1. Run the stock control and the moved boot back to back.
2. Diff the two GSCI lines; expect the same `0xE9C0000` delta on both.

**Limits.** Proves the host value positions the whole WPR. It does not show what the
FMC writes into FRTS.

<a id="e35"></a>
## E35 · The placement window reaches 1 GiB

*2026-10-26 · Revision 34 · status: model predictive*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 2 0x40000000` — 1 GiB from the
FB end.

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

**Result.** The window is at least 1 GiB, with no range check observed in either
direction; granularity below 128K and the small end are untested.

**Reproduce.**
1. `sudo tools/driver-harness/fmc_oracle.sh 2 0x40000000`.
2. Expect `frts=0x7b5e00000`, `nonWprHeap=0x7a8e20000`.

**Limits.** No observed range check in the tested window.

<a id="e36"></a>
## E36 · `WprMeta.magic` is enforced (`0x827`); `verified` is accepted

*2026-10-26 · Revision 35 · status: magic closed; verified deferred*

**Instrument.** `tools/driver-harness/wpr_oracle.sh 1` (bad magic) and
`tools/driver-harness/wpr_oracle.sh 3` (`verified = 0xa0a0a0a0a0a0a0a0`).

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

**Result.** `WprMeta.magic` is enforced. A preset `verified` reaches the FMC but has
no visible effect on initial boot; [E40](#e40--verified-does-not-bypass-image-verification) tests the bypass hypothesis directly.

**Reproduce.**
1. `sudo tools/driver-harness/wpr_oracle.sh 1`; expect `0x827` four times per card.
2. `sudo tools/driver-harness/wpr_oracle.sh 3`; expect a clean boot with the flag
   preset and the struct line above.

**Limits.** The magic is enforced. `verified` is not a cold-boot bypass.

<a id="e37"></a>
## E37 · `WprMeta` and COT sizes may disagree

*2026-10-26 · Revision 36 · status: missing cross-check, inert*

**Instrument.** `tools/driver-harness/wpr_oracle.sh 5` — `WprMeta.frtsSize =
0x200000` while the COT keeps `0x100000`.

**Observed data.**

```text
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7e72e0000 frts=0x7f42c0000
# no FSP or FMC error; both cards boot
```

**Result.** The FMC accepts the disagreement and builds the layout from the COT
value. The struct field is decorative on this path.

**Reproduce.**
1. `sudo tools/driver-harness/wpr_oracle.sh 5`.
2. Expect a clean boot and the stock layout.

**Limits.** A missing cross-check, not a lever.

<a id="e38"></a>
## E38 · The heap-size request is honoured, downward

*2026-10-26 · Revision 37 · status: live layout lever*

**Instrument.** `tools/driver-harness/wpr_oracle.sh 6 0x10000000` — 256 MiB
requested versus the stock 135 MiB.

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

**Result.** The extra request is honoured to the byte. The top stays anchored to
the COT base and the block grows downward. `span = 0xCFE0000 + (gspFwHeapSize −
0x8700000)`.

**Reproduce.**
1. `sudo tools/driver-harness/wpr_oracle.sh 6 0x10000000`.
2. Expect the GSCI line above; `nonWprHeap` moves down by `0x7900000`, `frts` does
   not move.

**Limits.** The heap request is honoured downward; the top stays anchored.

<a id="e39"></a>
## E39 · A 16 MiB heap request wedges the boot

*2026-10-26 · Revision 38 · status: wedge, not a refusal*

**Instrument.** `tools/driver-harness/wpr_oracle.sh 6 0x1000000` — a 16 MiB heap
request.

**Observed data.**

```text
GspStatusQueueInit: msgqRxLink failed: -7, nvStatus 0x00000065, retries: 2697191
Assertion failed: Call timed out [NV_ERR_TIMEOUT] ... @ kernel_gsp_gh100.c:1190
_kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
RmInitAdapter failed! (0x62:0x40:2168)
```

Both cards failed identically; the stock restore reported `No devices found.`

**Result.** The FMC accepts the COT and applies the layout without a sanity check
against GSP-RM's minimum. The failure is a hard wedge, not a structured refusal.
One reboot per point below the minimum; bisect from above.

**Reproduce.**
1. `sudo tools/driver-harness/wpr_oracle.sh 6 0x1000000`.
2. Expect the timeout and a wedged WPR2; reboot with `systemctl reboot -f`, and use
   a cold power cycle if WPR2 survives.

**Limits.** The FMC does not check the heap request against GSP-RM's needs.

<a id="e40"></a>
## E40 · `verified` does not bypass image verification

*2026-10-26 · Revision 39 · status: CLOSED-MEASURED*

**Instrument.** `tools/driver-harness/wpr_verified_patch_test.sh` installs the [E15](#e15--a-patched-gsp-rm-image-is-rejected-by-the-fmc)
patched GSP-RM, presets `WprMeta.verified`, and keeps the COT stock.

**Observed data.**

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
# 16 occurrences over four attempts per card; the verified flag was preset each time
```

**Result.** The FMC refuses the image on every attempt, both cards. The flag does
not change the image check. Recovery is clean, unlike [E15](#e15--a-patched-gsp-rm-image-is-rejected-by-the-fmc): firmware restored before
the stock restore, both cards back.

**Reproduce.**
1. Install the patched firmware from [E15](#e15--a-patched-gsp-rm-image-is-rejected-by-the-fmc).
2. Preset `WprMeta.verified` and run the harness.
3. Expect `0xaff`/info `0xb`; confirm the flag in the struct print before each
   attempt.

**Limits.** The image check is independent of the host-filled flag. A resume-path
use is not excluded here.

<a id="e41"></a>
## E41 · The COT hash is authenticated (`0x377`), and auth failure wedges

*2026-10-26 · Revision 40 · status: auth closed*

**Instrument.** `tools/driver-harness/fmc_oracle.sh 5` flips one bit in
`hash384[0]`; image, key, signature, and layout are stock.

**Observed data.**

```text
BF16: COT hash=ee0988ffa62832c4b2fe90d87e2f6104 ...
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x377
```

One send per card; every retry then hit `unexpected WPR2 already up`; the stock
restore found no devices.

**Result.** The COT hash is authenticated. Size, alignment, and magic rejections
restore cleanly; an auth failure leaves WPR2 up. The FSP arms WPR2 before
authenticating. Code map after this run: `0x83d`, `0xd9`, `0xd6`, `0x827`, `0x377`,
`0xaff`.

**Reproduce.**
1. `sudo tools/driver-harness/fmc_oracle.sh 5`.
2. Expect `0x377`; WPR2 is left up, so reboot before the next run.

**Limits.** The hash is authenticated; the auth-failure path wedges. Distinct from
the key-anchor code `0x1db` in [E61](#e61--the-cot-public-key-is-anchored-0x1db).

<a id="e54"></a>
## E54 · The FEAT bank is final before the FMC runs

*2026-10-26 · status: CLOSED-MEASURED (writer is pre-driver)*

**Hypothesis.** Something in the mutable boot chain (the FMC or GSP-RM) writes
`FEAT_OVR_PLM`, `FEAT_READOUT_1`, `SS0`, or `SS1`.

**Instrument.** `tools/driver-harness/feat_preboot.sh` builds 595.91.07 with
`BF16_FEAT_PREBOOT=1` and samples `0x823800`–`0x823824` at two hooks. Read-only;
root.

**Method.** Pre-FMC in `kgspSetupGspFmcArgs_GH100`: the FSP has executed, the COT
has not been sent, and the FMC does not exist yet. Post-boot in
`_kgspSetFwWprLayoutOffset`, after `GET_GSP_STATIC_INFO`: GSP-RM is up.

**Observed data.** Both cards, both points:

```text
GPU0 (c1:00.0) pre-FMC   = fffffb8f fffffb8f 01000380 00888888 002a2aaa 00000233 00c36180 54226037 00026005 00000003
GPU0 (c1:00.0) post-boot = fffffb8f fffffb8f 01000380 00888888 002a2aaa 00000233 00c36180 54226037 00026005 00000003
GPU1 (41:00.0) pre-FMC   = fffffb8f fffffb8f 01000280 00888888 002a2aaa 00000233 00c36180 21240001 00000002 00000003
GPU1 (41:00.0) post-boot = fffffb8f fffffb8f 01000280 00888888 002a2aaa 00000233 00c36180 21240001 00000002 00000003
```

The per-card `SS0`/`SS1` and the `0x823808` bit-8 difference are already present
before the FMC runs.

**Result.** Neither the FMC nor GSP-RM writes the bank. The writer is pre-driver, a
GPU-side devinit action; [E64](#e64--the-feat-bank-across-cold-boots-warm-reboots-and-an-flr)/[E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit) bracket it. The rate selectors are fixed before
any mutable firmware executes.

**Reproduce.**
1. `sudo tools/driver-harness/feat_preboot.sh`.
2. Expect byte-identical pre/post lines on both cards.

**Limits.** Neither the FMC nor GSP-RM writes the bank. The actor is pre-driver;
[E64](#e64--the-feat-bank-across-cold-boots-warm-reboots-and-an-flr)/[E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit) narrow it to GPU-side devinit.

<a id="e61"></a>
## E61 · The COT public key is anchored (`0x1db`)

*2026-10-27 · Revision 62 · status: CLOSED-MEASURED (key anchor)*

**Hypothesis.** The COT's `publicKey` field is host-authoritative: a self-signed
P-384 pair over the stock hash boots the stock FMC, and a re-signed container would
boot a custom one.

**Instrument.** `tools/driver-harness/cotkey/gen_cot_key.py` generates a secp384r1
pair and signs the 48-byte SHA-384 of the stock container. `tools/driver-harness/
fmc_oracle.sh 6` overwrites only `publicKey` and `signature` immediately before the
FSP send. The private key is generated locally and never published.

**Method.** Reproduce the production verification first: `openssl pkeyutl -verify
-pkeyopt digest:sha384` accepts the stock hash against the stock key/signature, and
`openssl dgst -sha384 -verify` accepts the whole container, so the encoding
matches. Then substitute the locally generated 97-byte uncompressed point and
96-byte `r || s` signature; the image, hash, and every layout field stay stock.

**Observed data.**

```text
BF16: COT self-signed key=04f20be3 sig=65bb6753
BF16: COT hash=ee0988fea62832c4b2fe90d87e2f6104 key=e30bf20469d9cb03818547adc45eed75 sig=5367bb6542b510288f7aa4c8fcb324c1
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x1db
```

One send per card; every retry then hit `unexpected WPR2 already up`, then
`RmInitAdapter failed! (0x62:0x40:2168)`. The driver maps `0x1db` to
`NV_ERR_GENERIC` (`0x40`) because it is not in `kern_fsp_retval.h`.

**Result.** `0x1db` is distinct from the `0x377` hash failure ([E41](#e41--the-cot-hash-is-authenticated-0x377-and-auth-failure-wedges)). A
self-consistent pair therefore dies before the hash/signature check, so the key is
validated separately and against something the host cannot supply. The COT
key-substitution route is closed.

The GSP-RM anchor has no substitution target either. `.fwsignature_gb20x` is
`0x1000` bytes: a 20-byte header (`0x00020001`, size `0x8c8`, count `0x0c`, `0x0101`,
stride `0x200`) and four 384-byte high-entropy blocks on a `0x200` stride. It
contains no SHA-384 of `.fwimage`, no valid P-384 point at any `0x04` candidate,
and no block shared across the ten chip sections; only the header is constant. The
key is fused or inside the FMC.

The resume path reuses the cold-boot image: `kgspBootstrap_GH100` re-sends the
existing `pCotPayload` and keeps the mapped image on `KGSP_BOOT_MODE_SR_RESUME`; it
does not re-read the firmware file. Only the restored state can change what runs
(see [E45/E46](../experiments/06_sr-resume.md)).

**Reproduce.**
1. Generate a local test pair with `tools/driver-harness/cotkey/gen_cot_key.py`.
2. `sudo tools/driver-harness/fmc_oracle.sh 6`.
3. Expect `0x1db`; reboot after the run because WPR2 is left up.
4. Keep the private key local; only the public point and signature are needed.

**Limits.** The COT key is validated by its own stage before the hash check. The
GSP-RM signature section carries no host key.

<a id="e62"></a>
## E62 · The FMC container is read back and tampered

*2026-10-27 · Revision 63 · status: CLOSED-MEASURED (image authenticated; no fault-injection primitive)*

**Hypothesis.** Two things were never measured. (1) `kfspSetupGspImages` copies the
FMC container into unprotected sysmem at `COT.gspFmcSysmemOffset` and nothing reads
it back; if the FSP decrypts in place, the FMC corpus is readable at PL0. (2) The
COT hash, signature, and key are copied verbatim from driver bindata and the driver
never computes or checks them; if secure firmware trusts that hash without binding
it to the image bytes, a corrupted ciphertext byte becomes a plaintext bit flip in
HS code.

**Instrument.** `tools/driver-harness/fmc_buffer_probe.sh` sets the dump/tamper
defines, rebuilds 595.91.07, loads the instrumented modules with context dumps off,
captures dmesg, and restores stock in the trap. `bf16DumpFmcBuffer()` maps the FMC
memdesc read-only and writes it at three points: `copy` (after
`bindataWriteToBuffer`), `postsend` (after the FSP response), and `release` (before
the memdesc is freed, so it also fires on the refused-boot path). `BF16_FMCTAMPER`
changes one byte of the container after copy-in, leaving the COT stock.

**Method.** Tamper modes: (1) flip one ciphertext byte in the body at `0x1048`; (2)
overwrite the plaintext body-size field at `0x04`; (3) flip one bit of the plaintext
magic at `0x00`.

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
| ciphertext `0x1048` `0xee`→`0xef` | `0x33` (task `0x1`, cmd `0x14`) | left up |
| header `0x00` `0x03`→`0x02` | `0x33` | left up |

The tampered dump has SHA-256
`81b05d6e69829bc678e8724bd3782695697e84f49dcfdd46c85e32b9b4a3fd4f`, and `cmp`
against the stock container finds exactly one byte (offset 1: `0x03` becomes
`0x02` in the magic case). Mode 2 was not run: the body-size field is inside the
same container, so both explanations predict `0x33`.

**Result.** [E41](#e41--the-cot-hash-is-authenticated-0x377-and-auth-failure-wedges) flips the COT hash field with the image stock and gets `0x377`, so
the signature over the claimed hash fails. Here the claimed hash is stock and
correct, the signature passes, and an image byte is rejected with a distinct code.
The order is: verify the signature over the claimed hash, then bind the image to
that hash. The binding covers the plaintext header too. The container is not a
pre-auth parser surface, and a corrupted ciphertext byte never reaches the
decrypted image.

**Reproduce.**
1. `sudo tools/driver-harness/fmc_buffer_probe.sh dump`; compare copy, postsend,
   and release.
2. `sudo tools/driver-harness/fmc_buffer_probe.sh tamper 1` or `tamper 3`; expect
   `0x33` and a one-byte `cmp`.
3. Reboot after `0x33`; WPR2 is left up.

**Limits.** The FSP does not decrypt in place or scrub the host buffer. The
container is bound to the COT hash, header included; this is not a fault-injection
primitive. A TOCTOU window between the hash read and the decrypt read is not
characterised.

<a id="e64"></a>
## E64 · The FEAT bank across cold boots, warm reboots, and an FLR

*2026-10-28 · status: CLOSED-MEASURED (SS writer is power-cycle-tied; words inert)*

**Hypothesis.** The boot-to-boot `SS0` movement means a mutable pre-FMC writer
exists, and the bank's reset behavior can be separated from its power-on
initialization.

**Instrument.** `tools/driver-harness/featbank_writer_probe.sh` reads only
`0x823800`–`0x823824` plus controls (`PMC_BOOT_0`, WPR2, FSP scratch/status, GSP
engine/reset PLM) through BAR0. It writes a CSV with one row per sample.

**Method.** Early-boot (`pre`, before `systemd-udev-trigger`), post-driver, 60 s
(`late`), and shutdown samples were collected on both cards across five cold power
cycles and two warm reboots. `41:00.0` was additionally FLR'd with the driver
unbound and rebound. PCIe link speed/width is recorded at every sample. The cycle
order for the last four boots was confirmed **W W C C**.

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
`FEAT_READOUT_1` was `0x00c36180` in every sample, and every nibble of every SS word
stayed below 8 (no override enable). Link speed/width was constant `16.0 GT/s x16`,
so the moving bits do not track link training.

**FLR.** With `41:00.0` unbound and FLR'd, SS0/SS1/`0x823808`/`READOUT_1` persisted
unchanged while WPR2 reset and the GSP became inaccessible. `FEAT_OVR_PLM`
(`0x823800`/`0x823804`) changed from `0xfffffb8f` to `0x80842bcf` and was restored
to `0xfffffb8f` after the rebind ([E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit)). `0x80842bcf` decodes as read mask `0xf`,
write mask `0xc` (L2+L3), source-enable `0x80842`; `0xfffffb8f` is read-all /
write-L3.

**Result.** The SS words are initialized at GPU power-on by a source with a fixed
per-card base and a small variable component. They are not written by the driver,
the FMC, GSP-RM, the host POST, or the warm-boot path. The FLR leaves them outside
its reset domain but resets the PLM, which the boot path re-locks ([E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit)).

**Reproduce.**
1. `sudo tools/driver-harness/featbank_writer_probe.sh selftest`.
2. Install the boot units and label each boot `cold` or `warm`; power-cycle for
   cold, `reboot` for warm.
3. `sudo tools/driver-harness/featbank_writer_probe.sh flr 0000:41:00.0` for the
   FLR sample.
4. Compare the CSV rows by `boot_id` and `phase`.

**Limits.** The SS words are power-cycle-tied and inert. This does not name the
writer; [E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit) brackets it.

<a id="e65"></a>
## E65 · The PLM re-lock is autonomous GPU-side devinit

*2026-10-28 · status: CLOSED-MEASURED (pre-COT, pre-open; host and GSP-RM excluded)*

**Hypothesis.** The `0x80842bcf` left by an FLR is re-locked by the FSP at the COT,
by the FMC after it, or by early GPU init.

**Instrument.** `tools/driver-harness/feat_preboot_flr.sh` builds 595.91.07 with
`BF16_FEAT_PREBOOT=1`, `BF16_FEAT_NVPROBE=1`, and `BF16_FEAT_RMINIT=1`. It unbinds,
FLRs, and rebinds `41:00.0`, then reads the 10 FEAT words at each attach bracket.

**Method.** Brackets: `nv_pci_probe` (after `pci_enable_device`/BAR0 request),
`nv-pre-set-master`/`nv-post-set-master`, `nv_start_device-entry` (first open),
`nv-pre-rm-init`, `RmInitAdapter` entry, `rm-gpu-got`, `kgspInitRm_IMPL` entry,
before `_kgspBootGspRm`, `_kgspBootGspRm` entry, `kgspPrepareForBootstrap_GH100`
entry, and `kgspSetupGspFmcArgs_GH100` (pre-COT). The post-boot hook fires after
GSP-RM. The first open is triggered by `nvidia-smi`.

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

**Result.** The FLR's `0x80842bcf` is not re-locked by the COT, the FMC, or any
GSP-RM code. The re-lock happens inside the ~3 s after the PCI probe and before the
first open, with no host code executing; the host is PL0 and neither PLM value
admits L0 writes. The writer is a GPU-side master acting on the enabled function,
using the reset mask's L2 permission. The PMU devinit is the leading candidate
(PL2); the FSP/BootROM (PL3) or a hardware re-latch are not excluded.

**Reproduce.**
1. `sudo tools/driver-harness/feat_preboot_flr.sh 0000:41:00.0`.
2. Expect `0x80842bcf` at the bind brackets and `0xfffffb8f` at
   `nv_start_device-entry`, before any RM or GSP code.

**Limits.** Brackets the re-lock to the ~3 s after the PCI probe and before the
first open. The actor is GPU-side; PMU devinit is the leading candidate, not a
confirmed one.

<a id="e66"></a>
## E66 · The vBIOS devinit-table scan: no FEAT address, authenticated tables

*2026-10-28 · status: CLOSED-STATIC (table route)*

**Question.** [E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit) leaves the pre-lock FEAT writer as a GPU-side devinit. If its
writes are table-driven by plaintext vBIOS tables, a custom-VBIOS no-flash route
could become a PL2 lever. This record scans the vBIOS for the FEAT address, for
devinit opcodes, for register-address lists, and for the PLM values, and checks
whether the DEVINIT tables/scripts can be edited on the host side.

**Instrument.** `tools/vbios-tools/devinit_scan.py`. It parses the ROM chain with
the NPDE override, finds the BIT and the `0x70` token, parses the 35-entry PMU
lookup table and the v6 descriptors, then scans every byte of the image for the
FEAT addresses in both endiannesses and the eight `DEVINIT_USE_*` flag forms; every
devinit opcode whose 32-bit address lands in `0x823800`–`0x8238FF`; u32/u64
register-address lists in `0x820000`–`0x824000`; and the known PLM values, mapping
each hit to its ucode body.

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
| Placeholders | `0x18`/tgt `0x01` (`0xD6104`) and `0x24`/tgt `0x0F` (`0xE3304`) both read `0xBADF1100` |

All four real descriptors are v6, size `0x50`, encrypted bit set, body entropy 8.0.
App `0x23`'s body is 64 KiB encrypted code (`0xB780C`–`0xC780C`), a ~2 KiB header
(`0xC780C`–`0xC8000`), then plaintext data (`0xC8000`–`0xD5A0C`, entropy 2–3) with
a `0xBADF5040` poison field and the PLM values.

**Result.**
- Zero FEAT address literals in the 1 MiB image or the 2 MiB aperture, on either
  card, in either endianness, raw or OR'd with `0x20000000`/`0x40000000`/
  `0x80000000`.
- Zero devinit opcodes with a FEAT address. `0x6E`, `0x7A`, `0x48`, `0x47`,
  `0x10`–`0x13`, `0x20`–`0x23`, `0x2C`, `0x58`, `0x91` were tested; none resolves
  into `0x823800`–`0x8238FF`.
- One register-address list: a 72-entry 64-bit table at `0x638E5`
  (`0x820800`–`0x8221A4`, the FUSE/strap block). No FEAT entry.
- The PLM values are in app `0x23`/target `0x0E` only: `0xFFFFFB8F` (4 hits),
  `0xFFFFFBFF` (7), `0xFFFFFF8F` (9), `0xFFFFFF0F` (7), all inside
  `0xB780C`–`0xD5A0C`. The other three bodies are encrypted throughout.
- Two tail tables at `0xE8300` and `0xE9400` hold `0x0884CB8F`, `0x0884CBCF`,
  `0xFFFFFB8F`, `0x0085CB8F` but no addresses.
- App `0x23`'s code is byte-identical across cards; its data differs by 65 bytes
  (per-card calibration); the PLM anchors are identical.

**Why the table route is closed.** The GSP-RM string table carries the DEVINIT
authentication errors:

```text
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_HEADER_DATA_NOT_PRESENT
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_SIGNATURE_TYPE_MISMATCH
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_DERIVEHWKEY_DOAESECB_NOT_IN_HSMODE
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_COMPUTEAESSIGNATURE_DOAESECB_NOT_IN_HSMODE
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_SIGNATURE_DATA_TYPE_DEVINIT
NV_UDE_ERR_DEVINIT_SCRIPT_AUTHENTICATE_... (same family)
NV_UDE_ERR_DEVINIT_AUTHENTICATE_DATA_PATCHER_...
NV_UDE_ERR_DEVINIT_RESIGN_DATA_PATCHER_...
NV_UDE_ERR_DEVICE_ID_WITH_DEVINIT_SCRIPTS_MISMATCH
NV_UDE_ERR_DEVICE_ID_WITH_DEVINIT_TABLES_MISMATCH
NV_UDE_ERR_UCODE_DMEM_VERIFICATION_FAILED
```

The DEVINIT tables and scripts are signed and authenticated in HS mode with
AES-ECB, and the table is bound to the device ID; the ucode DMEM is verified. A
plaintext edit fails authentication. The no-flash custom-VBIOS route is a host-side
table override at PL2; it changes what the host driver parses, not what the GPU's
HS firmware authenticates from the flash.

**Interpretation.** The table-driven hypothesis is removed. The remaining static
work is the encrypted app `0x23` code, which is a key problem. The scan does not
name the [E65](#e65--the-plm-re-lock-is-autonomous-gpu-side-devinit) writer.

**Reproduce.**
1. Dump the PROM aperture on your card:
   `sudo tools/vbios-tools/prom_read_raw <bdf> <out>`.
2. `python3 -I tools/vbios-tools/devinit_scan.py <out>`; expect zero FEAT hits and
   the anchor counts above.
3. Cross-check the PLM anchors against the GSP-RM DEVINIT authentication strings.

**Limits.** Plaintext tables only. The app `0x23` code is encrypted, so this does
not prove the executable devinit never targets the FEAT block; it closes the
plaintext table route.

<a id="e69"></a>
## E69 · The `WprMeta` bootloader description and both boot images

*2026-10-28 · status: CLOSED-MEASURED (fields checked; images authenticated)*

**Hypothesis.** The FMC consumes the host-filled bootloader description
(`sysmemAddrOfBootloader`, `sizeOfBootloader`, and the in-image code/data/manifest
offsets) plus a separate 4 KB signature buffer before or while it authenticates. A
host-controlled length or offset used in a copy/parse ahead of the check would be
the GB202 analogue of the Ada `BooterLoadUcode` bug.

**Instrument.** `tools/driver-harness/wpr_oracle.sh` fields 8–16 vary one
`WprMeta` field per module reload. `tools/driver-harness/boot_tamper_run.sh` flips
one ciphertext byte in `pGspRmBootUcodeImage` with every other field stock.

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
| `sizeOfBootloader` (8) | `0x47001` | **`0x82e`** on both cards — the length is checked |
| `sysmemAddrOfBootloader` (9) | — | not run |
| `bootloaderCodeOffset` (10) | `0xffffffff` | boots — unchecked or unused |
| `bootloaderDataOffset` (11) | `0xffffffff` | boots — unchecked or unused |
| `bootloaderManifestOffset` (12) | `0xffffffff` | **`0x885`** on both cards — the offset is used |
| `sysmemAddrOfSignature` (13) | — | not run |
| `sizeOfSignature` (14) | `0x100000` | boots — the verifier uses a fixed 0x1000 parse |
| `sysmemAddrOfRadix3Elf` (15) | — | not run |
| `sizeOfRadix3Elf` (16) | `0x100000` | **`0xaff`**, info `0xb` — bound into authentication |

The error lines:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x82e, additional info=0x0
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x885, additional info=0x0
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
```

**Result.** The FMC validates the bootloader size and manifest offset, ignores the
code/data offsets and the signature size, and binds the GSP-RM image size into
authentication. The image is authenticated: flipping the first ciphertext byte
(`0x84`→`0x85`) is refused with `0xaff`/info `0xb` on all four attempts, while the
untampered second card boots normally. A corrupted ciphertext never reaches
execution.

**Reproduce.**
1. `sudo tools/driver-harness/wpr_oracle.sh 8 0x47001`; expect `0x82e`.
2. `sudo tools/driver-harness/wpr_oracle.sh 12 0xffffffff`; expect `0x885`.
3. `sudo tools/driver-harness/boot_tamper_run.sh`; expect `0xaff`/info `0xb`.

**Limits.** The size and manifest offset are checked; code/data offsets and the
signature size are not. No host-controlled length or offset reaches a
pre-authentication copy.

<a id="e72"></a>
## E72 · The bootloader host buffer is not decrypted in place

*2026-10-28 · status: CLOSED-MEASURED*

**Hypothesis.** The FMC consumes the host-supplied `GspRmBoot` image from
unprotected sysmem (`WprMeta.sysmemAddrOfBootloader` = `pGspRmBootUcodeImage`). If
it decrypts in place, the 290,816-byte HS plaintext is readable at PL0 after the
boot — the cheapest possible decrypted-firmware route.

**Instrument.** `tools/driver-harness/bootbuf_dump.sh` builds 595.91.07 with
`BF16_BOOTDUMP=1`, loads the instrumented modules, triggers a normal boot, restores
the stock driver in its trap, and dumps `pGspRmBootUcodeImage` at
`kgspPopulateWprMeta_GH100` (pre-COT) and `_kgspSetFwWprLayoutOffset` (post-boot).

**Observed data.**

```text
gpu0: size 290816/290816 entropy 7.9835/7.9835 sha256 f5f63a71bb17b07d/f5f63a71bb17b07d diff_bytes 0
gpu1: size 290816/290816 entropy 7.9835/7.9835 sha256 f5f63a71bb17b07d/f5f63a71bb17b07d diff_bytes 0
```

The compare output prints the first 16 hex digits of SHA-256. Both sample points
and both cards agree.

**Result.** The FMC does not decrypt the bootloader in place in the host sysmem
buffer, and does not scrub it. It leaves the stock ciphertext, matching [E62](#e62--the-fmc-container-is-read-back-and-tampered) for the
FMC container. No host-side plaintext is produced by the boot path; the decrypted
image lives in protected memory or FB. The FB capture at PA `0x5dd00000` was the
remaining memory route; [E74](#e74--the-fb-route-is-shut-bar1-has-no-boot-time-vas-and-the-wpr-returns-0xbad0ac00) measured it shut.

**Reproduce.**
1. `sudo tools/driver-harness/bootbuf_dump.sh`.
2. Compare the pre/post dumps; expect `diff_bytes 0` and the same hash on both
   cards.

**Limits.** The FMC does not decrypt the host-supplied image in place and does not
scrub it.

<a id="e74"></a>
## E74 · The FB route is shut: BAR1 has no boot-time VAS, and the WPR returns `0xbad0ac00`

*2026-10-28 · Revision 86 · status: CLOSED-MEASURED (negative, structural)*

**Question.** The last memory route to the decrypted bootloader: can a host read of
FB reach it? The earlier model put the boot image at runtime VA `0xefd00000`, hence
PA `0x5dd00000` (subtracting the GSP-RM `+0x92000000` offset), outside the WPR.
[E48](../experiments/08_assessment-and-cross-checks.md)'s BAR1 attempt had failed its positive control.

**Instrument.** `tools/driver-harness/fb_capture.sh` in three runs, each triggered
by `nvidia-smi`/`nvidia-drm` opening the GPUs (`NVreg_GpuInitOnProbe=0`, so the
boot happens on first open). Root; the stock driver is restored in a trap.

**Method.**
1. BAR1 mapping at `kgspPopulateWprMeta_GH100` (before the COT). The hook published
   the BAR1 translation for `0x01000000`, `0x5DC00000`, and `0x181C0000` and left
   the mappings for a userspace poller.
2. BAR0 PRAMIN window read in `_kgspSetFwWprLayoutOffset` (after GSP-RM is up):
   64 KiB at a time at BAR0 `0x700000`, base moved with
   `kbusSetBAR0WindowVidOffset` and restored; window base/status are read back.
3. WPR read: the same window over `[frts − 0x50000, frts)` and FRTS, with the
   non-WPR heap at GSCI `nonWprHeapOffset` as the control.

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

Through that proven window:

```text
fb_nwpr_gpu0_7e72e0000.bin   size=0x10000 nz=58707 ent=7.6408 head=02000200200000001a00000000010000
fb_boot1_gpu0_5dd00000.bin   size=0x48000 nz=0 ent=-0.0000 head=00000000000000000000000000000000
fb_boot2_gpu0_181d0000.bin   size=0x48000 nz=0 ent=-0.0000 head=00000000000000000000000000000000
fb_elf_gpu0_1000000.bin      size=0x10000 nz=0 ent=-0.0000 head=00000000000000000000000000000000
fb_frts_gpu0_7f42c0000.bin   size=0x10000 nz=49152 ent=2.0000 head=00acd0ba00acd0ba...
fb_wprbin_gpu0_7f4270000.bin size=0x50000 nz=245760 ent=2.0000 head=00acd0ba00acd0ba...
```

`0x01000000`, `0x5dd00000`, and `0x181d0000` read zero. The WPR range returns the
repeating dword `0xbad0ac00` (entropy exactly 2.0, three nonzero bytes per dword).

**Result.**
1. BAR1 does not exist during the boot: offsets are BAR1-VAS offsets, not FB
   physical addresses, and the VAS is not built when the HS boot runs. Do not
   repeat the mapping before `gpuStateLoad`; it oopses on a NULL PTE array.
2. The BAR0 window is the working host FB path.
3. The candidate PAs are empty: `0x01000000`, `0x5dd00000`, `0x181d0000`.
4. The boot image is inside the WPR at `frts − sizeOfBootloader` = `0x7f4279000`;
   every host read of that range returns `0xbad0ac00`. The FB/BAR1 route is closed
   by hardware, not by a wrong address or a broken probe.

**Reproduce.**
1. Run `tools/driver-harness/fb_capture.sh` with `NVreg_GpuInitOnProbe=0`; trigger
   the boot with `nvidia-smi`.
2. Do not repeat the BAR1 mapping before `gpuStateLoad`.
3. Read the WPR through the BAR0 window; expect `0xbad0ac00`.

**Limits.** The decrypted boot image is a host-inaccessible WPR object. BAR1 is a
VAS, not a raw FB window. The BAR1 mapping attempt oopses the kernel.

<a id="e75"></a>
## E75 · The non-WPR heap holds no live RM objects

*2026-10-29 · Revision 87 · status: CLOSED-MEASURED (negative)*

**Question.** [E74](#e74--the-fb-route-is-shut-bar1-has-no-boot-time-vas-and-the-wpr-returns-0xbad0ac00) gave a working host read of unprotected FB. Does the 3 MiB GSP-RM
non-WPR heap (`GSCI nonWprHeapOffset`) contain the live RM objects behind the FEAT
method, the config object with `+0xEA4/+0xEA8/+0xEAC`, and the GR context/ucode
descriptor?

**Instrument.** `tools/driver-harness/fb_capture.sh` dumps the whole 3 MiB heap
plus three 64 KiB windows (below the start, the start, and one window past the end)
through the [E74](#e74--the-fb-route-is-shut-bar1-has-no-boot-time-vas-and-the-wpr-returns-0xbad0ac00) BAR0 window, both cards, immediately after GSP-RM is up.
`tools/driver-harness/fbread_analyze.py` mines it offline: pointer census by
region, ASCII/UTF-16 strings, known handler runtime VAs, FEAT constants.

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
the read path is consistent. There is no object structure: 3,324 dwords fall in the
code VA range and every one is distinct (the chance rate for the random span), the
16-byte block histogram is 102,149 distinct values in 102,666 blocks, and none of
the eight known handler runtime VAs (`FUN_ram_0160f1bc` = `0x934801bc`,
`FUN_ram_01c1f378` = `0x93a90378`, …) appears anywhere in the 3 MiB.

**Boundary.** The WPR sentinel `0xbad0ac00` starts at `0x7e75e0000`, exactly
`nonWprHeapOffset + 0x300000`: the published non-WPR heap size is the whole heap,
and the WPR starts at `0x7e75e0000`. The 64 KiB window below the published start
also holds data (6,766 nonzero bytes), so the start is an allocation boundary, not
the edge of FB. The captured GSP log corroborates the region
(`INIT id=0x20187640 args=[0x7e72e0000, 0x300000]`).

**Result.** The 3 MiB non-WPR heap is not where GSP-RM's RM objects live. It holds
a small structured header and one ~1.6 MiB high-entropy allocation of unknown
provenance (deterministic across both cards in this boot, not object memory), and
is otherwise zero. The RM objects are allocated from the WPR heap
(`gspFwHeapOffset`, 135 MiB), which is inside the protected region and returns the
sentinel. A runtime view would need GSP-RM cooperation (an RPC that reads or copies
its heap) or a PL3 primitive, not a host FB read.

**Reproduce.**
1. Dump the heap at GSCI `nonWprHeapOffset` with
   `tools/driver-harness/fb_capture.sh`.
2. `python3 -I tools/driver-harness/fbread_analyze.py <run-dir>`; expect no object
   structure and no handler VAs.

**Limits.** The non-WPR heap holds no live RM objects. This does not prove what the
high-entropy allocation is.
