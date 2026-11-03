# Privilege and rate control: the BF16 speed selector

## At a glance

- **Scope.** The selector that sets tensor throughput, the privilege mask that
  protects it, and the measurements behind both.
- **Bench.** Two RTX 5090s (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  plus one RTX PRO 6000 Blackwell reference (same GB202 die, `10de:2bb1`,
  615.71.09); external measurements say so in the table.
- **Evidence.** Measured claims link to the experiment that established them.
  Claims from public headers or carried over from Ada/Ampere say so in the
  sentence.

**The short version.**

- The 5090 and the RTX PRO 6000 use the same GB202 die. The 5090 runs the
  FP32-accumulate tensor path at about half the FP16-accumulate rate; the PRO
  6000 runs both at the same rate.
- The limit is a fuse-programmed speed selector, not a missing execution unit.
- The FEAT bank's write mask is PL3-only at stock. PL0 is the host, PL2 is
  GSP-RM, PL3 is boot firmware; host, GSP-RM, and CUDA debugger writes are
  dropped silently.
- The selector chain is fuse -> `SS0`/`SS1` -> FECS/GPCCS -> SM issue rate. A
  PCI function-level reset (FLR) opens a PL2-write window briefly, but it closes
  before GSP-RM starts.
- `SM_ISSUE_RATE_MODIFIER` is writable but reasserted and inert. The host driver
  is telemetry, not a lever.
- The full-rate encoding is measured: a PRO 6000 reads `FEAT_READOUT_1 = 0`
  with every arithmetic speed fuse at 0.
- The flanking readouts, `FEAT_READOUT_0` and `FEAT_READOUT_2`, carry ECC
  capability flags only; `READOUT_1` is the sole selector carrier
  ([the readout
  decode](../experiments/12_feat-readout-decode.md#122-the-consumer-class-names-the-bits)).
- The PRO 6000's FEAT bank uses the same PL3-only write gate as the 5090.

**In this spec.**

- [The cap is product segmentation](#the-cap-is-product-segmentation): the
  measured baseline and what the cap affects.
- [Privilege levels and the PLM](#privilege-levels-and-the-plm): the three
  levels, the mask, and the FLR window.
- [The selector chain](#the-selector-chain): fuse to SM issue rate.
  - [Fuses](#fuses)
  - [The two override paths](#the-two-override-paths)
  - [FEAT bank](#feat-bank)
  - [Selector encoding](#selector-encoding)
- [The RM getter and the host view](#the-rm-getter-and-the-host-view): what the
  driver reports.
- [Cross-part comparison](#cross-part-comparison): A100, Ampere, Ada, GB202,
  PRO 6000.
- [What is proven, what is inferred](#what-is-proven-what-is-inferred)
- [What would count as an unlock](#what-would-count-as-an-unlock)
- [Evidence map](#evidence-map)

## The cap is product segmentation

The RTX 5090 and the RTX PRO 6000 use the same GB202 die. The 5090 runs the
FP32-accumulate tensor path at about half the FP16-accumulate rate; the PRO 6000
runs both at the same rate, measured here. The limit is a
fuse-programmed speed selector, not a missing execution unit.

| Case | Result | Provenance |
|---|---:|---|
| FP16 → FP16 accumulate | 441.4 TF/s | external issue-rate probe, driver 610.57.04 |
| FP16 → FP32 accumulate | 224.3 TF/s | same probe |
| BF16 → FP32 accumulate | 222.8 TF/s | same probe |
| BF16 → FP32, two local cards | 226.6 / 229.6 TF/s | this machine, driver 595.91.07 |
| RTX PRO 6000, BF16 → FP32 | 518.0 TF/s | this machine, 615.71.09; whitepaper 503.8 |
| RTX PRO 6000, FP16 → FP16 | 515.0 TF/s | same run |
| BF16 cuBLAS GEMM, 8192³ | 234.8 TF/s | 5090 D, a different SKU |

The PRO 6000 has the full-rate path: its BF16 → FP32 and FP16 → FP16 issue
rates agree within 0.4%, while the 5090's BF16 → FP32 rate is half its external
FP16 → FP16 number. The 5090 has no local FP16-accumulate measurement, so its
full-rate ratio rests on the ai.rs number; the PRO row is measured. The PRO also
reads `FEAT_READOUT_1 = 0` and every arithmetic speed fuse at 0.

- **What the cap affects.** Compute-bound FP16/BF16 work that uses FP32
  accumulation: prefill, long-context inference, diffusion, LoRA, and training.
- **What it does not affect.** Token decode, FP8/FP4/INT8, or kernels that use
  FP16 accumulation.

## Privilege levels and the PLM

| Level | Name | Firmware that runs there |
|---|---|---|
| PL0 | Non-Secure (NS) | host CPU and ordinary driver access |
| PL2 | Light Secure (LS) | GSP-RM; PMU devinit |
| PL3 | Heavy Secure (HS) | FSP; GSP BootROM; FMC; SEC2 HS ucode; FWSEC-FRTS |

The FEAT bank is readable from every level. Its write permission is a 32-bit
privilege-level mask (PLM). The field layout matches NVIDIA's public Falcon v4
register header, which defines `READ_PROTECTION 3:0`, `WRITE_PROTECTION 7:4`
with `WRITE_PROTECTION_ONLY_LEVEL3_ENABLED 0x00000008`, the two violation bits,
the two source controls, and `SOURCE_ENABLE 31:12`
([dev_falcon_v4.h](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/inc/swref/published/nvswitch/ls10/dev_falcon_v4.h)).
The [mask
decode](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only)
applies that layout to the measured value. The FEAT block is not a Falcon
register file, so the match removes the field-name guess without proving the
bank is a Falcon PLM.

| Field | Bits | `0xfffffb8f` (stock) | `0x80842bcf` (after FLR) |
|---|---|---:|---:|
| Read mask | `3:0` | `0xf` (all levels) | `0xf` (all levels) |
| Write mask | `7:4` | `0x8` (PL3 only) | `0xc` (PL2 + PL3) |
| Read violation | `8` | 1 | 1 |
| Write violation | `9` | 1 | 1 |
| Source read control | `10` | 0 (lowered) | 0 |
| Source write control | `11` | 1 (blocked) | 1 |
| Source enable | `31:12` | `0xfffff` (all 20 sources) | `0x80842` |

The stock write mask is the entire wall: only PL3 may write the bank. Host BAR0
writes (PL0) and GSP-RM writes (PL2) are [dropped
silently](../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped).
The drop still returns `SUCCESS`; only a readback distinguishes it. The [mask
decode](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only)
gives the PL3-only write field.

The gate sits below every host-facing path. The public
[`GPU_EXEC_REG_OPS`
header](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gpu.h)
defines a per-op `NOACCESS` status, and the register-op implementation validates
the offset before execution, so a write with a valid offset returns `SUCCESS`
and is still dropped ([the GSP
write](../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped),
[the debugger
write](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
The drop is the hardware privilege check, not an argument error.

The PLM is not static across resets:

| Event | Value | Meaning |
|---|---|---|
| Stock boot | `0xfffffb8f` | write PL3 only |
| PCI FLR | `0x80842bcf` | write PL2 + PL3 |
| Re-lock after FLR | `0xfffffb8f` | GPU-side devinit, before the first open |

The FLR window is real but short. A direct BAR0 poller [measures the
re-lock](../experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm)
at 1156–1353 ms after the FLR; the first GSP-RM program counter appears at
3174–3176 ms. The re-lock therefore lands about 1.82–1.85 s before the only PL2
master exists. An early open does not help: the open→GSP-RM path is about 2.1 s,
longer than the 1.35 s window. The same poll sees no FSP core, scratch, engine,
or PLM movement, so the writer is the PMU or a hardware latch on the visible
registers. Only `FUSE_SS_PLM` (`0x8200fc`) moves with the bank: it takes the
FLR's `0x80842bcf`, the same value as the FEAT PLM, and re-locks to `0xfffffbff`
at the same instant; the FEAT PLM re-locks to `0xfffffb8f`. It is not a second
gate ([the re-lock
record](../experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).
The [re-lock is a GPU-side
devinit](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit),
not the FMC or GSP-RM.

**Self-access rule.** The PLM gates external masters, not an engine's own
registers. The same PL2 path that cannot write the FEAT bank can write the GSP's
own Falcon EMEM. The distinguishing property is whether the target belongs to
the executing engine, not the caller's numeric level.

## The selector chain

```
  one-time fuse -> SS0/SS1 override -> FECS/GPCCS microcode -> SM issue rate
                          ^
                   FEAT_OVR_PLM  (write gate: PL3 only)
```

FECS/GPCCS is the GR front-end and context-switch microcode; SM is the streaming
multiprocessor. The GSP reads the fused value to populate its static-info getter,
but it does not write the override.

### Fuses

| Register | Offset | GB202/GB203M | PRO 6000 |
|---|---|---:|---:|
| `FUSE_SS_DP` | `0x00820224` | 0 | 0 |
| `FUSE_SS_FFMA` | `0x0082059c` | 0 | 0 |
| `FUSE_SS_FMLA16` | `0x008207d4` | 0 | 0 |
| `FUSE_SS_FMLA32` | `0x008207d8` | 3 | 0 |
| `FUSE_SS_IMLA0` | `0x008207dc` | 0 | 0 |
| `FUSE_SS_IMLA1` | `0x008207e0` | 3 | 0 |
| `FUSE_SS_IMLA2` | `0x008207e4` | 3 | 0 |
| `FUSE_SS_IMLA3` | `0x008207e8` | 0 | 0 |
| `FUSE_SS_IMLA4` | `0x008207ec` | 3 | 0 |

Both PRO 6000s read 0 on every arithmetic speed fuse, the same shape as the
[A100](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus)
and the measured full-rate endpoint
([the reference dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

The fuse block is read-only to the host and to the GSP. The page-0 mask
`FUSE_SS_PLM` (`0x8200fc`) reads `0xfffffbff`, which looks write-all, but it is
not the effective gate: writes to `0x82074c` and `0x8207d8` stay unchanged from
both PL0 and PL2. See [the FUSE write
test](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier).

### The two override paths

Two fuses are usually read together, and they gate different things.

- `FUSE_FEAT_OVR_DIS` (`0x8203f0`) is the master kill for the feature
  overrides, the speed selectors included. It reads `0` on every measured part,
  Ampere and GB202 alike, so the path is available and the
  [PLM](#privilege-levels-and-the-plm) is the only gate in front of it.
- `FUSE_EN_SW_OVERRIDE` (`0x820040`) gates the CTRL_OPT floorsweep override:
  SM count, memory geometry, and the PCIe link. It reads `0` on the A100, the
  CMP 170HX, and every measured GB202 card; a throttled part with the same
  reading still reaches full rate by writing its speed selectors.

A `0` on `FUSE_EN_SW_OVERRIDE` is therefore not evidence that `SS0`/`SS1` are
fused off. The CMP 170HX and RTX 4090 both unlock with it at `0` ([the external
cross-check](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus)).

### FEAT bank

| Offset | Name | Stock | Role |
|---|---|---:|---|
| `0x823800` | `FEAT_OVR_ECC_PLM` | `0xfffffb8f` | ECC PLM; alias or second copy |
| `0x823804` | `FEAT_OVR_PLM` | `0xfffffb8f` | bank write gate |
| `0x823808` | `FEAT_OVR_QUADRO` | per-card | classification, not rate |
| `0x82380c` | `FEAT_OVR_ECC` | `0x00888888` | consumer stock ECC override |
| `0x823810` | `FEAT_OVR_ECC_1` | `0x002a2aaa` | ECC |
| `0x823814` | `FEAT_READOUT_0` | `0x00000233` | bit 16 = ECC enablement |
| `0x823818` | `FEAT_READOUT_1` | `0x00c36180` | selector readout |
| `0x82381c` | `FEAT_OVR_SM_SS0` | per-card | eight 4-bit override fields |
| `0x823820` | `FEAT_OVR_SM_SS1` | per-card | ninth field in `[3:0]` |
| `0x823824` | `FEAT_OVR_ROW_REMAP` | `3` | row remap |
| `0x823828` | `FEAT_READOUT_2` | `1` | readout |
| `0x82382c` | `FEAT_OVR_ECC_2` | `0xa` | ECC |

`0x82380c = 0x00888888` is `FEAT_OVR_ECC`, the stock consumer-GA10x ECC
override, not an Ada speed payload. The nibble pattern is a coincidence; [the
cross-part corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus)
identifies it.

### Selector encoding

`SS0` holds eight 4-bit fields; `SS1` holds the ninth in `[3:0]`. Each field uses
bit 3 as the override enable and bits 2:0 as the selector. The Ada/Ampere
encoding is `0` = full rate, `1` = 1/2, `2` = 1/4, `3` = 1/8; the unlock payload
was `SS0 = 0x88888888`, `SS1 = 0x8`. Writing that payload from PL2 is dropped,
like the zero write; it is only testable after a PL3 write opens the gate
([the payload
test](../experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).

At stock every enable bit is clear, so the fused selectors are in force. The
non-zero stock words are pre-driver shadow state. They vary across cold boots
but are invariant within a boot and across warm reboots:

| Card | Example SS0 values across cold boots | SS1 |
|---|---|---|
| `41:00.0` | `0x21240001`, `0x20240001`, `0x20260041`, `0x21265047`, `0x21265043` | `0x00000002` |
| `c1:00.0` | `0x54226037` / `0x54224037` | `0x00026005` / `0x00024005` |
| PRO 6000 card A | `0x56664061` (one boot) | `0x00075005` |
| PRO 6000 card B | `0x00544047` (one boot) | `0x00000001` |

Both cards [measure identically per
clock](../experiments/08_assessment-and-cross-checks.md#083-same-boot-two-card-issue-rate-probe),
so the differing words are binning/state, not selectors. [The FEAT bank across
boots](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)
covers the per-boot state. Both PRO 6000 snapshots have every enable bit clear,
and the words differ across the two cards; a same-card cold-boot series is still
unsampled
([the reference dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

`FEAT_READOUT_1` packs eight 3-bit selectors plus DP from a separate field:

| Field | Bits | Stock `0x00c36180` |
|---|---:|---:|
| imla0 | 2:0 | 0 |
| fmla16 | 5:3 | 0 |
| fmla32 | 9:7 | 3 |
| ffma | 12:10 | 0 |
| imla1 | 15:13 | 3 |
| imla2 | 18:16 | 3 |
| imla3 | 21:19 | 0 |
| imla4 | 24:22 | 3 |
| DP | 30:28 | 0 |

The readout is a fuse mirror, not an effective-rate readout. A `3` in `fmla32`
comes with a ~2× penalty, not the public enum's 1/8, and `imla1/2/4 = 3` still
runs INT8 at full rate. The Blackwell code→rate law is not the Ada law.

## The RM getter and the host view

`NV2080_CTRL_CMD_GR_GET_SM_ISSUE_RATE_MODIFIER` (`0x20801230`) returns the nine
bytes copied from `KGRAPHICS_STATIC_INFO`:

```
imla0=0, fmla16=0, dp=0, fmla32=3, ffma=0, imla1=3, imla2=3, imla3=0, imla4=3
```

V2 (`0x2080123c`) returns ten entries: FMLA16=0, FMLA32=3, FFMA=0, IMLA0=0,
IMLA1=3, IMLA2=3, IMLA3=0, IMLA4=3, FP16=0, FP32=0. The throttle getter
(`0x2080123d`) returns one `MASK=0` entry. All three are GET-only.

`SM_ISSUE_RATE_MODIFIER` (`0x504204`) is the one rate-related register that is
genuinely writable:

| Action | Result |
|---|---|
| Host PL0 write `0`, readback | 0 |
| GSP PL2 write `0`, readback | 0 |
| Restore `5` | 5 |
| At CUDA context creation | reasserted to 5 |
| Held at 0 after `cuCtxCreate` | stays 0 through every launch |

Holding it at 0 does not change the measured rate:

| Mode | Modifier 5 | Held at 0 |
|---|---:|---:|
| FP16 → FP32 | 227.1 TF/s | 227.1 |
| BF16 → FP32 | 227.1 TF/s | 225.9 |
| TF32 → FP32 | 113.6 TF/s | 113.0 |
| U4 → S32 | 596.5 TOPS | 591.1 |

The value 5 is applied by firmware/devinit or a context-switch restore, not by
the host driver or GSP-RM. [The FUSE/rate
test](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)
shows the register is writable and reasserted; [the static
pass](../experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp)
finds no RM writer by literal reference. The computed-offset forms are still
unrun ([the static audit](../experiments/02_registry-and-static-audit.md#021-static-scan-finds-no-rate-register-reference)).

The host driver is telemetry, not a lever. It fetches the nine selectors at GR
init and caches them; its only FEAT-bank access is the `0x823814` ECC readout.
The GB202-specific driver file is a vGPU-only HAL and does not override the
reset or COT path.

## Cross-part comparison

| Part | `FEAT_READOUT_1` | `FUSE_SS_FMLA32` | Measured FP32-accumulate rate |
|---|---:|---:|---|
| A100 | `0x00000000` | 0 | full |
| Consumer Ampere | `0x00400080` | 1 | half |
| Ada | `0x00410080` | not dumped | half |
| GB202/GB203M | `0x00c36180` | 3 | ~half |
| RTX PRO 6000 (measured) | `0x00000000` | 0 | full (518 TF/s) |

On every generation with a public dump, the readout mirrors the fuse words, and
zero is the full-rate encoding. The A100 and two PRO 6000s are the full-rate
references: all three read all zeros, and both PRO cards have every arithmetic
speed fuse at 0. The earlier inference from Ada/Ampere is now a measurement: every field
of `FEAT_READOUT_1` decodes to 0, including DP `[30:28]`
([the reference dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

## What is proven, what is inferred

The public record reproduces the FEAT drop on GB202 and GB203M before the
driver binds and places the missing primitive at PL3 code execution in the
security firmware ([the external
cross-check](../experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).
The local PLM decode matches the public Falcon v4 header's `WRITE_PROTECTION`
and `SOURCE_ENABLE` fields ([the mask
decode](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only)).

**Proven on hardware.**

- The [FEAT bank drops PL2
  writes](../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)
  and returns success.
- The [debugger class reads the bank and its FEAT write
  drops](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it).
- The [FUSE shadow is not
  writable](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)
  from PL0 or PL2.
- The [PLM is PL3-only at
  stock](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only)
  and is [re-locked by GPU-side
  devinit](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)
  after an FLR.
- [SS0/SS1 are per-boot shadow
  state](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr),
  not selectors.
- [`SM_ISSUE_RATE_MODIFIER` is writable but reasserted and
  inert](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier).
- The FECS and GPCCS falcon blocks are not host-readable: their documented bases
  return decode markers, and the GR window the GSP-RM admits is empty
  ([the falcon probe](../experiments/11_falcon-and-gr-window-probe.md)).
- The space above that window is decode refusals plus the vBIOS ROM at
  `0x300000`–`0x4fffff` and one per-card table at `0x1f2000`–`0x1f3fff`. Neither
  carries GR ucode or a known rate field
  ([the GR map](../experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom)).
- The vBIOS ucode table has no consumer in the open stack on GB202: the host
  FWSEC path is short-circuited and the RM boots GR through `sec2_acr` from RM
  memory ([the consumer
  record](../experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
- Two PRO 6000s read `FEAT_READOUT_1 = 0` with every arithmetic speed fuse at 0,
  and one card's FP32-accumulate rate equals its FP16-accumulate rate
  ([the reference dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- The speed-selector override is open at the fuse level on GB202:
  `FUSE_FEAT_OVR_DIS` reads `0` on every measured part — two 5090s, two PRO
  6000s — and only the [PLM](#privilege-levels-and-the-plm) gates it
  ([the debugger
  group](../experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read),
  [the reference
  dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
  `FUSE_EN_SW_OVERRIDE` also reads `0`, but it gates the CTRL_OPT floorsweep
  override, not this one ([the two override paths](#the-two-override-paths)).
- Every RM consumer of `FEAT_READOUT_0` and `FEAT_READOUT_2` decodes ECC
  capability flags, all clear on the measured cards; no rate or
  override-enable bit is read from either register, and the bits that differ
  between the product classes have no reader in the image
  ([the readout
  decode](../experiments/12_feat-readout-decode.md#122-the-consumer-class-names-the-bits)).

**Inferred or open.**

- The nonzero readout→rate mapping. The zero endpoint is measured; `FMLA32 = 3`
  with a ~2× penalty is not the Ada law.
- The pre-lock FEAT writer. The timing points to a GPU-side devinit. The FLR
  poll sees no FSP register activity, leaving the PMU or a hardware latch
  ([the re-lock
  record](../experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).
- The per-SM selector. Only the global FEAT bank was probed; per-SM copies could
  have a different gate. [The per-context
  probe](../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)
  reached the typed register space but needed a caller-owned RM channel.
- The Ada persistence model. On GB202 an FLR resets the PLM and the devinit
  re-locks it; the override does not stay open across reset.
- The on-die meaning of `SECURE_FEAT_OVR_QUADRO_WR_SEC`. The values are
  measured — `2` on GB202 against Ampere's `1` — but the field mapping is the
  public Ampere one carried over.
- Whether a Blackwell `SS0`/`SS1` write changes the rate. The prior art runs
  the same sequence on parts whose `FUSE_EN_SW_OVERRIDE` also reads `0`
  ([the two override paths](#the-two-override-paths)); the local measurement
  needs a PL3 write to [`FEAT_OVR_PLM`](#write-gate).

## What would count as an unlock

1. The rate getter reports `fmla32 = 0`.
2. `FEAT_READOUT_1` decodes to zero selectors on the Blackwell layout the PRO
   6000 uses.
3. `SS0`/`SS1` read back the intended values.
4. BF16→FP32 issue rate is about 440 TF/s, with FP16→FP16, INT8, FP8, and scalar
   controls unchanged.
5. A matched BF16 GEMM shows a real gain with numerical validation.
6. The override survives an FLR, a driver reload, and a device enable; the driver
   loads without GPU or GSP errors.
7. It reproduces on a second cold boot and a second card.

Issue-rate numbers alone are not enough; Ada GEMM gains were shape-dependent.

## Evidence map

| Topic | Experiments | Tools |
|---|---|---|
| FEAT write drop, positive control | [01.2 write drop](../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped) | [register access](../tools/register-access/) |
| Wider FEAT bank, `0x82380c` | [01.3 bank](../experiments/01_software-register-writes.md#013-the-whole-feat-bank-shares-one-gate) | [register access](../tools/register-access/) |
| FUSE shadow, rate register | [01.4 FUSE/rate](../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier) | [register access](../tools/register-access/), [issue-rate probe](../tools/issue-rate-probe/) |
| PLM decode | [01.5 mask decode](../experiments/01_software-register-writes.md#015-the-permission-mask-admits-pl3-writes-only) | offline |
| Two-card rate baseline | [08.3 two-card probe](../experiments/08_assessment-and-cross-checks.md#083-same-boot-two-card-issue-rate-probe) | [issue-rate probe](../tools/issue-rate-probe/) |
| Registry selectors | [02.3 live paths](../experiments/02_registry-and-static-audit.md#023-speed-select-keys-are-live-code-paths), [02.4 inert](../experiments/02_registry-and-static-audit.md#024-speed-select-keys-are-inert-on-hardware) | [issue-rate probe](../tools/issue-rate-probe/) |
| Cross-part corpus, `0x82380c` | [08.5 corpus](../experiments/08_assessment-and-cross-checks.md#085-external-cross-part-register-corpus) | offline |
| Full-rate reference | [PRO 6000 dump](../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump) | [direct probe](../tools/direct-probe/), [issue-rate probe](../tools/issue-rate-probe/) |
| Getter/static-info consumers | [08.7 static pass](../experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp) | [GSP-RM tools](../tools/gsp-rm-tools/) |
| FLR window and re-lock | [01.6 window](../experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm), [05.21 re-lock](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit) | [driver harness](../tools/driver-harness/) |
| Debugger-class write drop | [01.8 debugger test](../experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it) | [register access](../tools/register-access/) |
| Prior-art primitive and external drop | [08.11 external cross-check](../experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem) | offline |

Register values and the full FEAT/FUSE maps are in
[03_register-map.md](03_register-map.md). The boot chain that runs before the
driver is in [01_boot-chain.md](01_boot-chain.md).
