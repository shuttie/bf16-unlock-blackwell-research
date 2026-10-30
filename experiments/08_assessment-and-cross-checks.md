# Assessment and cross-checks

Recorded 2026-10-26. The evidence is inline; the only local inputs are listed below.

## Reproducing this group

**Hardware.** 2× RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
Linux, CUDA 13. `deviceId 1` is `41:00.0`; `deviceId 0` is `c1:00.0`.

**Tools.** [Issue-rate probe](../tools/issue-rate-probe/) for the two-card rate
test, [Direct probe](../tools/direct-probe/) for the BAR1 read,
[Register access](../tools/register-access/) for the BAR0/BAR1 reads,
[GSP-RM tools](../tools/gsp-rm-tools/) for the tracing, log, and static records,
and [Driver harness](../tools/driver-harness/) for the live capture.

**Inputs.** A local 595.91.07 open-driver source tree (`$SRC`) for the tracing,
log, and capture records; the 72.8 MB GSP-RM `.fwimage` (`$FWIMAGE`) and the
decompiled image/module split (`$DECOMPILED`, `$MODULES`) produced by
`tools/gsp-rm-tools/`, all from your driver package, for the log and static
records; the issue-rate cubin for the rate test. The cross-part tables below are
reproduced inline and need no external source. Nothing here fetches data at read
time.

**Boot state and cost.** Stock driver, root. The BAR1 read wedges the card
(reboot). The rate test is a normal benchmark. The tracing, cross-part, log, and
sentinel records are offline. The live capture needs the instrumented driver and a
module reload.

**Terms.**

| Term | Meaning |
|---|---|
| GSP-RM | GPU firmware that runs at PL2; the host driver's counterpart on the card |
| BAR1 / VAS | The GPU's second memory window; here it maps a virtual address space, not framebuffer physical addresses |
| PRI / ringstation | NVIDIA's privilege/error telemetry path; `0xBADFxxxx` values are PRI codes |
| LIBOS | The firmware's small OS/log library; its rings are the GSP log buffers |
| task class | Per-task log buffer category (RM, INIT, KERNEL, INTR, ROOT, RMON) |
| `gsp_log_ga10x.bin` | Missing metadata ELF with message text and severity; the function-level trace works without it |

## E44 · Critical reassessment

*2026-10-26 · Revision 43 · status: assessment*

**Hypothesis.** The findings can be separated into what is proven on hardware, what
is inferred from public sources, and what is carried over from Ada/Ampere.

