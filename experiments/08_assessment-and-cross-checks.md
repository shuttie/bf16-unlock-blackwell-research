# Assessment and cross-checks: what the evidence proves

## Summary

**The idea.**

- The direct experiments left a pile of claims with different strength: some
  measured on the two cards, some read from public sources, some carried over
  from Ada and Ampere.
- This group separates those claims, compares GB202 against other parts, and
  checks the static and log evidence behind the remaining surfaces.

**What it found.**

- The evidence split into measured, source-derived, and analogy; the remaining
  surfaces ranked suspend/resume first, FSP/FMC second, per-SM selectors third
  ([the reassessment](#081-critical-reassessment-of-the-findings)).
- The A100 is a full-rate part and reads [`FEAT_READOUT_1 = 0`](../specs/03_register-map.md#readout-decode) with every
  arithmetic speed fuse at 0; consumer Ampere and Ada carry nonzero fields
  ([the cross-part corpus](#085-external-cross-part-register-corpus)).
- The two cards' differing [`SS0`/`SS1`](../specs/03_register-map.md#ss0-and-ss1) words do not select different rates: both
  run BF16 at the FP16 rate and TF32 at half, within 0.23% per clock
  ([the same-boot comparison](#083-same-boot-two-card-issue-rate-probe)).
- The GSP log decodes to a function-level trace without the missing [metadata ELF](../specs/08_errors-and-logging.md#what-the-decoder-recovers);
  141 of 173 records resolve, and the KERNEL buffer's metadata base is still
  unknown ([the decoder](#086-gsp-log-decoding-without-the-metadata-elf),
  [the live capture](#088-live-gsp-log-capture-and-decode)).
- The [`0xBADF`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) log records are PRI refusal telemetry, not probes of the rate path
  ([the sentinel analysis](#089-sentinel-and-raw-function-analysis)).
- A static write method for `SS0`/`SS1` exists, but it has no visible caller and
  any PL2 write is still dropped by the mask
  ([the static pass](#087-static-pass-over-feat-and-fsp)).
- [BAR1](../specs/07_memory-and-host-access.md#bar0-and-bar1) is a virtual address space, not a framebuffer physical window, so a BAR1
  read cannot reach the protected regions
  ([the BAR1 probe](#082-direct-bar1-framebuffer-read-probe)).
- The Linux driver's tracing facility is a compile-time no-op; there is no
  per-launch firmware trace to capture
  ([the tracing audit](#084-audit-of-the-tracing-facilities)).

**What it did not find.**

- No full-rate GB202 dump, so the Blackwell readout-to-rate law is still inferred
  ([the cross-part corpus](#085-external-cross-part-register-corpus)).
- No reachable `SS0`/`SS1` writer from PL0 or PL2
  ([the static pass](#087-static-pass-over-feat-and-fsp)).
- No GSP log text or severity, because the metadata ELF is missing
  ([the decoder](#086-gsp-log-decoding-without-the-metadata-elf)).
- No evidence that the sentinel records touch the rate selector
  ([the sentinel analysis](#089-sentinel-and-raw-function-analysis)).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 08.1 | [Critical reassessment of the findings](#081-critical-reassessment-of-the-findings) | Claims split; routes ranked |
| 08.2 | [Direct BAR1 framebuffer read probe](#082-direct-bar1-framebuffer-read-probe) | BAR1 is a VAS |
| 08.3 | [A same-boot two-card rate probe](#083-same-boot-two-card-issue-rate-probe) | SS0/SS1 do not select |
| 08.4 | [Audit of the tracing facilities](#084-audit-of-the-tracing-facilities) | No per-launch firmware trace |
| 08.5 | [An external cross-part register corpus](#085-external-cross-part-register-corpus) | A100 sets all-zero target |
| 08.6 | [GSP log decoding without metadata](#086-gsp-log-decoding-without-the-metadata-elf) | Decoded without metadata ELF |
| 08.7 | [Static pass over FEAT and FSP](#087-static-pass-over-feat-and-fsp) | SS0 writer exists, unreachable |
| 08.8 | [Live GSP log capture and decode](#088-live-gsp-log-capture-and-decode) | 173 records per card |
| 08.9 | [Sentinel and raw-function log analysis](#089-sentinel-and-raw-function-analysis) | 0xBADF records are PRI refusals |

## 08.1 Critical reassessment of the findings

**Question.** Can the findings be separated into proven, source-derived, and
analogy, and what should be probed next?

**Why.**

- The project had accumulated claims from different evidence levels; some rested
  on thin baselines or assumed layouts.
- A reassessment would rank the remaining surfaces and list the weak points to
  fix before spending more hardware time.
- What it would give: a route ranking and a concrete list of next experiments.

**Method.**

- No new hardware run. I re-read four claims against
  [the two-card probe](#083-same-boot-two-card-issue-rate-probe),
  [the suspend/resume experiments](../experiments/06_sr-resume.md),
  [the cross-part corpus](#085-external-cross-part-register-corpus), and
  [the log records](#086-gsp-log-decoding-without-the-metadata-elf).
- Updated the route ranking and the next-experiment list.
- No command is needed for the synthesis.

**Observed data.** The numbers behind the updated claims:

```text
two-card rates  FP16->FP32  226.65 / 229.65 TF/s   BF16->FP32  226.64 / 229.62 TF/s
two-card rates  per-clock agreement across four modes: within 0.23%
SR state dump   205.875 MiB per card (0xcde0000 = 215,875,584 B), entropy 7.9998
cross-part      A100 FEAT_READOUT_1 = 0x00000000; GB202 = 0x00c36180
```

**Result.**

- **Answer:** the premise is proven by the RTX PRO 6000, which uses the same die
  at full rate; the half rate is product segmentation. The weak points and the
  route ranking below are what the reassessment produced.
- **What we learned:**
  - The readout-to-rate mapping was unproven; [`0x82380c`](../specs/03_register-map.md#other-feat-words) was under-analysed at
    the time (later resolved by
    [the cross-part corpus](#085-external-cross-part-register-corpus)); the
    FECS-context closure rested on an assumed layout and a cross-card diff that
    cannot see shared constants; the local baseline was thin; the per-SM
    selector was not swept.
  - Route ranking at the time: suspend/resume trust first, FSP/FMC parser second,
    per-SM selectors third, `0x82380c` and aliases fourth, firmware-mediated
    buffers fifth, the Pro-card reference sixth.
  - Next experiments, cheapest first: the two-card rate probe and an
    FP16-accumulate mode; a Pro 6000 reference; an SR dump; broader FSP fuzzing;
    the `0x82380c` decode; then netconsole plus SR structure probes.
  - Since then: [the two-card probe](#083-same-boot-two-card-issue-rate-probe) is
    done; [the SR state dump](../experiments/06_sr-resume.md) is done; `0x82380c`
    is resolved by
    [the cross-part corpus](#085-external-cross-part-register-corpus); the SR
    structure probes remain open.
- **Related:**
  - The [two-card probe](#083-same-boot-two-card-issue-rate-probe) resolves the
    differing-[`SS0`/`SS1`](../specs/03_register-map.md#ss0-and-ss1) weak point.
  - The [suspend/resume group](../experiments/06_sr-resume.md) closes the state
    editing route.
  - The [cross-part corpus](#085-external-cross-part-register-corpus) resolves
    `0x82380c` and supplies the A100 reference.
  - The [log records](#086-gsp-log-decoding-without-the-metadata-elf) supply the
    static trace.
- **Open question:** an FP16-accumulate mode, a local Pro 6000 reference, and a
  per-SM selector sweep are still not done.

## 08.2 Direct BAR1 framebuffer read probe

**Question.** Is [BAR1](../specs/07_memory-and-host-access.md#bar0-and-bar1) a 1:1 window onto framebuffer physical addresses, so a read
there can reach the non-WPR heap, the WPR, or the boot image?

**Why.**

- If BAR1 maps physical framebuffer addresses, it would be a host-readable path
  into protected firmware memory without the driver.
- What it would give: a direct read of the WPR or the boot image, or a clear
  negative.

**Method.**

- Tool: `tools/direct-probe/fb_peek.py`, a read-only `mmap` of `resource1`
  (BAR1, 32 GiB ReBAR).
- No register writes and no driver calls; root for the mapping.
- Steps: map four offsets and report nonzero, entropy, and FF counts.
- Positive control: the GSP access-map buffer at physical `0x7dd580000`, known
  from [the two-card probe](#083-same-boot-two-card-issue-rate-probe) to hold
  15,063 nonzero bytes.
- Args used:
```bash
sudo tools/direct-probe/fb_peek.py 0000:41:00.0 0x1000000,0x7e72e0000,0x7f0000000,0x7f42c0000
```

**Observed data.** The per-offset result, as recorded; the console output was not
saved to a file:

| Offset | Read |
|---|---|
| `0x1000000` (control) | 0/4096 nonzero |
| [`0x7e72e0000`](../specs/07_memory-and-host-access.md#the-non-wpr-heap) (non-WPR heap) | 0/4096 nonzero |
| [`0x7f0000000`](../specs/07_memory-and-host-access.md#wpr-and-frts-layout) (mid-WPR) | 0/4096 nonzero |
| [`0x7f42c0000`](../specs/07_memory-and-host-access.md#wpr-and-frts-layout) (FRTS) | 0/4096 nonzero |

The same boot's context dump recorded the positive control as:

```text
bf16_ctxdump_global_0_8.bin  size=524288  nonzero=15063
```

So the zeros are not a bad mapping; BAR1 does not expose those physical
addresses. After the reads both GPUs reported `GPU requires reset`.

**Result.**

- **Answer:** no. BAR1 offsets are not a 1:1 window onto framebuffer physical
  addresses.
- **What we learned:**
  - The four offsets read zero while the positive control is nonzero, so the
    mapping itself was live.
  - The driver reaches framebuffer through its own aperture and page-table
    mapping; BAR1 exposes a virtual address space instead.
  - The read wedged both GPUs (`GPU requires reset`).
  - [The boot-input group](../experiments/05_fmc-fsp-boot-inputs.md) resolves the
    route: BAR1 is a VAS, that VAS is absent during boot, and the offsets are VAS
    offsets, so this test could never have worked. The BAR0 PRAMIN window is the
    correct mechanism; the WPR returns [`0xbad0ac00`](../specs/07_memory-and-host-access.md#fault-behavior-and-sentinels).
- **Related:**
  - The [two-card probe](#083-same-boot-two-card-issue-rate-probe) supplied the
    positive-control buffer.
  - The [boot-input group](../experiments/05_fmc-fsp-boot-inputs.md) closes the
    BAR1 route and points at BAR0 PRAMIN.

## 08.3 Same-boot two-card issue-rate probe

**Question.** Do the two cards' differing [`SS0`/`SS1`](../specs/03_register-map.md#ss0-and-ss1) words select different
effective rates?

**Why.**

- The cards read different `SS0`/`SS1` values; if those words encoded the
  selector, the measured rates should differ.
- What it would give: a direct test of whether `SS0`/`SS1` are the effective
  rate words or runtime state.

**Method.**

- Tool: `tools/issue-rate-probe/`, stock driver, no register poke, no root.
- Cubin SHA-256 `099aecf4…`; 20,000 iterations × 3 reps; 270,336 output cells
  checked per mode, 0 mismatches.
- Steps: run the probe on both cards in one boot and normalize each rate by the
  reported SM clock. `$UUID` comes from `nvidia-smi -L`; `$HASH` is the SHA-256
  of the built cubin.
- Args used:
```bash
cd tools/issue-rate-probe && python3 build_ptx.py
ptxas -arch=sm_120 -O3 -o tensor_modes_issue_sm120.cubin tensor_modes_issue_sm120.ptx
CUDA_VISIBLE_DEVICES=$UUID python3 tensor_modes_driver_runner.py tensor_modes_issue_sm120.cubin \
  --sha256 $HASH --expect-uuid $UUID --expect-power-limit 575 --iters 20000 --reps 3
```

**Observed data.** Extracted from the two result files:

| Mode | `41:00.0` | `c1:00.0` | Per-clock `41` / `c1` |
|---|---:|---:|---:|
| FP16 → FP32 | 226.65 TF/s | 229.65 TF/s | 0.07789 / 0.07771 |
| BF16 → FP32 | 226.64 TF/s | 229.62 TF/s | 0.07788 / 0.07771 |
| TF32 → FP32 | 113.34 TF/s | 114.83 TF/s | 0.03895 / 0.03886 |
| U4 → S32 | 595.96 TOPS | 604.55 TOPS | 0.20480 / 0.20459 |

```text
# card 41:00.0
best_Top_per_s: f16=226.6479 bf16=226.6434 tf32=113.3419 u4=595.9609
telemetry_after: 2910 MHz SM, 14001 MHz mem, 39 C, 126.53 W, 575 W cap

# card c1:00.0
best_Top_per_s: f16=229.6469 bf16=229.6219 tf32=114.8271 u4=604.5503
telemetry_after: 2955 MHz SM, 14001 MHz mem, 38 C, 100.48 W, 575 W cap
```

**Result.**

- **Answer:** no. `BF16/FP16 = 1.000` and `TF32/FP16 = 0.500` on both cards; all
  four modes agree within 0.23% per clock. The differing `SS0`/`SS1` nibbles do
  not encode the effective selector.
- **What we learned:**
  - The two cards run the same rate per clock, so the per-card `SS0`/`SS1`
    difference is runtime state.
  - The probe measures register-resident issue rate, not wall-clock GEMM.
  - The probe has no FP16-accumulate mode, so the stock-versus-full ratio is
    inferred from the published full-rate reference.
- **Related:**
  - The [reassessment](#081-critical-reassessment-of-the-findings) records this as
    the resolution of its differing-`SS0`/`SS1` weak point.
  - The [cross-part corpus](#085-external-cross-part-register-corpus) supplies the
    A100 full-rate reference.
- **Open question:** an FP16-accumulate mode is still missing, so the cap ratio is
  not measured locally.

## 08.4 Audit of the tracing facilities

**Question.** Can the open driver dump its firmware operations on a CUDA kernel
launch, or be made to?

**Why.**

- A per-launch firmware trace could show a selector update or a rate write.
- What it would give: direct observation of the rate path at launch time.

**Method.**

- Static audit of the 595.91.07 open-driver source tree; no GPU access.
- Read the launch path, the RM tracing macros, the GSP log allocation and decode,
  the NVLOG path, and the debug-dump tool.
- Check the firmware directory for the log metadata. `$SRC` is a local
  595.91.07 open-driver source tree.
- Args used:
```bash
grep -n 'RMTRACE_' "$SRC/src/nvidia/inc/kernel/diagnostics/tracer.h"
find /lib/firmware/nvidia -name 'gsp_log_*.bin' -o -name '*.fwlogging'
grep -n 'gsp_log_ga10x\|fwlogging' "$SRC/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
```

**Observed data.** `tracer.h` defines every [`RMTRACE_*`](../specs/08_errors-and-logging.md#host-tracing-facilities) macro empty outside the
Windows ETW build:

```c
#define RMTRACE_INIT_NEW()
#define RMTRACE_IS_PTIMER_LOG_ENABLED() \
    NV_FALSE
#define RMTRACE_DISP1(id, gpuId, param1)
#define RMTRACE_RMAPI(id, cmd)
#define RMTRACE_RMLOCK(id)
```

The GSP log path allocates host buffers in `_setupLogBufferBaremetal`, but the
metadata ELF ([`gsp_log_ga10x.bin`](../specs/08_errors-and-logging.md#what-the-decoder-recovers)) is not shipped. The 33,640 log call sites still
carry literal metadata IDs; that is the
[decoder](#086-gsp-log-decoding-without-the-metadata-elf) fallback.

**Result.**

- **Answer:** no. There is no per-launch firmware operation to trace: a launch is
  a pushbuffer entry plus a doorbell, and the RM is not in that path.
- **What we learned:**
  - [`RMEnableEventTracer`](../specs/08_errors-and-logging.md#host-tracing-facilities) is a compile-time no-op on Linux.
  - The [GSP task log buffers](../specs/08_errors-and-logging.md#gsp-log-ring-format) are host-allocated and host-readable.
  - The metadata ELF is missing, so a text trace is unavailable.
  - [The decoder](#086-gsp-log-decoding-without-the-metadata-elf) recovers a
    function-level trace by joining the raw rings to an ID table, without the
    metadata ELF.
- **Related:**
  - The [decoder](#086-gsp-log-decoding-without-the-metadata-elf) uses the log
    buffers this audit found.
  - The [live capture](#088-live-gsp-log-capture-and-decode) exercises the same
    path.

## 08.5 External cross-part register corpus

**Question.** Is the FEAT block the same IP on Ampere, Ada, and Blackwell, so
cross-part values settle the register names and the `0x82380c` false positive?

**Why.**

- Cross-part values can name the registers and distinguish a speed word from a
  stock ECC word.
- What it would give: a full-rate reference and corrected register names.

**Method.**

- A compiled cross-part table, reproduced inline below. The values come from a
  public survey of CMP-170HX, A100, consumer GA10x, and RTX 3090 Ti parts; the
  record does not depend on the source at read time.
- Compare the [`0x823800`–`0x82382c`](../specs/03_register-map.md#feat-bank) block and the [`FUSE_SS_*`](../specs/03_register-map.md#cross-part-fuse-values) words across the
  four part classes.
- The same block is collected in
  [the register-map spec](../specs/03_register-map.md#feat-bank).

**Observed data.** Register names and cross-part values:

| Register | Offset | GB202 | Consumer GA10x | A100 (all) | RTX 3090 Ti |
|---|---|---:|---:|---:|---:|
| `FEAT_OVR_ECC_PLM` | `0x823800` | `0xfffffb8f` | `0xffffff8f` | `0xffffff8f`† | `0xffffff8f` |
| `FEAT_OVR_PLM` | `0x823804` | `0xfffffb8f` | `0xffffff8f` | `0xffffff8f` | `0xffffff8f` |
| `FEAT_OVR_QUADRO` | `0x823808` | `0x01000280` / `0x01000380` | varies | `0x00000080`–`0x01100080` | `0x01000383` |
| `FEAT_OVR_ECC` | `0x82380c` | `0x00888888` | `0x00888888` | `0x00000100`–`0x00110111` | `0x00888888` |
| `FEAT_OVR_ECC_1` | `0x823810` | `0x002a2aaa` | `0x002aaaaa` | `0x00100400`–`0x00104104` | `0x00aaaaaa` |
| `FEAT_READOUT_0` | `0x823814` | `0x00000233` | `0x00000233` | `0xef8ff100` | `0x00000233` |
| `FEAT_READOUT_1` | `0x823818` | `0x00c36180` | `0x00400080` | **`0x00000000`** | `0x00400080` |
| `FEAT_OVR_SM_SPD` | `0x82381c` | `0x21240001` / `0x54226037` | varies | varies | `0x30403100` |
| `FEAT_OVR_SM_SPD_1` | `0x823820` | `0x00000002` / `0x00026005` | varies | varies | `0x00000004` |
| `FEAT_OVR_ROW_REMAP` | `0x823824` | `0x3` | `0x1` (`0x3` on 3090 Ti) | `0x0`/`0x1` | `0x3` |
| `FEAT_READOUT_2` | `0x823828` | `0x1` | `0x0` | `0x7` | `0x1` |
| `FEAT_OVR_ECC_2` | `0x82382c` | `0xa` | `0x8`/`0xa` | `0x0`/`0x1` | `0xa` |

† The A100 SXM4 40 GB is the outlier at `0x0000abcf`; every other card reads
`0xffffff8f`.

Fuse values and the full-rate reference:

| Fuse | A100 (all) | Consumer Ampere | GB202/GB203M |
|---|---:|---:|---:|
| `FUSE_SS_FMLA32` | **0** | 1 | **3** |
| `FUSE_SS_IMLA4` | **0** | 1 | **3** |
| `FUSE_SS_IMLA2` | **0** | 0 | **3** |
| `FUSE_SS_IMLA1` | **0** | 0 | **3** |
| all other `FUSE_SS_*` | **0** | 0 | 0 |

**Result.**

- **Answer:** the A100 is a full-rate part and reads `FEAT_READOUT_1 = 0` with
  every arithmetic speed fuse at 0. Consumer Ampere reads [`0x00400080`](../specs/03_register-map.md#cross-part-feat-values)
  (`FMLA32 = IMLA4 = 1`); Ada reads [`0x00410080`](../specs/03_register-map.md#cross-part-feat-values), which adds `IMLA2 = 1` (its
  fuse dump was not taken). On every generation the readout mirrors the fuse
  words, and `0` is the full-rate encoding.
- **What we learned:**
  - [`0x82380c`](../specs/03_register-map.md#other-feat-words) is `FEAT_OVR_ECC`, the stock ECC override, not a speed word.
    `0x00888888` is the stock value on every consumer GA10x part and is an ECC
    configuration, not the Ada speed payload. The earlier speed-override
    hypothesis is withdrawn.
  - `0x823810` is `FEAT_OVR_ECC_1`; `0x823824/28/2c` are
    `FEAT_OVR_ROW_REMAP`/`FEAT_READOUT_2`/`FEAT_OVR_ECC_2`, not counters.
    GB202's `3/1/0xa` is byte-identical to the RTX 3090 Ti triple.
  - `0x823808` is `FEAT_OVR_QUADRO`, a Quadro/consumer classification word. The
    per-card bit-8 difference is binning, not a rate selector.
  - The readout is a fuse mirror across generations, and the A100 confirms the
    all-zero target. This strengthens the target in
    [the rate-control spec](../specs/02_privilege-and-rate-control.md#cross-part-comparison) without
    validating the Blackwell override payload format.
  - The GB203M dump ([`SS0`](../specs/03_register-map.md#ss0-and-ss1) `0x02000000`, then `0x12000000`; bit 28 moved between
    boots) confirms `SS0`/`SS1` are runtime state, not per-part fuses. The FECS
    copies at [`0x409664/68`](../specs/03_register-map.md#fecs) were [`0xbadf5040`](../specs/03_register-map.md#bad-read-sentinels) on Ada too, so their GB202 sentinel
    is not a Blackwell regression.
- **Related:**
  - The [reassessment](#081-critical-reassessment-of-the-findings) records the
    `0x82380c` correction as resolving one of its weak points.
  - [The bank write test](../experiments/01_software-register-writes.md#013-the-whole-feat-bank-shares-one-gate)
    supplies the GB202 readback for `0x82380c`.
  - [The registry audit](../experiments/02_registry-and-static-audit.md) had
    observed that the words do not move; this corpus explains why.
- **Open question:** no public RTX PRO 6000 (full-rate GB202) dump exists, and none
  is available locally. The two unknowns that only such a card can settle are
  whether a full-rate GB202 has `FUSE_SS_FMLA32 = 0` and `READOUT_1 = 0`, and
  whether its `SS0`/`SS1` carry a live override with bit 3 set. The override
  payload format still needs a PL3 write or an authoritative header.

## 08.6 GSP log decoding without the metadata ELF

**Question.** Can the host-side GSP log buffers be decoded without the missing
metadata ELF?

**Why.**

- The metadata ELF ([`gsp_log_ga10x.bin`](../specs/08_errors-and-logging.md#what-the-decoder-recovers)) is not shipped, so the normal text trace
  is unavailable.
- If the raw rings decode anyway, the boot and GR-init sequence becomes readable.
- What it would give: a function-level trace without firmware text.

**Method.**

- Tools: `tools/gsp-rm-tools/logdecode/`: `build_id_table.py`,
  `gsp_log_decode.py`, `build_init_strings.py`, and `selftest.py`.
- Needs `$FWIMAGE` (the 72.8 MB GSP-RM image), `$DECOMPILED` (the decompiled
  image), and `$MODULES` (the module split), all produced by
  `tools/gsp-rm-tools/`; no GPU.
- Steps: scan the image for metadata IDs; build the `{ID → function, operand
  count}` table; parse each ring backwards; join the records.
- Args used:
```bash
cd tools/gsp-rm-tools/logdecode
python3 -I build_id_table.py --decompiled "$DECOMPILED" --modules "$MODULES" \
  --image "$FWIMAGE" --out id_table.csv --summary id_table_summary.json
python3 -I selftest.py
python3 -I gsp_log_decode.py --manifest ../../driver-harness/gsplog/manifest.json
```

**Observed data.** `id_table_summary.json`:

```json
{
  "rows": 63612,
  "raw_rows": 33044,
  "writers": {
    "FUN_ram_01b9e86e": {"task_class": "RM",    "base": "0x2018f000", "rows": 63352, "distinct_ids": 58736},
    "FUN_ram_011849a6": {"task_class": "INIT",  "base": "0x20183000", "rows": 184,   "distinct_ids": 184},
    "FUN_ram_01179c62": {"task_class": "EARLY", "base": "0x20178000", "rows": 76,    "distinct_ids": 75}
  }
}
```

The decoder selftest passes all 27 checks:

```text
PASS  small: records round-trip in order
PASS  wrap: newest tail matches
PASS  bad boundary: stops
PASS  resync: recovers older records
PASS  early: exact text attached
all tests passed
```

**Result.**

- **Answer:** yes. The raw rings decode to a function-level trace without the
  metadata ELF: 63,612 table rows (33,044 raw), 58,736 distinct RM IDs, 184 INIT,
  and 75 early.
- **What we learned:**
  - Per-task buffer: [`word0`](../specs/08_errors-and-logging.md#gsp-log-ring-format) is the total u64 words written (monotonic, not a ring
    index); `word1` starts as the GPU physical address and becomes the first
    record slot; capacity is `size/8 - 1`.
  - Record: `[args...][meta][time]`, all u64. The metadata word is second-to-last,
    immediately before the timestamp. An earlier draft had it first; that is
    wrong for `N > 2` and was caught by the selftest.
  - Meta: bits 47:0 are the metadata VA minus the per-task base (RM
    [`0x2018F000`](../specs/08_errors-and-logging.md#gsp-log-ring-format), INIT `0x20183000`, early writer `0x20178000`); 55:48 is `N`
    (2..22); 63:56 is the task ID.
  - `FUN_ram_01b9e86e(n, ...)` takes an operand count, not a level; it writes
    `N = n + 1` entries and packs the last vararg (the metadata struct pointer)
    into the meta word. `argumentCount = n - 1 = N - 2`.
  - The decoder recovers function, arguments, task, and timestamp. RM and INIT
    message text and severity need the missing ELF.
  - The ID table is 8.3 MB and generated, not committed.
- **Related:**
  - The [live capture](#088-live-gsp-log-capture-and-decode) confirms the format
    on hardware.
  - The [sentinel analysis](#089-sentinel-and-raw-function-analysis) uses the
    decoded rings.
- **Open question:** the [KERNEL metadata base](../specs/08_errors-and-logging.md#limits-and-open-questions) is still unknown, and text and
  severity need the missing metadata ELF.

## 08.7 Static pass over FEAT and FSP

**Question.** Does a static pass over the 595.91.07 image and host source close
the remaining call-site and control-surface questions?

**Why.**

- Static analysis can find a write method, the decoder selection, the registry
  consumers, the FSP surface, and the GR init path without hardware.
- What it would give: the reachable writers and the true control surface.

**Method.**

- Tools: `tools/gsp-rm-tools/` (`DecompileAt.java`, `DisasmRange.java`,
  `refscan.py`) over `$FWIMAGE` (the GSP-RM image) and the host source tree; no
  GPU access.
- Six directions: FEAT consumers, static-info controls, decoder selection,
  registry consumers, FSP surface, and GR init.
- Args used:
```bash
cd tools/gsp-rm-tools && python3 -I refscan.py "$FWIMAGE" 0x3818
```

**Observed data.** The report's six findings, quoted:

```text
A: FUN_ram_0160f1bc writes 0x381c/0x3820 through FUN_ram_01c60868;
   no direct jal to 0x160f1bc; no visible 4-argument caller.
B: the GR ctrl table has 44/44 IDs matching the public SDK; no SET control.
C: variant = desc[0x10] & 0x1f; {5..9} install FUN_ram_015ff1dc (0x9668),
   all others FUN_ram_015ffae8 (0x3818).
D: exactly two readers of config+0xEA8/0xEAC, both boolean; 0x504204 has no writer.
E: host->FSP COT 0x14, CAPS 0x16, CLOCK 0x20; nine NVDM types never sent.
F: 29 FECS command IDs; no selector; no 0x504204 writer.
```

| Direction | Finding | Status |
|---|---|---|
| FEAT consumers | `FUN_ram_0160f1bc` writes [`0x381c`/`0x3820`](../specs/03_register-map.md#ss0-and-ss1) through `FUN_ram_01c60868`; installed at `obj+0x938` for variants not in `{5..9}`; the helper's fallback is a direct BAR0 MMIO store, but there is no visible 4-argument caller. Bit 6 is the alternate ninth byte. | CLOSED-STATIC (method exists; unreachable/PLM-blocked) |
| Static-info controls | The control table confirms V1 internal `0x48` (8×9), V2 internal `0x3fe0`, public V1 `0x20`, V2 `0x7fc`; the getter is a copy-out/cache. Handler pointers are 2 bytes early, so the reader trace is partial. | PARTIAL |
| Decoder selection | `{5..9}` twin confirmed by `0x3e0 >> variant & 1`. `0xC38` is variant-dependent: `FUN_ram_01615a40` (DP `[30:28]`) or `FUN_ram_015ffbd0` (bit 6). GB202 is `0x02`, not in `{5..9}`, so it installs `FUN_ram_015ffae8` / [`0x3818`](../specs/03_register-map.md#readout-decode). | CLOSED-STATIC |
| Registry consumers | `config+0xEA8/0xEAC` are read by `FUN_ram_0216d680` and `FUN_ram_0217f718`, reduced to booleans, and written to a GR context/ucode descriptor, not MMIO; EA8 is gated by `+0xEA4`. [`0x504204`](../specs/03_register-map.md#sm-and-gr) has no writer. | CLOSED-STATIC |
| FSP surface | Only COT [`0x14`](../specs/01_boot-chain.md#fsp-command-surface), caps `0x16`, and clock `0x20` are live; PRC `0x13` is GH100-only; nine NVDM types are unused. No length field; the host controls TX length via `QUEUE_TAIL`; response identity is unchecked. | CLOSED-STATIC |
| GR init | 29 FECS command IDs, all init/context/feature; no selector; no per-SM rate loop; no `0x504204` writer. | CLOSED-STATIC |
| GSP log | See the [decoder](#086-gsp-log-decoding-without-the-metadata-elf). | CLOSED-STATIC |

**Result.**

- **Answer:** a write method for `SS0`/`SS1` exists (`FUN_ram_0160f1bc`), but it
  has no visible 4-argument caller and any PL2 write is dropped by
  [`FEAT_OVR_PLM`](../specs/03_register-map.md#write-gate). The decoder selection and registry consumers resolve; the FSP
  surface has no memory, fuse, register, or debug command.
- **What we learned:**
  - The earlier "no computed-offset write to `SS0`/`SS1`" claim is too strong. A
    write method exists and attempts a direct BAR0 MMIO store, but it is
    unreachable from the visible call graph and unusable at PL2.
  - [The registry audit](../experiments/02_registry-and-static-audit.md) had the
    producer wrong: it is `FUN_ram_015ce3e8`, not `0x015cf1be` (an interior
    address). The keys are inert because the value is boolean-ized and EA8 is
    gated by `+0xEA4`, not because the consumer is absent.
  - No RM code writes `0x504204`; the value 5 comes from firmware/devinit or a
    context-switch/golden-context restore.
  - Bit 6 of `FEAT_READOUT_1` is the alternate ninth byte
    (`FUN_ram_015ffbd0` / the twin's `param_3[2]`), not an unexplained gap.
  - [The decoder audit](../experiments/07_plaintext-corpus.md) had the `0xC38`
    slot as variant-dependent; on some parts it is the bit-6 reader, not
    `FUN_ram_01615a40` (DP).
  - The FSP surface is COT `0x14`, caps `0x16`, and clock `0x20`; PRC `0x13` is
    GH100-only; nine NVDM types are unused; the host controls TX length via
    `QUEUE_TAIL`; response identity is unchecked.
  - GB202's implementation constant is `0x02`, not in `{5..9}`; it installs
    `FUN_ram_015ffae8` and reads `0x3818`. The `0x9668` twin is the
    GB205/GB206/GB207 path, which is why the direct [`0x009668`](../specs/04_firmware-formats.md#module-map) read is
    unimplemented.
  - The helper's `+0xb48` field is the BAR0 base, not a shadow; the fallback is a
    direct MMIO store. On GeForce, the `is_geforce` byte skips the `fuse+0x108`
    access callback.
- **Related:**
  - [The PL2 write test](../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)
    shows the FEAT mask dropping the write.
  - [The registry audit](../experiments/02_registry-and-static-audit.md) owns the
    producer correction.
  - [The decoder audit](../experiments/07_plaintext-corpus.md) owns the `0xC38`
    slot correction.
- **Open question:** the decompiled C is a hypothesis until checked against the
  instruction bytes, and the handler pointers in the control table are two bytes
  early, so the reader traces are partial.

## 08.8 Live GSP log capture and decode

**Question.** Does the [decoder](#086-gsp-log-decoding-without-the-metadata-elf)
format and ID table decode a real capture to a function-level boot and GR-init
trace?

**Why.**

- The decoder was built from static data; a live capture tests the format and the
  ID table on hardware.
- What it would give: a real boot timeline and confirmation of the ring format.

**Method.**

- Tools: `tools/driver-harness/gsp_log_capture.sh` and the instrumented 595.91.07
  `kernel_gsp.c` hook at `_kgspFreeLibosLoggingStructures`; decoder in
  `tools/gsp-rm-tools/logdecode/`.
- No firmware was modified and no GPU register was written.
- Steps: apply the log-dump patch, build the tree, unload the stock modules, load
  only the instrumented `nvidia.ko`, wait for both cards, issue a few RM queries,
  unload (firing the hook), and restore stock in a trap. Then decode the rings.
- Args used:
```bash
sudo tools/driver-harness/gsp_log_capture.sh
python3 -I tools/gsp-rm-tools/logdecode/gsp_log_decode.py --manifest tools/driver-harness/gsplog/manifest.json
```

**Observed data.** `decode_gpu0.txt` buffer headers:

```text
# buffer 0: <ring> gpu=None hint=INIT    size=65536B capacity=8191 put=0xa4  records=42 wrapped=False
# buffer 2: <ring> gpu=None hint=INTR    size=65536B capacity=8191 put=0x4   records=2 wrapped=False
# buffer 4: <ring> gpu=None hint=RM      size=65536B capacity=8191 put=0x13f records=98 wrapped=False
# buffer 6: <ring> gpu=None hint=MNOC    size=65536B capacity=8191 put=0x0   records=0 wrapped=False
# buffer 8: <ring> gpu=None hint=DEBUG   size=65536B capacity=8191 put=0x0   records=0 wrapped=False
# buffer 10: <ring> gpu=None hint=ROOT   size=4096B  capacity=511  put=0x7   records=3 wrapped=False
# buffer 12: <ring> gpu=None hint=RMON   size=4096B  capacity=511  put=0x6   records=2 wrapped=False
# buffer 14: <ring> gpu=None hint=KERNEL size=65536B capacity=8191 put=0x56  records=26 wrapped=False
```

A sample decoded record:

```text
[    +2.263872 ms] t=2 INIT    id=0x201874d8 n_args=2  FUN_ram_01187426 [logging_debug]  args=[0xa00000, 0x9400000456490000]
```

| Buffer | Records | Resolved | Base | Note |
|---|---:|---:|---:|---|
| RM (`task 3`) | 98 | 96 | [`0x2018F000`](../specs/08_errors-and-logging.md#gsp-log-ring-format) | registry, inforom, SEC2/ACR, GR/FECS, display; 27 via raw fallback |
| INIT (`task 2`) | 42 | 41 | `0x20183000` | WPR/buffer layout |
| KERNEL (`task 1`) | 26 | 0 | unknown | IDs `0x2017c3c0`–`0x2017ccf0` not referenced in `.fwimage` |
| INTR (`task 4`) | 2 | 2 | `0x2018F000` | n/a |
| ROOT (`task 8`) | 3 | 0 | `0x2018F000`? | IDs `0x2018fea0`/`0x2018fff0`/`0x2018ff30` not referenced |
| RMON (`task 9`) | 2 | 2 | `0x2018F000` | n/a |
| MNOC / DEBUG | 0 | n/a | unknown | empty at capture time |

**Result.**

- **Answer:** yes. Both cards produced 173 records with an identical
  `(task, ID, argc)` sequence, which confirms the ring framing and the ID table.
  Total: 141 of 173 records (81.5%) resolved.
- **What we learned:**
  - The record layout is confirmed on hardware: `[args...][meta][time]`, meta
    second-to-last, with no bad boundary. The earlier `[meta][args...]` draft
    would have misparsed every `N > 2` record.
  - INIT uses a third writer, `FUN_ram_011849a6`, with base `0x20183000`. The
    earlier assumption that INIT uses the `0x20178000` writer is wrong.
  - The RM base `0x2018F000` is confirmed. The raw `AUIPC+ADDI`/`LUI+ADDI` scan
    recovers 33,044 extra IDs.
  - The KERNEL buffer is a separate metadata section. Task-1 IDs do not appear as
    literals, PC-relative targets, or pointers in the `.fwimage`; the base cannot
    be recovered without the metadata ELF.
  - The trace is deterministic across cards.
  - The RM timeline is usable without text: registry at about 65 ms, inforom
    about 89–345 ms, SEC2/ACR about 365–385 ms, GR/FECS init about 435–484 ms,
    display about 462 ms and 1723 ms.
- **Related:**
  - The [decoder](#086-gsp-log-decoding-without-the-metadata-elf) supplies the
    format and ID table.
  - The [sentinel analysis](#089-sentinel-and-raw-function-analysis) uses these
    rings.
- **Open question:** the KERNEL metadata base is unknown, and RM/INIT text,
  level, and source line remain unavailable without the metadata ELF.

## 08.9 Sentinel and raw-function analysis

**Question.** Are the [`0xBADF`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) records in the log trace feature probes that might
touch the rate path?

**Why.**

- If the firmware probes the rate path with `0xBADF` sentinels, the log could
  reveal a rate write.
- What it would give: either evidence of a rate probe or confirmation that the
  sentinels are PRI telemetry.

**Method.**

- Tools: `tools/gsp-rm-tools/logdecode/gsp_log_decode.py` on the
  [live capture](#088-live-gsp-log-capture-and-decode) rings, plus
  `DecompileAt.java` on the 17 raw-attributed functions.
- Steps: verify the raw-function starts, decompile the three sentinel producers,
  and inspect the feature-mask functions. The
  [GSP-RM tools](../tools/gsp-rm-tools/) README has the `DecompileAt.java`
  invocation.
- Args used:
```bash
python3 -I tools/gsp-rm-tools/logdecode/gsp_log_decode.py --manifest tools/driver-harness/gsplog/manifest.json
```

**Observed data.** The captured sentinel records:

```text
[   +96.222656 ms] t=3 RM      id=0x203cd1a8 n_args=4  FUN_ram_01230c00 [rm_core]  args=[0x1d5e9d0, 0xbadf4100, 0x1100f4, 0x1]
[  +483.978560 ms] t=3 RM      id=0x20471918 n_args=1  FUN_ram_016ea930 [gr_fecs]  args=[0x1]
[  +484.002048 ms] t=3 RM      id=0x20471930 n_args=5  FUN_ram_016ea930 [gr_fecs]  args=[0x0, 0x137200, 0x0, 0x14252215, 0xbadf5128]
```

`0x14252215` decodes as SUBID 20, PRIV_LEVEL 2, SENDING_RS 18, PENDING 1,
PRIV_MASTER 21; [`0xbadf5128`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) is `NV_PPRIV_SYS_PRIV_ERROR_CODE`. All 17 reported
raw-function starts are genuine prologues; 70 of 70 raw-attributed records
matched a real writer call site. One decoder attribution was wrong (`0x01187eae`
is an inner stack adjustment inside `FUN_ram_01187426`); the table builder now
maps it there.

The feature-mask functions found in the trace:

| Function | Behaviour |
|---|---|
| `0x016ec3d0` | Sets bit `(index&0x1f)` in a 32-bit enable mask at `param_2+0x198`; live index 26 |
| `0x01976d44` | Logs/tests a 32-bit mask at `param_3+0x4c` (live `0xf`); bit 0 gates a handler |
| `0x01bc6320` | Unpacks a 38-bit GR/FECS feature bitmap at `0x042f5970` into flag bytes at `+0x48..+0x6f`, plus 16/32-bit tokens at `+0xa8..+0xe0`; reads 21 registry values |
| `0x015acb70` | `0xBADF0200` sentinel probe plus 3-bit feature mask `(+0x10f100)&0xe`; live log shows `0xBADF4100` |
| `0x0157107c`, `0x013fc2f4` | PCIe link-speed/status probing |
| `0x01931684`, `0x0198c9cc` | FWSECLIC/ECID/EDID and registry feature gating; GR error bit `0x400000` |

The 38-bit table at `0x042f5970` has 23 of 38 flags set (bits 2, 5, 7, 8, 9, 11,
14, 16, 17, 18, 19, 22, 24, 25, 26, 27, 28, 31, 32, 33, 35, 36, 37). The tokens
copied to `+0xa8..+0xe0` are `0x3b9e`, `0x0493`, `0x2cfb`, `0xd7e6`, `0xabf8`,
`0xfa1f4936`, `0x68a19441`, `0xd2f674a2`, `0x20d5`. The `+0xb4` token
(`0xfa1f4936`) is compared against `0x102e`; on this image the check fails.

**Result.**

- **Answer:** no. The `0xBADF` records are PRI error telemetry, not feature
  probes, and no [`0x8238xx`](../specs/03_register-map.md#feat-bank) FEAT register,
  [`FUSE_SS_FMLA32`](../specs/03_register-map.md#fuse-and-otp),
  [`FEAT_READOUT_1`](../specs/03_register-map.md#readout-decode), or
  [`SM_ISSUE_RATE_MODIFIER`](../specs/03_register-map.md#sm-and-gr) appears in
  them.
- **What we learned:**
  - `FUN_ram_016ea930` is a PRI ringmaster/ringstation global-write-error dumper.
    It reads `BAR0+0x120058`/`+0x12005c`, walks the per-station records at
    `0x122120+0x800*n`, and logs `[station, ADR, WRDAT, INFO, CODE]`. The
    captured `0x20471930` record is a refused PL2 access at [`0x137200`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
  - `FUN_ram_01230c00` logs `[direction, PRI_CODE, ADR, valid]`; the captured
    `[0x1d5e9d0, 0xbadf4100, 0x1100f4, 1]` is a refused access to GSP `HWCFG2`
    ([`0x1100f4`](../specs/03_register-map.md#gsp-falcon)).
  - `FUN_ram_016d80c8` is a generic GSP ucode event pump, not a register probe.
  - The trace adds no evidence about the rate selector; it does show the GSP
    hitting PRI refusals at PL2 during boot.
  - `0xBADF51` is a generic PRI client/privilege error family, not
    fuse-specific. `0xBADF510C` at the fuse block and `0xBADF5128` at `0x137200`
    are instances with different low bytes. `0xBADF4100` belongs to the
    `0xBADF41` PRI-decode family
    ([errors and logging](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)).
- **Related:**
  - The [live capture](#088-live-gsp-log-capture-and-decode) supplies the rings.
  - [The decoder](#086-gsp-log-decoding-without-the-metadata-elf) supplies the
    attribution table.
- **Open question:** why the GSP hits PRI refusals at PL2 during boot is not
  identified; the records show the refusals, not their cause.