**Instrument.** No new hardware run. This is a synthesis of
[E49](#e49--same-boot-two-card-issue-rate-probe),
[E45](../experiments/06_sr-resume.md),
[E56](#e56--external-cross-part-register-corpus), and
[E57](#e57--gsp-log-decoding-without-gsp_log_ga10xbin)–[E60](#e60--sentinel-and-raw-function-analysis-of-the-log-trace).

**Method.** Re-read the four claims below against the evidence and update the
route ranking.

**Observed data.** The numbers behind the updated claims:

```text
two-card rates  FP16->FP32  226.65 / 229.65 TF/s   BF16->FP32  226.64 / 229.62 TF/s
two-card rates  per-clock agreement across four modes: within 0.23%
SR state dump   205.875 MiB per card (0xcde0000 = 215,875,584 B), entropy 7.9998
cross-part      A100 FEAT_READOUT_1 = 0x00000000; GB202 = 0x00c36180
```

**Result.** Four findings:

1. The premise is proven by the RTX PRO 6000 (same die, full rate); the half rate is
   product segmentation.
2. Weak points: the readout→rate mapping is unproven; `0x82380c` was under-analysed
   (since resolved by [E56](#e56--external-cross-part-register-corpus)); the
   FECS-context closure rests on an assumed layout and a cross-card diff that cannot
   see shared constants; the local baseline was thin; the per-SM selector was not
   swept.
3. Route ranking at the time: SR-resume trust first, FSP/FMC parser second, per-SM
   selectors third, `0x82380c`/aliases fourth, firmware-mediated buffers fifth,
   Pro-card reference sixth.
4. Next experiments, cheapest first: two-card rate probe and FP16-accumulate mode;
   Pro-6000 reference; SR dump; broaden FSP fuzzing to framing; decode `0x82380c`;
   then netconsole plus SR structure probes.

**Updated since.** The two-card probe is [E49](#e49--same-boot-two-card-issue-rate-probe)
(the “differing `SS0`/`SS1`” weak point is resolved). The SR state dump is
[E45](../experiments/06_sr-resume.md) (state editing closed).
[E56](#e56--external-cross-part-register-corpus) resolves `0x82380c` as the ECC
override and supplies the A100 full-rate reference. The SR structure probes remain
open. The FP16-accumulate local mode, the Pro-card reference, and the per-SM sweep
are still not done.

**Reproduce.** Read [E49](#e49--same-boot-two-card-issue-rate-probe),
[E45](../experiments/06_sr-resume.md),
[E56](#e56--external-cross-part-register-corpus), then
[E42](../experiments/06_sr-resume.md)/[E43](../experiments/06_sr-resume.md)/[E58](#e58--static-pass-feat-consumers-decoder-selection-registry-consumers-fsp-surface-gr-init)
in that order. No command is needed for the synthesis itself.

**Limits.** This is an assessment, not a measurement. It records what was believed
at the time and what has since changed; it is not a standalone result.

## E48 · The BAR1 FB-read probe

*2026-10-26 · Revision 47 · status: INCONCLUSIVE + hazard*

**Hypothesis.** BAR1 is a 1:1 window onto framebuffer physical addresses, so a read
there can reach the non-WPR heap, the WPR, or the boot image.

**Instrument.** `tools/direct-probe/fb_peek.py`, a read-only `mmap` of `resource1`
(BAR1, 32 GiB ReBAR). No register writes and no driver calls; root for the mapping.

**Method.** Map four offsets and report nonzero/entropy/FF counts. The positive
control is the GSP access-map buffer at physical `0x7dd580000`, known from
[E49](#e49--same-boot-two-card-issue-rate-probe) to hold 15,063 nonzero bytes.

**Observed data.** The per-offset result, as recorded (the console output was not
saved to a file):

| Offset | Read |
|---|---|
| `0x1000000` (control) | 0/4096 nonzero |
| `0x7e72e0000` (non-WPR heap) | 0/4096 nonzero |
| `0x7f0000000` (mid-WPR) | 0/4096 nonzero |
| `0x7f42c0000` (FRTS) | 0/4096 nonzero |

The same boot's context dump recorded the positive control as:

```text
bf16_ctxdump_global_0_8.bin  size=524288  nonzero=15063
```

So the zeros are not a bad mapping; BAR1 does not expose those physical addresses.
After the reads both GPUs reported `GPU requires reset`.

**Result.** BAR1 offsets are not a 1:1 window onto FB physical addresses; the driver
reaches FB through its own aperture/PTE mapping. The probe says nothing about
whether the WPR is readable, and it does not reopen the firmware-read route.
[E74](../experiments/05_fmc-fsp-boot-inputs.md) resolves it: BAR1 is a VAS, the VAS
is absent during the boot, and its offsets are VAS offsets, so this test could never
have worked. The BAR0 PRAMIN window is the correct mechanism, and through it the
WPR returns `0xbad0ac00`.

**Reproduce.**
1. Confirm the card is bound to the stock driver and BAR1 is ReBAR-enabled.
2. `sudo tools/direct-probe/fb_peek.py 0000:41:00.0 0x1000000,0x7e72e0000,0x7f0000000,0x7f42c0000`
3. Expect `0/4096` nonzero at all four offsets.
4. Check `dmesg -T` for the Xid 13/120/154 signature; reboot if the GPU is wedged.
5. Do not repeat casually: BAR1 is a VAS, not a physical FB window.

**Limits.** The probe shows BAR1 offsets are not FB physical addresses. It does not
prove the WPR is unreadable by any path; [E74](../experiments/05_fmc-fsp-boot-inputs.md)
answers that with the BAR0 window.

## E49 · Same-boot two-card issue-rate probe

*2026-10-26 · Revision 48 · status: resolves the per-card-selector hypothesis*

**Hypothesis.** The two cards' differing `SS0`/`SS1` words select different
effective rates.

**Instrument.** `tools/issue-rate-probe/`, stock driver, no register poke, no root
needed. Cubin SHA-256 `099aecf4…`; 20,000 iterations × 3 reps; 270,336 output cells
checked per mode, 0 mismatches.

**Method.** Run the probe on both cards in one boot and normalize each rate by the
reported SM clock.

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

**Result.** `BF16/FP16 = 1.000` and `TF32/FP16 = 0.500` on both cards; all four
modes agree within 0.23% per clock. The differing `SS0`/`SS1` nibbles do not encode
the effective selector.

**Reproduce.**
1. `cd tools/issue-rate-probe && python3 build_ptx.py`
2. `ptxas -arch=sm_120 -O3 -o tensor_modes_issue_sm120.cubin tensor_modes_issue_sm120.ptx`
3. `nvidia-smi --query-gpu=uuid --format=csv,noheader` (lists both cards).
4. `HASH=$(sha256sum tensor_modes_issue_sm120.cubin | cut -d' ' -f1)`; expect
   `099aecf4…`.
5. For each UUID from step 3, run the runner without `--reg-offset`:
   `CUDA_VISIBLE_DEVICES=$UUID python3 tensor_modes_driver_runner.py tensor_modes_issue_sm120.cubin --sha256 $HASH --expect-uuid $UUID --expect-power-limit 575 --iters 20000 --reps 3`
6. Normalize each rate by the reported SM clock; expect the table within about
   0.25%, with 0 mismatches in 270,336 cells per mode.

**Limits.** Measures the register-resident issue rate, not wall-clock GEMM. The
local probe has no FP16-accumulate mode, so the stock-vs-full ratio is inferred
from the published full-rate reference.

## E55 · Tracing-facility audit

*2026-10-26 · status: static*

**Hypothesis.** The open driver can dump its firmware operations on a CUDA kernel
launch, or can be made to.

**Instrument.** Static audit of the 595.91.07 open-driver source tree (`$SRC`); no
GPU access.

**Method.** Read the launch path, the RM tracing macros, the GSP log allocation and
decode, the NVLOG path, and the debug-dump tool. Check the firmware directory for
the log metadata.

**Observed data.** `tracer.h` defines every `RMTRACE_*` macro empty outside the
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
metadata ELF (`gsp_log_ga10x.bin`) is not shipped. The 33,640 log call sites still
carry literal metadata IDs; that is the
[E57](#e57--gsp-log-decoding-without-gsp_log_ga10xbin) fallback.

**Result.** There is no per-launch firmware operation to trace: a launch is a
pushbuffer entry plus a doorbell, and the RM is not in that path. The useful facts:

- `RMEnableEventTracer` is a compile-time no-op on Linux.
- The GSP task log buffers are host-allocated and host-readable.
- The metadata ELF is missing, so a text trace is unavailable.
- [E57](#e57--gsp-log-decoding-without-gsp_log_ga10xbin) recovers a function-level
  trace by joining the raw rings to an ID table, without the metadata ELF.

**Reproduce.**
1. `grep -n 'RMTRACE_' "$SRC/src/nvidia/inc/kernel/diagnostics/tracer.h"`
2. `find /lib/firmware/nvidia -name 'gsp_log_*.bin' -o -name '*.fwlogging'`
   (expect none).
3. `grep -n 'gsp_log_ga10x\|fwlogging' "$SRC/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"`
4. Expect no text trace; capture the buffers with
   [E59](#e59--live-gsp-log-capture-and-decode).

**Limits.** Static audit. It shows these facilities are absent, not that no other
firmware trace exists.

## E56 · External cross-part register corpus

*2026-10-26 · status: external static; corrects
[E09](../experiments/01_software-register-writes.md)/[E51](../experiments/02_registry-and-static-audit.md)
and the `0x82380c` hypothesis*

**Hypothesis.** The FEAT block is the same IP on Ampere, Ada, and Blackwell, so
cross-part values settle the register names and the `0x82380c` false positive.

**Instrument.** A compiled cross-part table, reproduced inline below. The values
come from a public survey of CMP-170HX, A100, consumer GA10x, and RTX 3090 Ti
parts; the record does not depend on the source at read time. The same block is
collected in [the register-map spec](../specs/03_register-map.md).

**Method.** Compare the `0x823800`–`0x82382c` block and the `FUSE_SS_*` words
across the four part classes.

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

**Result.** The A100 is a full-rate part and reads `FEAT_READOUT_1 = 0` with every
arithmetic speed fuse at 0. Consumer Ampere reads `0x00400080`
(`FMLA32 = IMLA4 = 1`); Ada reads `0x00410080`, which adds `IMLA2 = 1` (its fuse
dump was not taken). On every generation the readout mirrors the fuse words, and
`0` is the full-rate encoding.

The corrections:

1. `0x82380c` is `FEAT_OVR_ECC`, not an override-shaped speed word. `0x00888888`
   is the stock value on every consumer GA10x part and is an ECC configuration,
   not the Ada speed payload. The earlier speed-override hypothesis is withdrawn.
2. `0x823810` is `FEAT_OVR_ECC_1`; `0x823824/28/2c` are
   `FEAT_OVR_ROW_REMAP`/`FEAT_READOUT_2`/`FEAT_OVR_ECC_2`, not counters. GB202’s
   `3/1/0xa` is byte-identical to the RTX 3090 Ti triple. The
   [E51](../experiments/02_registry-and-static-audit.md) observation that the words
   do not move is still true, but it is not evidence about a blocked write attempt:
   these are static feature words.
3. `0x823808` is `FEAT_OVR_QUADRO`, a Quadro/consumer classification word. The
   per-card bit-8 difference is binning, not a rate selector.
4. The readout is a fuse mirror across generations, and the A100 confirms the
   all-zero target. This strengthens the target in
   [the rate-control spec](../specs/02_privilege-and-rate-control.md) without
   validating the Blackwell override payload format.
5. The GB203M dump (`SS0` `0x02000000`, then `0x12000000`; bit 28 moved between
   boots) confirms `SS0/SS1` are runtime state, not per-part fuses. The FECS copies
   at `0x409664/68` were `0xbadf5040` on Ada too, so their GB202 sentinel is not a
   Blackwell regression.

**What remains unresolved.** No public RTX PRO 6000 (full-rate GB202) dump exists,
and none is available locally. The two unknowns that only such a card can settle
are (a) whether a full-rate GB202 has `FUSE_SS_FMLA32 = 0` and `READOUT_1 = 0`, and
(b) whether its `SS0/SS1` carry a live override with bit 3 set. The override
payload format itself still requires a PL3 write or an authoritative header; no
stock card, including the Pro, is expected to validate it.

**Reproduce.**
1. On any available A100, consumer Ampere, or Ada part, dump the
   `0x823800`–`0x82382c` block and the `FUSE_SS_*` words. The local commands are in
   [E09](../experiments/01_software-register-writes.md) and
   [E12](../experiments/01_software-register-writes.md).
2. Compare to the two tables above.
3. Expect the A100 row all-zero and the consumer row carrying `0x00400080`.

**Limits.** External data from other parts; no local A100 or PRO 6000. It resolves
the register names and the ECC false positive, not the Blackwell code-to-rate law.

## E57 · GSP log decoding without `gsp_log_ga10x.bin`

*2026-10-26 · status: static + implementation; corrects the writer semantics and
the record layout below*

**Hypothesis.** The host-side GSP log buffers can be decoded without the missing
metadata ELF.

**Instrument.** `tools/gsp-rm-tools/logdecode/`: `build_id_table.py`,
`gsp_log_decode.py`, `build_init_strings.py`, and `selftest.py`. Needs the 72.8 MB
`.fwimage` (`$FWIMAGE`), the decompiled image, and the module split produced by
`tools/gsp-rm-tools/`; no GPU.

**Method.** Scan the image for metadata IDs, build the `{ID → function, operand
count}` table, parse each ring backwards, and join the records. The missing ELF only
carries message text and severity, not the IDs.

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

**Result.** The raw format is known:

- Per-task buffer: `word0` = total u64 words written (monotonic, not a ring index);
  `word1` initially holds the GPU physical address and is then the first record
  slot; capacity = `size/8 - 1`.
- Record: `[args...][meta][time]`, all u64. The metadata word is second-to-last,
  immediately before the timestamp. An earlier draft had it first; that is wrong
  for `N > 2` and was caught by the selftest.
- Meta: bits 47:0 = metadata VA minus the per-task base (RM `0x2018F000`,
  INIT `0x20183000`, early writer `0x20178000`); 55:48 = N (2..22); 63:56 = task
  ID. The task-1 KERNEL buffer uses a section whose base is still unknown
  ([E59](#e59--live-gsp-log-capture-and-decode)).
- `FUN_ram_01b9e86e(n, ...)` takes an operand count, not a level; it writes
  `N = n + 1` entries and packs the last vararg (the metadata struct pointer) into
  the meta word. `argumentCount = n - 1 = N - 2`.

The table has 63,612 rows (33,044 raw), 58,736 distinct RM IDs, 184 INIT, and 75
early. The decoder recovers function, arguments, task, and timestamp; RM and INIT
message text and severity need the missing ELF.

**Reproduce.**
1. Extract `.fwimage` from `gsp_ga10x.bin` and the decompiled image/module split
   with `tools/gsp-rm-tools/` (the tool README covers extraction).
2. `cd tools/gsp-rm-tools/logdecode`
3. `python3 -I build_id_table.py --decompiled "$DECOMPILED" --modules "$MODULES" --image "$FWIMAGE" --out id_table.csv --summary id_table_summary.json`
4. `python3 -I selftest.py`; expect `all tests passed`.
5. `python3 -I gsp_log_decode.py --manifest ../../driver-harness/gsplog/manifest.json`
6. Expect 63,612 table rows and a function-level trace; RM/INIT text still absent.

**Limits.** The ID table is 8.3 MB and generated, not committed. Text and severity
need the missing metadata ELF. The KERNEL base remains unknown
([E59](#e59--live-gsp-log-capture-and-decode)).

## E58 · Static pass: FEAT consumers, decoder selection, registry consumers, FSP surface, GR init

*2026-10-26 · status: static; corrects the “no `SS0`/`SS1` write path” and
[E50](../experiments/02_registry-and-static-audit.md) producer claims*

**Hypothesis.** A static pass over the 595.91.07 image and host source closes the
remaining call-site and control-surface questions.

**Instrument.** `tools/gsp-rm-tools/` (`DecompileAt.java`, `DisasmRange.java`,
`refscan.py`) over `$FWIMAGE` and `$SRC`; no GPU access.

**Method.** Six independent directions: FEAT consumers, static-info controls,
decoder selection, registry consumers, FSP surface, and GR init.

**Observed data.** The report answers, quoted:

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
| FEAT consumers | `FUN_ram_0160f1bc` writes `0x381c`/`0x3820` through `FUN_ram_01c60868`; installed at `obj+0x938` for variants not in `{5..9}`; the helper’s fallback is a direct BAR0 MMIO store, but there is no visible 4-argument caller. Bit 6 is the alternate ninth byte. | CLOSED-STATIC (write method exists; unreachable/PLM-blocked) |
| Static-info controls | The control table confirms V1 internal `0x48` (8×9), V2 internal `0x3fe0`, public V1 `0x20`, V2 `0x7fc`; the getter is a copy-out/cache. Handler pointers are 2 bytes early, so the reader trace is partial. | PARTIAL |
| Decoder selection | `{5..9}` twin confirmed by `0x3e0 >> variant & 1`. `0xC38` is variant-dependent: `FUN_ram_01615a40` (DP `[30:28]`) or `FUN_ram_015ffbd0` (bit 6). GB202 is `0x02`, not in `{5..9}`, so it installs `FUN_ram_015ffae8` / `0x3818`. | CLOSED-STATIC |
| Registry consumers | `config+0xEA8/0xEAC` are read by `FUN_ram_0216d680` and `FUN_ram_0217f718`, reduced to booleans, and written to a GR context/ucode descriptor, not MMIO; EA8 is gated by `+0xEA4`. `0x504204` has no writer. | CLOSED-STATIC |
| FSP surface | Only COT `0x14`, caps `0x16`, and clock `0x20` are live; PRC `0x13` is GH100-only; nine NVDM types are unused. No length field; the host controls TX length via `QUEUE_TAIL`; response identity is unchecked. | CLOSED-STATIC |
| GR init | 29 FECS command IDs, all init/context/feature; no selector; no per-SM rate loop; no `0x504204` writer. | CLOSED-STATIC |
| GSP log | See [E57](#e57--gsp-log-decoding-without-gsp_log_ga10xbin). | CLOSED-STATIC |

**Result.** The corrections:

1. The earlier “no computed-offset write to `SS0`/`SS1`” claim is too strong. A
   write method exists (`FUN_ram_0160f1bc`, installed at `obj+0x938`) and attempts
   a direct BAR0 MMIO store, but it has no visible 4-argument caller, and any PL2
   write is dropped by `FEAT_OVR_PLM`
   ([E08](../experiments/01_software-register-writes.md)). It is not a usable lever.
2. [E50](../experiments/02_registry-and-static-audit.md): the producer is
   `FUN_ram_015ce3e8`, not `0x015cf1be` (an interior address). The keys are inert
   because the value is boolean-ized and EA8 is gated by `+0xEA4`, not because the
   consumer is absent or PLM-dropped.
3. The earlier claim that no RM code writes `0x504204` stands; the value 5 comes
   from firmware/devinit or a ctxsw/golden-context restore.
4. Bit 6 of `FEAT_READOUT_1` is resolved: it is the alternate ninth byte
   (`FUN_ram_015ffbd0` / the twin’s `param_3[2]`), not an unexplained gap.
5. [E17](../experiments/07_plaintext-corpus.md)’s `0xC38` slot is
   variant-dependent; on some variants it is the bit-6 reader, not
   `FUN_ram_01615a40` (DP).
6. The FSP command surface is enumerated; there is no memory, fuse, register, or
   debug command, and the only data-returning command (PRC) is GH100-only.
7. GB202’s implementation constant is `0x02`, not in `{5..9}`; it installs
   `FUN_ram_015ffae8` and reads `0x3818`. The `0x9668` twin is the
   GB205/GB206/GB207 path, which is why the direct `0x009668` read is
   unimplemented.
8. The helper’s `+0xb48` field is the BAR0 base, not a shadow; the fallback is a
   direct MMIO store. On GeForce, the `is_geforce` byte skips the `fuse+0x108`
   access callback; a PL2 `SS0`/`SS1` write is dropped by `FEAT_OVR_PLM`.

**Reproduce.**
1. Extract `.fwimage` from the 595.91.07 package (the `tools/gsp-rm-tools/`
   README covers extraction).
2. `cd tools/gsp-rm-tools && python3 -I refscan.py "$FWIMAGE" 0x3818`; expect the
   five materializations and the GB202 variant selection.
3. Decompile the named functions with `DecompileAt.java`; decode the ctrl table at
   `0x01d16xxx`; expect 44/44 IDs and the counts above.
4. The A–F findings are summarized here; no external report is needed.

**Limits.** Static analysis. Decompiled C is a hypothesis until checked against the
instruction bytes or hardware; handler pointers in the ctrl table are 2 bytes early,
so reader traces are partial.

## E59 · Live GSP log capture and decode

*2026-10-26 · status: measured (host-side read only)*

**Hypothesis.** The [E57](#e57--gsp-log-decoding-without-gsp_log_ga10xbin) format
and ID table are correct, and a real capture decodes to a function-level
boot/GR-init trace.

**Instrument.** `tools/driver-harness/gsp_log_capture.sh` plus the instrumented
595.91.07 `kernel_gsp.c` hook at `_kgspFreeLibosLoggingStructures`; decoder in
`tools/gsp-rm-tools/logdecode/`. No firmware was modified and no GPU register was
written.

**Method.** Apply the log-dump patch from `tools/driver-harness/`, build the
595.91.07 tree, unload the stock modules, load only the instrumented `nvidia.ko`,
wait for both cards, issue a few RM queries, unload (firing the hook), and restore
stock in a trap. Then decode the raw rings.

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
| RM (`task 3`) | 98 | 96 | `0x2018F000` | registry, inforom, SEC2/ACR, GR/FECS, display; 27 via raw fallback |
| INIT (`task 2`) | 42 | 41 | `0x20183000` | WPR/buffer layout |
| KERNEL (`task 1`) | 26 | 0 | unknown | IDs `0x2017c3c0`–`0x2017ccf0` not referenced in `.fwimage` |
| INTR (`task 4`) | 2 | 2 | `0x2018F000` | — |
| ROOT (`task 8`) | 3 | 0 | `0x2018F000`? | IDs `0x2018fea0`/`0x2018fff0`/`0x2018ff30` not referenced |
| RMON (`task 9`) | 2 | 2 | `0x2018F000` | — |
| MNOC / DEBUG | 0 | — | unknown | empty at capture time |

**Result.** Both cards produced 173 records with an identical `(task, ID, argc)`
sequence, which confirms the ring framing and the ID table. Total: 141/173
(81.5%) resolved.

The findings:

1. The record layout is confirmed on hardware: `[args...][meta][time]`, meta
   second-to-last, with no bad boundary. The earlier `[meta][args...]` draft would
   have misparsed every `N > 2` record.
2. INIT uses a third writer, `FUN_ram_011849a6`, with base `0x20183000`. The earlier
   assumption that INIT uses the `0x20178000` writer is wrong.
3. The RM base `0x2018F000` is confirmed. The raw `AUIPC+ADDI`/`LUI+ADDI` scan
   recovers 33,044 extra IDs.
4. The KERNEL buffer is a separate metadata section. Task-1 IDs do not appear as
   literals, PC-relative targets, or pointers in `.fwimage`; the base cannot be
   recovered without the metadata ELF.
5. The trace is deterministic across cards.
6. The RM timeline is usable without text: registry at ~65 ms, inforom
   ~89–345 ms, SEC2/ACR ~365–385 ms, GR/FECS init ~435–484 ms, display ~462 ms and
   ~1723 ms.

**Reproduce.**
1. Apply the log-dump patch from `tools/driver-harness/` to a local 595.91.07
   source tree (`$SRC`) and build it.
2. Load only the instrumented `nvidia.ko`; keep the stock DKMS modules as the
   restore path.
3. `sudo tools/driver-harness/gsp_log_capture.sh`
4. `python3 -I tools/gsp-rm-tools/logdecode/gsp_log_decode.py --manifest tools/driver-harness/gsplog/manifest.json`
5. Expect 173 records per card and the same task/ID sequence.

**Limits.** RM and INIT message text, level, and source line remain unavailable: the
metadata ELF is missing. The KERNEL base is unknown. The capture is one boot on two
cards.

## E60 · Sentinel and raw-function analysis of the log trace

*2026-10-26 · status: static analysis of the
[E59](#e59--live-gsp-log-capture-and-decode) capture*

**Hypothesis.** The `0xBADF` records in the log trace are feature probes that might
touch the rate path.

**Instrument.** `tools/gsp-rm-tools/logdecode/gsp_log_decode.py` on the
[E59](#e59--live-gsp-log-capture-and-decode) rings, plus `DecompileAt.java` on the
17 raw-attributed functions. Static analysis; no GPU.

**Method.** Verify the raw-function starts, decompile the three sentinel producers,
and inspect the feature-mask functions.

**Observed data.** The captured sentinel records:

```text
[   +96.222656 ms] t=3 RM      id=0x203cd1a8 n_args=4  FUN_ram_01230c00 [rm_core]  args=[0x1d5e9d0, 0xbadf4100, 0x1100f4, 0x1]
[  +483.978560 ms] t=3 RM      id=0x20471918 n_args=1  FUN_ram_016ea930 [gr_fecs]  args=[0x1]
[  +484.002048 ms] t=3 RM      id=0x20471930 n_args=5  FUN_ram_016ea930 [gr_fecs]  args=[0x0, 0x137200, 0x0, 0x14252215, 0xbadf5128]
```

`0x14252215` decodes as SUBID 20, PRIV_LEVEL 2, SENDING_RS 18, PENDING 1,
PRIV_MASTER 21; `0xbadf5128` is `NV_PPRIV_SYS_PRIV_ERROR_CODE`. All 17 reported
raw-function starts are genuine prologues; 70/70 raw-attributed records matched a
real writer call site. One decoder attribution was wrong (`0x01187eae` is an inner
stack adjustment inside `FUN_ram_01187426`); the table builder now maps it there.

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

**Result.** The `0xBADF` records are PRI error telemetry, not feature probes:

- `FUN_ram_016ea930` is a PRI ringmaster/ringstation global-write-error dumper. It
  reads `BAR0+0x120058`/`+0x12005c`, walks the per-station records at
  `0x122120+0x800*n`, and logs `[station, ADR, WRDAT, INFO, CODE]`. The captured
  `0x20471930` record is a refused PL2 access at `0x137200`.
- `FUN_ram_01230c00` logs `[direction, PRI_CODE, ADR, valid]`; the captured
  `[0x1d5e9d0, 0xbadf4100, 0x1100f4, 1]` is a refused access to GSP `HWCFG2`
  (`0x1100f4`).
- `FUN_ram_016d80c8` is a generic GSP ucode event pump, not a register probe.

No `0x8238xx` FEAT register, `FUSE_SS_FMLA32`, `FEAT_READOUT_1`, or
`SM_ISSUE_RATE_MODIFIER` appears in any of them. The trace adds no evidence about
the rate selector; it does show the GSP hitting PRI refusals at PL2 during boot.

**Correction to the sentinel table.** `0xBADF51` is a generic PRI
client/privilege error family, not fuse-specific. `0xBADF510C` at the fuse block
and `0xBADF5128` at `0x137200` are instances with different low bytes.
`0xBADF4100` belongs to the `0xBADF41` PRI-decode family. See
[the errors and logging spec](../specs/08_errors-and-logging.md).

**Reproduce.**
1. Capture and decode the rings as in
   [E59](#e59--live-gsp-log-capture-and-decode).
2. Decompile `FUN_ram_016ea930`, `FUN_ram_01230c00`, and `FUN_ram_016d80c8` with
   `tools/gsp-rm-tools/DecompileAt.java`.
3. Expect the same `[station, ADR, WRDAT, INFO, CODE]` and
   `[direction, PRI_CODE, ADR, valid]` records.

**Limits.** Attribution is static. The sentinel records show refusals, not their
cause, and they add no evidence about the rate selector.
