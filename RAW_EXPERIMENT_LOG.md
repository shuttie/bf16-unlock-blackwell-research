# RTX 5090 BF16 / FP32-accumulate rate cap

**Findings, closed routes, and the open surface**

| | |
|---|---|
| Target | NVIDIA GeForce RTX 5090, GB202, PCI ID `10de:2b85` |
| Local machine | 2 cards: `41:00.0` (ZOTAC, VBIOS `98.02.2E.00.AF`), `c1:00.0` (InnoVISION, VBIOS `98.02.2E.40.53`) |
| Power limit | 575 W per card (default/current; min 400 W, max 600/575 W depending on card) |
| Driver / firmware | 595.91.07 (exact open-source tag), GSP-RM 595.91.07, compute capability 12.0 |
| Last updated | 2026-10-29 |
| Status | No public unlock. The cap is proven product segmentation; no host-reachable PL0/PL2 path reaches it. The FEAT bank's pre-lock writer is a GPU-side devinit, re-applied on every reset; the vBIOS devinit-table route to it is closed (E66). The PRISCV ICD is live and host-writable at PL0, and with the core halted it reads the 14.4 MB GSP-RM code segment (E67). The read window is that code segment only: the ICD is blocked through the HS boot window, RDM is refused at the LS transition, and after boot it cannot reach the boot image at `0xefd00000`, the data segment or the WPR (E68). The FMC validates the host-supplied bootloader description (`0x82e`, `0x885`) and authenticates both boot images (`0xaff`/info `0xb`), so a corrupted ciphertext never reaches HS (E69). The post-FLR L2 window is real but ends 1.85 s before the first GSP-RM PC, so no host-controlled PL2 master can use it (E70); `GPU_EXEC_REG_OPS` cannot reach the `GR_CTX`/`GR_CTX_SM` register space from PL0 without a caller-owned RM channel (E71); and the FMC does not decrypt the bootloader in place in host sysmem (E72). The decrypted boot image is not in open FB: a proven BAR0-window read (non-WPR heap control, 58,707 nonzero bytes) finds PAs `0x01000000`, `0x5dd00000` and `0x181d0000` empty, while the region it must occupy (`frts − sizeOfBootloader`) returns the WPR access-denied fill `0xbad0ac00` (E74); the non-WPR heap is readable but holds no live RM objects, and the WPR base is `0x7e75e0000` (E75). The debug FMC key is not in the published MD5-IV test-key family: the body is code-first and both debug containers were searched exhaustively under five AES hypotheses, all negative (E73). |

## Abstract

BF16 tensor math on the RTX 5090 runs at half the FP16 rate, because every BF16
tensor operation uses FP32 accumulation and the FP32-accumulate path is fused to
half rate. The same GB202 die in the RTX PRO 6000 runs that path at full rate, so
the limit is a product decision, not an architectural one.

Every software write path reachable from the host (PL0) or from GSP-RM (PL2) has
now been tested and is either privilege-gated or inert: the FEAT bank, the FUSE
shadow, `SM_ISSUE_RATE_MODIFIER`, the registry keys, the FECS context buffers, and
the HS memory windows. What remains is code execution at PL3/Heavy Secure. The two
live host-facing surfaces that PL3 code parses — the FMC/FSP boot inputs (COT and
`WprMeta`) and the suspend/resume metadata — both have working oracles and partial
host control, but neither yields code execution yet.

One further host-facing surface is now measured. The PRISCV in-circuit debugger at
`0x1113d0` is live and host-writable at PL0; with the core halted it reads the
14.4 MB GSP-RM code segment (E67). It is a debug port, not a PL3 bypass: a
read-only trace of the boot window shows the ICD command/PC registers blocked
through the whole HS phase, and `RDM` refused both at an HS-window halt and at the
LS transition. After boot `RDM` works, but its aperture is the RM code segment
only — the boot image (watched executing at `0xefd00000`, size `0x47000`, matching
the host-supplied `GspRmBoot`), the data segment and the WPR are all refused
(E68). The FMC's host-facing bootloader description is also checked (`0x82e` for
the size, `0x885` for the manifest offset) and both boot images are authenticated
(`0xaff`/info `0xb`), so a corrupted ciphertext never reaches HS (E69).

Four follow-up measurements close the remaining PL2 and host-memory hypotheses. The L2-writable
PLM window after an FLR is real — `0x80842bcf` for 1.32 s — but the first GSP-RM PC
appears at 3.18 s, so the re-lock precedes the only PL2 master by 1.85 s; the
"boot the GSP inside the window" variant is falsified by timing, not assumption
(E70). `GPU_EXEC_REG_OPS` rejects every `GR_CTX`/`GR_CTX_TPC`/`GR_CTX_SM`/
`GR_CTX_QUAD` op with `NV_ERR_INVALID_ARGUMENT` even as root, with a live CUDA
context and every `grRouteInfo` route, while `FB` returns `NV_ERR_NOT_SUPPORTED`;
the per-context/per-SM register space is not reachable from PL0 without an RM
channel owned by the caller (E71). The host-supplied `GspRmBoot` buffer is
byte-identical before the FMC reads it and after GSP-RM is up (SHA-256
`f5f63a71…`, entropy 7.9835, both cards), so the FMC decrypts into protected
memory, not in place in unprotected sysmem (E72). The FB memory route is now
measured shut: BAR1 does not exist during the GSP boot (it is initialised in
`gpuStateLoad`, after `kgspInitRm`), the BAR0 PRAMIN window does work and reads
the non-WPR heap correctly, and the decrypted boot image is inside the WPR —
every byte from `frts − 0x50000` through FRTS returns the access-denied
sentinel `0xbad0ac00` (entropy exactly 2.0) on both cards (E74). The earlier
`VA 0xefd00000 → PA 0x5dd00000` inference and the "GSP-RM ELF identity-mapped
at PA 0x01000000" model are both retracted. A follow-up dump of the 3 MiB non-WPR heap with the
same window found no live RM objects — a 64 KiB header, one 1.6 MB
high-entropy allocation and zeros — and pinned the WPR base at
`0x7e75e0000`, so the RM objects are in the protected heap and the host cannot
see them (E75).

Four earlier results close the last non-L3 hypotheses. The registry speed-select keys,
which an earlier pass called dead, are live code paths — parsed and stored by
GSP-RM — but measure inert on both cards (§6.2). The FEAT bank, including
`SS0`/`SS1`, is byte-identical before the FMC runs and after GSP-RM is up, so no
FMC/GSP-RM code writes it (§2.3, E54). The SS words still move across cold power
cycles (not warm reboots), and an FLR resets `FEAT_OVR_PLM` to an L2-writable value
that a GPU-side devinit re-locks autonomously before the first open (§2.3, §2.6,
E64–E65). A static scan of the vBIOS closes the last table-edit hypothesis: no
plaintext devinit table or script references the FEAT bank, and the DEVINIT
tables and scripts are HS-authenticated (§11.1, E66). The third closes the key-substitution
shortcut: a self-signed COT key is refused with its own code, `0x1db`, before the
hash check, and the GSP-RM signature section carries no host key (§9.2.4, §11.5,
E61). The fourth closes image tampering: secure firmware binds the loaded FMC
container to the host-supplied COT hash, so a one-byte change to its header or
body is refused with `0x33` (§9.8, E62).

## How to read this document

**One fact, one home.** Each finding is stated once, in the section that owns it.
Everywhere else is a pointer. The experiment log in Appendix D is the only
chronological part; the body is ordered by topic.

**Experiment IDs.** Individual passes are cited as `E01`–`E69`. Each has a full
record in Appendix D (date, hypothesis, method, commands, result, artifacts).
Appendix H lists the pass history.

**Status vocabulary.** Used literally, not as emphasis:

| Label | Meaning |
|---|---|
| OPEN | Not tested. |
| LIVE | Tested; the surface accepts host input or behaves as a lever, but is not yet an exploit. |
| CLOSED-MEASURED | Tested on hardware; the route does not work. |
| CLOSED-STATIC | Shown by source or binary analysis; no hardware test. |
| INCONCLUSIVE | Test invalid, or the control failed. |
| SUPERSEDED(Exx) | An earlier claim, replaced. The replacement is named. |

**Evidence type.** Where a statement is not measured on this machine, it says so:
*(source)* for open-source or vendor documentation, *(analogy)* for conclusions
carried over from Ada/Ampere, *(measured)* for a hardware result on the local cards.

## Notation

| Term | Meaning |
|---|---|
| PL0 / PL2 / PL3 | Privilege levels: Non-Secure host, Light Secure firmware, Heavy Secure firmware. |
| NS / LS / HS | The same three levels by name. GSP-RM runs LS/PL2. |
| PLM | Privilege-level mask. Low byte: read mask `[3:0]`, write mask `[7:4]`, level 0 = bit 4. |
| FEAT bank | The `0x823800`–`0x8238b0` register block: readouts and speed-selector overrides. |
| FUSE bank | The `0x820000`–`0x8207ff` OTP readout/shadow block. |
| `SS0` / `SS1` | `FEAT_OVR_SM_SS0` (`0x82381c`) and `FEAT_OVR_SM_SS1` (`0x823820`). |
| FMLA32 | The selector for the FP32-accumulate tensor path — the capped one. |
| WPR | Write-protected region: where GSP firmware, boot bin, heaps and FRTS live in FB. |
| FRTS | Firmware runtime state region inside the WPR. |
| COT | Chain-of-Trust message the host sends to the FSP (v2 on GB202). |
| `WprMeta` | 256-byte host-filled descriptor consumed by the FMC on a cold boot. |
| `SRMeta` | 256-byte host-filled descriptor consumed by HS on suspend/resume. |
| radix3 | 3-level page table, built by the host, that HS walks for suspend/resume state. |
| FSP | Security processor that runs first out of reset, from ROM. |
| GSP BootROM | GSP Falcon ROM that authenticates and starts the FMC. |
| FMC | First-stage mutable firmware on the GSP, runs HS; authentication is enforced. |
| GSP-RM | The main GPU firmware, runs LS/PL2; loaded from `gsp_ga10x.bin`. |
| FECS / GPCCS | GR front-end and context-switch firmware; the rate consumer. |
| `0xBADFxxxx` | Bad-read sentinel. Bits `[31:8]` are a PRI-ringstation error code; see Appendix C. |

---

# Part I — The model

## 1. The problem

### 1.1 What the cap is

- BF16 tensor operations use HMMA with BF16 inputs and an **FP32 accumulator**.
  There is no BF16-accumulate variant in PTX or in the tensor core.
- The capped selector is therefore the **FP32-accumulate tensor path**, tracked as
  `FMLA32` in the fuse and readout tables.
- FP16 with FP16 accumulation is a different, uncapped path. FP16 with FP32
  accumulation is capped exactly like BF16.
- INT8, FP8, FP4, scalar FP32, and copy/memory paths are not governed by this
  selector. An unlock would not help them.

The consequence is that BF16 workloads cannot escape the cap by changing
accumulator format, while FP16 workloads usually can.

### 1.2 Measured baseline

#### 1.2.1 Issue rate and GEMM

Register-resident issue-rate probe, RTX 5090, driver 610.57.04 (`ai.rs`); GEMM
figures from `gpu-bench` on an RTX 5090 D.

| Path | Measured | Reference | Source |
|---|---:|---:|---|
| FP16 → FP16 accumulate | **441.4 TF/s** | 419.5 TF/s | issue-rate probe |
| FP16 → FP32 accumulate | **224.3 TF/s** | 209.5 TF/s | issue-rate probe |
| **BF16 → FP32 accumulate** | **222.8 TF/s** | 209.5 TF/s | issue-rate probe |
| TF32 → FP32 accumulate | **112.4 TF/s** | 104.8 TF/s | issue-rate probe |
| INT8 → INT32 | **910.5 TOPS** | 838 TOPS | issue-rate probe |
| cuBLAS BF16 GEMM, 8192³ | **234.8 TF/s** | — | gpu-bench |
| FP16 cuBLAS GEMM, 8192³ | **236.3 TF/s** | — | gpu-bench |
| FP8 GEMM, FP32 accumulate | **548.5 TF/s** | — | gpu-bench |
| FP4 GEMM | **~1040 TF/s** | — | gpu-bench |

The decisive ratio is `441.4 / 224.3 ≈ 1.97`: the FP32-accumulate path runs at
~51% of the FP16-accumulate path. Measured values sit 5–9% above NVIDIA's
reference numbers because of boost clocks.

#### 1.2.2 Comparison with prior generations

| Card | FP16/BF16 → FP32 issue rate | Notes |
|---|---:|---|
| RTX 3090 Ti, BF16 GEMM 8192³ | 87.5 → 157.4 TF/s | unlocked; +80% |
| RTX 4090, stock | 165.6 / 165.5 TF/s | half rate |
| RTX 4090, unlocked | 331.6 / 330.6 TF/s | 2.00× |
| RTX 4070 Ti SUPER, stock → unlocked | 95.0 → 189.9 TF/s | 2.00× |
| **RTX 5090, stock** | **224.3 / 222.8 TF/s** | capped |
| **RTX PRO 6000, same GB202 die** | **503.8 / 503.8 TF/s** | **full rate** |

The Pro 6000 row is the document's control. The same die runs FP16-accumulate and
BF16/FP32-accumulate at the same 503.8 TF/s; the 5090 is fused to 419/209.5. The
half rate is **per-SM speed-selector segmentation**, not silicon. That is what
makes an unlock physically possible, and it also names the missing piece: a Pro
card's `FEAT_READOUT_1`/`SS0`/`SS1` or fuse dump would show the full-rate encoding.

A stock 5090 still beats a stock 4090 on this path, but an unlocked 4090 at
~331 TF/s beats a stock 5090 at ~223 TF/s.

#### 1.2.3 Same-boot, two-card baseline

The two local cards carry different `SS0`/`SS1` words but the same
`FEAT_READOUT_1`. Measuring both in one boot settles whether those words mean
anything for rate (E49).

| Mode | `41:00.0` (`SS0=0x21240001`, `SS1=0x2`) | `c1:00.0` (`SS0=0x54226037`, `SS1=0x00026005`) |
|---|---:|---:|
| FP16 → FP32 | 226.65 TF/s | 229.65 TF/s |
| BF16 → FP32 | 226.64 TF/s | 229.62 TF/s |
| TF32 → FP32 | 113.34 TF/s | 114.83 TF/s |
| U4 → S32 | 595.96 TOPS | 604.55 TOPS |
| SM clock after | 2910 MHz | 2955 MHz |
| Power after | 126.5 W | 100.5 W |

Normalised by SM clock, all four modes agree within 0.23%:

| Mode | `41:00.0` | `c1:00.0` | Δ |
|---|---:|---:|---:|
| FP16→FP32 | 0.07789 TF/s/MHz | 0.07771 TF/s/MHz | −0.22% |
| BF16→FP32 | 0.07788 | 0.07771 | −0.23% |
| TF32 | 0.03895 | 0.03886 | −0.23% |
| U4 | 0.20480 | 0.20459 | −0.10% |

`BF16/FP16 = 1.000` and `TF32/FP16 = 0.500` on both cards. The per-clock local
baseline for the FP32-accumulate path is **0.0777 TF/s/MHz**, measured on this
machine. The differing `SS0`/`SS1` nibbles do not encode a different effective
selector; the fused, identical `FEAT_READOUT_1` governs.

### 1.3 Which workloads are affected

The cap matters only for compute-bound workloads using FP16/BF16 with FP32
accumulation:

- LLM prefill, long-context and RAG, batched or offline inference.
- Diffusion and other FP16/BF16 compute-bound kernels.
- Fine-tuning and LoRA where FP32 accumulation is used.
- BF16 training and mixed-precision training.

It does not help:

- Token decode and other bandwidth-bound inference.
- 4-bit, FP8, INT8, or FP16-accumulate paths, which are already uncapped.
- Graphics workloads.

Published cuBLAS evidence on Ada shows the instruction-rate gain does not translate
uniformly: 4090 GEMM gains were shape-dependent, with some BF16 shapes gaining
16–20% and one 4096³ shape essentially unchanged. Any 5090 unlock would need matched
GEMM evidence, not only issue-rate numbers.

### 1.4 What this project is not doing

- Not a clock or power-limit change.
- Not a vBIOS flash or a driver patch of the kind used on prior generations.
- Not a change to the model's numerical format.
- Not a persistent fuse rewrite. The prior unlocks are volatile and are reapplied
  at boot.

---

## 2. The mechanism

### 2.1 The rate-control path

Two sources feed one selector, one gate protects the override, and one class of
firmware consumes the result:

```
  FUSE_SS_* (OTP, fused)                    FEAT_READOUT_1 (readout of fuse state)
          \                                        ^
           \                                       | read by GSP-RM via HAL offset 0x3818
            \-> FEAT_OVR_SM_SS0/SS1 (override) -> SM issue-rate selector
                          ^                        |
                          |                        v
                 FEAT_OVR_PLM (write gate, PL3)   FECS / GPCCS ucode -> issue rate
                          ^
      masters: PL0 host BAR0 | PL2 GSP-RM | PL3 FSP/BootROM/FMC/SEC2
```

The important asymmetry: the FEAT bank is readable from every level, but its write
mask admits only PL3. The GSP reads the fused value and reports it; it never writes
the override.

The bank is already fully final before the FMC executes (E54). The writer is
therefore pre-driver — a GPU-side devinit action; the PMU (PL2) is the leading
candidate, with the FSP/BootROM or hardware not excluded (E64/E65) — and no mutable
firmware in the driver/FMC/GSP-RM chain participates. The reset window and the
autonomous re-lock are in §2.6.

### 2.2 The fuses

The selectors are driven by one-time-programmable `FUSE_SS_*` values. The block is
read-only to the host; the override registers are the only writable shadow.

| Register | Offset | GB202/GB203M value |
|---|---|---:|
| `FUSE_SS_DP` | `0x00820224` | 0 |
| `FUSE_SS_FFMA` | `0x0082059c` | 0 |
| `FUSE_SS_FMLA16` | `0x008207d4` | 0 |
| **`FUSE_SS_FMLA32`** | **`0x008207d8`** | **3** |
| `FUSE_SS_IMLA0` | `0x008207dc` | 0 |
| `FUSE_SS_IMLA1` | `0x008207e0` | 3 |
| `FUSE_SS_IMLA2` | `0x008207e4` | 3 |
| `FUSE_SS_IMLA3` | `0x008207e8` | 0 |
| `FUSE_SS_IMLA4` | `0x008207ec` | 3 |

On Ada the consumer `FMLA32` value was `1` (half rate). On GB202/GB203M it reads
`3`, which the public `ctrl2080gr.h` enum calls 1/8 rate. **The measured penalty is
~2×, not 8×**, and INT8 measures full rate while `IMLA1/2/4` also read 3. The
Blackwell encoding is therefore not the Ada encoding, and the public enum cannot be
read literally. See §2.4 and §16.3.

### 2.3 The FEAT bank

The `0x823800`–`0x8238b0` block is the **feature readout/override bank**, not just
SM rate. It is sparse: unimplemented offsets return `0xBADF5040`.

| Register | Offset | Stock value | Role |
|---|---|---:|---|
| `FEAT_OVR_ECC_PLM` | `0x823800` | `0xfffffb8f` | ECC PLM; reads identically to `0x823804` (alias or second copy, unresolved) |
| `FEAT_OVR_PLM` | `0x823804` | `0xfffffb8f` | the write gate for the bank |
| `FEAT_READOUT_0` | `0x823814` | `0x00000233` | bit 16 = ECC enablement (identified) |
| `FEAT_READOUT_1` | `0x823818` | `0x00c36180` | selector readout (decoded below) |
| `FEAT_OVR_SM_SS0` | `0x82381c` | `0x21240001` (`41:00.0`) | eight 4-bit override fields |
| `FEAT_OVR_SM_SS1` | `0x823820` | `0x00000002` (`41:00.0`) | ninth field in `[3:0]` |

Full block map is in Appendix A. The block is the same cross-generation FEAT
override/readout block as Ampere (E56); only `SS0`/`SS1` are speed words.

**The gate.** `FEAT_OVR_PLM = 0xfffffb8f`. Its low byte is the Falcon v4 privilege
mask used by the other IP blocks (`dev_falcon_v4.h` in the open tree): read mask
`[3:0] = 0xf` (all levels) and write mask `[7:4] = 0x8` (**L3 only**). The remaining
fields decode as `READ_VIOLATION [8] = 1`, `WRITE_VIOLATION [9] = 1`,
`SOURCE_READ_CONTROL [10] = 0` (lowered), `SOURCE_WRITE_CONTROL [11] = 1` (blocked),
and `SOURCE_ENABLE [31:12] = 0xfffff` — **all 20 sources enabled**. Ada's
`0xffffff8f` differs only in bit 10, i.e. `SOURCE_READ_CONTROL`, not a source enable.

This resolves the earlier "cleared bit 10 names a removed source" reading: there is
no removed source. The write mask is the entire wall (E53).

*Caveat:* the FEAT block is not described in the public headers. The low-byte fields
match the Falcon layout exactly, but applying the violation and `SOURCE_*` field
names above the low byte is *(source)* by analogy, not a FEAT-specific definition.

**Table route.** No plaintext devinit table or script in the vBIOS references this
block, in either endianness or in the devinit address-flag forms (E66). The PLM
values themselves sit in a plaintext data section of the app `0x23`/target `0x0E`
ucode image, whose code is encrypted and whose data is covered by the DEVINIT/UCODE
authentication; the custom-VBIOS table edit cannot reach it (§4.6, §11.1, E66).

**What the readout says.** `FEAT_READOUT_1` is not the Ada nibble layout. It packs
eight 3-bit selectors, plus DP from a separate field:

| Field | Bits | Stock `0x00c36180` |
|---|---:|---:|
| imla0 | 2:0 | 0 |
| fmla16 | 5:3 | 0 |
| fmla32 | 9:7 | **3** |
| ffma | 12:10 | 0 |
| imla1 | 15:13 | **3** |
| imla2 | 18:16 | **3** |
| imla3 | 21:19 | 0 |
| imla4 | 24:22 | **3** |
| DP | 30:28 | 0 |

Bit 6 is an unexplained gap between `fmla16` and `fmla32`; bits 25–27 and 31 are
not used by the decode. The decode was recovered from a GSP-RM function that reads
HAL offset `0x3818` from the `0x820000` fuse base, i.e. this register, and fills
the RM getter's nine bytes in order (E13, E17; §11.2).

**`SS0`/`SS1` are inert at stock.** Every nibble of both words has bit 3 (the
override enable) clear, so all override fields — eight in `SS0`, the ninth in
`SS1` — are disabled and the fused selectors are in force. The non-zero values are
pre-driver writes that mirror fuse state without overriding it: they are already
present at the pre-FMC sample and identical after GSP-RM is up within a boot (E54),
but vary across cold boots (E64). They also
differ between the two local cards (`0x21240001`/`0x00000002` vs
`0x54226037`/`0x00026005`) and the two cards measure identically per clock
(§1.2.3), so they are per-chip binning/state, not selectors.
For reference, Ada stock was `SS0 = 0x44023025`, `SS1 = 0x00000007`, and the earlier
GB203M read was `0x02000000`/`0x12000000` with `SS1 = 0x00002004`; the words are
board- and state-dependent, so any unlock value must be validated against a readout
rather than assumed from a stock word.

**Per-boot state and the reset window (E64, E65).** `SS0`/`SS1` are not constant
across boots. Read-only sampling on both cards gave `41:00.0` SS0 values
`0x21240001`, `0x20240001`, `0x20260041`, `0x21265047`, `0x21265043` across five
cold boots, while `c1:00.0` alternated `0x54226037`/`0x54224037` and its SS1
alternated `0x00026005`/`0x00024005`. The words were invariant for the whole of each
boot (pre-FMC, post-driver, 60 s, and shutdown after 7.5 h) and across two warm
reboots; they changed only across cold power cycles. `0x823808` moved once
(`41:00.0` `0x01000280` → `0x00000080`). `FEAT_READOUT_1` stayed `0x00c36180` and
every nibble stayed below 8 in every sample, so the moving bits are inactive shadow
state, not a selector.

An FLR is different: it leaves `SS0`/`SS1`/`0x823808` and `READOUT_1` untouched,
but resets `FEAT_OVR_PLM` (`0x823800`/`0x823804`) from `0xfffffb8f` to
`0x80842bcf` (read all, **write L2+L3**). The PLM is re-locked to `0xfffffb8f`
autonomously by a GPU-side devinit before the first open; the host is PL0, cannot
write either value, and no GSP-RM code runs in that window (§2.6, E65). The SS
writer is therefore the same GPU-side devinit class, not the FMC, the driver, or
GSP-RM. Full values, timeline, and bracket points are in E64/E65.

**`0x82380c` is the ECC override, not a speed word (E56).** It reads `0x00888888`
— six nibble fields with enable-bit-3 and selector 0 — which looks like an active
override at full rate and is the same payload the Ada unlock wrote. An external
cross-part survey resolves it: `0x82380c` is `FEAT_OVR_ECC`, and `0x00888888` is its
stock value on every consumer GA10x part. The adjacent words are `FEAT_OVR_ECC_1`
(`0x823810`), `FEAT_OVR_ROW_REMAP` (`0x823824`), `FEAT_READOUT_2` (`0x823828`) and
`FEAT_OVR_ECC_2` (`0x82382c`). The Ada-payload resemblance is a nibble-pattern
artifact. The write was dropped like every other write in the bank (E09; §5.3).

### 2.4 Selector encoding

**Ada/Ampere model (established by the prior unlocks):**

- `SS0` contains eight 4-bit fields; `SS1` holds the ninth in `[3:0]`.
- Each field: bit 3 = override enable, bits 2:0 = speed selector.
- `0` = full rate, `1` = 1/2, `2` = 1/4, `3` = 1/8.
- Unlock payload: `SS0 = 0x88888888`, `SS1 = 0x8`.

**Blackwell:**

- The override format still appears to be enable-bit-3 + 3-bit value.
- The readout format is the eight 3-bit fields above, plus DP.
- The readout value `3` does **not** map linearly to the public enum's 1/8: the
  measured `FMLA32` penalty is ~2× and INT8 is full rate despite `IMLA1/2/4 = 3`.

**Cross-generation check (E56).** The readout is a fuse mirror on every generation
with a public dump. A100 — a full-rate part — reads `FEAT_READOUT_1 = 0` with every
arithmetic `FUSE_SS_*` at 0. Consumer Ampere reads `0x00400080` with `FMLA32 =
IMLA4 = 1`; Ada reads `0x00410080`, which adds `IMLA2 = 1`; GB202/GB203M read
`0x00c36180` with `FMLA32 = IMLA1 = IMLA2 = IMLA4 = 3`. "Zero = full rate" is
therefore not Ada-specific: it is also the data-centre Ampere encoding. What has
not been observed is a *full-rate Blackwell* part, so the Blackwell code→rate law
and the override payload format remain inferred.

The working target for an unlock is therefore **every field of `FEAT_READOUT_1`
decoding to 0, including DP `[30:28] = 0`** — not the Ada `0x88888888`/`0x8`
payload. That target is an inference from Ada and data-centre Ampere, not a
Blackwell measurement; see §14.3.

### 2.5 The RM getter

`NV2080_CTRL_CMD_GR_GET_SM_ISSUE_RATE_MODIFIER` (`0x20801230`) works on GB202 with
the Ada field layout:

```
imla0=0, fmla16=0, dp=0, fmla32=3, ffma=0, imla1=3, imla2=3, imla3=0, imla4=3
```

It is a copy-out of `KGRAPHICS_STATIC_INFO`, populated once at GR init from the GSP
through internal ctrl `0x20800a34` (V1) and `0x20800b03` (V2). The GSP method table
contains the V1 entry at RAM `0x01d182e8` with param size `0x48` (eight engines ×
nine bytes), so the GSP is the responder. The getter does not touch hardware, which
is why it still answered after the GSP crash in E07 (§5.2). V2
(`0x2080123c`) returns ten entries: FMLA16=0, FMLA32=3, FFMA=0, IMLA0=0, IMLA1=3,
IMLA2=3, IMLA3=0, IMLA4=3, FP16=0, FP32=0. The throttle getter (`0x2080123d`)
returns one `MASK=0` entry with no credits. All three are GET-only.

The V1 values match the `FEAT_READOUT_1` decode exactly, and the decoder that
produces them is installed as a per-chip HAL method (E17, §11.2). E58 closes the
variant question: GB202's implementation constant is `0x02`, outside the `{5..9}`
twin set, so the installed decoder is the `0x3818` one. That is strong evidence,
not proof, that the getter reflects this register. Whether the readout
reflects the **effective** rate or only the fused value is still not proven;
E12 showed that writing `SM_ISSUE_RATE_MODIFIER` changes neither the getter nor
the measured rate.

### 2.6 The privilege boundary

NVIDIA's nova-core documentation defines the levels; the cmp170hx work names the
PLM semantics *(source)*:

| Level | Name | Firmware that runs there |
|---|---|---|
| PL3 | Heavy Secure (HS) | FSP; GSP BootROM; FMC; SEC2 HS ucode; FWSEC-FRTS |
| PL2 | Light Secure (LS) | **GSP-RM**; PMU devinit |
| PL0 | Non-Secure (NS) | Host CPU and ordinary driver access |

`FEAT_OVR_PLM` writes `[7:4] = 1000`, i.e. bit 7 only, i.e. PL3. Therefore:

- Host BAR0 writes (PL0) are silently dropped.
- GSP-RM writes (PL2) are also dropped.
- The Ada unlock worked because the write came from a Falcon executing an
  already-verified HS image. The grant is tied to the HS execution context, not to
  the payload's numeric level.
- A GSP-RM code-execution bug is therefore **not sufficient**. The target must be
  code that runs at PL3.

E08 measured this from the outside: a GSP-executed write to `SS0` returned
`SUCCESS` and changed nothing, while the same control wrote a PBUS scratch register
successfully (§5.2).

**The PLM is reset and re-locked by the GPU.** `0xfffffb8f` is not the reset value.
A PCI FLR resets the bank's PLM to `0x80842bcf` (read mask `0xf`, write mask `0xc` =
**L2+L3**), and the device then re-locks it to `0xfffffb8f` without host
involvement: the PLM is still `0x80842bcf` through the driver's PCI probe (including
`pci_set_master`) and is already `0xfffffb8f` three seconds later, before the device
is opened or any RM/GSP code runs (E65). The host is PL0 and is admitted by neither
value, so the writer is GPU-side firmware/hardware. The PMU devinit (PL2) is the
leading candidate, because the reset mask admits L2 writes and the lock is applied
afterwards. The GSP-RM (PL2) never runs while the bank is open, and a runtime
PLM-opening write is undone at the next device reset/enable.

**The window is measured, and it ends before any PL2 master exists (E70).** A
direct BAR0 poller across the FLR, unbind and bind reads `0x80842bcf` from the
reset and sees the re-lock at 1156–1323 ms; the first GSP-RM PC (`0x9xxx…`)
appears at 3176 ms; the boot image's first PC is ~0.5–0.6 ms before it (E68).
The re-lock is therefore ~1.85 s before the boot image and is a pre-boot
GPU-side devinit (FSP/PMU/hardware), and the GSP-RM — the
only PL2 master — arrives 1.85 s after the window has closed. An early open
does not help: the open→GSP-RM path measured ~2.1 s, which cannot fit a 1.32 s
window even with a zero-delay open. The "host boots the GSP early" variant is
closed; the window is a firmware-internal phase.

**The self-access rule.** The PLM gates *external* masters, not the engine's own
registers. The same PL2 path that cannot write the FEAT block freely writes the
GSP's own Falcon block: `EMEMC`/`EMEMD` accept a write, hold it, and return it on
read (E10; §8.1). The distinguishing property is not the caller's level but whether
the target belongs to the executing engine. This explains every write result in
this document: the FEAT bank refuses a PL2 write, the GSP's own block accepts one,
and neither says anything about the other.

**The boundary is also why the FSP must go first.** The host-driven FMC bootstrap
waits for the level-0 read/write enables in
`NV_PGSP_FALCON_RESET_PRIV_LEVEL_MASK` (`0x1103c4`) before it can reset the GSP —
and only running GSP firmware ever sets them. The host cannot reset the GSP it needs
to reset in order to boot it (E11; §6.3).

### 2.7 The host driver's role

The host driver is telemetry, not a lever (E16; §11.3). At GR init it fetches the
nine selectors and caches them; the only public controls are the three GETs above.
The 595.91.07 source contains no literal reference to any FEAT override,
`FUSE_SS_*`, or `SM_ISSUE_RATE_MODIFIER` register. Its only FEAT-bank access is the
`0x823814` ECC readout. The new `kernel_gsp_gb202.c` is a 63-line, two-function
vGPU-only HAL and does not override the GB100/GH100 reset or COT path. There is
nothing to patch out at PL0.

---

## 3. Prior generations: how the 3090/4090 unlock worked

### 3.1 Boot flow

1. The board ROM runs signed FWSEC-FRTS on the GSP, provisioning WPR2.
2. The driver starts a signed **SEC2 `BooterLoadUcode`** image.
3. The booter copies signature data into DMEM. The copy length is attacker-
   controlled and overflows the stack, including the saved return address and
   canary.
4. A ROP chain built from authenticated booter instructions performs a protected
   32-bit write.
5. The payload writes `FEAT_OVR_PLM` (and WPR/WPR_CFG/FBPA on Ada), changing it
   from L3-only to `0xffffffff`.
6. The unlock's separate kernel module — not `nvidia.ko` — writes
   `SS0 = 0x88888888`, `SS1 = 0x8`.
7. A PCIe FLR resets the card; the stock driver binds and the override persists.

### 3.2 Why it worked

- NVIDIA once shipped **debug** booter images encrypted with a known test-key
  scheme (key index 37), giving researchers plaintext to disassemble and mine for
  gadgets.
- The production booter is authenticated and decrypted inside the GPU. The crafted
  signature data redirects execution through existing authenticated instructions;
  attacker code is never loaded as a new image.
- The payloads use a fixed set of gadget signatures, a canary slot, a return slot,
  and a small number of PLM target registers.

### 3.3 Results

| Card | Path | Stock | Unlocked |
|---|---|---|---:|
| RTX 3090 Ti | BF16→FP32 GEMM 8192³ | 87.5 TF/s | 157.4 TF/s |
| RTX 4090 | FP16/BF16→FP32 issue rate | 165.6 / 165.5 | 331.6 / 330.6 |
| RTX 4070 Ti SUPER | FP16/BF16→FP32 issue rate | 95.0 | 189.9 / 189.7 |
| RTX 4070 Ti SUPER | FP8 GEMM | 59.33 | 59.50 (no meaningful gain) |

The unlock is volatile, survives FLR and stock driver initialization on Ada, and is
reapplied at boot and resume by the kernel module.

### 3.4 Which preconditions Blackwell removes

| Precondition | Ada | Blackwell |
|---|---|---|
| Signed HS image with a host-controlled copy | SEC2 `BooterLoadUcode` | **gone** — no GB20x SEC2 booter ships |
| Known test-key family for debug images | key 37 (GA100) | **absent** — no fingerprint anywhere (E06) |
| Writable `FEAT_OVR_PLM` from an HS payload | yes | still the only route; no plaintext HS corpus |
| Separate host module writing `SS0`/`SS1` | worked | dropped at PL2 (§5.2) |

---

## 4. What changed on Blackwell

### 4.1 Boot chain and COT

Blackwell has **no `booter_load`/`booter_unload`** image for any GB20x chip. The
normal dGPU path is *(source; corrected by NVIDIA's August 2026 nova-core patch)*:

```
FSP (immutable ROM, hardware root of trust)
  → GSP BootROM (ROM)
    → GSP-FMC (host-supplied, signed, encrypted; runs HS)
      → GSP-RM (host-supplied, signed, plaintext; runs LS)
```

The host driver sends a **Chain-of-Trust (COT)** message over MCTP/NVDM on the
Falcon MSGQ:

- GB202 uses COT **version 2**; size `0x35c`.
- The payload carries the GSP-FMC image address in sysmem, FRTS region
  descriptions, a SHA-384 hash, a public key, a signature, and a GSP boot-args
  pointer.
- GB202 uses a **97-byte P-384 public key and 96-byte signature**.
- GB20B/GB100 use 384-byte RSA-3K fields.
- `RmDisableFsp` is honoured only in emulation; the FSP cannot be skipped on
  retail silicon.

On this SKU the ordinary boot path uses the **production-signed FMC**, not a
confidential-compute-only path: the COT hash matches the shipped
`GspRmFmcGfwProdSigned_GB202` container `c04`, and the COT key is the production
P-384 key (E28; §9.1).

### 4.2 The PL3 component inventory

Four components run at PL3 during a normal boot. For each, the questions are: is
the code obtainable, what host-controlled data does it consume, and what is the
specific target.

| Component | Code available? | Host-controlled input | Main blocker | Value |
|---|---|---|---|---|
| FSP | No — immutable ROM | MCTP/NVDM stream, COT, boot args | no corpus, root of trust | highest leverage, very hard |
| GSP BootROM | No — immutable ROM | image descriptor, addresses | no corpus | high if a pre-verify copy exists |
| FMC | Encrypted, both prod and debug variants, plaintext ELF wrapper | COT, boot args, `WprMeta`, GSP-RM image | encryption | **best target** |
| SEC2 HS ucode | Only TU102 (303 B) and AD10X (6,233 B) archives | debug image selection, MCTP header | image absent for GB20x; fuse state | medium |

The split is the finding:

1. **The ROMs cannot be falsified offline.** No image, no debug path, no way to
   test a hypothesis without a modified driver on real silicon.
2. **The signed images are the analyzable class.** The FMC ships in both variants
   with byte-identical plaintext wrappers, and its ELF section table is readable. A
   decrypted debug FMC would provide what the Ada researchers got from the debug
   booter: an HS image to mine for parsers and gadgets.

**One-line conclusion:** of the four boot-chain components, the FMC is the only one
with both a corpus worth attacking and a host-data path. It is the best *static*
target, not necessarily the best live surface (§15); the FSP is the highest-value
but closed; the BootROM is closed; SEC2's vulnerable image no longer ships.

**Availability.** `/lib/firmware/nvidia/gb202/gsp/` ships `bootloader`, `fmc`, and a
`gsp` symlink to the shared GSP-RM. Nothing else. The FSP and BootROM never appear
in any driver package or firmware bundle, and no running-system path exposes them
(E03): `nvidia-debugdump` emits an opaque encrypted blob, the UNC `nvdebug` module
reads MMIO registers rather than mask ROM, and the driver's FSP EMEM messages are
`NV_PRINTF` logging, not an extraction API. What **is** obtainable: the board
vBIOS (plaintext structure; encrypted µcode), the encrypted FMC, and the plaintext
GSP-RM. The only public primitive for reading anything out of HS code is the
cmp170hx SEC2 DMEM-exfiltration ROP, which requires an exploit; the ROMs are never
mapped into a readable window.

### 4.3 The FMC container

A **`0x48`-byte plaintext header** followed by an encrypted body (E05):

| Offset | Field | GB202 prod | linux-firmware |
|---|---|---:|---:|
| `0x00` | magic `03 04 48 00` | header size `0x48` | same |
| `0x04` | body size | `0x46200` | `0x30A00` |
| `0x0C` | code size | `0x37000` | `0x25800` |
| `0x14` | data size | `0xE800` | `0xA800` |
| `0x18` | flags / version | `0x104` | `0x104` |
| `0x20` | constant | `0x2801` | `0x2801` |

The size algebra is exact in all 14 samples: **body = code + data + `0xA00`**. The
order is **`[code][data][manifest 0xA00]`** (E73): the data region and the
`0xA00` residue are byte-identical to the data and manifest components of the
matching `GspRmBoot` image (manifest at 0, data at `0xA00`, code at `0xF200`), and
the FMC code is a prefix of that image's code. The manifest is encrypted with the
rest; there is no plaintext tail or header beyond the `0x48` bytes. Because the
same component encrypts identically at different absolute offsets in the two
images, there is no cross-component chaining: the mode is ECB or a per-component
reset (CBC/CTR with an IV/counter that restarts at each component). The first
plaintext block of the body is therefore code, not a container header.

**Signature envelope.** The `0xF8` bytes before a signed container are:
`publickey[97] || pad[7] || signature[96] || hash[48] || container`. The key is an
uncompressed P-384 point, the signature is `r || s`, and `hash` is SHA-384 over the
entire container including its header. Both signatures verify with OpenSSL. Two
keys ship in the retail driver:

| Key | First bytes | Signs |
|---|---|---|
| Production | `04 8b f1 18 bb …` | 4 containers, incl. the GB202 prod FMC and the linux-firmware FMC |
| Debug | `04 d3 0b d5 4b …` | 2 containers, incl. the GB202 debug FMC (99.6% different body) |

**Signing is not decryption.** Body entropy is 7.999 in every sample; there are no
repeated 16-byte ECB blocks; the prod/debug XOR is indistinguishable from random
(1,154 zero bytes in 287,232), so the variants share no keystream. The header
carries no nonce. The debug signing key is public; the debug **encryption** key is
not in any package.

**What the FMC consumes from the host.** After decryption it is handed
`GSP_FMC_BOOT_PARAMS` plus the COT. The host fills registry keys, the GSP-RM image
descriptor and address, the boot-args pointer, SPDM parameters (CC mode only), and
the COT's addresses, sizes, hash, key and signature. Every one is a 64-bit address
or 32-bit length consumed by code that runs before (FSP) or after (FMC) the
hash/signature check. That is the fuzzing surface, and it is the same shape as the
Ada `BooterLoadUcode` bug. The container bytes are not part of it: they are bound
to the COT hash, and a one-byte change is refused (§9.8, E62).

### 4.4 The register-reference audit

Three plaintext components exist: GSP-RM (72,830,976 B), `nvidia.ko`
(21,085,053 B), and the board vBIOS (819,200 B). Three independent scans — raw
32/64-bit constant search, decompiled-code constant extraction, and an x86
absolute-store scan for the option ROM — find **zero literal references** to any
FEAT/FUSE rate register in any of them (E01, E04; §11.1–11.2).

| Register | Offset | GSP-RM | `nvidia.ko` | vBIOS |
|---|---|---:|---:|---:|
| `FEAT_OVR_PLM` | `0x00823804` | 0 | 0 | 0 |
| `FEAT_READOUT_1` | `0x00823818` | 0 | 0 | 0 |
| `FEAT_OVR_SM_SS0` | `0x0082381c` | 0 | 0 | 0 |
| `FEAT_OVR_SM_SS1` | `0x00823820` | 0 | 0 | 0 |
| `FUSE_SS_FMLA32` | `0x008207d8` | 0 | 0 | 0 |
| `FUSE_SS_PLM` | `0x008200fc` | 0 | 0 | 0 |
| `SM_ISSUE_RATE_MODIFIER` | `0x00504204` | 0 | 0 | 0 |

The absence is meaningful because the same aperture **is** used: the decompiled GSP
references 151 distinct constants in `0x00800000`–`0x008fffff`, including
`0x820c04`, `0x820c1c` and the SEC2 `0x840408`/`0x840804` pair. None falls in the
FEAT sub-block.

**The literal scan has one blind spot, and the image contains a code path through
it.** A GSP-RM function reads `FEAT_READOUT_1` as a computed `base + 0x3818` where
the base is the fuse HAL's `0x820000` — so the instruction contains `0x3818`, not
`0x823818`. The decoder is `FUN_ram_015ffae8`; it is not dead code — it is installed
as a per-chip HAL method, with a register-based twin for other chip variants (E17;
§11.2). What remains unproven is which implementation GB202 runs and who calls the
slot. The image contains no computed-offset write to `FEAT_OVR_PLM`, `SS0`, or
`SS1`.

The host driver's only FEAT-bank access is the ECC readout: `NV_FUSE_ZB_FEATURE_READOUT`
= `0x3814` from the fuse base, i.e. `0x823814` bit 16, read by
`kmemsysCheckReadoutEccEnablement_GA100`/`_GB100`. It reads 0 here, as expected on
a GeForce SKU.

**Conclusion.** No plaintext component programs the rate block. The stock
`SS0`/`SS1` values are produced *before the FMC runs* (E54) by a GPU-side devinit
action, not by the FMC, the driver, or GSP-RM (E64/E65). The reset PLM is
L2-writable, and a PL2-capable GPU-side writer — most likely the PMU devinit —
programs the bank before the lock is applied; the FSP/BootROM or hardware cannot be
excluded from the host side. The read path is present. E58 find one `SS0`/`SS1`
write method (`FUN_ram_0160f1bc`, installed at `obj+0x938`), which attempts a
direct BAR0 MMIO store, but it has no visible 4-argument caller and any PL2 write
after the lock is dropped by `FEAT_OVR_PLM` (E08). It is not a usable lever.

### 4.5 Residual SEC2 surface

SEC2 hardware and host-side logic remain:

- `ksec2DumpDebugState_GB20B`, `ksec2PrepareAndSendBootCommands_GB20B`,
  `ksec2ValidateMctpPayloadHeader_GB20B`, `ksec2ReadUcodeFuseVersion_GB100`.
- Driver strings: "Loading Debug GSP FMC image for GSP RM using SEC2", "Chain-of-
  trust (GSP-FMC) cannot be disabled on silicon", "RM cannot boot with FSP missing
  on silicon".
- Signature-slot selection is fuse-version based (`sigIndex = numSigs - 1 - fuseVer`,
  bounds-checked).

The image that carried the old stack overflow does not ship for this chip. The
debug FMC path is only reachable with debug fuse state and a debug-signed image,
and no public method to enter that state on a retail 5090 exists (E03, E07 context;
§15.1).

### 4.6 The custom-VBIOS route and its privilege ceiling

Since October 2026 a public toolset (Panchovix) loads edited vBIOS images without
flashing — on Windows through a driver registry key, on Linux through patched open
kernel modules. The images keep NVIDIA's original signature, which no longer
matches, so `nvflash` refuses them; the tools use a host-side override path instead
of breaking a signature.

Three points matter here:

1. **It is a table edit, not a privilege escalation.** The demonstrated effects are
   power limits, voltage ceilings, OCP, fan channels and offsets — data the GSP
   reads, not code that runs at elevated privilege.
2. **The GSP-RM level is fixed by hardware at Falcon start.** A custom GSP-RM runs
   LS/PL2 whether stock or custom. The override changes *what* runs, not *at what
   level*.
3. **Consequence.** A custom GSP-RM's writes to `FEAT_OVR_PLM`, `SS0`, `SS1` are
   dropped exactly like PL0 host writes. It cannot reach the unlock.
4. **The pre-driver writer is outside the edit's reach (E66).** The re-lock happens
   before the first open in a GPU-side master, and the DEVINIT tables/scripts are
   authenticated in HS mode with AES-ECB (GSP-RM `NV_UDE_ERR_DEVINIT_*AUTHENTICATE*`
   strings). A no-flash table edit changes what the host driver parses, not what
   the HS firmware authenticates. The static scan finds no FEAT address in any
   plaintext table at all (§11.1, E66).

If a custom image boots at all, something in the authentication path was bypassed
(driver-side loading, debug fuse state, or an in-memory patch), which is
interesting in its own right but does not cross the LS/HS line. As an instrument, a
minimal custom GSP-RM that attempts the `SS0` write and logs the readback would be a
cleaner LS-side test of the boundary than the host ioctl — same expected refusal,
with no ambiguous IPC route.

---

# Part II — What has been tried, clustered by lever

Each lever ends with a verdict and a status. Full commands, run directories and
artifacts are in the matching Appendix D records.

## 5. Lever: software register writes from PL0 and PL2

### 5.1 The instrument

`NV2080_CTRL_CMD_GPU_EXEC_REG_OPS` (`0x20800122`) is a normal, exported RM control
that takes an array of `NV2080_CTRL_GPU_REG_OP` records:

```c
typedef struct NV2080_CTRL_GPU_REG_OP {
    NvU8  regOp;          // READ_32 / WRITE_32 / READ_64 / ...
    NvU8  regType;        // GLOBAL, GR_CTX, FB, ...
    NvU8  regStatus;
    NvU8  regQuad;
    NvU32 regGroupMask;
    NvU32 regSubGroupMask;
    NvU32 regOffset;      // BAR0 byte offset
    NvU32 regValueHi;
    NvU32 regValueLo;
    NvU32 regAndNMaskHi;
    NvU32 regAndNMaskLo;
} NV2080_CTRL_GPU_REG_OP;
```

Write semantics are read-modify-write:
`new = (read32(bar0 + offset) & ~regAndNMaskLo) | regValueLo`. To force an exact
value, set `regValue = V` and `regAndNMask = ~V`.

Why it is the right instrument:

- The method is registered in the GSP-RM ctrl table and the host RPCs to the GSP
  (`NV_RM_RPC_GPU_EXEC_REG_OPS`, `subdevice_ctrl_gpu_regops.c:189–212`). The write
  is issued by GSP firmware, a different bus master from the host CPU.
- Its method flags are `NON_PRIVILEGED | GPU_LOCK_DEVICE_ONLY | API_LOCK_READONLY`,
  so any RM client may call it.
- The only offset gate is
  `!bSkipPermissionValidation && !osIsAdministrator() && !gpuGetUserRegisterAccessPermissions()`
  (`gpu_access.c:1620`). A root caller bypasses the compressed allowlist. Root plus
  one ioctl therefore gives an arbitrary BAR0 offset executed at GSP privilege.

This is the cleanest test of the PL2/PL3 boundary available from userspace: the
write is real, issued by firmware, and its success or failure is readable back.

### 5.2 `SS0` writes: invalid first run, then closed by measurement

**First attempt (E07) — invalidated.** A userspace client (`regops/regops.c`)
issued the control through `NV01_ROOT_CLIENT → NV01_DEVICE_0 → NV20_SUBDEVICE_0 →
NV_ESC_RM_CONTROL`. Two allocation details matter for anyone repeating it: `hRoot`
must carry the client handle for every child allocation, and the device allocation
requires `NV_ESC_REGISTER_FD` on `/dev/nvidiaN` first.

The control returned `0x62` (`NV_ERR_RESET_REQUIRED`) on every invocation, while a
parameterless getter on the same client returned `NV_OK`. The reason was in the
logs: **both GSPs had crashed 36 minutes earlier**.

| Time | GPU | Event |
|---|---|---|
| 16:13:40 | `41:00.0` | Xid 13 (FECS UCODE error) → Xid 120 → Xid 154 reset required |
| 16:13:47 | `c1:00.0` | identical sequence, 7 s later |

Xid 120 is a GSP task exception: `load access page fault (cause 0xd) @
pc 0x1368618, partition 4#0`, `stval 0x250` — a NULL base plus `0x250`.
`_kgspRpcSanityCheck` returns `NV_ERR_RESET_REQUIRED` for every RPC once the GSP is
fatal. The rate getter still answered because it is served from the boot-time cache
(§2.5).

The crash window coincides with a read-only page scan of BAR0 `0x300000`–`0x400000`,
which is now a documented hazard (§12.1). Causation is not established: the scan
touched only `41:00.0`, and `c1:00.0` faulted 7 s later at the identical PC, so a
firmware bug firing on its own is equally consistent. The register-op question was
left **OPEN** by this run.

**Second attempt (E08) — closed.** After a clean reboot, `deviceId 1` (`41:00.0`),
same tool:

| Step | Command | Result |
|---|---|---|
| benign op | `regops 1 0000:41:00.0 one` | `SUCCESS`, `PMC_BOOT_0 = 0x1b2000a1`, matches BAR0 |
| read block | `regops 1 0000:41:00.0 read` | all 8 ops `SUCCESS`; GSP and host values identical |
| **FEAT write** | `regops 1 0000:41:00.0 wr 82381c 0` | write `SUCCESS`, readback **`0x21240001` (unchanged)**, host BAR0 unchanged |
| **positive control** | `regops 1 0000:41:00.0 sc` | `SCRATCH[15]` (`0x143c`): `0x5A5AA5A5` → `0x5A5AA5A5`; restore `0` → `0` |

The FEAT write was behaviourally inert at the register level (`SS0 = 0` leaves every
enable bit clear) but exercised the gate. The control writes a PBUS scratch register
that the host itself writes at PL0 and restores it inside the same RPC batch.

**Conclusion.** The RM accepts the op, the GSP issues it, and the FEAT register does
not change, while the same path writes a different register. The PLM is enforced
against PL2 after the post-reset lock (E65), and the drop is **silent**:
`regStatus = SUCCESS` with no error.
Nothing in userspace can distinguish "written and dropped" from "written and
applied" except by reading back. This is the experimental confirmation of §2.6 and
the closure of the last software lever.

### 5.3 The rest of the FEAT bank

E09 mapped the `0x823800` block through the same control and found the bank wider
than the four known registers (Appendix A). The one candidate for a different write
gate was `0x82380c = 0x00888888`, because it reads as an active override rather than
a fuse shadow (§2.3). E56 later identifies it as `FEAT_OVR_ECC`, the stock consumer
ECC override; the write test is retained as a whole-bank gate check.

```bash
./regops 1 0000:41:00.0 wr 82380c 88888888
#   WRITE 0x82380c = 0x88888888  status=SUCCESS
#   READBACK                   = 0x00888888   (unchanged)
```

`0x88888888` is the same nibble pattern as the Ada payload, but E56 shows it is the
stock `FEAT_OVR_ECC` value on consumer GA10x, not a speed word. The write was
accepted and dropped like `SS0`. The PLM gates the whole bank, not just the SM-rate
shadow; there is no ungated register in `0x823800`–`0x8238b0` to reach through.

### 5.4 The FUSE/OTP bank

The FUSE block looks more open than the FEAT block and is not (E12). The map
(`0x820000`–`0x8207ff`) is sparse and contains a run of privilege-mask-shaped words
at `0x8200d0`–`0x8200fc`. The page-0 mask `FUSE_SS_PLM = 0x8200fc` reads
**`0xfffffbff`** — read all, write all levels — and NVIDIA's GB100 header names it
for registers in page 0.

Two documented targets were tested, each as write → readback → restore, from the
host (PL0) and from the GSP (PL2):

| Target | Offset | Stock | Host PL0 | GSP PL2 |
|---|---|---:|---|---|
| `OPT_SECURE_GSP_DEBUG_DIS` (`RW-4R`) | `0x82074c` | `1` | `1 → 1` | `1 → 1` |
| `FUSE_SS_FMLA32` | `0x8207d8` | `3` | `3 → 3` | `3 → 3` |

All four writes were issued and left the register unchanged. **The page-0 mask is
not the effective write gate.** These fuse readouts are soft-read-only, locked by a
mechanism below the PLM (fuse controller, override window, or an early lock), and a
PLM value is not a writability oracle.

The pass also found a new sentinel, **`0xBADF510C`**, clustered at
`0x820158`–`0x8201ec`, `0x8204a8`–`0x8204b0`, and `0x820578` — distinct from
`0xBADF5040` (`unimplemented`), meaning unestablished. Separately, the page-4
region `0x824100`–`0x8241cc` reads a uniform `0x00000002` while `0x8240fc` is a
sentinel, so the page-relative `__PRIV_LEVEL_MASK 0xFC` convention is not confirmed
on GB202.

**Consequence.** The FUSE shadow is not a way around `FEAT_OVR_PLM`. A write would
have to come from code that runs before the lock — the FSP/HS path — not from the
host or GSP-RM.

### 5.5 `SM_ISSUE_RATE_MODIFIER`

`0x504204` reads 5 on both GB202 cards and on Ada. It is the one rate-related
register that turned out to be genuinely writable (E12):

| Master | Write `0` | Readback | Restore `5` | Readback |
|---|---|---|---|---|
| Host BAR0 (PL0) | store issued | **0** | store issued | 5 |
| GSP `GPU_EXEC_REG_OPS` (PL2) | `SUCCESS` | **0** | `SUCCESS` | 5 |

It is also **reasserted to 5 at CUDA context creation**: setting it before starting
a probe reads back 5 after the run; poking it from inside the process after
`cuCtxCreate` holds it at 0 through every subsequent launch. E58 finds no RM code
that writes `0x504204`; the reassertion is from firmware/devinit or a
ctxsw/golden-context restore, not `nvidia.ko` or GSP-RM.

The sm_120 probe (Appendix F) ran with the register held at 0 after context creation
and before every launch, logging its value at all 17 stages:

| Mode | Baseline (modifier = 5) | Held at 0 |
|---|---:|---:|
| FP16→FP32 | 227.1 TF/s | 227.1 |
| BF16→FP32 | 227.1 TF/s | 225.9 |
| TF32→FP32 | 113.6 TF/s | 113.0 |
| U4→S32 | 596.5 TOPS | 591.1 |

All 270,336 output cells validate in every mode; the small differences are
run-to-run clock variance (telemetry 2.88–2.93 GHz, 575 W cap). E58 finds no RM
writer of `0x504204`; the value 5 is applied by firmware/devinit or a
ctxsw/golden-context restore, and a post-init write does not change the configured
selectors. This is the Blackwell confirmation of the Ampere false lead.

### 5.6 The GR control surface has no hidden setter

The GSP method table can be decoded statically and compared with the public SDK
(E13). For the GR class the table contains **44 control IDs and `ctrl2080gr.h`
defines 44**; the sets are identical. `0x2080123e` is `GR_TEST_CTXSW_ERROR_LOGS`,
not a hidden setter. The two enumerating getters (`0x2080123c` V2 and `0x2080123d`
throttle) are GET-only and are described in §2.5. Together with the
`FEAT_READOUT_1` decode, this enumerates the whole rate-control space the GSP
exposes. It contains no writable path.

### 5.7 Verdict

| Path | Result | Status |
|---|---|---|
| `SS0` write, GSP (PL2) | accepted, silently dropped | CLOSED-MEASURED (E08) |
| Host BAR0 writes to the FEAT bank | dropped by the PLM (observed; no recorded `SS0`-from-PL0 write) | §2.6 |
| Rest of FEAT bank (`0x82380c`) | accepted, silently dropped | CLOSED-MEASURED (E09) |
| FUSE shadow `0x82074c`, `0x8207d8` | accepted, unchanged from PL0 and PL2 | CLOSED-MEASURED (E12) |
| `SM_ISSUE_RATE_MODIFIER` | writable, reasserted, rate unchanged | CLOSED-MEASURED (E12) |
| `GR_CTX`/`GR_CTX_TPC`/`GR_CTX_SM`/`GR_CTX_QUAD` regtypes | `0x1f` from PL0 with root, a live context and every route; needs a caller-owned RM channel | CLOSED-MEASURED (E71) |
| `FB` regtype | `0x56` `NV_ERR_NOT_SUPPORTED` | CLOSED-MEASURED (E71) |
| Hidden GR SET control | none in the table | CLOSED-STATIC (E13) |

Every cheap software write path to a rate-related register is measured inert. The
wall is PL3.

---

## 6. Lever: registry keys and driver knobs

### 6.1 The key inventory

The GSP-RM contains ~1,178 registry-namespace strings. The ones relevant here:

| Key | Location | Status |
|---|---|---|
| `RMOverrideSmSpeedSelect` | GSP-RM `0x01f3a958` | **parsed and stored** (E50); no rate effect (E51) |
| `RMOverrideSmSpeedSelect1` | GSP-RM `0x01f3a970` | same |
| `RMDisableFeatureDisablement` | GSP-RM `0x01eebb48` | parsed (config+`0x545a`); bypasses a **display-only** feature gate (E52) |
| `RmDisableFsp` | GSP-RM | emulation-only |
| `RmDisableFspFuseErrorCheck` | GSP-RM | live |
| `RmDisableCotCmd` | GSP-RM | live, bitfield |
| `RmDisableSec2` | GSP-RM | boot-chain only |
| `RmFspUseMnoc` | GSP-RM | FSP transport |
| `RMSec2UseDebugFuseOnlyBinary` | GSP-RM | debug fuse path |

Any key is forwarded: `rm_parse_option_string()` (`osapi.c:3352`) writes every
unrecognized `key=value` into the RM registry, which reaches GSP-RM. The host
driver's string table is not a filter (E50).

### 6.2 `RMOverrideSmSpeedSelect*`: live code paths, inert effect

The names map 1:1 to `SS0`/`SS1`, so they were the obvious first hypothesis. An
earlier pass closed them as "dead strings". That closure was wrong on **both** of
its arguments (E50).

**Forwarding is generic, not a driver allowlist.** `rm_parse_option_string()`
(`osapi.c:3352`) walks every `key=value` in `NVreg_RegistryDwords` and, for any name
not in the host module-param table, calls `rm_write_registry_dword()`. The registry
reaches GSP-RM. The host binary does not contain the string
`RMDisableFeatureDisablement` either, yet that key works on this driver family — a
proof by construction that unknown keys are forwarded.

**The strings are referenced by code.** The corrected raw scan (sign-extended
`auipc`, RVC-aware) finds both in 595.91.07:

```
015cf1be  auipc+addi -> 0x01f3a958   "RMOverrideSmSpeedSelect"
015cf1ea  auipc+addi -> 0x01f3a970   "RMOverrideSmSpeedSelect1"
```

The disassembly is a registry read through `FUN_ram_011cfb2c` — the same primitive
used elsewhere for `ForceP2P` — followed by two stores:

```
015cf1ba  addi a2,s0,-0x80          ; &value
015cf1be  auipc a1,0x96b / addi     ; key string
015cf1cc  jalr  -> FUN_ram_011cfb2c ; registry read
015cf1d2  c.bnez a0                 ; skip if absent
015cf1d4  lw   a4,-0x80(s0)         ; parsed dword
015cf1de  sb   a3,-0x1bb(a5)        ; config[0xE45] = 1
015cf1e2  sw   a4,-0x158(a5)        ; config[0xEA8] = value
```

and the same sequence at `0x15cf1ea` for `_1` (`config[0xE46]`, `config[0xEAC]`).
The key is parsed and its value stored in the RM config structure; it is not a
vestigial string. What consumes `config[0xEA8]` is unresolved (E50, §16.2).

**Measurement.** Four variants on both cards, each one stock-driver reload, with the
sm_120 probe and a FEAT-bank read before and after (E51):

| Variant | `41:00.0` FP16/MHz | `c1:00.0` FP16/MHz | FEAT bank |
|---|---:|---:|---|
| baseline (E49) | 0.07789 | 0.07771 | stock |
| `RMOverrideSmSpeedSelect=0x88888888` | 0.07821 | 0.07760 | identical |
| `RMOverrideSmSpeedSelect=0` | 0.07792 | 0.07755 | identical |
| `RMDisableFeatureDisablement=1` | 0.07782 | 0.07764 | identical |
| both keys (`0x88888888` / `0x8`) | 0.07782 | 0.07792 | identical |

Every point is within ±0.4% per clock. The bank is byte-identical before and after,
including each card's distinct stock `SS0`/`SS1`, and the static feature words at
`0x823824/28/2c` (`FEAT_OVR_ROW_REMAP`/`FEAT_READOUT_2`/`FEAT_OVR_ECC_2`, not
counters; E56) do not move. They are static state, so this is not evidence about a
blocked write attempt.

**Status: CLOSED-MEASURED (E50, E51).** The keys are live code paths with no
measured rate effect. E58 resolves the consumer: `config+0xEA8/0xEAC` are read by
`FUN_ram_0216d680` and `FUN_ram_0217f718`, reduced to booleans, and written to a GR
context/ucode descriptor, not MMIO; EA8 is gated by `config+0xEA4`. The value is
destroyed, so no selector can ever be sourced from the key. The "dead" label is
retracted — and the way it was reached is the same reference-audit negative
already withdrawn once (E13 → E17). `+0xE45`/`+0xE46` are write-only "key
present" flags; `+0xEA4` is the timeout/gate. The exact targets are
`(*(GRCfg+0xA8)+0xD8)+0x20` (EA8 → bit 17 when `+0xEA4 != 0`, EAC → bit 18) and
`(*(GRCfg+0x42698))+8` (EA8 → 0/1 in the GR ucode image header); the first reader
also writes a 4K-page count at `+0x24`. Neither is MMIO.

### 6.3 The forwarded keys are a live host→HS input surface

`RmDisableCotCmd` is a bitfield (FRTS sysmem bits 1:0, FRTS vidmem bits 3:2, GSPFMC
bits 5:4). Each test is one module reload with `NVreg_RegistryDwords` on the
modprobe command line only, nothing persisted (E11):

| Key | GPUs after load | Kernel evidence |
|---|---|---|
| `RmDisableFspFuseErrorCheck=1` | 2/2 | `FSP's fuse error detection status check ... is disabled using the regkey` |
| `RmDisableCotCmd=0x1` (FRTS sysmem) | 2/2 | none |
| **`RmDisableCotCmd=0x4`** (FRTS vidmem) | **0/2** | **`Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x83d, additional info=0x0`** ×4, then `Max GSP-RM boot attempts exceeded: 4/4` |
| `RmDisableCotCmd=0x10` (GSPFMC) | 0/2 | `kgspResetHw_GB100: Timed out waiting for GSP reset PLM to be lowered` |
| `RmDisableFsp=1` | not run | source: emulation-only |

**Finding 1 — the input surface is live and observable.** Withholding the vidmem
FRTS region changes what the FMC receives, and it refuses through a structured
channel (`version`, `partition`, `error code`, `additional info`) that appears in
`dmesg` before the driver gives up. A host→HS input with an oracle, reachable by a
registry bit and no signature; the failure is clean.

**Finding 2 — the host-driven FMC bootstrap is deadlocked by design.**
`RmDisableCotCmd=0x10` sets `PDB_PROP_KFSP_DISABLE_GSPFMC`, and `kgspBootstrap_GH100`
calls `_kgspBootstrapGspFmc_GH100` instead of `kfspSendBootCommands`. The assertion
at `kernel_gsp_gh100.c:980` proves the path was taken. Its first step is
`kgspResetHw_HAL`, which on GB100 requires `READ_PROTECTION_LEVEL0` **and**
`WRITE_PROTECTION_LEVEL0` in `NV_PGSP_FALCON_RESET_PRIV_LEVEL_MASK` (`0x1103c4`).
At cold boot those bits are clear, and nothing lowers them except running GSP
firmware. The host cannot reset the GSP it needs to reset in order to boot it.

**Side effect — a third sentinel.** In that state the host cannot read the block at
all: `0x1103c0` reads `0xBADF5720` from the host while reading `0x00000200` through
GSP-RM. The sentinel family is in Appendix C: unimplemented, no such port, present
but blocked.

**Cost.** The GSPFMC failure leaves an ioctl blocked forever (`nvidia-smi` stuck in
`nvidia_unlocked_ioctl`, `rmmod` blocked on the open fd), so each attempt ends in a
reboot. `RmDisableCotCmd=0x3f` would only re-fail at the FRTS-vidmem stage.

### 6.4 Verdict

| Path | Result | Status |
|---|---|---|
| `RMOverrideSmSpeedSelect*` | parsed and stored; no rate or bank change | CLOSED-MEASURED (E50/E51) |
| `RMDisableFeatureDisablement` | parsed; bypasses a display-only feature table | CLOSED-STATIC (E52) |
| Other registry keys as rate controls | no rate path in source | CLOSED-STATIC (E11/E16) |
| `RmDisableCotCmd` as a host→HS input | live, with an oracle (`0x83d`) | **LIVE** (E11) |
| Host-driven FMC bootstrap | unreachable at cold boot (reset PLM) | CLOSED-MEASURED (E11) |

The speed-select keys are inert as a rate path; the boot keys remain valuable as an
input channel. That is why the work moved to a patched driver: it turns three bits
into arbitrary control over every host-built structure HS parses, and into
instrumentation (§9).

---

## 7. Lever: FECS / GR context

### 7.1 The command doorbell

The `0x409000`–`0x409fff` block is a **sparse GR/FECS register/PLM block, not the
Falcon core** (E18). 789 of 1024 dwords are `0xBADF5040`; the IMEM/DMEM ports at
`0x409180`/`0x4091c0` return sentinels. Implemented registers begin around
`0x409400`.

| Probe | Host | GSP | Meaning |
|---|---:|---:|---|
| `0x409668` | `0xbadf5040` | `0xbadf5040` | unimplemented; the alternate getter's `0x9668` is not here |
| `0x409660` | `0xfffffbef` | `0xfffffbef` | PLM: read all / write L1–L3 |
| `0x409688` | `0xffffffcf` | `0xffffffcf` | PLM: read all / write L2–L3, source bit 10 set |
| `0x409438` | `0xffffffef` | `0xffffffef` | PLM: read all / write L1–L3, source bit 10 set |
| `0x4096d0` | `0xffffffff` | `0xffffffff` | PLM: read/write all |
| **`0x409800`** | `1` | `1` | **GSP-writable** doorbell/status |
| `0x409b00` / `0x409b04` | `0x007e0f0a` | `0x007e0f0a` | DP/companion readout pair |
| `0x409b78` / `0x409638` | `0` / `5` | `0` / `5` | implemented |

The FECS PLMs are write-locked: GSP writes of `0xffffffff` to `0x409688`,
`0x409438`, and `0x409660` were silently dropped, like the FEAT block. The
`0x409800` write landed because it sits in the fully open `0x4096d0` block.

### 7.2 The command protocol

`0x409800` is not a speed selector. The decompiled GSP uses it as the FECS command
doorbell (E18, E19):

```c
method(obj, 0x409800, 0, param, method);
FUN_ram_015e2724(..., 0x21, 0x3fffffff, ...);   /* send command */
FUN_ram_015cc798(...);                          /* wait for response */
```

The sender `FUN_ram_015e2724` writes the command data to `0x9500`, the command ID
(`param & 0xfff`) to `0x9504`, and an optional payload to `0x9800 + 4*param`. The
waiter `FUN_ram_015cc798` polls that status slot. With the FECS base these map to:

| Register | Measured | Meaning |
|---|---:|---|
| `0x409500` | `0` | command data, readable |
| `0x409504` | `0xbadf5545` | command ID; **read-blocked** to the generic caller (new PRI `0xBADF55`) |
| `0x409800` | `1` | status/payload; GSP-writable |

Known command IDs across the GSP-RM (`mod_gr_fecs.c`, `mod_logging_debug.c`):
`0x01/03/04/09/0c/0d/0e/0f/1a/21/24/2c/2d/2e/2f/30/31/32/3a/71/72/75/76/7d/7e/b7`.
`0x21/0x3fffffff` is a feature command sent at boot and does not unlock; `0x30/31/32/75/76`
are GR init/context; the rest are feature/context commands.

The handler lives in the encrypted FECS/GPCCS ucode. No plaintext ucode handler or
vBIOS descriptor fingerprint exists in the GSP-RM; the vBIOS µcode entries are
encrypted. The command-ID register is the trigger and must not be blind-fuzzed.

### 7.3 The context path is a buffer loader

The host-reachable subset is the GR context path. `FUN_ram_0162cc10` and
`FUN_ram_0162cda8` are installed at `obj+0xD00` in the same per-chip HAL table that
installs the FEAT decoder (E20). The caller `FUN_ram_0184499c` sends `0x30` (a
buffer-size query), allocates a memdesc of that size, maps it, and then sends:

| Command | Data | Role |
|---|---|---|
| `0x30` | `1` | query the required context-buffer size |
| `0x31` | address A bits 12..39 | |
| `0x76` | address A bits 40..55 | |
| `0x32` | address B bits 8..39 | |
| `0x75` | address B bits 40..63 | |

The 0x20-byte entry behind them is a memory descriptor:
`+0x00` memdesc, `+0x08` 64-bit address, `+0x10` size (29 bits) + flags (3 bits),
`+0x18` state, `+0x1c` flag.

**The host builds descriptors, not the image.** `GR_GLOBALCTX_BUFFERS` is an array
of memdescs; `NV2080_CTRL_GR_CTX_BUFFER_INFO` is handles/addresses/sizes;
`kgrctxPrepareInitializeCtxBuffer_IMPL` fills `gpuPhysAddr`, `size`, `physAttr`,
`bufferId`, `bInitialize`, `bNonmapped`. Initialization is done by the GSP-side
`NV2080_CTRL_CMD_GPU_PROMOTE_CTX`. The only `portMemCopy` calls in
`kernel_graphics_context.c` are the UUID copy and a sort swap. The rate state is a
separate read-only cache (`KGRAPHICS_STATIC_INFO.pSmIssueRateModifier`) and is
never inserted into a context buffer or a command.

The static answer is therefore negative: there is no rate/selector/enable field in
the payloads or the host structures. The remaining question was what the
*initialized image* contains, which needed a live dump.

### 7.4 The dump campaign

Six runs with an instrumented driver (E22–E27) turned the question into data. The
harness evolved from dmesg hex to direct file dumps, then added a post-use hook and
a bounded window.

| Run | Target | Result |
|---|---|---|
| E22 | GPU0 only; first dump | patch buffer 287 `{address, value}` entries, main 4 KB window zero; GPU1 WPR2-up |
| E23 | GPU0, post-use | 287 entries, **10 values change, no address changes** |
| E24 | GPU0, 8 KB at main `0x4000` | window zero for both driver-init and compute contexts |
| E25 | GPU0, global buffers | lost to the dmesg ring; switched to file dumps |
| E26 | GPU0, full files | main image 3.6 MB, 311,213/180,373 nonzero; no known rate constants |
| E27 | both cards, same boot | 618 of 908,288 words differ (0.068%), all structural |

**What the patch buffer is.** A 287-entry list of 8-byte `{address, value}` pairs;
`0x8f8` bytes initialized, the rest `0xaddeadde` poison. The post-use differential
changes exactly ten entries, all in global-context address slots, with values that
are buffer placements, not selectors. This matches the host source's description of
the patch buffer as global-context address overrides.

**What the main image is not.** The full 3.6 MB image contains no `0x00c36180`,
`0xfffffb8f`, `0x00504204`, or either stock `SS0` word. The `0x88888888` hits
(1,076 aligned in one image, 1,000 at position-identical offsets in both) are a
static fill, not the Ada payload; the earlier `ADA_SS0_PAYLOAD` label was a false
positive.

**The cross-card test.** Both cards captured at the same driver-init hook in one
boot. The differences are 427 words of a 4-bit index field at bits `[30:27]` in a
`~0x3b00`-stride record array, 191 in 52-byte-stride tables plus per-boot random
words. No word decodes to the Blackwell FEAT vector, neither image contains a known
rate constant, and the global `UNRESTRICTED_PRIV_ACCESS_MAP` is byte-identical to
the previous boot.

### 7.5 Verdict and strength of evidence

| Question | Answer | Status |
|---|---|---|
| Do FECS command payloads carry a selector? | No — addresses, sizes, flags | CLOSED-STATIC (E19/E20) |
| Does the host build the context image? | No — descriptors only | CLOSED-STATIC (E20) |
| Does the initialized image contain a rate word? | No known constant, no FEAT-shaped field, no card-dependent field | CLOSED-MEASURED (E27) |
| Could a hidden FECS command set the rate? | The plaintext call-site map has 29 IDs, all init/context/feature, with no selector; the handler is encrypted | **OPEN** (low) |

**Caveat on the closure.** The content search assumes the Blackwell 3-bit layout,
and the cross-card diff by construction cannot find a constant both capped cards
share. The one decisive experiment — modify a host-owned context/patch buffer after
the GSP fills it and measure — was never run. The route is closed as a *rate
setter*; it is not closed as a *write primitive* for the context image (E44;
§14.4).

---

## 8. Lever: HS / SEC2 / FSP memory windows

### 8.1 The GSP's own block

The RISC-V GSP exposes its register file but not its local memory (E10). A
read-only dump of `0x110000`–`0x110d4c` through `GPU_EXEC_REG_OPS` agrees with
the published Falcon headers. (E10 labelled the whole `0x110000`–`0x11172c`
window "GSP Falcon"; E63 shows it is two blocks — the Falcon register file ends
at `0x110d4c` and the PRISCV block starts at `0x111004`, §8.6.)

| Offset | Register | Value | Check |
|---|---|---|---|
| `0x1103c0` | `FALCON_ENGINE` | `0x00000200` | reset deasserted |
| `0x1100f4` | `HWCFG2` | `0x818787f7` | bit 10 = 1 → RISC-V core |
| `0x110108` | `HWCFG` | `0x80420100` | IMEM size `0x100` |
| `0x110008` | `IRQSTAT` | `0` | no pending interrupt |
| `0x1103c4` | `RESET_PRIV_LEVEL_MASK` | `0x00000f00` | level-0 enables clear |
| `0x111700` | `RISCV_FAULT_CONTAINMENT_SRCSTAT` | `0` | no faulted domain |

The legacy **IMEM/DMEM ports are absent** (`0x110180`+, `0x1101c0`+ return
`0xBADF5610`), so there is no window onto ITCM/DTCM. The eight **EMEM ports are
present** (`0x110ac0`–`0x110afc`) and measure 8 KB: `HWCFG1` (`0x11012c`) bits
21:25 = 1 → 512-byte blocks, and `0x110abc = 0x20` → 32 × 256 B. A further PLM
sits at `0x110b84 = 0xffffff8f`, the same read-all / write-L3-only shape as
`FEAT_OVR_PLM`.

Streaming the window with `AINCR` advances the pointer exactly 4 bytes per read
(`0x02000000 → 0x02002000` over 2048 reads) and **all 2048 words read zero**, every
op `SUCCESS`, no sentinels. A write/read-back discriminator with a neighbour-address
control proves it is genuine read/write storage, not a mask or loopback:

```
PASS  AINCW arm readback:   0x01001ffc
PASS  word at 0x1ffc:       0xdeadbeef
PASS  word at 0x1ff8:       0x00000000   (neighbour: not loopback)
PASS  word at 0x1ffc (2nd): 0xdeadbeef   (after re-arm: not stale)
PASS  word at 0x1ffc after restore: 0
```

One caution: an immediate readback of `EMEMD` after a write returned `0xdead5ed0`,
neither the written word nor zero. Only **arm-then-read** is a trustworthy data
path.

**The debug interface is compiled out.** Every RISC-V debug entry point in the
shipped `nvidia.ko` is an inert stub (`mov $0x56,%eax; ret` = `NV_ERR_NOT_SUPPORTED`)
— `IcdReadMem`, `IcdReadReg`, `IcdRpc`, `IcdWaitForIdle`. The only exposed registers
are `BCR_CTRL`, `BCR_DMACFG`, `BCR_DMAADDR_*` and `CPUCTL`: a fetch path into the
core, not a read-back window.

**Consequence:** EMEM is real PL2-reachable storage, and it holds nothing. The FMC
plaintext never leaves HS.

### 8.2 FSP core EMEM and PFSP EMEM

Two different EMEM blocks were conflated in early passes (E21):

- `0x8f2ac0` is `NV_PFSP_EMEMC(0)` — the **host-driven RM/MCTP transport**. Its
  pointer and data move as RM sends packets.
- `0x8f0ac0` is the **FSP core's Falcon EMEM port block**, with four live channels.
  The PLM at `0x8f0a90 = 0xffffff8f` (read all / write L3 only) is the likely gate.

The measured core map (`41:00.0`; host and GSP agree; both cards byte-identical on
ch0–3):

| Offset | Value | Meaning |
|---|---|---|
| `0x8f0a58/5c` | `0x6624b970` / `3` | status/config |
| `0x8f0a90` | **`0xffffff8f`** | **PLM: read all / write L3 only** |
| `0x8f0aa0/a4` | `0x00804bff` / `0x0001fffe` | PLM-shaped pair |
| `0x8f0ab0`–`abc` | `e81dc861 98216d8b 803e5471 9e870bdf` | unidentified 16-byte constant |
| `0x8f0ac0/c4` | `0x5536c785` / `0x6fd593dc` | ch0 control/data |
| `0x8f0ac8/cc` | `0xc79705f3` / `0x8f7a6cc2` | ch1 |
| `0x8f0ad0/d4` | `0x5792ea26` / `0xf7cd4b7b` | ch2 |
| `0x8f0ad8/dc` | `0xc1c4c375` / `0x21fa03ab` | ch3 |
| `0x8f0ae0`–`ec` | `0` | ch4–5 |
| `0x8f0af0`–`fc` | `0xbadf5620` | ch6–7 |

The control decodes with the published `NV_PFSP_EMEMC` fields: OFFS[7:2], BLK[15:8],
AINCW[24], AINCR[25]. For ch0, OFFS=33 and BLK=199, so the documented EMEM address
is `0xC784`; the data register returns that word, not a hardware constant.

**The pointer cannot be moved.** Two write/read/restore/read batches through
`GPU_EXEC_REG_OPS` at PL2 (`ctrl|AINCR` and a cleared pointer) both returned
`SUCCESS` and read back unchanged, while the same path writes `0x409800` and PBUS
scratch. The only FSP-internal data readable is the firmware-selected word per
channel.

**PFSP EMEM is master-dependent:** the host sees ch4–7 `0xBADF5720` and ch1–3
zero/`0xdead5ed0`; the GSP sees ch1/2/4/6/7 `0xBADF5723` and ch3/5
zero/`0xdead5ed0`.

### 8.3 SEC2

- `0x8401c0/c4` (DMEM) is a real, host-controlled port; `AINCR` advances it
  (`0x02000000 → 0x02002000`) but the first 8 KB is zero.
- `0x840180/184` (IMEM) is blocked: `0xbadf5720` from the host, `0xbadf5723` from
  the GSP.
- `0x840ac0/c4` (EMEM) reads `0x02000040` / `0`; empty.
- `0x8403c4` (PLM) reads `0x00000b0f` (read all / write none).

### 8.4 The 16-byte constant

`e81dc861 98216d8b 803e5471 9e870bdf` at `0x8f0ab0` is not present in the GSP-RM,
`nvidia.ko`, the vBIOS, or the FMC containers; it is not an MD5/SHA prefix of any
of them. Tested as an AES-128 key on the FMC and bootloader in ECB/CBC/CTR with
several key/IV variants: entropy stayed ~7.95 and no plaintext appeared. It remains
unidentified — an FSP ROM measurement, a fuse-derived value, or an identifier.

### 8.5 Verdict

| Window | Result | Status |
|---|---|---|
| GSP IMEM/DMEM | no port on this chip | CLOSED-MEASURED (E10) |
| GSP EMEM | 8 KB read/write scratch, empty | CLOSED-MEASURED (E10) |
| RISC-V debug reads | compiled to `NV_ERR_NOT_SUPPORTED` | CLOSED-STATIC (E10) |
| FSP core EMEM | present, L3-gated, firmware-selected word only | CLOSED-MEASURED (E21) |
| FSP PRISCV/ICD | no core interface: the full 16 KB PFSP window (`0x8f0000`–`0x8f3fff`) was swept from host and GSP; `CPUCTL`/`RPC`/ICD are `0xbadf5040` at both `+0x3d0` and `+0x1000` placements (`0x8f1388` etc.). The `0x8f1f00`/`0x8f1f80` tables and a `0x8f3000` block exist, but there is no command engine | CLOSED-MEASURED (E68) |
| PFSP EMEM | MCTP transport, channel-dependent blocking | CLOSED-MEASURED (E21) |
| SEC2 DMEM/IMEM | DMEM real but empty; IMEM blocked | CLOSED-MEASURED (E18) |
| RISC-V PRISCV block | two-sided host/GSP map measured; **the ICD is live** — host-writable at PL0, commands execute, and `STOP` + `RDM` reads the 14.4 MB RM code segment of the halted core; no memory-mapped debug module | **LIVE** (E63, E67) |

No HS memory is readable at PL2.

### 8.6 The RISC-V PRISCV block and its two-sided map (E63)

The GSP's RISC-V subsystem is two register blocks, not one. The Falcon-style
block ends at `0x110d4c`; `0x110d50–0x110ffc` is unimplemented; the PRISCV block
starts at `0x111004`. The GB202 `dev_riscv_pri.h` offsets are relative to
`0x111000`, confirmed four ways: `CPUCTL` `0x111388`, `RPC` `0x1113ec`,
`IRQMASK`/`IRQDEST` `0x111528/52c`, and `PRIV_ERR`/`HUB_ERR`
`0x111420–0x111430`; E10's fault-containment read at `0x111700` is offset `0x700`.

A read-only 4 KB sweep (`0x110000–0x113fff`, 4,096 dwords, all `SUCCESS`)
through `GPU_EXEC_REG_OPS`, plus a host BAR0 map of the same window, shows the
block is **partitioned per master**, not a single register file seen twice:

| Class (512 common offsets) | Count | Example |
|---|---:|---|
| Same value to host and GSP | 66 | `CPUCTL 0x111388 = 0x180` (halted 0, active 1); PLMs `0x111300–0x111328`; IRQ `0x111528/52c` |
| Differ | 199 | core state `0x111004–0x111094`: GSP reads values, host gets `0xBADF5720` |
| Host-only | 69 | `0x1111a8–0x1111e4` (16 × `0x2`), `0x111610+` (`0xbbbbbbbb` fill), ICD `0x1113d0+` |
| GSP-only | 80 | GSP-side `0x1113ec = 0x01404f66` (a different register, not the PC; E67); trace `0x111404–0x111410` (host gets `0xBADF5720`) |

The debug interface is in the host half. At the Ampere ICD layout
(`PRISCV+0x3d0`) the host reads `ICD_CMD`/`ADDR0`/`ADDR1`/`RDATA` as zero and is
not blocked, while the GSP is refused with `0xbadfffff` — a new class, seen only
at these four registers (Appendix A.10). The requested `0x111800–0x113fff`
window contains no debug module: 16 implemented dwords, two 12-byte-stride
tables at `0x111f00` and `0x111f80`, the rest `0xBADF5040`.

The PC register is per-master, and E67 reverses E63's reading. The ICD's `RPC`
returns `0x93002ebc`, matching the host's `0x1113ec`; the RDM translation shows
`0x93002ebc` is the true halted PC (it maps to PA `0x01002ebc`, whose bytes match
the image). The GSP master's `0x1113ec` reads `0x01404f66`, a different register
within the code segment but not the current PC. The host can therefore sample the
core's PC once the ICD is commanded; the GSP-side value is not it.

Status: the map is measured. E67 then commanded the ICD: it is live and
host-writable at PL0, and `STOP` + `RDM` reads the 14.4 MB code segment of the
halted core. The two write gates in the block are `0x111320 = 0xffffff8f`
(read all / write L3) and `0x111328 = 0xffffffff` (read/write all); the
ADDR-latch writes show the ICD is admitted at PL0.

### 8.7 The ICD is live (E67)

The four registers E63 found host-readable-but-idle are a working debug command
engine. At PL0 the host writes `ADDR0`/`ADDR1` (they retain the value), `CMD`
(it retains the command), and the engine executes:

- While the core runs, `RSTAT` idx 0/3/4 completes (`ERROR=0`, value 0);
  `RREG`, `RCSR` and `RDM` are rejected with `CMD[14]=1` and
  `RDATA=0xbadfbadf` (`0xbadfbadfbadfbadf` for 8-byte reads), a new sentinel
  meaning "command rejected" — the halted-hart requirement.
- `CMD=0` (`STOP`) halts the core. `CPUCTL` moves `0x2a0` → `0x380`, but
  `CPUCTL[4]` stays clear, so the GA102 `HALTED` bit is not the indicator on
  GB202. After `STOP`, `RREG`/`RCSR`/`RDM` succeed (`ERROR=0`).
- `RPC` returns `0x93002ebc`, `ra` `0x93002ea6`, `sp` `0xa3003ed0`. The
  host's `0x1113ec` reads the same `0x93002ebc`; the GSP-side value
  (`0x01404f66`) is a different register (§8.6).
- `RDM` reads the 14.4 MB RM code segment at core address `0x01000000`–
  `0x01DCD000` (tested to `0x01B40000`; `0x02000000` fails). `0x01000000` is the
  ELF magic at file `0x18F000`; the loaded image is linked at `0x01000000` and
  runs at runtime VA `link + 0x92000000`. This is the core's address space: the
  host FB PA `0x01000000` is empty (E74), so the backing is in the WPR. The data
  segment (`0x04000000`) and the WPR/FRTS physical addresses are not reachable
  through the ICD.
- The driver's own `kflcnCoreDumpDestructive_IMPL` uses this same ICD: after the
  `STOP` it read CSRs and attempted an `RDM` stack unwind, then raised Xid 154.
  The Linux `kflcnRiscvIcd*` stubs of E10 are an API layer, not a hardware gate.
- **The block is closed through the HS phase (E68).** A read-only trace armed
  after the COT response samples `CPUCTL`, the host PC mirror and `ICD_CMD`
  every 100 µs. From t=0 to ~155 ms the PC and `ICD_CMD` read `0xbadf5620`, and
  the Falcon `ENGINE` (`0x1103c0`) reads `0xbadf5720`; `CPUCTL` (`0x180`) and the
  reset PLM (`0x00000f00`) are readable. At ~155–157 ms the PC/CMD unblock, the
  first valid PCs are the boot image at `0xefd0xxxx`, and GSP-RM
  (`0x9300xxxx`/`0x01xxxxxx`) starts ~0.5–0.6 ms later. The boot image is
  `0x47000` bytes — the host-supplied `GspRmBoot` — and a halt inside it reads
  `ra=0xefd00ca0`, `sp=0xefd1f730`.
- **`STOP` works in that window; `RDM` does not (E68).** Halting on the first
  valid PC (`0xefd017ee`) or on the first GSP-RM PC (`0x930014bc`) leaves
  `CPUCTL=0x380` and lets `RPC`/`RREG` complete, but every `RDM` — including the
  `0x01000000` control — is refused with `0xbadfbadfbadfbadf`. `RDM` is enabled
  later in GSP-RM init, not by the HS→LS transition.
- **The post-boot aperture is the RM code segment only (E68).** In the E67 halt
  state `0x01000000` still returns ELF magic, while `0xEFD00000`, `0x5DD00000`,
  `0x181D00000`, the data segment (`0x04000000`) and its runtime VA
  (`0x96000000`) are all refused. The GSP-RM image contains no ICD-unlock write;
  its only PRISCV writes are `IRQDEST`/`0x111520` setup and `ICD_CMD=0` in fatal
  self-halt paths.

This does not touch the FEAT bank or the PL3 boundary. The boot-window halt does
not reach the boot image, so the ICD is closed as a route to decrypted HS
firmware (§17.3, E68).

---

## 9. Lever: the FMC/FSP boot-input surface

This is the live approach: the host builds the structures that HS parses at boot,
and HS answers with structured error codes. The method is a patched open driver at
exactly 595.91.07, so the host can vary one field per run and observe.

### 9.1 Baseline: what the host sends

Read-only instrumentation of the ordinary boot path (E28):

| Field | GPU0 (`c1:00.0`) | GPU1 (`41:00.0`) |
|---|---|---|
| COT version / size | 2 / `0x35c` | 2 / `0x35c` |
| `gspFmcSysmemOffset` | `0x14e500000` | `0x151180000` |
| `frtsSysmemOffset` / size | 0 / 0 | 0 / 0 |
| `frtsVidmemOffset` / size | `0x1b40000` / `0x100000` | same |
| `gspBootArgsSysmemOffset` | `0x152e11000` | `0x10e928000` |
| COT `hash384[0..3]` | `ee0988fe a62832c4 b2fe90d8 7e2f6104` | same |
| COT public key / signature | `18f18b04…` / `606f48f2…` | same |
| `WprMeta` magic / rev / flags | `0xdc3aae21371a60b3` / 1 / 0 | same |
| radix3 ELF address / size | `0x13ec00000` / 72,830,976 | `0x184400000` / 72,830,976 |
| bootloader address / size | `0x14e380000` / 290,816 | `0x14d780000` / 290,816 |
| `gspFwHeapSize` / `frtsSize` | `0x8700000` / `0x100000` | same |
| `gspFwWprStart`, heapOff, frtsOff, wprEnd, fbSize | 0 | 0 |

The zero fields are by design: the host supplies sizes and sysmem addresses, and
the ACR/FMC fills and patches the FB offsets.

**FMC identity.** The COT hash bytes match `GspRmFmcGfwProdSigned_GB202` container
`c04` (287,304 B) and the COT key matches `c04`'s production P-384 key. The FMC is
on the ordinary GB202 boot path in this build, not only under confidential compute.

**The oracle hook.** `kern_fsp_gh100.c` carries compile-time defines that vary one
COT field immediately before `kfspSendAndReadMessage`: (1) `frtsVidmemSize`,
(2) `frtsVidmemOffset`, (3) `gspBootArgsSysmemOffset`, (4) `gspFmcSysmemOffset`,
(5) `hash384[0] ^= value`. The applied variant is printed. Defaults are inert.
`phase2b/fmc_oracle.sh` sets the define, rebuilds, loads, captures dmesg, and
restores the stock driver in its trap.

### 9.2 The COT oracle

#### 9.2.1 Size: exactly 1 MB

`frtsVidmemSize = 0x80000` (half) was refused by the **FSP**, not the FMC, with
error **`0xd9`** (Task ID `0x1`, command type `0x14`) on every send (E29). The
driver bug exposed by that run is in §9.5.

The stock size (`0x100000`) sent through the same override path booted both cards
cleanly, so `0xd9` is attributable to the value, not the plumbing (E30). A **larger**
size (`0x200000`) was also refused with `0xd9` at four distinct placements the
driver cycled (`0x1b40000`, `0x10520000`, `0x1ef00000`, `0x2d8e0000`). The FSP
requires exactly 1 MB; the check is keyed to size, not placement. The COT size
field is closed as a parser-slack surface.

#### 9.2.2 Offset: alignment checked, placement free

The offset is **from the end of FB**, not an absolute address
(`kern_fsp_gh100.c:1450–1492`: `memmgrGetFBEndReserveSizeEstimate_HAL` plus the PMU
reservation, aligned up to 128K):

```
Layout:  0 | ... | FRTS | PMU | rsvd est | END
frtsOffsetFromEnd =        ^ ............... ^
```

| COT offset | Meaning | Result |
|---|---|---|
| stock `0x1b40000` | 27.25 MiB from FB end | accepted |
| `0x10520000` | 261.1 MiB from FB end | accepted (E31) |
| `0x10500000` | 261.0 MiB from FB end | accepted (E33) |
| `0x40000000` | 1 GiB from FB end | accepted (E35) |
| `0x10520001` | same, one byte off | **`0xd6`** (E32) |

A misaligned base is refused with **`0xd6`**, a different code from the size
mismatch. The FSP validates the offset separately from the size, rejects rather than
rounds, and maps two codes to two checks. The accepted base may sit **below** the
driver's own end-reserve estimate — `0x10500000` is 233.75 MiB below it and boots
cleanly — so the FSP's rule is exact size plus alignment, not the driver's reserve
policy.

#### 9.2.3 The placement lever

The COT offset does not merely pass validation: it **selects the FB base of the
entire GSP-RM WPR**. Comparing a stock boot with the moved boot (E33, E34):

| Field | Stock, COT `0x1b40000` | Moved, COT `0x10500000` | Δ |
|---|---:|---:|---:|
| GSCI `nonWprHeap` | `0x7e72e0000` | `0x7d8920000` | `0xE9C0000` |
| GSCI `frts` | `0x7f42c0000` | `0x7e5900000` | `0xE9C0000` |
| COT offset delta | — | — | `0xE9C0000` (233.75 MiB) |

The deltas are identical to the byte. The layout model:

```
GSP_frts_abs  = FB_end − COT_offset − 0xA200000      (fixed 162 MiB gap)
nonWprHeap    = GSP_frts_abs − span
span          = 0xCFE0000 + (gspFwHeapSize − 0x8700000)
```

At a 1 GiB COT base the model predicts exactly and the measurement matches:
`frts = 0x7b5e00000`, `nonWprHeap = 0x7a8e20000` (E35). The firmware ELF, boot bin,
WPR heap, non-WPR heap and FRTS all move together. The tested window is at least
1 GiB, subject only to exact size and 128K alignment; no range check has been
observed in either direction.

#### 9.2.4 Hash and key: both authenticated, and auth failure wedges

A one-bit flip in `hash384[0]` is refused with FSP code **`0x377`** (E41). Unlike
the size, alignment and magic rejections, an authentication failure leaves **WPR2
up**: every retry reports `unexpected WPR2 already up`, and the machine needs a
reboot.

**The public key is anchored.** Replacing the COT's `publicKey` and `signature`
with a locally generated P-384 pair over the correct hash is refused with a
different code, **`0x1db`** (E61). A self-consistent pair therefore dies before the
hash/signature check, so the key is validated separately and against something the
host cannot supply. The COT key-substitution route for the FMC is closed.

The ordering is the result: the FSP arms WPR2 *before* it authenticates the COT
(both `0x1db` and `0x377` leave it up). Pre-auth field checks reject without side
effects; the auth failure does not unwind. The COT pointer fields (3 and 4) most
likely land on that path, so they now carry a reboot cost.

### 9.3 The `WprMeta` oracle

The host fills all 256 bytes of `GspFwWprMeta` and the FMC reads them from sysmem.
`phase2b/wpr_oracle.sh` varies one field per run.

#### 9.3.1 `magic` is enforced

`magic = 0xdeadbeefdeadbeef` is rejected with a new FMC code, **`0x827`**, on every
attempt (E36). The oracle plumbing is proven end to end. The retry path also
revealed its FRTS margin: each failed attempt moves the COT base by `0xE9C0000`
(233.75 MiB) and sets `flags = 0x12`.

#### 9.3.2 `verified` is not a bypass

`verified = 0xa0a0a0a0a0a0a0a0` is accepted at initial boot (E36): both cards boot
cleanly, and the readback shows the flag reached the FMC. The decisive test was the
patched GSP-RM image (one instruction replaced by `ret`) **with the flag preset**:
still refused on every attempt, **16 × `0xaff`, additional info `0xb`** (E40). The
image check is independent of the host-filled flag. A resume-path use cannot be
excluded, but the cold-boot bypass hypothesis is closed.

#### 9.3.3 `frtsSize` cross-check does not exist

Setting `WprMeta.frtsSize = 0x200000` while the COT keeps its exact-validated
`0x100000` boots cleanly on both cards with no error and an unchanged layout (E37).
The FMC accepts the two copies disagreeing and builds the layout from the COT's
value. The struct's size field is decorative on GH100 — a missing cross-check, not
a lever.

#### 9.3.4 `gspFwHeapSize` is honoured in both directions

Raising the request from `0x8700000` (135 MiB) to `0x10000000` (256 MiB) boots
cleanly and grows the WPR **downward by exactly the requested increase** (E38):

| Field | Stock | This run | Δ |
|---|---:|---:|---:|
| `gspFwHeapSize` | `0x8700000` | `0x10000000` | `0x7900000` (121 MiB) |
| GSCI `frts` | `0x7f42c0000` | `0x7f42c0000` | 0 |
| GSCI `nonWprHeap` | `0x7e72e0000` | `0x7df9e0000` | `0x7900000` |
| WPR span | 207.875 MiB | 328.875 MiB | 121 MiB |

The top stays anchored to the COT base; the block grows downward. Heap *size* is a
second host lever, independent of position.

Shrinking to 16 MiB (`0x1000000`) **wedges the boot** rather than drawing a parser
error (E39). The FMC accepts the request and applies the layout, then GSP-RM never
comes up: `GspStatusQueueInit: msgqRxLink failed` with `NV_ERR_TIMEOUT (0x65)`
after ~2.7M retries, both cards, WPR2 stuck up. The FMC does not sanity-check the
heap request against what GSP-RM needs; the failure surfaces one layer later. Below-
minimum variants cost one reboot each, so bisect from above if the floor matters.

`fbSize` and `nonWprHeapSize` remain untested (E44, §16.2).

#### 9.3.5 The bootloader description and both boot images (E69)

`WprMeta` also carries the bootloader image description — `sysmemAddrOfBootloader`,
`sizeOfBootloader`, and the in-image code/data/manifest offsets — plus a separate
4 KB signature buffer. Stock on both cards: size `0x47000`, `cOff=0xf200`,
`dOff=0xa00`, `mOff=0`, `sig{size=0x1000}`. The oracle was extended to these
fields:

| Field | Value | Result |
|---|---|---|
| `sizeOfBootloader` | `0x47001` | **`0x82e`** — the length is checked |
| `bootloaderCodeOffset` | `0xffffffff` | boots — unchecked or unused |
| `bootloaderDataOffset` | `0xffffffff` | boots — unchecked or unused |
| `bootloaderManifestOffset` | `0xffffffff` | **`0x885`** — the offset is used |
| `sizeOfSignature` | `0x100000` | boots — the verifier uses a fixed 0x1000 parse |
| `sizeOfRadix3Elf` | `0x100000` | **`0xaff`**, info `0xb` — the size is bound into authentication |

The manifest offset is real: the manifest sits at offset 0 of the image, with data
at `0xa00` and code at `0xf200`; a wild offset draws `0x885`, a code distinct from
the image-authentication failure, so it is checked separately. The code and data
offsets are not consumed on this path (a wild value still boots).

**The images are authenticated.** Flipping one ciphertext byte of the bootloader
image in sysmem (the driver keeps it mapped writable), with the COT, FMC
container, signature buffer and `WprMeta` all stock, is refused with `0xaff`,
additional info `0xb` — the same code a patched GSP-RM ELF draws. In the same
boot the untampered second card booted normally, so the failure is attributable to
the byte flip. A corrupted ciphertext never reaches execution; the bootloader has
no fault-injection surface. §9.8/E62 is the analogous result for the FMC
container.

### 9.4 Error-code map and failure taxonomy

| Code | Source | Trigger | Side effect |
|---|---|---|---|
| `0x83d` | FMC, partition 1 | vidmem FRTS withheld (`RmDisableCotCmd=0x4`) | clean |
| `0xd9` | FSP response | COT `frtsVidmemSize != 0x100000` | clean |
| `0xd6` | FSP response | COT offset not 128K-aligned | clean |
| `0x827` | FMC/ACR | `WprMeta.magic` wrong | clean |
| `0x82e` | FMC, partition 1 | `WprMeta.sizeOfBootloader` changed (stock `0x47000` + 1) | clean |
| `0x885` | FMC, partition 1 | `WprMeta.bootloaderManifestOffset` outside the image | clean |
| `0x377` | FSP response | COT hash authentication failure | **WPR2 left up** |
| `0x1db` | FSP response | COT public key not accepted (self-signed pair) | **WPR2 left up** |
| `0x33` | FSP response | FMC container byte changed while the COT hash is stock | **WPR2 left up** |
| `0xaff` | FMC, partition 1 | modified GSP-RM image **or bootloader image** (additional info `0xb`) | clean (if firmware restored) |

Four failure modes, with different costs:

1. **Structured refusal, clean recovery** — pre-auth field checks. One module
   reload.
2. **Structured refusal, wedged WPR2** — authentication failure. One reboot.
3. **Hang with no host log** — bad SRMeta magic, and the SR path generally. One
   reboot and no evidence unless an out-of-band console is present (§10.2).
4. **Hard wedge** — a heap below GSP-RM's minimum. One reboot, and the layout is
   applied before the failure.

### 9.5 Driver bugs found en route

- **`pPollEvent` lifetime.** After the first `0xd9`, `kfspCleanupBootState_IMPL`
  destroyed the engine-lifetime `pPollEvent`; the retry then scheduled and destroyed
  a freed event and oopsed in `hrtimer_active` (NULL `hrtimer.base`), wedging the
  module. Fixed by moving the destroy to `kfspStateDestroy_IMPL`. The fix held over
  a 24-send failure path (E30).
- **GSPFMC ioctl hang.** A failed host-driven bootstrap leaves an ioctl that never
  returns; the module cannot be unloaded. Treat that experiment as one-shot.
- **Health-check hazards.** A SIGTERM-stopped `nvidia-smi` pins the module; use
  `timeout -s KILL` and `pkill -9 -x nvidia-smi`.

### 9.6 What this lever does and does not give

Gives: a validated host→HS oracle with ten mapped codes, and control over where
the entire GSP-RM footprint lives in FB, subject to exact size and 128K alignment.

Does not give: code execution in HS, decryption of the FMC, or any change to the
rate selectors. The parsed fields so far are layout and authentication metadata.
The FMC container itself is not a lever: it is bound to the COT hash and a
one-byte change is refused with `0x33` (§9.8, E62). E58 maps the message framing
and command set (§9.7); the remaining surface is a malformed-length packet or a
stale/unsolicited response, not a hidden command.

### 9.7 The FSP command surface and framing (E58)

The host→FSP surface is smaller than the COT oracle suggests. Only three NVDM
commands are live on GB202: COT `0x14`, caps query `0x16`, and clock boost `0x20`.
The only data-returning command, PRC `0x13`, is GH100-only; nine other NVDM types
are defined and never sent. There is no memory, fuse, register, or debug command;
FSP state is read out-of-band from registers (`NV_THERM_I2CS_SCRATCH`,
`NV_PFSP_FUSE_ERROR_CHECK`, `NV_PBUS_SW_SCRATCH_GSP_FMC_ERROR`, CMS2).

The framing has no length field: the message length is the queue head/tail distance
in the FSP EMEM channel. The host controls the TX length via
`NV_PFSP_QUEUE_TAIL(0)`; the FSP controls the RX length, which is bounds-checked
before the copy. MCTP type/vendor and a minimum 13-byte response are checked, but
the response's task ID, command type, tag, sequence, and SEID are not: only the
error code is used. A malformed or unsolicited `0x15` response can satisfy an
unrelated pending command; a never-EOM message can hold the reader in an unbounded
reassembly loop; a stale fragment can wedge future EMEM sends or be mis-attributed
on the MNOC transport (`RmFspUseMnoc`). There is no copy-before-verify on the
receive path. The host copies the COT hash from bindata rather than computing it,
but that is host-side bookkeeping only: secure firmware binds the loaded container
to that hash, so verification is not delegated (§9.8, E62). The fuse-error check
is log-only on GB202.

### 9.8 The FMC container is bound to the COT hash (E62)

The host places the production-signed FMC container — a plaintext `0x48` header
plus an encrypted body — in unprotected sysmem at `COT.gspFmcSysmemOffset`.
Read-only samples at three points (after the copy-in, after the FSP response, and
at memdesc release) are byte-identical to each other and to the stock `c04`
container, on both cards, with the tail past the container zero. The FSP neither
decrypts in place nor scrubs the buffer; the plaintext never appears in host
memory.

Tampering the buffer while the COT hash, signature and key stay stock is refused
before boot, with a code of its own:

| Change (one byte, container offset) | FSP response | WPR2 | Release dump |
|---|---|---|---|
| ciphertext body byte at `0x1048` (`0xee`→`0xef`) | **`0x33`** | left up | unchanged |
| plaintext header magic at `0x00` (`0x03`→`0x02`) | **`0x33`** | left up | unchanged |

`0x33` is distinct from the `0x377` signature failure (E41), which fires when the
*supplied hash* is wrong while the image is stock. The ordering is therefore:
verify the signature over the claimed hash, then bind the image bytes to that hash.
The binding covers the plaintext header as well as the encrypted body, and no
header-magic rejection surfaces first, so the container is not a pre-auth parser
surface in the Ada sense.

Consequence: a corrupted ciphertext byte does not reach the decrypted image as a
fault, so the host-supplied buffer is not a fault-injection primitive. The
remaining host-parse surface is the COT fields and the FSP message framing (§9.2,
§9.7), not the image content. The one residual use of the primitive would be a
TOCTOU race between the FSP's hash read and its decrypt read; the uniform `0x33`
behaviour suggests a local copy, and the window is not characterised.

The instrument is kept for regression: `phase2b/fmc_buffer_probe.sh` dumps the
buffer at the three points and applies one tamper variant per run (Appendix F.13).

---

## 10. Lever: the SR-resume path

### 10.1 The trigger and what the host builds

A **device-level** suspend/resume cycle (`pm_test=devices`, then `mem`) runs the GPU
callbacks in ~8 s without powering the machine down, and both cards come back (E42).
On resume the boot takes `bootMode=1` (`KGSP_BOOT_MODE_SR_RESUME`), and the FMC is
handed `GspFwSRMeta` instead of `WprMeta`:

```c
typedef struct {
    NvU64 magic;                          // 0x8a3bb9e6c6c39d93
    NvU64 revision;                       // 2
    NvU64 sysmemAddrOfSuspendResumeData;  // the radix3
    NvU64 sizeOfSuspendResumeData;
    NvU32 internal[32];                   // "for use by secure ucode", zero
    NvU32 flags;                          // 0
    NvU32 subrevision;
    NvU32 padding[22];
} GspFwSRMeta;
```

The host zeroes it and fills every scalar field. The radix3 page table is built by
`kgspCreateRadix3` in **unprotected sysmem**. The state size is
`frtsOffset + frtsSize − (nonWprHeapOffset + nonWprHeapSize)` = `0xcde0000`
(231.875 MiB) — exactly the WPR span measured at boot. So the region HS saves and
restores is the firmware code + heap + FRTS block.

This is the surface that matters: a magic-gated host structure carrying a pointer to
a host-built page table, consumed by secure ucode, reachable with a cheap,
repeatable cycle.

### 10.2 A bad magic hangs, and the log blind spot

`SRMeta.magic = 0xdeadbeefdeadbeef` hangs the resume: the machine did not come back
and was rebooted (E43). The previous boot's journal ends at `Filesystems sync`,
because journald is frozen immediately after that point and post-freeze printk is
only flushed on a successful resume. A failed resume therefore leaves **no
host-visible log**, and the ring buffer is lost on reboot.

Attribution rests on the stock cycle completing with the same trigger and the same
build; the only change was the magic. So secure ucode consumes it, and the failure
mode is a hang, not a structured error.

Consequences:

- The SR oracle is a **binary test** (resumes vs hangs) until an out-of-band console
  is added. netconsole is the natural choice (a printk backend, survives the
  freeze); `ttyS0` if serial capture is available. **Phase markers** — small files
  written at prepare / save / resume-start / restore-done — are the cheaper fix and
  were the next step.
- On a hang the script's traps do not run: the compiled defines stay armed and the
  stock driver is not restored. The tree was reset manually, and the COT/WprMeta
  oracles now clear the SR defines on entry.
- Runtime PM is a plausible non-freezing trigger (both GPUs are `power/control=auto`
  with ~200 ms accumulated runtime-suspend). Whether that path exercises SR
  prepare/restore is untested.

### 10.3 The saved state is encrypted

Dumping the host-built radix3 data region at resume gives 231.875 MiB per card
(E45):

| Metric | Value |
|---|---|
| Zero 1-MiB chunks | 97 / 205, identical mask on both cards |
| Nonzero spans | 0–7, 11–17, 112–204 MiB (108 MiB used) |
| Entropy, nonzero chunks | **7.9998 bits/byte** |
| ELF / WprMeta / SRMeta magic / vendor strings / compression headers | none |
| Bytes equal between cards outside zero chunks | 2,258,261 of ~108 MiB |
| FEAT/selector constants | 0 |

Editing the saved image to change selectors is closed. The failure mode also
explains the magic hang: the structure is validated before anything is decrypted.

### 10.4 The radix3 is plaintext and fully mapped

The second dump covers the whole descriptor (`0xce49000` per card; state
`0xcde0000`, data at `0x69000`) (E46):

| Level | Content |
|---|---|
| root (1 page) | `root[0]` → L1 at `+0x1000` |
| L1 (1 page) | `L1[0..102]` → 103 L2 pages |
| L2 (103 pages) | **52,704 nonzero, unique, 4K-aligned PTEs** in 52,736 slots |

The data pages sit in **52 physical runs, mostly 1,024 pages (4 MiB)**. Geometry
matches the driver exactly: 52,704 × 4 K = the state size, and 1 + 1 + 103 table
pages = `0x69000`.

The ciphertext is **per-boot and per-card**: zero of 27,322 nonzero pages match
across boots, and zero of 27,427 match across cards. No fixed keystream, no
replayable capture.

### 10.5 What remains on this surface

HS parses, before any decryption: the `SRMeta` fields (`magic`, `size`, radix3
pointer) and the **plaintext PTEs**. A malformed PTE is the last structural probe —
at suspend HS would write ciphertext to the chosen physical address; at resume it
would read from it. The outcome is blind without netconsole or phase markers.

Status: `SRMeta`/radix3 structure **LIVE**; state editing **CLOSED-MEASURED**;
whether HS validates a host-chosen page table is **OPEN**.

**The resume boot reuses the cold-boot image.** `kgspBootstrap_GH100` re-sends the
existing `pCotPayload` and keeps the already-mapped GSP-RM image on
`KGSP_BOOT_MODE_SR_RESUME`; it does not re-read `gsp_ga10x.bin`. Swapping the
firmware file between module load and resume therefore cannot change what runs at
resume — only the restored state can (E61).

---

## 11. Lever: the plaintext corpus

### 11.1 The vBIOS

**Where it is.** The flash sits behind the PROM aperture at BAR0 + `0x300000`; on
GB202 the image starts at BAR0 + **`0x338000`**, with a `0x38000` head before it
(E04). The PCI expansion ROM BAR exposes only the two PCI images; the rest needs
the PROM window. There is no ERoT on this board.

**Image chain** (little-endian PCI structures):

| Offset | Size | Type | Notes |
|---|---:|---|---|
| `0x000000` | `0xFA00` | PciAt | `PCIR` @ `0xCA0`; `10de:2b85`; BIT at `0xDF0` |
| `0x00FA00` | `0x18000` | EFI | `NPDE` clears `last_image` |
| `0x027A00` | `0x0FA00` | FwSec | first partition |
| `0x037400` | `0x9E800` | FwSec | last image; extends past the 1 MiB readable window |

**BIT table.** Twenty tokens at image offset `0xDF0`. `BIOSDATA` decodes to the
`nvidia-smi` version. The Falcon-ucode table (token `0x70`) is at image `0x64E9D`
(after the `+0x18000` EFI-image correction), 35 entries: **four real images and two
placeholders** (E66; E04 read the placeholders as "beyond window"):

| App ID | Target | vDesc | Encrypted | Body |
|---|---|---|---|---|
| `0x07` | `0x06` | 6 | yes | `0x6FDF0`–`0x8FFF0` |
| `0x19` | `0x01` | 6 | yes | `0x90040`–`0xB1B40` |
| `0x15` | `0x01` | 6 | yes | `0xB1C80`–`0xB7780` |
| `0x23` | `0x0E` | 6 | yes | `0xB780C`–`0xD5A0C` |
| `0x18` | `0x01` | — | — | placeholder: descriptor reads `0xBADF1100` |
| `0x24` | `0x0F` | — | — | placeholder: descriptor reads `0xBADF1100` |

The four real bodies begin with encrypted code (entropy 8.0); only app
`0x23`/target `0x0E` has a plaintext data tail (`0xC8000`–`0xD5A0C`, entropy 2–3,
after a ~2 KiB header at `0xC780C`–`0xC8000`); it contains
`0xFFFFFB8F`, `0xFFFFFBFF`, `0xFFFFFF8F`, `0xFFFFFF0F` and a large `0xBADF5040`
poison field. The PLM values are in that data, not in a table carrying the FEAT
address. Target IDs are not publicly mapped; the PLM-bearing image is consistent
with the SEC2 class identified by the public cmp170hx analysis, but
"app `0x23` = SEC2" remains inference.

**No FWSEC µcode.** The driver looks for app IDs `0x05`, `0x45`, `0x85`; none is
present. That is consistent with the FSP-based boot chain.

**No rate constants.** A 32-bit scan of the whole 819,200-byte image finds zero
occurrences of `0x00823804/18/1c/20`, `0x008207d4/d8`, `0x0082059c`, `0x008200fc`,
`0x008203f0`, `0x0082074c`, `0x00504204`, or the block bases; the x86 option ROM
has no absolute MMIO store into `0x0080xxxx`–`0x008fxxxx`.

**No FEAT address either (E66).** A full scan of the 1 MiB image and the 2 MiB
aperture, on both cards, in either endianness and with the devinit address flags
(`0x20000000`/`0x40000000`/`0x80000000`), finds zero occurrences of
`0x00823800/04/08/0c/10/14/18/1c/20`. No devinit opcode (`0x6E`, `0x7A`, `0x48`,
`0x47`, `0x10`–`0x13`, `0x20`–`0x23`, `0x2C`, `0x58`, `0x91`) carries an address
in `0x823800`–`0x8238FF`. The only register-address list is a 72-entry 64-bit
FUSE/strap table at `0x638E5` (`0x820800`–`0x8221A4`), and it has no FEAT entry.

**The full 2 MiB aperture** (E47) shows what the earlier dump missed:

| Range | Content |
|---|---|
| `0x00000`–`0x38000` | head: `4cc0` tag, FF fill, `NVFW` at `+0x1000`, **encrypted blob `0x1400`–`0x36a40`** (entropy 8.0), plaintext board metadata `0x36a40`–`0x36a90`, FF |
| `0x38000`–`0x138000` | the vBIOS image |
| `0x138000`–`0x200000` | not flash: every dword is the PROM sentinel `0xBADF1100` |

The head is 99.65% identical between the two cards (790 differing bytes: the
metadata block plus seven longer runs). The metadata is plaintext board data —
vendor codes `pcp` (ZOTAC) / `ask` (InnoVISION) with part and board IDs. The 218 KiB
blob is encrypted; `NVFW` is a marker surrounded by FF, not a parseable header.

**The PMU/devinit question.** The PMU runs devinit from the vBIOS before the
driver. The driver contains `kgspParseFwsecUcodeFromVbiosImg_IMPL`, `KernelPmu`,
PMU post-load work items, and many `NV_DEVINIT_ERR_*` strings. The earlier closure
("the PMU runs at LS/PL2, so the PL3-only PLM blocks its writes") is **withdrawn**:
the PLM's reset value is `0x80842bcf`, which admits L2 writes, and the PMU is the
leading candidate for the pre-lock FEAT writes (E65). Warm reboots leave
`SS0`/`SS1` unchanged, so the host POST/devinit path is not the SS writer; the
re-lock of the PLM after an FLR happens autonomously after the device is enabled,
before the first open. The executable devinit firmware is in the encrypted head
blob or the FwSec images rather than the plaintext tables, so the writes cannot be
read from the plaintext corpus. Status: **writer OPEN; table route CLOSED (E66)** —
PMU devinit versus FSP/BootROM/hardware remains, but no plaintext devinit table or
script references the FEAT bank, and the DEVINIT tables/scripts are
HS-authenticated (GSP-RM `NV_UDE_ERR_DEVINIT_*AUTHENTICATE*` strings). The
custom-VBIOS table edit cannot reach the writer.

**Conclusion.** The plaintext vBIOS layer is board configuration, not executable
devinit bytecode. The executable boot firmware is the encrypted head blob or the
FwSec images. "Who writes `SS0`/`SS1` at boot" cannot be separated further from
plaintext, but E54/E64/E65 fix the timing and the privilege: a GPU-side devinit
action writes the bank while the reset PLM admits L2 writes and locks it afterwards;
the PMU is the leading candidate, with the FSP/BootROM or hardware not excluded.
The FMC, driver, and GSP-RM do not write it. The table-edit route is closed (E66):
no plaintext table names the FEAT block, the only PLM values are in an
authenticated ucode data section, and the DEVINIT tables/scripts are
HS-authenticated with AES-ECB.

### 11.2 The GSP-RM image

`gsp_ga10x.bin` is a 72.8 MB RISC-V ELF with a large plaintext `.fwimage` and
per-chip signature sections. It is shared across GA10x/AD10x/GB20x; Blackwell
behavior is selected by chip tables inside the image (E01, E13, E17). The
decompilation method and its traps are in Appendix G.

**Address model (E67).** The `.fwimage` has a `0x18F000`-byte wrapper; the loaded
ELF64 RISC-V image starts at file `0x18F000`, with code linked at
`vaddr 0x01000000` (`filesz 0xDCD000`, RX) and data at `0x04000000`
(`filesz 0x1A1000`, RW), entry `0x01A0F3DA`. It is loaded at core address `0x01000000` (identity in the
core's address space; **not** host FB PA `0x01000000`, which reads zero — E74)
and runs at runtime VA `link + 0x92000000`. Therefore
`file offset = link VA − 0x00E71000`. The Ghidra file-offset formula
(`file offset = Ghidra VA − 0x01000000`) is correct for the file, but a Ghidra
address is not a runtime address: `link VA = Ghidra VA − 0x18F000`, and the
runtime VA is `link VA + 0x92000000`. This is the live/static delta E60 observed.

The local static split (69 module files) gives an approximate map. Function counts
are for navigation, not ground truth:

| Module | Functions | Notes |
|---|---:|---|
| registry | 534 | includes the registry parser `FUN_ram_011ac464` |
| platform | 434 | is_geforce / Quadro / self-hosted |
| gr_fecs | 984 | FECS/GPCCS/context-switch interfaces; `0x409xxx` |
| sec2_acr | 22 | SEC2/ACR/FWSEC interfaces |
| pmu_devinit | 10 | PMU/devinit strings |
| fsp_fmc | 7 | FSP/FMC strings |
| memory_wpr | 25 | WPR/FBPA |
| display | 482 | display registry keys and code |
| pcie_bif | 9 | BIF/LTR/PCIe strings |
| logging_debug | 600 | NVRM/assert/dump |
| libos | 1,539 | kernel/task/rootfs/memory pool |
| crypto | 454 | AES/RNG/PKA/CCC |
| inforom | 158 | inforom |
| rm_core | 3,044 | generic RM core |
| feat_rate | 0 | no FEAT/SS access anywhere in the binary |

The ~12k "dynamic communities" are structural clusters named by their top strings
(`community_0_KDASHARE`, `community_1_NV_FWSECLIC...`), not clean source modules.

**What the image contains:**

- Plaintext registry strings, error strings, and code.
- A FEAT readout decoder, `FUN_ram_015ffae8`, which reads fuse HAL offset `0x3818`
  (i.e. `0x823818`) and fills the getter's nine bytes.
- A second implementation of the same method, `FUN_ram_015ff1dc`, selected for
  descriptor variants `{5…9}`; it reads register `0x9668` instead and produces the
  same layout. The DP byte comes from a second slot, `FUN_ram_01615a40`, which
  extracts `FEAT_READOUT_1[30:28]`.
- A per-chip HAL table initializer, `FUN_ram_01c1c374`, which installs the decoder
  at `obj+0xC20` and the context functions at `obj+0xD00`. The object is `0x3E40`
  bytes, built by `FUN_ram_01acd340`.

**The reference-audit correction.** An early scan reported the decoder as
statically unreferenced. That was wrong: the materializations use a **negative
20-bit `auipc` immediate**, five of them inside the initializer. Ghidra's reference
manager also missed them because the containing function was never disassembled.
The corrected scan is part of the standard method (Appendix G.4). The decoder is
table-installed, chip-selected code, not dead code.

**What remains unresolved.** The factory `FUN_ram_01acd340` has **no static
references at all**, so how the class is instantiated is open. The slot's caller is
whatever invokes `obj+0xC20`. Host instrumentation shows the values arrive from the
GSP at module load; a one-instruction GSP-RM patch is rejected by the FMC (`0xaff`),
so GSP-side tracing is unavailable (§11.5).

**The buffer, not the image.** The read path is real; the write path is nearly
empty. E58 find one `SS0`/`SS1` write method (`FUN_ram_0160f1bc`), installed at
`obj+0x938` for variants not in `{5..9}`. Its helper (`FUN_ram_01c60868`) attempts
a direct BAR0 MMIO store (the `+0xb48` field is the BAR0 base, not a shadow), but
the method has no visible 4-argument caller and any PL2 write after the lock is
dropped by `FEAT_OVR_PLM`. No computed-offset write to `FEAT_OVR_PLM` exists.
Neither this method nor any other plaintext GSP-RM path accounts for the observed
pre-boot values; the writer is outside the image, in the GPU-side devinit
(E64/E65).

### 11.3 The host driver

595.91.07 is an exact upstream tag, so the running module can be rebuilt and
compared in source (E16). The driver:

- Fetches the selectors at GR init and caches them.
- Exposes three GET controls and no SET (`§2.5`).
- Contains **no literal reference** to `0x823804/18/1c/20`, `0x8207d8`, `0x8207d4`,
  `0x82059c`, `0x8200fc`, `0x8203f0`, or `0x504204`.
- Has exactly one FEAT-bank access: the ECC readout at `0x823814`.
- Contains `kernel_gsp_gb202.c`, which is a 63-line, two-function vGPU-only HAL
  (called only under `bVgpuGspPluginOffloadEnabled`, introduced in 580.65.06) and
  does not override reset or COT. GB202 still dispatches to `kgspResetHw_GB100`,
  `kgspSetupGspFmcArgs_GH100`, and `kgspBootstrap_GH100`.

Instrumentation (E14) confirms the values arrive **from the GSP at module load**,
and that the host boot structures (`GSP_ARGUMENTS_CACHED`, `GSP_FMC_BOOT_PARAMS`)
carry no rate field. The driver is telemetry, not a lever.

### 11.4 FMC signature and encryption analysis

The container algebra and signature envelope are in §4.3. Three results constrain
the GA100-ECB shortcut:

**The GA100 test-key route does not apply (E06).** The CMP 170HX work showed
GA100-era Falcon blobs use AES-128-ECB with a numbered debug test key (index 37),
with identical debug/prod cleartext. The only public oracle is the zero-padding
known-answer test `AES-ECB(key37, 0×16) = 717d1494…`. Three tests against GB202:

| Test | Result |
|---|---|
| Zero-padding fingerprint in every artifact | **0 hits** |
| ECB block structure | FMC ≤ 1 repeated block; vBIOS µcode bodies 512/512 distinct |
| 132,240 structured key candidates vs the KAT | no match |

The exact permutation is unpublished; a full search is 16! ≈ 2.09 × 10¹³
candidates (~1–3 h on two 5090s). The GB202 tests rule out the
**ECB-with-zero-padding** shape, not the key itself: an FMC in CBC/CTR/XTS, or
compressed before ECB, would show none of those three signs. The key/ mode
question is developed in §11.6.

**Encryption properties (E05).** Body entropy 7.999; no repeated ECB blocks; the
prod/debug XOR has the 1/256 chance rate; the header carries no nonce. Nothing in
the encrypted region is recoverable without the key.

**Availability (E02/E03).** The FMC ships in both variants, encrypted, with
byte-identical plaintext wrappers. The debug signing key is in the retail driver;
the debug encryption key is not.

**The bootloader image is opaque (E68/E69).** `GspRmBoot_GB202` ships as a raw
290,816-byte (`0x47000`) blob in the driver bindata (prod at file `0x4d6a58`,
debug at `0x51da78`), not as the FMC's `0x48`-header container: entropy is 7.999
across the whole image, there is no plaintext header, size algebra or trailer, and
the prod/debug XOR has 1,167 zero bytes in 290,816 (**0.401%**, the chance rate) —
no shared keystream. Its size and address match the image observed executing at
`0xefd00000` during boot (§8.7), and the FMC authenticates it: a one-byte
ciphertext flip draws `0xaff`/info `0xb`, the same code as a patched GSP-RM ELF
(§9.3.5, E69).

### 11.5 The signed-image boundary

Patching a single instruction in the GSP-RM is rejected before the image runs
(E15):

```
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
```

A four-byte change (`jalr x0, 0(ra)` at `FUN_ram_015ffae8`) is enough to fail the
per-chip `.fwsignature_gb20x` authentication. Restoring the original firmware brings
both cards back without a reboot. GSP-side instrumentation is therefore unavailable
on retail silicon, and proving the decoder's live caller requires the PL3 problem
itself.

**The signature section carries no host key.** `.fwsignature_gb20x` is `0x1000`
bytes: a 20-byte header (`0x00020001`, size `0x8c8`, count `0x0c`, `0x0101`, stride
`0x200`) followed by four 384-byte high-entropy blocks on a `0x200` stride. It
contains no SHA-384 of `.fwimage`, no valid P-384 point at any `0x04` candidate, and
no block shared across the ten chip sections — the payload differs in ~1,530 of
~1,545 nonzero bytes, and only the header is constant. The GSP-RM verification key
is therefore fused or inside the FMC, not supplied by the image, so this anchor has
no key-substitution target either (E61).

### 11.6 FSP/FMC encryption and key-recovery potential

The boot chain has four signed/encrypted layers, and only one of them is a
software-key target:

| Layer | What it is | Crypto | Key | Recoverable? |
|---|---|---|---|---|
| FSP | RISC-V security processor, immutable BootROM; root of trust | ROM-resident, no host image | fused/HW | **No corpus** |
| GSP BootROM | immutable ROM | ROM | fused | No |
| FMC | host-loaded HS bootloader; `0x48` plaintext header + encrypted body; ECDSA P-384 / SHA-384 signature | mode unknown: no ECB repeats, no nonce, entropy 7.999 | debug FMC uses a debug key; production likely `csecret(6)` in SCP | **only software target** |
| SEC2 `BooterLoadUcode` | HS booter; GA100/GA102/AD102 debug images | AES-128-ECB | test key #37 (MD5-IV permutation) | yes on GA100/GA102/AD102; **negative on GB202** (revs 76–77) |
| GSP-RM | post-boot RISC-V firmware | plaintext | — | available |

**FMC facts.** Header `0x48`; body = `[code][data][manifest 0xA00]` (order
measured, E73); entropy 7.999; no repeated 16-byte blocks; no nonce; the
prod/debug bodies differ by 99.6%; the debug signing key is public and the debug
encryption key is not (E05). The GB202
test-key checks are negative: no key37 KAT, ≤1 repeated block, 132,240 structured
candidates no match (E06). That says the **GA100 ECB scheme does not visibly
apply**, not that the FMC is unbreakable: an FMC in CBC/CTR/XTS, or compressed
before ECB, would show none of those three signs.

**The test-key route is real and proven through Ada.** The GA100/GA102/AD102
debug booters are AES-128-ECB with numbered test key #37, a permutation of the
MD5 initialization vector; debug and production plaintext are identical, so the
debug image yields the production logic. The public oracle is
`AES-ECB(key37, 0×16) = 717d1494…`; the decoded AD102 debug IMEM is public as
SHA-256 `7cdc788c…` (the same hash the Ada decoder produces). The key itself is
**not** in the public gist or in the Ada/TOTORONG trees; the upstream projects
keep it private. The full 16! permutation search is the published path: ~2.09 ×
10¹³ candidates, ~1–3 h on two 5090s with a custom kernel. The local
`fmc-analysis/scripts/key37_search.py` is the scaffold; it only tests 132k
structured candidates, not the full permutation.

**Result (2026-10-28).** The full 16! search completed on both 5090s
(20,922,789,888,000 candidates; ~530 s per half; ~19.7 G keys/s per GPU):
**no match**. Under the zero-block KAT, the key is not a plain permutation of
the MD5-IV bytes. The next checks are the FF-block KAT (the gist's disputed
control), the index-37/byte-replacement variants, the round-key-reversal hint,
and the FMC first-block oracle. **(This result is invalid: the enumeration bug
below shows the pass was not exhaustive. Re-run pending.)**

**Kernel ideas from the literature (2026-10-28).** Rolling 4-word round-key
schedule instead of the 44-word expansion (Yang & Goodman 2007; Hansung
bitslicing dissertation): **+5%** (10.5 → 11.0 G keys/s per 5090). Conflict-free
T-table padding (cihangirtezcan): neutral — the four lookups already use
different byte positions, and the `+1/+2/+3` table offsets cannot change
intra-instruction bank conflicts; the lever is bank replication across lanes
(rev 74), not padding. Two-key ILP, the cheap form of the 32-key bitsliced
design: **−20%** (8.4 G/s), register pressure/occupancy; the wide multi-key
design is not a free win for AES-128 on this part. `key37_cuda --ff` now
supports the FF-block KAT.

**FF and round-key passes (2026-10-28).** FF-KAT 16! (`AES(K, FF×16) = 717d…`):
**no match** — 20.3 G keys/s per 5090, 515 s per half. Last-round-key transform
(K = round key 10 of `schedule(P)`, `AES(K, 0×16) = 717d…`): **no match** —
14.2 G keys/s per 5090, 735 s per half. Three exhaustive derivations are now
negative: the debug key is not a plain MD5-IV permutation under either control,
nor the last round key of that schedule. The next moves are the actual key
source (gist comments/revisions, TOTORONG fixtures), the FMC first-block oracle,
and only then the index-37 variant.

**Invalidated by an enumeration bug (2026-10-28).** The zero, FF and round-key
16! "no match" passes above — and the FMC first-block oracle run — are **invalid**.
`unrank` decoded the factoradic digits in colexicographic order
(`idx = rank % (16−i)`, taken from the pool end) while `next_perm` walks
lexicographic order. Each shard therefore started inside another shard's range:
the passes covered overlapping subsets, not the whole of 16!. The symptom was one
key recorded at ~128 ranks spaced ~16!/128, and the FMC oracle's 5,706 hit lines
collapsing to 122 distinct keys with 0 valid bodies. The fix is the standard
lexicographic unrank, `idx = rank / (15−i)!; rank %= (15−i)!`, with the pool
removed in ascending order; it is applied in both `key37_cuda.cu` and
`key37_factoradic.c`. The corrected passes were subsequently re-run and are
recorded below: zero-KAT, FF-KAT and last-round-key are all negative (revs
76–77), and the `c09`/`c11` FMC oracle passes are negative (revs 75–76). The
fixed tools now self-test: boundary ranks (0–4, 14!/15! edges, half-range, 16!−2/−1),
20,000 random consecutive-rank chain checks, 64-shard tiling, a 4,096-thread ×
64-rank device partition-window digest (no gaps, overlaps or reordering), and a
hit-writer dedup test that collapses and counts exact duplicates. A 5×10⁹
corrected FMC window produced 5 distinct keys at distinct ranks (no duplicates).

**Inverse T-tables for the FMC oracle (2026-10-28).** The byte-wise
`aes_decrypt` was replaced with Td0–Td3 (InvSubBytes + InvShiftRows +
InvMixColumns fused into one lookup per byte) and the equivalent inverse key
schedule; the round-key transform `dw[r] = InvMixColumns(w[r])` uses four
raw-byte U tables, so it costs four lookups per word with no S-box step. A/B in
one session, with the zero-KAT reference steady at 17.4 G/s before and after:

| Oracle path | Registers | Rate per 5090 |
|---|---|---|
| byte-wise `aes_decrypt` (baseline) | 124, 208-byte local stack | 2.47–2.50 G/s |
| Td + U, precomputed 44-word schedule | 96, no spills | **4.66–4.72 G/s** |
| Td + U, rolling backwards-derived schedule | 72 | 3.28 G/s |
| Td + U with `__launch_bounds__(256,3)` | 80, small spills | 4.24 G/s |

That is **1.89×** over the byte path for the same hit sets: over the first
5×10⁹ keys both oracles produced the identical five hits (same mode, key, rank
and plaintext block). The rolling backward schedule was expected to win on
occupancy but lost to its dependent key chain; the launch-bounds variant lost to
spills. Two 5090s now sustain ~9.4 G/s on the both-mode oracle, i.e. ~37 min for
a corrected 16! FMC pass (the byte path was ~70 min under the same clocks).
Selftests cover the FIPS inverse vector, byte-vs-Td agreement on eight keys, and
the combined forward/inverse routine against the reference kernels.

**Bank-replicated tables (2026-10-28).** The next bottleneck is the shared-memory
load path, not ALU or occupancy. A microbenchmark on the 5090 (8 independent
lookup chains, 2 blocks/SM) gives 5.17 × 10¹² random LUT loads/s and 6.28 × 10¹²
with 32-way bank replication (+21%); RF=16 already reaches 6.30 × 10¹². The
device allows 100 KB shared per SM, 48 KB static per block. A new oracle variant
stores T0 and Td0 as `tab[256][16]` and has each lane read its own column
(`tab[idx*16 + (lane & 15)]`), deriving T1–T3 and Td1–Td3 with rotates; loops are
unrolled so `w[44]` stays in registers, and `__maxnreg__(128)` keeps 2 blocks/SM
without spills. Result: **11.69 vs 10.35 G keys/s (+13%)** in the same bench
session, with byte-identical hit sets over 5×10⁹ keys. Notably, both the oracle
and the zero-KAT search sit at ~5.4 × 10¹² shared loads/s (448 and 200 loads per
key), i.e. the same LSU ceiling of ~0.34 warp-loads/cycle/SM.

**What does not help (2026-10-28).** A short in-process bench mode (`--bench S`,
GPU 0) keeps the GPU loaded and measures the boost window; it agrees with the
long runs on ratios but reads higher in absolute terms (zero 27.6 vs 17.4 G/s
sustained). Launch-shape sweep (64–512 threads) moves less than 2%. Bitsliced
AES is not worth the rewrite: the 2024 GPU speed-record paper measures only
2.6–9% over the best table-based implementation (IEEE ESL 10.1109/LES.2024.3409725;
TPDS 10.1109/TPDS.2019.2911278), and our per-key key schedule, which bulk-AES
papers amortize, would have to be bitsliced too. The remaining lever would be
the 144 U loads/key for the equivalent-inverse key transform (31% of all loads);
replacing them with ALU InvMixColumns is slower on this part (byte path 7.3 vs
10.35 G/s), so they stay.

**Corrected 16! FMC oracle pass (2026-10-28).** After the enumeration bug in
revisions 69–71 was fixed (lexicographic `unrank`, `idx = rank/(15−i)!`), the FMC
first-block oracle was run exhaustively over the whole 16! space against the
debug GB202 container `c09_00691480_046200.bin` (287,304 bytes; C0
`ce14e61d4359e1da7673eb6fa349e095`) on both 5090s:

| Item | GPU 0 | GPU 1 |
|---|---|---|
| Rank range | 0 … 10,461,394,944,000 | 10,461,394,944,000 … 20,922,789,888,000 |
| Wall time | 1,031.1 s | 1,023.3 s |
| Sustained rate | 10.15 G keys/s | 10.22 G keys/s |
| Candidate hits | 3,119 | 2,996 |
| Exact duplicates | 0 | 0 |

Kernel `key37_cuda --fmc-rf`: RF=16 bank-replicated T0/Td0, T1–T3 and Td1–Td3
derived by rotates, 128 registers via `__maxnreg__(128)`, 2 blocks/SM, `--chunks
128`, 4096 blocks × 256 threads. Each key is tested in both first-block modes —
mode 0 `D(K,C0)` (ECB or CBC with zero IV) and mode 1 `E(K,0)⊕C0` (CTR with zero
counter). The two halves are disjoint; the merged hit file is 6,115 lines.

**Enumeration and duplicate check.** Each GPU wrote `3119 raw, 3119 unique, 0
exact duplicates, 0 same-key two-mode` (GPU 0) and `2996/2996/0/0` (GPU 1). With
the old colexicographic `unrank` every hit key appeared at ~128 ranks; the total
absence of duplicate `(mode,key,rank)` records here is the end-to-end proof that
the corrected enumeration visits each of the 16! permutations exactly once.

**Validation.** Each hit whose first block passed the structural filter was
decrypted over the whole 287,304-byte body in the corresponding mode and tested
as zstd (module decompress), gzip (zlib), xz (lzma), ELF (`readelf -h`), a
`nvfw_bin_hdr` (magic `0x10de`, header/load parse), the new-format magic
`0x3b1d14f0`, a nested FMC container, and NVFW TLV. Result: `hits=6115
tested=9136 valid=0` — 9,136 because each mode-0 hit is tried as both ECB and
CBC-zero, plus the CTR hits. The strongest-looking first blocks (zstd magic,
`nvfw-10de` within the first `0x20`) are chance 4-byte matches; none decrypted
into a parseable body.

**Interpretation.** Under AES-128 with the key restricted to a permutation of the
16 MD5-IV bytes and a zero IV/counter, the debug GB202 FMC key is not in the
family. Three explanations remain: the FMC key is unrelated to the SEC2 test key
and not an IV permutation; the mode is not one of ECB / CBC-zero / CTR-zero (CBC
with a header-derived IV, CTR with a non-zero counter, XTS, or
compressed-then-ECB are all still open); or the debug FMC is keyed per image or
part. This pass says nothing about the `c11` container (`0x30500`), whose
ciphertext differs even under the same key, and nothing about the booter KAT.

**Artifacts and reproduction.** Everything is under
`fmc-analysis/out/fmc_run_rf16_c09_2gpu/`: `gpu0/run.log`, `gpu1/run.log`,
`fmc_hits_all.txt` (6,115 lines), `fmc_hits.txt` (deduped), `counts.txt`,
`summary.txt`, `hits_test.log` (scores), `fullbody.log` (`tested=9136 valid=0`).
Runner: `fmc-analysis/scripts/run_fmc_rf16_c09_2gpu.sh`. The core of it is:

```
key37_cuda --device 0 --fmc-rf --fmc c09_00691480_046200.bin \
           --start 0 --count 10461394944000 --chunks 128
key37_cuda --device 1 --fmc-rf --fmc c09_00691480_046200.bin \
           --start 10461394944000 --count 10461394944000 --chunks 128
sort -u gpu0/fmc_hits.txt gpu1/fmc_hits.txt > fmc_hits.txt
python3 -I fmc_fullbody.py --hits fmc_hits.txt --container c09_00691480_046200.bin
```

**Rate note.** The sustained 10.2 G keys/s per GPU supersedes the 4.66 G/s figure
recorded earlier, which was taken in a low-clock window; under the short bench
the Td kernel measured 10.35 and RF=16 measured 11.69 G/s. At ~17 minutes for a
full 16! pass on two cards, testing each remaining mode variant is cheap.

**Next targets at that point, in order.** (1) `c11` debug container (`0x30500`)
over the same 16! space; (2) CBC with a header-derived IV; (3) CTR with a
non-zero counter; (4) the corrected booter KAT passes (zero/FF/round-key), then
still invalid. Items (1) and (4) were run and came back negative; (2) and (3)
remain the only cheap mode variants, and the header analysis below finds no
IV/nonce field to derive them from.

**Corrected zero-KAT and c11 pass (2026-10-28).** The corrected enumeration was
applied to the two primary oracles that were still invalid:

| Pass | Coverage | Time (GPU 0 / GPU 1) | Rate | Result |
|---|---|---|---|---|
| zero-KAT 16! | both halves | 442.5 s / 440.2 s | 23.64 / 23.77 G keys/s | **no match** |
| c11 FMC oracle 16! | both halves | 1,032.2 s / 1,023.5 s | 10.14 / 10.22 G keys/s | 3,014 + 3,131 hits, all unique, 0 duplicates; full-body `tested=9190 valid=0` |

The zero-KAT checks `AES-128-ECB(K, 0¹⁶) = 717d1494…` over all 16! orderings of
the MD5-IV bytes: no permutation satisfies it. That is the first valid run of
this test — revisions 69–71 were invalid — so, under the zero control, key #37
is not a plain MD5-IV permutation. The c11 (`0x30500`) debug FMC was searched
with the same RF=16 both-mode oracle; its 6,145 candidate first blocks were all
unique and none decrypted into a valid body. Together with revision 75 (c09),
the IV-permutation family does not open either debug FMC under ECB, CBC with a
zero IV, or CTR with a zero counter.

At this point the **FF-block control** and the **last-round-key transform** were
the two remaining readings of the same family; both were subsequently re-run
corrected and are negative (next paragraph). The FMC mode variants (non-zero CBC
IV / CTR counter) are the only cheap remainder, and neither container header
carries a nonce. Artifacts: `fmc-analysis/out/kat_then_c11_2gpu/` (`kat0/`,
`kat1/`, `c11/`, `status.txt`).

**FF and round-key controls, corrected (2026-10-28).** The two remaining
public readings of the test-key claim were re-run with the fixed enumeration over
the whole 16! space on both GPUs:

| Variant | Check | Time (GPU 0 / GPU 1) | Rate | Result |
|---|---|---|---|---|
| FF-block KAT | `AES(K, FF¹⁶) = 717d1494…` | 443.2 s / 440.9 s | 23.60 / 23.73 G keys/s | **no match** |
| Last-round-key | `K = rk[10](schedule(P))`, `AES(K, 0¹⁶) = 717d…` | 555.4 s / 553.3 s | 18.84 / 18.91 G keys/s | **no match** |

Together with the corrected zero-KAT (previous paragraph), **all three published
variants of the MD5-IV-permutation family are validly exhausted and negative**:
the key is not a plain IV permutation under either control, nor the last round
key of an IV-permutation schedule. The "test key #37 = MD5-IV permutation" claim
therefore does not reproduce on GB202 in any of its published readings. What is
left is speculative: intermediate round keys 1–9 (nine more passes, ~1.9 h),
FMC mode variants with guessed IVs/counters (no nonce material exists in either
container header), or the conclusion that the family does not apply to this part.
Artifacts: `fmc-analysis/out/ff_then_rk_2gpu/` (`ff0/`, `ff1/`, `rk0/`, `rk1/`,
`status.txt`).

**Variant algebra and the remaining mode space (2026-10-28).** The key pool's
structure prunes much of the speculative list for free. The 16 IV bytes are the
eight pairs `{x, x^0x11}` for `x ∈ {01,23,45,67,89,ab,cd,ef}`. The set of all
16! orderings is therefore closed under nibble swap (= XOR `0x11`), XOR
`0x22`/`0x33` and their complements including `0xFF`, and under any elementwise
bijection of the pool; position rotations and reversals are permutations of the
ordering itself. Those “XOR/rotate/nibble” variants enumerate the **same key
set** and need no passes. Only transforms that map pool bytes outside the pool
(bit-reversal, arbitrary XOR constants) create new keys, and there is no
evidence for any of them.

What is genuinely untested is the mode space. The `c09` header is magic
`03 04 48 00`, body size `0x46200` at `+4`, three more size fields, 16 zero
bytes at `0x38–0x47`, then the first body block at `0x48`; `c11` has the same
shape with size `0x30500`. Neither header carries a nonce or IV field. The only
structural variants left are (a) the first 16 body bytes are a cleartext
IV/counter with ciphertext starting at `0x58` — CBC `D(K,C0')⊕IV`, CTR
`E(K,IV)⊕C0'` — and (b) CTR with a small counter such as 1. Each is one
~17-minute two-GPU pass (a combined prefix kernel costs ~1.5 passes), but both
only pay off if the key is an IV permutation, which the three KAT negatives now
argue against. Intermediate round keys 1–9 are nine ~12-minute passes (~1.9 h)
with no support beyond the already-failed round-key-10 reading.

**All corrected 16! passes, consolidated (2026-10-28).** Every row used the
lexicographic enumeration, disjoint GPU halves, and the duplicate-counting hit
writer; every FMC row's hits were all unique with zero duplicates.

| Oracle | Check | GPU 0 / GPU 1 time | Rate | Result |
|---|---|---|---|---|
| zero-KAT | `AES(K, 0¹⁶) = 717d…` | 442.5 / 440.2 s | 23.64 / 23.77 G keys/s | no match |
| FF-KAT | `AES(K, FF¹⁶) = 717d…` | 443.2 / 440.9 s | 23.60 / 23.73 G keys/s | no match |
| last-round-key | `K = rk[10](schedule(P))`, `AES(K, 0¹⁶) = 717d…` | 555.4 / 553.3 s | 18.84 / 18.91 G keys/s | no match |
| FMC oracle `c09` | `D(K,C0)` and `E(K,0)⊕C0`, both modes | 1,031.1 / 1,023.3 s | 10.15 / 10.22 G keys/s | 6,115 hits, `valid=0` |
| FMC oracle `c11` | same | 1,032.2 / 1,023.5 s | 10.14 / 10.22 G keys/s | 6,145 hits, `valid=0` |

The five passes cover both debug FMC images and all three published readings of
the test-key claim, each over the entire 16! space. **At the time this read as
family exhaustion; E73 later showed the FMC oracle's plaintext filter was wrong
(the body starts with code), so the FMC rows test the wrong plaintext class.
The corrected code-first oracle re-ran both images under five hypotheses and is
also negative (revs 88–89).** The family is exhausted for the FMC under the
tested modes; the booter KAT rows stand on their exact known answers.

**Source check (2026-10-28).** The public gist has no comments and no key; its
files are the VBIOS analysis and the KAT. TOTORONG's `source/fixtures` contains a
256-byte PCI config only; `source/unlock/handoff.inc` and `assets.json` carry
selector checks and SHA-256 asset hashes, no key material. The Ada key remains
private. The “published debug test key” is therefore not public as bytes; the
three negative 16! derivations cannot be papered over by a source fetch.

**The production key is different.** `csecret(6)` is held in SCP hardware and is
shared across GA100 variants; the cmp170hx source frames its recovery as a
differential-fault-analysis hardware attack, and lists no public success. That
key is not software-recoverable.

**FMC mode and known plaintext.** The FMC has no nonce and no repeated ECB
blocks. The likely shapes are CBC with a fixed/derived IV, CTR with a fixed
counter, XTS, or compressed-then-ECB. This section originally assumed the first
body block would be a **known-plaintext handle** — a compression header (raw
DEFLATE / LZ4 / zstd), a Falcon IMEM/NVFW header, or a `0x10de` magic — giving a
candidate-key filter even without the ECB KAT. **That assumption is wrong for
the GB202 FMC: E73 measured the body as `[code][data][manifest 0xA00]`, so the
first block is RISC-V code.** The replacement oracle scores the block against a
parcel model; the compression-header case remains the one plaintext class it
cannot see (raw DEFLATE has no magic), but the exact size algebra and the
component sharing argue against a compressed body.

**Ranked recovery avenues.**

1. **Recover test key #37 with the full 16! search**, then test it on the GB202
   debug FMC (`c09`, `c11`) in ECB, CBC-zero, CTR-zero and XTS, using a structure
   oracle on the first block. Offline, no GPU firmware changes, ~1–3 h. This is
   the only concrete software recovery with a public KAT. **Done, negative**
   (revs 76–77): the zero, FF and last-round-key variants each covered all of
   16! and found no match.
2. **FMC-specific known-plaintext search.** If the test key fails, run the same
   test-key family against the FMC's first-block oracle. **Done for `c09` and
   `c11`, negative** under ECB, CBC-zero and CTR-zero (revs 75–76): 12,260
   unique first-block candidates and 18,326 mode expansions, no valid body.
   Those passes used a magic/header filter, which E73 showed tests the wrong
   plaintext class; the corrected code-first oracle re-ran both images under
   five hypotheses (ECB, CBC-zero, CBC-header-IV, CTR start 0/1) and is also
   negative (revs 88–89). The IV/counter-prefix variant listed here as the only
   remainder has now been covered, apart from IVs with no evidence behind them.
3. **Debug-key release/upstream.** The Ada and TOTORONG projects hold the decoded
   AD102/GA102 debug booter and, presumably, the key; their repositories ship the
   plaintext hashes and payloads, not the key. A released key or decoded FMC
   would unblock this immediately. Low effort, not under our control.
4. **Production `csecret(6)`.** DFA/voltage-glitch hardware; high risk, not
   software, and the debug FMC is the safer static target.
5. **FSP / GSP BootROM.** No image, no host path, no corpus. Closed.

**What decryption buys, and what it does not.** The FMC is the HS bootloader
that parses the COT/`WprMeta` and loads the GSP-RM; its code is the PL3 static
corpus (parsers, copy routines, gadgets). Debug/prod code identity means the
debug FMC is enough for static analysis. It does **not** give execution on a
retail card (debug fuse state is still required) or the production key.

**Bottom line.** The FSP is genuinely blind — it is ROM, and no host-visible
image or key exists. The FMC is not: it is the one obtainable HS image, and the
only question is its key/mode. The booter test key was searched exhaustively in
all three published variants and does **not** reproduce on GB202. The earlier
FMC negatives used a first-block magic oracle and the body is now known to start
with code (E73); the rebuilt RISC-V-parcel oracle has since re-run the whole 16!
space for both debug FMCs under five hypotheses and is **also negative** (3
chance records, all rejected by the full-code walk). The question is therefore
no longer the feasibility of the search but whether the published key derivation
applies to this part at all; a different key source (release/leak) or key family
is required.

**Oracle caveat.** The FMC 16! passes accept a candidate only if its first
decrypted block looks like a container/compression header (zstd/gzip/xz/ELF/NVFW).
The FMC body begins with code, so a correct key whose first block is not a magic
would be discarded. The FMC results are therefore "no key produced a recognizable
header", not "no key in the family"; a RISC-V-validity/entropy oracle is the
remaining cheap test (§16.2 #7, §17.1 #12). The KAT passes are unaffected — they
use an exact known answer.

**The FMC body layout, measured (2026-10-28, E73).** The caveat is not
hypothetical: the body starts with code. Two independent cross-image
comparisons settle the layout. For the GB202 production pair (`c04` and the
`GspRmBoot_GB202` prod image in `nvidia.ko`) and again for the debug pair
(`c09` and the debug GspRmBoot), with the GspRmBoot geometry from `WprMeta`
(manifest at 0, data at `0xA00` size `0xE800`, code at `0xF200` size `0x37E00`)
and the container header (code `0x37000`, data `0xE800`):

| FMC body region | Matches | Result |
|---|---|---|
| `[0, codeSize)` | `GspRmBoot[0xA00 + dataSize, ...]` | byte-identical prefix |
| `[codeSize, codeSize + dataSize)` | `GspRmBoot[0xA00, 0xA00 + dataSize)` | **byte-identical** |
| `[codeSize + dataSize, bodySize)` (the `0xA00` residue) | `GspRmBoot[0, 0xA00)` | **byte-identical** |

So the body is `[code][data][manifest 0xA00]`, and the manifest is the
GspRmBoot image's manifest. The FMC code is a prefix of the GspRmBoot code (the
bootloader carries `0xE00` more code bytes). The same three components appear
at different absolute offsets in the two images yet encrypt identically: there
is no chaining between components, so the mode is ECB or a per-component reset
(CBC-zero/CTR-zero per component). Block 0 of the code component is therefore
`D(K, C0)` (or `E(K,0) XOR C0` under CTR), and its plaintext is the first bytes
of the image entry — not a header.

**The RISC-V-validity oracle (E73).** `phase2b/key37_cuda.cu` gained a
`--fmc-riscv` oracle. `phase2b/build_riscv_logp.py` trains a 16-bit-parcel
log-probability table (65536 entries, int8 half-bit units) on the plaintext
GSP-RM code segment (14.4 MB, entropy 11.59 bits/parcel). Per key:

- **Stage 1** decrypts block 0 in both modes and scores its eight parcels
  against the table. Threshold `t1 = -256` (3.8 σ; exact random pass 7.6e-4 —
  the Gaussian approximation understates this bounded-support tail).
- **Stage 2** runs only for survivors: decrypts 8 blocks (128 bytes) and scores
  the ECB stream and the CBC-zero stream (one branch, since block 0 is the same),
  or the CTR-zero stream with counter = block index, threshold
  `t2 = mu·64 + 9·sd·sqrt(64) = -2102`. Stage 2 is conditional on Stage 1, which
  shares block 0, so the random tail is the *joint* event
  `P(S0 > t1 and S64 > t2) = 1.2e-14` by exact DP: ~0.5 false records per
  hypothesis over the whole 16! (five hypotheses after the mode extension,
  ~2.5 per run), at 99.92% clean-code recall. The CTR counter is the block index
  in the low 32 bits of a big-endian 128-bit block (word 3 = j); CBC XORs
  `D(K,C_j)` with the previous ciphertext block, not the previous plaintext.
- Hits carry the hypothesis (0 ECB, 1 CBC-zero, 2 CTR-zero, 3 CBC-header-IV,
  4 CTR start 1), the key, rank and the stage-2 score;
  `phase2b/fmc_riscv_verify.py` then decrypts the **whole code component** and
  walks every instruction as RV32/64 IMC. Compiled code is ~0.03–0.5% invalid
  (literal pools); random plaintext is ~9%.

Calibration on 19,481 GSP-RM function starts: Stage 1 retains 97.0% overall and
99.3% of the clean code region (`< 0xC00000`); Stage 2 (8 blocks, 9 σ) retains
99.92% of clean code, and the staged false-positive rate (exact DP on the
quantized table) is `1.2e-14` per hypothesis. The compact AES kernel
keeps the 64 KB table in L1 (12.9 KB shared, 2 blocks/SM) and sustains
**8.5 G keys/s per 5090** with Stage 2 enabled (9.0 G/s with it disabled; the
RF16 table layout was 2.8× slower because the table no longer fits L1).

**Controls (E73).** A synthetic container whose code component is the real
GSP-RM entry code, encrypted under the rank-0 key (`POOL` in order), is recovered
as exactly one hit with the correct key in every mode: ECB (mode 0), CBC-zero
(mode 1) and CTR-zero (mode 2), each with score -1533 for the 8-block window;
the full-code verifier accepts all three decryptions. The same key with random
plaintext produces no hit. A full-image synthetic (all `0x37000` code bytes)
passes the instruction walk at 0.046% invalid; a random key is rejected at 8.8%.
Re-scoring the 12,260 legacy first-block hits (c09 and c11) with the parcel
model gives medians of -297 Q, exactly the random mean, and only 7 of 12,260
cross `t1` — chance rate. The old "family exhausted" FMC result was therefore
measured with a filter that records random magics and would discard a correct
code-first key.

**The c09 re-run is negative (2026-10-29).** The whole 16! space was searched on
both 5090s with the code-first oracle (ECB/CBC-zero/CTR-zero, `t1=-256`, 8-block
Stage 2 at `t2=-2102`): 1375 s wall, 7.61 G keys/s per card, rc 0 on both, and
**0 hits** (expected chance records ~1.5, P(0|1.5)=0.22). Under the tested modes
the debug GB202 FMC is not decrypted by any MD5-IV permutation.

**Mode-completeness extension (2026-10-29).** The component-identity result rules
out whole-body chaining but not a *per-component* non-zero IV/counter. The oracle
now tests five hypotheses: ECB (mode 0), CBC with a zero IV (1), CBC with the
container's first 16 bytes (`03 04 48 00` + sizes) as the IV (3), CTR with
counter start 0 (2), and CTR with counter start 1 (4). An IV affects only CBC
block 0 (later blocks XOR the previous ciphertext), so the two CBC variants share
one stream and the header candidate is a block-0 re-score; CTR start 1 costs one
extra encrypt per key. A true CBC key can legitimately hit *both* CBC modes —
the header IV is a small mask, so the corrupted block 0 still decodes — and a CBC
hit therefore arrives as a pair; the genuine IV is the one whose block-0 plaintext
is real entry code (the higher score in the controls). Controls: all five modes
recover the rank-0 key and pass the full-code walk; random plaintext is rejected.
Rate with all five: **6.0 G keys/s per 5090** (the extra CTR encrypt, ~30%).

**Both combined runs are negative (2026-10-29).** c09 ran
`00:31:30Z → 01:03:12Z` (1902 s) and c11 `01:03:12Z → 01:34:59Z` (1907 s),
both GPUs rc 0, ~5.50 G keys/s per 5090 (11.0 G/s combined). Three chance
records were written in total — c09: one mode-4 (`CTR start 1`, rank
13,567,028,728,510, score -2097); c11: one mode-0 (`ECB`, rank
5,123,222,474,751, score -2089) and one mode-4 (rank 14,469,189,879,912, score
-2094) — and the verifier rejected all three at 8.6–8.9% invalid instructions
(random). The counts match the exact-DP expectation (~2.5 per container across
five hypotheses). **The debug GB202 and 0x30500 FMCs are not decrypted by any
MD5-IV permutation under ECB, per-component CBC with a zero or header IV, or CTR
with counter start 0 or 1.** The IV-permutation avenue is exhausted for the FMC
under all tested modes.

### 11.7 Verdict

The plaintext corpus is exhausted as a source of a rate writer:

| Component | Finding | Status |
|---|---|---|
| GSP-RM | reads `FEAT_READOUT_1`; writes neither override nor PLM; no dead keys | CLOSED-STATIC (E01/E13/E17) |
| `nvidia.ko` | telemetry only; no literals; GB202 HAL irrelevant | CLOSED-STATIC (E16) |
| vBIOS | plaintext structure, encrypted µcode, no FWSEC, no rate constants | CLOSED-STATIC (E04/E47) |
| FMC | encrypted; signatures verify; the body layout is `[code][data][manifest 0xA00]`, so the first block is code (E73). The IV-permutation family is negative on `c09` and `c11` under ECB/CBC-zero/CTR-zero **with the old structural first-block oracle**, which records random magics and would discard a code-first plaintext; every one of the 12,260 legacy hits re-scores as random. The RISC-V-validity oracle is built and self-tested; the **c09 and c11 16! re-runs are negative** under five hypotheses (ECB, CBC-zero, CBC-header-IV, CTR start 0/1): 3 chance records total, all rejected by the full-code walk. The same family fails all three KAT variants on the booter | CLOSED-MEASURED (family exhausted for the FMC under the tested modes) — E05/E06, E73, §11.6 |
| Patched GSP-RM | rejected at authentication | CLOSED-MEASURED (E15) |

---

## 12. Hazards and recovery

### 12.1 BAR0 aperture and BAR1 reads

- **BAR0 page scan.** A read-only scan of BAR0 `0x300000`–`0x400000` on a live GSP
  coincides with an identical GSP crash on both cards: Xid 13 → Xid 120 (load page
  fault, `cause 0xd`, `stval 0x250`, `pc 0x1368618`) → Xid 154. Causation is
  unproven, but the working rule is: **do not scan that aperture while the driver
  owns the GPU.** Read the flash through the single known-good window (`0x338000`).
- **BAR1 FB reads.** Reading four FB offsets through BAR1 (including the stock
  non-WPR heap, mid-WPR, and FRTS) returned zeros — and so did the intended
  positive control, the GSP access-map buffer at its previously observed physical
  address (E48). E74 explains it: BAR1 is bound to a VAS, not to FB physical
  addresses, and during the GSP boot the BAR1 VAS does not exist yet
  (`kbusInitBar1` runs in `gpuStateLoad`, after `kgspInitRm`); a manual mapping at
  that point oopses on a NULL PTE array. After boot, BAR1 offsets are still VAS
  offsets. The measured FB mechanism is the **BAR0 PRAMIN window** (64 KiB at
  BAR0 `0x700000`, moved with `kbusSetBAR0WindowVidOffset`), which reads the
  non-WPR heap correctly (E74). After the E48 reads, both GPUs reported
  `GPU requires reset`, telemetry was unavailable, and CUDA no longer initialized.
  The previous boot's journal confirms the same Xid 13/120/154 signature as the
  BAR0 scan (E49). This read path is a reproducible GSP-fault trigger and is
  operationally closed.
- **The WPR is unreadable from the host, but not by faulting (E74).** With the
  BAR0 window proven by the non-WPR heap control, reads from
  `frts − 0x50000` through FRTS return the repeating dword `0xbad0ac00` — a
  deliberate access-denied fill (entropy exactly 2.0, nonzero count exactly 3/4
  of the window, identical on both cards). Reads do not wedge the GPU and the
  window is restored afterwards. The boot image's own location
  (`frts − sizeOfBootloader` = `0x7f4279000`) lies in this poisoned range.
- **Neither result re-opens the firmware-read route**, which E10 measured shut
  independently.

### 12.2 Wedges

| Trigger | Failure mode | Cost |
|---|---|---|
| BAR0 scan / BAR1 FB read | Xid 154, GSP fatal | reboot |
| ICD `STOP` (E67) | GSP halt, heartbeat timeout, Xid 154 (`GPU Reset Required`) | reboot |
| `RmDisableCotCmd=0x10` | ioctl never returns | reboot |
| COT auth failure (`0x377`) / key rejection (`0x1db`) | WPR2 left up | reboot |
| `WprMeta.gspFwHeapSize` below minimum | WPR2 up, both cards | reboot, possibly cold power cycle |
| SR magic change | resume hang, no log | reboot |

`nvidia-smi -r` is not implemented on GeForce SKUs. The PCI `remove` path can spin
in the driver. A forced reboot (`systemctl reboot -f`, SysRq-B as fallback) is the
reliable exit; a cold power cycle if a warm reboot does not clear WPR2.

### 12.3 Recovery

Every script restores the stock DKMS modules in a trap and resets its compile-time
oracle defines. A hung SR run cannot run its trap, so the tree must be checked after
any SR experiment. Keep the restore commands with the scripts that use them.

---

# Part III — Assessment and frontier

## 13. Current state

| Area | State | Evidence |
|---|---|---|
| Premise | Cap is product segmentation, proven by the RTX PRO 6000 on the same die | §1.2.2 |
| Host driver | telemetry only; no rate writer | E16 |
| FEAT bank | PL3-gated after boot; writes silently dropped from PL0 and PL2. An FLR resets the PLM to `0x80842bcf` (L2+L3), and a GPU-side devinit re-locks it to `0xfffffb8f` autonomously before the first open | E08, E09, E58, E64, E65 |
| FUSE/OTP shadow | soft-read-only even where the PLM says writable | E12 |
| `SS0`/`SS1` | inert at stock; moving bits are enable-clear shadow state; vary across cold power cycles, not warm reboots; set by a GPU-side devinit, not the FMC/driver/GSP-RM | §2.3, E49, E58, E64, E65 |
| PLM persistence | Reset to `0x80842bcf` by an FLR, re-locked to `0xfffffb8f` after every device enable; a runtime PLM write does not survive a reset/probe | E64, E65 |
| `SM_ISSUE_RATE_MODIFIER` | writable, reasserted at context init, measured inert; no RM writer (value 5 is external) | E12, E58 |
| Registry keys | speed-select keys parsed and stored but inert; consumer is a boolean GR descriptor field, not MMIO; p2p bypass is display-only; boot keys live | E11, E50–E52, E58 |
| FECS command protocol | 29 IDs mapped; payloads are addresses/sizes/features; no selector; command-ID register read-blocked | E19, E20, E58 |
| FSP command surface | COT/caps/clock only; no memory/fuse/register/debug command; framing and response-identity issues open | E58 |
| GR context images | full 3.6 MB dumps on both cards; no rate word, no card-dependent field | E27 |
| HS memory windows | GSP EMEM empty; IMEM/DMEM absent; FSP EMEM L3-gated; SEC2 empty; **PRISCV ICD live at PL0**: host-writable, commands execute, `STOP` + `RDM` reads the 14.4 MB halted-core RM code segment (not WPR/FRTS). The block is closed through the whole HS boot phase; `RDM` is refused at an HS-window halt and at the LS transition, and after boot its aperture is the RM code segment only (boot image, data segment refused) | E10, E18, E21, E63, E67, E68 |
| FMC/FSP boot inputs | live oracle, ten codes; host controls WPR placement and heap size; key anchor enforced; the FMC container is bound to the COT hash (`0x33`); the bootloader size (`0x82e`) and manifest offset (`0x885`) are checked, and both boot images are authenticated (`0xaff`/`0xb`) | E28–E41, E61, E62, E69 |
| SR-resume | host-driven structure live; saved state encrypted; radix3 plaintext | E42–E46 |
| vBIOS | fully dumped (2 MiB aperture); encrypted head blob; no rate constants or FEAT addresses; DEVINIT tables/scripts HS-authenticated | E04, E47, E66 |
| vBIOS devinit-table route | CLOSED-STATIC: no FEAT address in any plaintext table/script; DEVINIT tables/scripts authenticated in HS mode with AES-ECB; PLM values only in the app `0x23`/tgt `0x0E` ucode data | E66 |
| Host FB read (BAR1 / BAR0 window) | BAR1 has no VAS during boot (a manual mapping oopses); the BAR0 window works and reads the non-WPR heap, but the boot image's WPR slot returns the access-denied fill `0xbad0ac00`. Route closed | E48, E74 |
| Remaining class | PL3 code execution, via a parser/structure bug in FSP, FMC, or HS SR code | §15 |

Reading the table: the mechanism is understood, the premise is proven, and every
host-reachable path that does not require PL3 has been measured and closed. The
FEAT bank's pre-lock writer is now located in a GPU-side devinit (most likely the
PMU), not in a host-reachable component; the L2 window is real but closed to the
host and to GSP-RM, and the vBIOS devinit-table route is closed as well (E66).
The last memory route is also closed: the decrypted boot image is inside the WPR,
and a proven host FB read returns the access-denied fill `0xbad0ac00` there
(E74). The frontier is narrow and specific — the host-facing structures
HS parses (the boot inputs and the suspend/resume metadata), plus the possibility of
a per-SM copy of the selector that the global bank does not cover.

## 14. What is proven, what is assumed

### 14.1 Measured on this hardware

- The FP32-accumulate path measures ~227 TF/s, and the local per-clock baseline is
  0.0777 TF/s/MHz. The 2× gap to FP16-accumulate is external (the local probe has no
  FP16-accumulate mode; §14.4).
- The two cards' differing `SS0`/`SS1` do not change the effective rate (E49).
- The whole FEAT bank is byte-identical before the FMC runs and after GSP-RM is up
  within a boot (E54); the SS words are invariant through 7.5 h and shutdown, and
  change only across cold power cycles (E64).
- `SS0`/`SS1` vary across cold boots on both cards (e.g. `41:00.0` `0x21240001` →
  `0x20240001` → `0x20260041` → `0x21265047` → `0x21265043`) and are identical
  across warm reboots and within a boot (E64).
- An FLR leaves `SS0`/`SS1`/`0x823808`/`READOUT_1` unchanged, resets
  `FEAT_OVR_PLM` to `0x80842bcf` (write mask L2+L3), and the PLM is re-locked to
  `0xfffffb8f` by GPU-side devinit between the PCI probe and the first open, with
  no host/RM code in the window (E65).
- The PLM's reset value admits PL2 writes; the pre-lock writer is GPU-side (PMU
  devinit is the leading candidate). The host is PL0 and is admitted by neither
  value (E65).
- The vBIOS static scan finds no FEAT address in any plaintext devinit table or
  script; the DEVINIT tables/scripts are authenticated in HS mode with AES-ECB;
  the only PLM values are in the app `0x23`/target `0x0E` ucode data (E66).
- The speed-select registry keys are parsed and stored but leave the rate and the
  bank unchanged on both cards (E50, E51).
- `SS0`, the rest of the FEAT bank, and the FUSE shadow accept writes and do not
  change (E08, E09, E12).
- `SM_ISSUE_RATE_MODIFIER` is writable, reasserted, and inert (E12).
- The FSP validates COT size (`0xd9`), alignment (`0xd6`), hash (`0x377`), and the
  public key (`0x1db`); the COT offset selects the FB base of the whole GSP-RM WPR
  (E29–E35, E41, E61).
- The FMC container buffer is byte-identical at copy-in, after the FSP response,
  and at release; the FSP does not decrypt in place or scrub it (E62).
- A one-byte change to that container — plaintext header or ciphertext body — with
  the COT hash stock is refused with `0x33` and leaves WPR2 up (E62).
- The FMC enforces `WprMeta.magic` (`0x827`), ignores `frtsSize` disagreement,
  honours `gspFwHeapSize`, and does not let `verified` bypass image authentication
  (E36–E40).
- The SR state image is encrypted, per-boot and per-card; the radix3 is plaintext
  and fully mapped (E45, E46).
- No known rate constant or FEAT-shaped field exists in the GR context image
  (E27).
- The RISC-V PRISCV block is at `0x111000`; the Falcon block ends at `0x110d4c`
  (E63).
- The PRISCV window is partitioned per master: of 512 common offsets, 66 are
  identical to host and GSP, 199 differ, 69 are host-only and 80 GSP-only (E63).
- The PRISCV ICD is host-writable at PL0: `ADDR0/1` and `CMD` retain their
  writes; `RSTAT` executes while the core runs; `RREG`/`RCSR`/`RDM` are rejected
  while running (`CMD[14]=1`, `0xbadfbadf`) and succeed after `STOP` (E67).
- `STOP` halts the core but leaves `CPUCTL[4]` clear; the halted PC is
  `0x93002ebc` (host `0x1113ec`), and `RDM` reads the 14.4 MB RM code segment
  at PA `0x01000000`–`0x01DCD000`; the WPR/FRTS are not reachable (E67).
- The loaded ELF starts at file `0x18F000`, is linked at `0x01000000`, and runs
  at runtime VA `link + 0x92000000`; the document's Ghidra VAs are `0x18F000`
  above the link/runtime VA (E67). It is **not** identity-mapped at host FB PA
  `0x01000000`: that PA reads zero through a proven FB window, so the ICD's
  `0x01000000` is an address in the core's space, backed by the WPR (E74).
- `0x111800–0x113fff` contains no debug module: 16 implemented dwords in two
  12-byte tables at `0x111f00`/`0x111f80` (E63).
- The ICD command/PC registers are blocked to the host (`0xbadf5620`) through the
  entire HS boot phase; they unblock ~155 ms after the COT response, while the
  boot image executes at `0xefd00000` (`0x47000` bytes, matching the host-supplied
  `GspRmBoot`), and GSP-RM starts ~0.5–0.6 ms later (E68).
- `STOP` in the boot-image window halts the core (`CPUCTL=0x380`) and
  `RPC`/`RREG` return the boot image's `pc`/`ra`/`sp`, but every `RDM` — including
  the `0x01000000` control — is refused (`0xbadfbadfbadfbadf`). The same is true
  at the LS transition (`0x930014bc`) (E68).
- After full boot `RDM` works only for the RM code segment: `0x01000000` returns
  ELF magic while `0xEFD00000`, `0x5DD00000`, `0x181D00000`, `0x04000000` and
  `0x96000000` are refused (E68).
- The full FSP PFSP window (`0x8f0000`–`0x8f3fff`) has no PRISCV core interface
  (no `CPUCTL`/`RPC`/ICD at `+0x3d0` or `+0x1000`); the FSP is not a debug-port
  target (E68).
- BAR1 is not a raw FB window: it is bound to the BAR1 VAS, and the VAS does not
  exist during the GSP boot (`kbusInitBar1` runs in `gpuStateLoad`, after
  `kgspInitRm`); creating a mapping there faults the kernel on a NULL PTE array
  (E74).
- The BAR0 PRAMIN window (64 KiB at BAR0 `0x700000`, base moved with
  `kbusSetBAR0WindowVidOffset`, restored afterwards) reads FB: the non-WPR heap
  at `0x7e72e0000` returns 58,707 nonzero bytes, entropy 7.6408, identical on
  both cards (E74).
- FB PAs `0x01000000`, `0x5dd00000` and `0x181d0000` are **zero** through that
  window. The decrypted boot image is not in open FB (E74).
- `[frts − 0x50000, frts)` (including the boot bin at `frts − 0x47000` =
  `0x7f4279000`) and FRTS itself return the repeating dword `0xbad0ac00`
  (entropy exactly 2.0, nonzero exactly 3/4 of the window) on both cards — an
  access-denied fill, not data. The WPR is host-unreadable (E74).
- The GSP-RM non-WPR heap is `0x7e72e0000` + `0x300000` (GSCI and `WprMeta`
  agree; the GSP log records the same init). It is byte-identical on both
  cards and holds a 64 KiB structured header, one `0x1910A2`-byte allocation
  at entropy 7.999 and zeros — no vtable pointer sets, no known handler VAs,
  no identifiers (E75).
- The WPR base is `0x7e75e0000`: the access-denied fill starts exactly at
  `nonWprHeapOffset + 0x300000`, so the published non-WPR heap size is exact
  (E75).
- `WprMeta` stock bootloader description: size `0x47000`, `cOff=0xf200`,
  `dOff=0xa00`, `mOff=0`, signature buffer `0x1000` (E69).
- A changed `sizeOfBootloader` (`0x47001`) draws `0x82e`; a wild
  `bootloaderManifestOffset` draws `0x885`; `bootloaderCodeOffset` and
  `bootloaderDataOffset` are not used; a 1 MB `sizeOfSignature` is ignored; a
  1 MB `sizeOfRadix3Elf` draws `0xaff`/info `0xb` (E69).
- A one-byte ciphertext flip in the host-supplied GspRmBoot image draws
  `0xaff`/info `0xb`, while the untampered second card boots: the bootloader is
  authenticated (E69).
- The GspRmBoot image is fully encrypted (entropy 7.999, no plaintext header);
  its prod/debug XOR is at the chance rate (0.401% zeros) — no keystream reuse
  (E68).
- After an FLR the FEAT PLM reads `0x80842bcf` from the reset to a re-lock at
  1156–1323 ms; the first GSP-RM PC appears at 3176 ms, so the re-lock is
  1853 ms before the only PL2 master (E70).
- The open→GSP-RM path is ~2.1 s, so an early open cannot fit the 1.32 s L2
  window even with zero delay (E70).
- `GPU_EXEC_REG_OPS` returns `NV_ERR_INVALID_ARGUMENT` (0x1f) for every
  `GR_CTX`/`GR_CTX_TPC`/`GR_CTX_SM`/`GR_CTX_QUAD` batch, with root, a live
  CUDA context, and every `grRouteInfo` flag; `FB` returns
  `NV_ERR_NOT_SUPPORTED` (0x56); `GLOBAL` works (E71).
- The host-supplied `GspRmBoot` buffer is byte-identical before the FMC reads it
  and after GSP-RM is up: 290,816 bytes, SHA-256 `f5f63a71…`, entropy 7.9835,
  both cards (`diff_bytes 0`) (E72).

### 14.2 Source-derived or documented

- The privilege levels and their names (nova-core `falcon.rst`; cmp170hx).
- The boot chain order (nova-core FSP patch, August 2026).
- The FMC container format, signature scheme, and key inventory (E05).
- The absence of literal register references in GSP-RM, `nvidia.ko`, and the vBIOS
  (E01, E16; static).
- The FECS command encoding and the GR context descriptor layout (E19, E20).
- The PLM field layout (`dev_gsp.h`; the Falcon v4 names above the low byte come from
  `dev_falcon_v4.h` and are *(source)* by analogy for the FEAT block, E53) and the
  sentinel encoding (`dev_pri_ringstation_sys.h`).

Two limits on this class of evidence. Some figures (the RTX 5090 D GEMM numbers,
the Ada comparisons) come from community reports rather than independent
reproduction, and the 5090 D / GB203M variants may differ. And the decompiled C is
not compilable: it can misidentify data as code and does not represent indirect
calls fully, so a static conclusion is a hypothesis until checked against the
instruction bytes or hardware.

### 14.3 Carried over by analogy from Ada/Ampere

These are the load-bearing assumptions that are **not** measured on Blackwell:

- `0` in a readout field means full rate, and the unlock target is all fields zero.
- The `SS0`/`SS1` enable-bit-3 + 3-bit-selector format.
- A PLM write mask with `[7:4] = 1000` means L3-only on this chip (the semantics are
  documented, the enforcement is measured, but the level *name* comes from
  nova-core).
- The prior unlock's persistence and FLR behavior — **falsified for the PLM on
  GB202**: an FLR resets the PLM and the GPU-side devinit re-locks it (E65).
- The PMU devinit is the pre-lock FEAT writer. The privilege arithmetic and timing
  fit, but the FSP/BootROM or a hardware re-latch are not excluded (E65).

### 14.4 Weak points in our own conclusions

- **The readout→rate mapping is not proven.** `FUSE_SS_FMLA32 = 3` yet the penalty
  is ~2×, not the enum's 1/8, and `IMLA1/2/4 = 3` runs INT8 at full rate. The
  "unlock target is all fields zero" is an inference from Ada and data-centre
  Ampere (A100, full rate, reads zero; E56), not a Blackwell measurement. A
  Pro-card readout (`0x823818`, `0x82381c`, `0x823820`, and the fuses if reachable)
  would settle it.
- **`0x82380c` is resolved (E56): it is `FEAT_OVR_ECC`, not an override word.** Its
  `0x00888888` is the stock ECC override on every consumer GA10x part. The "real
  per-class override" hypothesis is withdrawn; only `SS0`/`SS1` are speed words.
- **The FECS-context closure is weaker than "closed" suggests.** The content search
  assumes the 3-bit layout, and the cross-card diff cannot find a constant both
  capped cards share. The decisive experiment — modify a host-owned context/patch
  buffer after the GSP fills it, then measure — was never run.
- **The local baseline still lacks an FP16-accumulate mode.** The ~441 TF/s full-
  rate figure is external, so the local cap ratio is inferred rather than measured.
- **The per-SM selector is not swept.** The whitepaper says the selector is per-SM;
  only the global FEAT bank was probed. Per-SM copies, if mapped in the GR/SM
  aperture, could have a different write gate.
- **The GR context differential is from driver-init contexts.** The cross-card
  comparison used the first context after module load, not a compute context on both
  cards. A context-specific field would not appear there.
- **The pre-lock FEAT writer is not identified.** E65 locates it to the GPU-side
  devinit after function enable, but cannot separate the PMU (PL2, the leading
  candidate) from the FSP/BootROM (PL3) or a hardware re-latch. The PMU devinit
  ucode is encrypted, so the write cannot be read from the plaintext corpus.
- **The persistence model changed.** The Ada-derived "PLM stays open across FLR"
  does not hold on GB202; the reset/re-lock happens on every device enable (E65).

## 15. Threat-surface map

### 15.1 The PL3 components, ranked

| # | Component | Code | Host input | Oracle | Status |
|---|---|---|---|---|---|
| 1 | SR-resume structure + radix3 | encrypted state, plaintext structure | `SRMeta`, PTEs | hang only (no console) | **LIVE** — best surface |
| 2 | FSP COT/MCTP parser | ROM | COT fields, framing | `0xd9`, `0xd6`, `0x1db`, `0x377` | **LIVE** — fields and command surface mapped (E58); key anchor enforced (E61); malformed-length test open |
| 3 | FMC boot-params parser | encrypted | COT, `WprMeta` | `0x83d`, `0x827`, `0x82e`, `0x885`, `0xaff`, `0x33` | partly mapped; bootloader size/manifest checked, code/data offsets unused; container and both images authenticated (E62, E69) |
| 4 | GSP BootROM | ROM | image descriptor | none visible | closed |
| 5 | SEC2 debug path | image absent | MCTP header | fuse-gated | closed on retail |

Not in this table: the FEAT bank's pre-lock writer is a GPU-side devinit (PL2; most
likely the PMU) that runs after the device is enabled and re-locks the PLM before
the first open (E65). It is not a host-facing parser surface.

**What to look for inside the parsers.** Host-controlled 64-bit offsets and 32-bit
sizes that are not validated before DMA or copy; integer truncation between 64-bit
COT fields and 32-bit firmware fields; image length fields trusted before the
signature check; MCTP/NVDM packet-length and packetisation checks; any copy that
happens before hash/signature verification. On the FMC side the target is
`GSP_FMC_BOOT_PARAMS` and the GSP-RM container; on the FSP side it is the COT/NVDM
framing. This is the structural analogue of the Ada `BooterLoadUcode` bug: a
host-supplied length consumed by early boot code.

Two of those targets are already measured shut: the FMC container is bound to the
COT hash byte-for-byte, header included (`0x33`, §9.8/E62), and a modified GSP-RM
container is rejected by the FMC (`0xaff`, E15/E40). What remains is the COT/NVDM
framing itself and the structures the FMC parses *after* it has authenticated its
own image (`WprMeta`, `SRMeta`).

### 15.2 Every surface touched

| Surface | Status | Evidence |
|---|---|---|
| Host BAR0 writes to FEAT/FUSE | closed | E08, E09, E12 |
| GSP-mediated writes (`GPU_EXEC_REG_OPS`) | closed for FEAT/FUSE; works for own registers | E08, E10, E12 |
| Registry speed-select keys | parsed, stored, inert | E50, E51 |
| `RMDisableFeatureDisablement` SKU gate | display-only feature table | E52 |
| Registry boot keys | live input surface | E11 |
| FECS command doorbell | live PL2 path, not a host lever | E18, E19 |
| GR context buffers | closed as rate source | E20–E27 |
| GSP EMEM / debug interface | closed | E10 |
| RISC-V PRISCV / ICD | host-facing ICD live at PL0: writable, commands execute, `STOP` + `RDM` gives a 14.4 MB halted-core RM code-segment window; no memory-mapped DM. Blocked through the HS phase, `RDM` refused at the LS transition, aperture is the code segment only after boot | E63, E67, E68 |
| FSP core EMEM | closed (L3-gated) | E21 |
| SEC2 DMEM/IMEM | closed (empty/blocked) | E18 |
| COT envelope | mapped; size/alignment/hash enforced; placement controllable | E29–E35, E41 |
| `WprMeta` | mapped; magic enforced; heap size controllable; bootloader size (`0x82e`) and manifest offset (`0x885`) checked, code/data offsets unused, signature size ignored | E36–E40, E69 |
| `SRMeta` + radix3 | live structure, encrypted state | E42–E46 |
| vBIOS plaintext | no writer, no constants | E04, E47 |
| FMC encryption | test-key route proven for GA100/GA102/AD102 booters; GB202 FMC key/mode unknown; debug FMC is the target. The GspRmBoot image is fully encrypted with no plaintext header and no prod/debug keystream reuse | E05, E06, E68, §11.6 |
| Patched GSP-RM | closed (authentication) | E15 |
| GPU-side FEAT devinit (pre-lock) | measured; locks the PLM before GSP-RM; the L2 window is not host/GSP-RM reachable, and it closes 1853 ms before the first GSP-RM PC | E64, E65, E70 |
| `GPU_EXEC_REG_OPS` context space | closed from PL0: `GR_CTX`/`TPC`/`SM`/`QUAD` all `0x1f` with root, a live CUDA context and every route; `FB` is `0x56`; requires a caller-owned RM channel | E71 |
| `GspRmBoot` host buffer | not decrypted in place: pre == post, 290,816 B, SHA-256 `f5f63a71…`, entropy 7.9835 | E72 |
| Host FB read | closed: BAR1 is VAS-bound and absent during boot; the BAR0 window proves FB reads work outside the WPR, and inside it returns `0xbad0ac00` | E48, E74 |
| Custom VBIOS route | PL2 ceiling; not an unlock | §4.6 |

### 15.3 Routes that are not viable, and why

- **Fuse editing:** reported to prevent POST; the FSP performs a fuse-error check
  that `RmDisableFspFuseErrorCheck` does not bypass early enough.
- **Voltage glitching:** no public demonstration on a 5090, no methodology, high
  risk of damaging the card.
- **UEFI / GRUB writes:** failed in reports; the PLM is enforced below devinit.
- **vBIOS flashing:** signed; the no-flash route is PL2-only (§4.6).
- **A GSP-RM code-execution bug:** insufficient by construction. GSP-RM runs LS/PL2,
  and by the time it runs the GPU-side devinit has re-locked the PLM (E65); its FEAT
  writes are dropped. Measured: the L2 window closes 1853 ms before the first
  GSP-RM PC (E70). It would have to pivot into an HS context.
- **Per-SM/context register writes via `GPU_EXEC_REG_OPS`:** the `GR_CTX` family
  returns `0x1f` from PL0 with root, a live CUDA context and every route; a channel
  owned by the calling RM client would be required (E71).
- **Host-side bootloader plaintext:** the FMC leaves the host-supplied
  `GspRmBoot` buffer as ciphertext; it does not decrypt in place (E72).
- **Debug firmware acquisition:** the debug signing key ships, the debug encryption
  key does not, and the test-key family does not apply (E05, E06).
- **ICD memory reads as a firmware leak:** the debug engine can halt the core at
  the boot-image window and read registers, but every `RDM` in that state is
  refused, and after boot the aperture is the RM code segment only (E68). The ICD
  cannot read HS memory.
- **Bootloader image tampering as fault injection:** the FMC authenticates the
  host-supplied `GspRmBoot` image; a one-byte ciphertext flip draws `0xaff`/info
  `0xb` and the untampered card boots (E69).

## 16. Open questions

### 16.1 Resolved

| Question | Answer | Evidence |
|---|---|---|
| Who writes `SS0`/`SS1` at boot? | A GPU-side devinit action before the FMC and before the first host open; the PMU (PL2, acting while the reset PLM is L2-writable) is the leading candidate. Not the FMC, driver, or GSP-RM. | E54, E64, E65 |
| Can GSP-RM write the FEAT block? | No — PL2, and the lock is L3-only by the time GSP-RM runs. | E08, E65 |
| Does an FLR reset the FEAT bank? | The SS words and `0x823808` persist; `FEAT_OVR_PLM` resets to `0x80842bcf` and is re-locked to `0xfffffb8f` before the first open. | E64, E65 |
| Is the reset PLM L3-only? | No — `0x80842bcf` admits L2+L3; the lock is applied afterwards. | E65 |
| Can a GSP-RM (PL2) bug use the pre-lock window? | No — the GPU-side devinit locks the PLM before GSP-RM exists. Measured: the window is 1.32 s and the first GSP-RM PC is at 3.18 s, 1.85 s later. | E65, E70 |
| Can an early open boot the GSP inside the window? | No — the open→GSP-RM path is ~2.1 s, longer than the 1.32 s window even with a zero-delay open. | E70 |
| Can `GPU_EXEC_REG_OPS` reach the GR context/SM register space from PL0? | No — `GR_CTX`/`TPC`/`SM`/`QUAD` return `0x1f` with root, a live CUDA context and every `grRouteInfo` route; `FB` is `0x56`. A caller-owned RM channel would be required. | E71 |
| Does the FMC decrypt the bootloader in place in host sysmem? | No — the host buffer is byte-identical before and after the boot (SHA-256 `f5f63a71…`, entropy 7.9835, both cards). | E72 |
| Is BAR1 a 1:1 window onto FB physical addresses? | No — BAR1 is bound to a VAS; the VAS does not exist during the GSP boot and a manual mapping faults. The working host FB mechanism is the BAR0 PRAMIN window. | E74 |
| Can a host FB read capture the decrypted bootloader at PA `0x5dd00000`? | No. With the read path proven, `0x5dd00000`, `0x181d0000` and `0x01000000` are zero; the boot bin's actual location (`frts − sizeOfBootloader` = `0x7f4279000`) and FRTS return the WPR access-denied fill `0xbad0ac00`. The image is inside the WPR and host-inaccessible. | E74 |
| Do `SS0`/`SS1` change across boots? | Across cold power cycles yes; across warm reboots no; invariant within a boot. | E64 |
| Where is `RMOverrideSmSpeedSelect` referenced? | GSP-RM `0x15cf1be` / `0x15cf1ea`; parsed into config+`0xE45`/`0xEA8`; no rate effect. | E50, E51 |
| Does the p2p SKU bypass affect the rate? | No — the 10-entry gate is display-only (feature 5). | E52 |
| Who consumes the fuse value? | The getter is a cache; a GSP decoder maps `FEAT_READOUT_1` to those values (live call unproven). | E13, E14, E17 |
| How is `FEAT_READOUT_1` packed? | Eight 3-bit fields; DP at `[30:28]`. | E13, E17 |
| Does the GSP read the FEAT aperture? | Yes, by computed offset `0x3818`. | E13, E17 |
| Is there a hidden GR setter? | No — 44/44 IDs match the public SDK. | E13 |
| Which PL3 component is worth attacking? | FMC first; FSP highest value but closed. | E02, E03 |
| Can FSP/BootROM be obtained? | No. | E03 |
| Does the vBIOS carry plaintext FWSEC µcode? | No; µcode encrypted, no FWSEC entries. | E04, E47 |
| Is the FMC host-loaded? | Yes, in linux-firmware, encrypted. | E03, E05 |
| Is the FUSE shadow software-writable? | No, from PL0 or PL2. | E12 |
| Does `SM_ISSUE_RATE_MODIFIER` set the rate? | No. | E12 |
| Does `kernel_gsp_gb202.c` override reset/COT? | No — vGPU-only. | E16 |
| Is the alternate getter `0x9668` at `0x409668`? | No — unimplemented at that address. | E18 |
| Is FSP EMEM an HS-code window? | No — MCTP transport / core ports, L3-gated. | E18, E21 |
| Is SEC2 DMEM readable? | Port real, first 8 KB zero. | E18 |
| Where is the RISC-V PRISCV block? | `0x111000`; the Falcon block ends at `0x110d4c`. | E63 |
| Is there a memory-mapped debug module in `0x111800–0x113fff`? | No — 16 dwords in two 12-byte tables at `0x111f00`/`0x111f80`. | E63 |
| Do host and GSP see the same GSP register block? | No for PRISCV: 66 identical, 199 differing, 69 host-only, 80 GSP-only. | E63 |
| Can the host read the core's PC? | Yes — the host's `0x1113ec` matches the ICD `RPC` and the RDM-confirmed halted PC (`0x93002ebc`); the GSP-side `0x01404f66` is a different register. | E67 |
| Is `0x409800` a rate control? | No — FECS command doorbell. | E18, E19 |
| Does the GR context image carry a rate field? | No. | E20, E27 |
| Is the FMC host-loaded? | Yes — `request_firmware("fmc")`; only the ELF `image` section is DMA-mapped. | E03, E05 |
| Is the FMC on the ordinary boot path? | Yes, production-signed `c04`. | E28 |
| Can the host influence HS boot input? | Yes, with a structured oracle. | E11, E28–E41 |
| Is the host-driven FMC bootstrap usable? | No — reset-PLM deadlock. | E11 |
| Does `GPU_EXEC_REG_OPS` reach the GSP? | Yes; the FEAT write is dropped there (the PLM is already locked). | E08, E65 |
| Do per-card `SS0`/`SS1` differences matter? | No — equal per clock. | E49 |
| Does `verified` gate anything? | Not the image check on cold boot. | E40 |
| Is the SR state plaintext? | No — encrypted, per-boot, per-card. | E45, E46 |
| What is the FMC signature scheme? | ECDSA P-384 over SHA-384; both keys ship. | E05 |
| Does the GA100 test-key family apply? | No. | E06 |
| Can the decrypted FMC be read at PL2? | No. | E10 |
| Do legacy IMEM/DMEM ports expose local memory? | No port exists. | E10 |
| What does the GSP keep in EMEM? | Nothing. | E10 |
| Is the FMC's ACR error space mapped? | Ten codes: `0x33`, `0x83d`, `0xd9`, `0xd6`, `0x827`, `0x82e`, `0x885`, `0x1db`, `0x377`, `0xaff`. | E29–E41, E61, E62, E69 |
| Is the COT public key host-authoritative? | No — a self-signed P-384 pair over the correct hash is refused with `0x1db`, a code distinct from the `0x377` hash failure. | E61 |
| Does the FSP decrypt the FMC in place? | No — the sysmem container is unchanged at copy, postsend and release. | E62 |
| Is the FMC image bound to the COT hash? | Yes — a one-byte change to the plaintext header or the ciphertext body is refused with `0x33`. | E62 |
| What is `0x82380c = 0x00888888`? | `FEAT_OVR_ECC`, the stock consumer-GA10x ECC override, not a speed word. | E56 |
| What consumes config+`0xEA8`/`0xEAC`? | Two readers, both boolean-only, writing a GR context/ucode descriptor (not MMIO); EA8 is gated by `+0xEA4`. | E58 |
| Who writes `0x504204`? | No host or GSP-RM writer; the value 5 comes from firmware/devinit or a ctxsw/golden-context restore. | E58 |
| Is there a GSP-RM write path to `SS0`/`SS1`? | One method (`FUN_ram_0160f1bc`, `obj+0x938`) attempts direct BAR0 MMIO; no visible 4-arg caller; after the lock the PLM blocks PL2 writes. The pre-lock window is GPU-side, not reachable from GSP-RM. | E58, E65 |
| What is bit 6 of `FEAT_READOUT_1`? | The alternate ninth byte (bit-6 reader / twin), not an unexplained gap. | E58 |
| What is the FSP command surface? | COT `0x14`, caps `0x16`, clock `0x20`; PRC `0x13` is GH100-only; no memory/fuse/register/debug command. | E58 |
| Is the PRISCV ICD live and host-commandable? | Yes — host-writable at PL0; commands execute; `RREG`/`RCSR`/`RDM` require a halted hart; `STOP` then `RDM` works. | E67 |
| What can `RDM` read? | The 14.4 MB RM code segment at PA `0x01000000`–`0x01DCD000` (tested to `0x01B40000`); not the data segment, WPR or FRTS. | E67 |
| What is the GSP-RM runtime address model? | ELF at file `0x18F000`, linked at core address `0x01000000` (not host FB PA `0x01000000`, which is empty), runtime VA `link + 0x92000000`; `file offset = link VA − 0x00E71000`. | E67, E74 |
| Is the host's `0x1113ec` the core PC? | Yes — it matches the ICD `RPC` (`0x93002ebc`) and the RDM-confirmed PC; the GSP-side `0x01404f66` is a different register. | E67 |
| Can the ICD observe or read the HS boot window? | It sees the PC only after ~155 ms, when the boot image (`0xefd0xxxx`) is executing; `CMD`/`PC` are blocked before that. `STOP` + `RREG` work in that window, but every `RDM` is refused, including the `0x01000000` control. | E68 |
| Does the `RDM` aperture follow the boot image? | No. After boot `RDM` works only for the RM code segment; `0xEFD00000`, `0x5DD00000`, `0x181D00000`, the data segment and its runtime VA are refused. | E68 |
| Does GSP-RM open the ICD memory path? | No PRISCV unlock write exists; its only ICD writes are self-halt (`ICD_CMD=0`) plus `IRQDEST`/`0x111520` setup. `RDM` is enabled later in GSP-RM init. | E68 |
| Does the FSP have a debug port? | No — the full 16 KB PFSP window has no PRISCV core interface at `+0x3d0` or `+0x1000`. | E68 |
| Is the GspRmBoot image authenticated? | Yes — a one-byte ciphertext flip draws `0xaff`/info `0xb`; the untampered second card boots normally. | E69 |
| Which `WprMeta` bootloader fields are consumed? | `sizeOfBootloader` (`0x82e`) and `bootloaderManifestOffset` (`0x885`) are checked; `bootloaderCodeOffset`/`DataOffset` are unused; `sizeOfSignature` is ignored; `sizeOfRadix3Elf` is bound into image authentication (`0xaff`). | E69 |
| Does the GspRmBoot encryption reuse a keystream? | No — the prod/debug XOR is at the chance rate (0.401% zeros) and the image has no plaintext header. | E68 |

### 16.2 Open, ranked by value ÷ cost

| # | Question | Why it matters | Cost |
|---|---|---|---|
| 1 | Does HS validate or bound-check the radix3 PTEs? | The last plaintext structure HS walks; a malformed PTE is the only structural probe left. | medium; needs phase markers/netconsole |
| 2 | Does the FSP NVDM/COT parser trust framing? | E58 maps the surface: no length field; the host controls TX length via `QUEUE_TAIL`; response identity (task/command/tag) is unchecked; there are no non-COT memory/fuse commands. The remaining test is a malformed-length packet. | medium–high; sacrificial card |
| 3 | Does the FMC trust `fbSize` and `nonWprHeapSize` as it trusts `gspFwHeapSize`? | The two remaining layout fields; one may move the WPR in the other direction. | medium; possible wedge |
| 4 | Can the COT pointer fields (boot args, FMC image) be moved safely? | Would reveal whether the FSP validates addresses before the FMC consumes them. | high; auth failure wedges |
| 5 | Are there per-SM selector registers with a different write gate? | The GR context/SM space is the remaining place, but `GPU_EXEC_REG_OPS` cannot target it from PL0: all `GR_CTX` types return `0x1f` with root, a live CUDA context and every route (E71). A caller-owned RM channel (or a kernel hook holding a channel handle) separates a handle check from an architectural gate: success exposes the per-SM space for a read sweep, and a rejection with a valid channel closes the question. The rate expectation is tempered by E12 — the one known GR-context word, `SM_ISSUE_RATE_MODIFIER` at `0x504204`, is writable but reasserted at context init and inert. | medium–high (RM channel) |
| 6 | What is the full-rate encoding? | Needed before any L3 primitive can be aimed. A100 confirms zero on Ampere; a full-rate Blackwell part is still missing. | low if a Pro 6000 is available; none is public (E56) |
| 7 | What is the FMC/bootloader encryption scheme and key index? | The booter is AES-128-ECB with test key #37 (MD5-IV permutation); the key is not public but is recoverable by a 16! search against the public KAT. The GB202 FMC's mode/key is unknown (no ECB repeats/nonce); the debug FMC is the target. E73 measured the body layout: `[code][data][manifest 0xA00]`, component-wise deterministic and code-first, so the old magic filter was the wrong oracle. The RISC-V-validity oracle is built and self-tested, and the **c09 and c11 16! passes are negative** under five hypotheses (ECB, CBC-zero, CBC-header-IV, CTR start 0/1); 3 chance records, all verifier-rejected. The family is exhausted for the FMC under these modes; the remaining unknown is the key derivation/source. | closed (family); key source open |
| 8 | Does the FECS ucode contain a command that sets the rate? | The interface is a real PL2 path to the consumer. | static blocked by encryption |
| 9 | Does `0x409504` accept a write, and which IDs are safe? | Would turn the doorbell into a trigger. | high; do not fuzz |
| 10 | What is the exact `desc+0x10` packing (family/variant)? | Confirms from the live descriptor that GB202 is implementation `0x02`; the constant already points to `0x3818` (E58). | low; live descriptor read |
| 11 | Is `FUN_ram_0160f1bc` ever called, and what is the `(0,0)` descriptor handler? | The installed `SS0`/`SS1` method has no visible 4-arg caller; a GSP log trace or a ctrl-table scan settles reachability. | low–medium; static + instrumented driver |
| 12 | What class owns `obj+0x938`, and what is the `FUN_ram_01c1f378` registration? | Completes the E58 mechanism; the initializer has no static references. | medium; static, unanalyzed region |
| 13 | Does the GSP consume the nine-byte static-info beyond the getter? | The static-info reader trace is partial because the handler pointers are 2 bytes early; re-decompile at +2. | low; static |
| 14 | Can the PMU devinit's FEAT writes be influenced (vBIOS devinit tables/ucode)? | **Closed by E66**: no plaintext devinit table or script references the FEAT block; the DEVINIT tables/scripts are HS-authenticated (AES-ECB); the PLM values sit in the app `0x23` ucode data. The custom-VBIOS table route cannot reach the writer. | CLOSED-STATIC (E66) |
| 15 | Confirm the pre-lock writer: PMU devinit vs FSP/BootROM vs hardware | Decides whether the only pre-lock path is a firmware class we can influence. E70 fixes the timing (re-lock at 1.32 s, before the boot image) but not the actor. | medium; instrumented PMU/devinit path |
| 16 | Can a working FB read capture the decrypted bootloader at PA `0x5dd00000`? | **Closed by E74, negative.** The BAR0 PRAMIN window reads FB correctly (non-WPR heap control), but `0x5dd00000`, `0x181d0000` and `0x01000000` are zero, and the boot bin's real slot (`frts − 0x47000` = `0x7f4279000`) plus FRTS return the WPR access-denied fill `0xbad0ac00`. The image is inside the WPR; the host has no readable copy. | CLOSED-MEASURED (E74) |

E65 closes the "GSP-RM PL2 window" question: the lock is applied by GPU-side
devinit before GSP-RM exists. E66 closes the follow-up (#14): the table route is
closed. E70 fixes the timing: the window (1.32 s) ends 1.85 s before the first
GSP-RM PC, so no PL2 master can act inside it. E74 closes #16: the boot image is
in the WPR and the host FB read returns the protection sentinel. What remains is
naming the writer (#15) and the PL3 frontier.

E67 answers the E63 question: the ICD is live, host-writable at PL0, and
`STOP` + `RDM` reads the 14.4 MB halted-core RM code segment.
`RREG`/`RCSR`/`RDM` are rejected while the core runs and succeed after `STOP`;
the halt costs a GPU reset. E68 answers the follow-up: the boot-time halt sweep is
done. The ICD is blocked through the whole HS phase; at the unblock the boot
image (`0xefd0xxxx`) is still executing and `STOP`/`RREG` work, but `RDM` is
refused, and after boot the aperture is the RM code segment only. The ICD is not
a firmware-leak path; the boot-image question is closed (§17.3).

### 16.3 Open instrument facts

| Unknown | Where it surfaced |
|---|---|
| Which pre-driver component sets the FEAT bank: PMU devinit, FSP/BootROM, or hardware | E54, E64, E65 |
| Whether the PMU devinit's FEAT writes are table-driven or hardcoded in the encrypted ucode — answered for tables: no plaintext table references the FEAT block; the values are in the app `0x23` ucode data | E65, E66 |
| The exact reset default/domain of `FEAT_OVR_PLM` (`0x80842bcf` after FLR; `0xfffffb8f` after devinit) | E65 |
| Which event triggers the autonomous re-lock (time after enable, PCIe state, or a PMU timer) — the timing is measured at 1156–1323 ms after the FLR; the trigger is still unnamed | E65, E70 |
| Whether a caller-owned RM channel makes `GR_CTX` succeed, and whether the GSP then accepts context writes | E71 |
| Whether a working FB read can reach PA `0x5dd00000` (the decrypted bootloader) — answered: it cannot; the image is in the WPR and FB reads there return `0xbad0ac00` | E48, E72, E74 |
| Semantics of `FEAT_OVR_QUADRO` (`0x823808 = 0x01000280`) and the unknown `0x8238b0 = 0x12800541`; `0x823810` is `FEAT_OVR_ECC_1` (E56) | FEAT bank map |
| Bit 6 of `FEAT_READOUT_1` — resolved: it is the alternate ninth byte (`FUN_ram_015ffbd0` / the twin's `param_3[2]`) | §2.3, E58 |
| Whether `0x823800` is an alias or a second PLM | FEAT bank map |
| What locks the FECS PLM writes below the PLM | E18 |
| Whether the FEAT `3` is a rate code at all (the readout is a fuse mirror; the code→rate law changed on Blackwell) | §2.4, E56 |
| What `0x409b00/0x409b04 = 0x007e0f0a` encodes | E18 |
| The PMU's real BAR0 base (`0x10a000` is wrong) | E18 |
| The 16-byte constant at `0x8f0ab0` | E21 |
| What the 128-dword CMS2 table encodes | E18 |
| Whether EMEM survives a GSP reset, and whether SPDM data is written there | E10 |
| What the FMC writes into the FRTS region (position proven, contents unobserved) | E31–E35 |
| Whether the SEC2 DMEM is larger than 8 KB or masked | E18 |
| How the FEAT decoder's HAL class is instantiated (the factory has no static refs) | E17 |
| Whether the PLM can be opened by a source other than PL3 | E01, E12 |
| Whether the GSP Falcon block is host-writable at cold boot | E11 |
| What GSP-RM's minimum heap actually is (the 16 MiB point wedges) | E39 |
| The vBIOS app-ID → engine mapping for the four real µcode entries (targets `0x06`, `0x01`, `0x01`, `0x0E`); app `0x23`/tgt `0x0E` carries the PLM values | E04, E66 |
| Whether app `0x23`/target `0x0E` is the SEC2 image (target IDs are not public) | E66 |
| Whether GB203M / 5090 D share the encoding and PLM behavior | — |
| The FMC's remaining ACR code space | E29–E41 |
| The GB202 FMC encryption mode/key (CBC/CTR/XTS vs compressed-ECB; test key #37 vs another index) | §11.6 |
| Whether the recovered test key #37 opens the GB202 debug FMC | §11.6 |
| What the host-side `0x1113ec` register is — resolved: the core PC when the block is accessible; it reads `0xbadf5620` while blocked | E63, E67, E68 |
| Which PLM covers the PRISCV ICD (`0x111320` L3-only vs `0x111328` all) | E63 |
| Why `RDM` is refused in the HS window and early GSP-RM although the hart is halted (`CPUCTL=0x380`): privilege/firewall state vs late firmware init | E68 |
| What enables `RDM` during GSP-RM init (the control works only in the fully booted state) | E68 |
| The physical backing of the boot image at `0xefd00000` — resolved: inside the WPR (`frts − sizeOfBootloader`), not at PA `0x5dd00000` or `0x181d00000`; reads there return `0xbad0ac00` | E68, E74 |
| Where the WPR starts, and whether the non-WPR heap holds the live RM objects — resolved: WPR base `0x7e75e0000`; the 3 MiB heap holds no object memory, the RM objects are in the WPR heap | E75 |
| What `0x82e` and `0x885` name precisely (bootloader size/manifest stages) | E69 |
| What the `sig{0x1000}` buffer verifies and how its four blocks map to chips | E69 |
| Whether the PRISCV per-master split is decoupler mapping or two register files | E63 |
| What the host-only `0x1111a8–0x1111e4` (16 × `0x2`) and `0x111610+` (`0xbb` fill) are | E63 |
| Whether `TRACEPC_LO 0x11140c = 0x0100287c` is a real trace PC (it does not decode) | E63 |
| What the 16-byte block at `0x11106c` (GSP-only) is | E63 |

## 17. Next experiments

### 17.1 Cheap and non-wedging

1. **Obtain a Pro 6000 reference** (§17.4) — not available locally and not public
   (E56). Highest information per unit of effort.
2. **Add an FP16-accumulate mode to the local probe** and measure the cap ratio on
   this machine rather than inferring it.
3. **Per-SM/GR register space — the `EXEC_REG_OPS` route is closed (E71).**
   `GR_CTX`/`TPC`/`SM`/`QUAD` return `0x1f` with root, a live CUDA context and
   every route. A read-only sweep is only meaningful after a channel owned by our
   RM client exists, or through a kernel hook; the GSP may still reject it.
4. **Decode `FEAT_OVR_QUADRO`** (`0x823808`) against the two cards' differing bit 8;
   the speed-select question no longer involves `0x82380c` (E56).
5. **A larger read-only SEC2 DMEM scan** to distinguish empty from masked.
6. **Search for the real PMU base** among the implemented register blocks.
7. **A cross-card compute-context dump**, if the context route is ever revisited:
   the existing differential used driver-init contexts.
8. **EMEM survival test:** marker write, `rmmod`/`insmod`, read back. Cheap and
   answers whether EMEM matters as an input rather than a readout.
9. **Rerun the FEAT/FLR harnesses** (`phase2b/feat_preboot.sh`, E54;
   `phase2b/feat_preboot_flr.sh`, E65) after any firmware, driver, or VBIOS change;
   they are the cheapest way to detect a change in the pre-driver/reset writer.
10. **Static scan of the vBIOS devinit tables — done (E66).** It found no FEAT
    address in any plaintext table or script and confirmed the DEVINIT
    tables/scripts are HS-authenticated; the table route is closed. The remaining
    static target is the encrypted app `0x23`/target `0x0E` code, which needs a key
    (the FACEB13D precedent; E06 closed the GA100 key transfer to GB202).
11. **Recover test key #37 and test it on the GB202 debug FMC — done, negative.**
    The corrected 16! passes over the whole space (zero-KAT, FF-KAT,
    last-round-key) and the `c09`/`c11` first-block oracles are all negative
    (revs 76–77); the IV-permutation family does not reproduce on GB202 (§11.6).
12. **Re-score the FMC key oracle — done, negative (E73).** The body layout is
    now measured (`[code][data][manifest 0xA00]`,
    §11.6), so the first block is code and the old magic filter was the wrong
    oracle. The replacement is in `phase2b/key37_cuda.cu --fmc-riscv`: a 16-bit
    parcel language model trained on the GSP-RM code segment, Stage 1 on one
    block, Stage 2 on eight blocks for survivors only, at **8.5 G keys/s per
    5090**. The synthetic controls pass (rank-0 key recovered from a code-first
    body; random rejected; full-code walk 0.05% vs 8.8% invalid). The **c09 and
    c11 16! passes are negative** (2026-10-29; both halves, five hypotheses:
    ECB, CBC-zero, CBC-header-IV, CTR start 0/1). Three chance records total,
    all rejected by the full-code walk. The family is exhausted for both debug
    FMCs under the tested modes; the remaining unknown is the key
    derivation/source (§11.6, §16.2 #7).
13. **FB capture at PA `0x5dd00000` — done, negative (E74).** The BAR0 PRAMIN
    window reads FB correctly (non-WPR heap control, 58,707 nonzero bytes), but
    `0x5dd00000`, `0x181d0000` and `0x01000000` are zero, and the boot bin's
    actual slot (`frts − sizeOfBootloader` = `0x7f4279000`) plus FRTS return the
    WPR access-denied fill `0xbad0ac00`. The image is inside the WPR; the host
    has no readable copy and the memory route is closed. The `VA 0xefd00000 →
    PA 0x5dd00000` inference is retracted.

14. **Non-WPR heap mining — done, negative (E75).** The 3 MiB heap is
    readable but contains no live RM objects (no vtables, no handler VAs);
    the objects live in the protected WPR heap. A runtime view needs a GSP
    RPC or a PL3 primitive, not a host FB read. The WPR start is pinned at
    `0x7e75e0000`.

### 17.2 Needs instrumentation first

- **Phase markers for the SR path** (files written at prepare / save /
  resume-start / restore-done) or netconsole. Without one of these, every SR probe
  is a blind hang.
- Then: `SRMeta.size`, `SRMeta.sysmemAddrOfSuspendResumeData`, and one malformed
  PTE. These are the highest-value remaining structural probes.
- **Framing analysis of the FSP message path** statically first (`kern_fsp.c`,
  nova-core NVDM definitions), then a controlled malformed-length test.
- **Bracket the pre-lock FEAT write to the PMU devinit.** E65 narrows it to the
  post-enable window before the first open; E70 fixes the timing (re-lock at
  1.32 s, 1.85 s before the first GSP-RM PC) but not the actor. Instrument the
  PMU/devinit path during GPU attach to name it (PMU vs FSP/BootROM/hardware).
- **A channel-owned `GR_CTX` probe.** Allocate a mini-RM channel (VA space +
  GPFIFO + UserD + bind/schedule) or add a kernel hook that issues the op with a
  channel handle; this is the only remaining way to test the per-SM context
  space (E71). The GSP may still reject it.
- **Dump the raw GSP-RM log buffers.** The decode needs `gsp_log_ga10x.bin`, which is
  not shipped; without it the records remain numeric (§19).
- **ICD boot-window work — done (E68).** The PC trace and the targeted halts
  closed the question: the ICD is blocked through the HS phase, `RDM` is refused
  at the unblock and at the LS transition, and the post-boot aperture is the RM
  code segment only. The remaining ICD instrument is a read-only PRISCV register
  sweep **at the boot-image halt** to compare the block's PLMs/state with the
  post-boot map; it can explain why `RDM` is gated but cannot read the image.

### 17.3 Risky

- COT pointer fields (`gspBootArgsSysmemOffset`, `gspFmcSysmemOffset`): auth failure
  wedges the machine.
- **`STOP` on the GSP (ICD halt)**: halts GSP-RM, heartbeat timeout, Xid 154,
  GPU Reset Required; one reboot per attempt (E67).
- `fbSize` / `nonWprHeapSize` at the wrong values: possible WPR2 wedge.
- The remaining `WprMeta` address fields (`sysmemAddrOfBootloader`,
  `sysmemAddrOfSignature`, `sysmemAddrOfRadix3Elf` at zero) and an oversize
  `sizeOfRadix3Elf`: a wild DMA source is a possible bus error or wedge; expected
  to draw `0xaff` or a clean boot, not a primitive (E69).
- FSP parser fuzzing beyond field values.
- Skipping `kgspResetHw` on the GSPFMC path: whether the Falcon block is
  host-writable at cold boot at all.
- Any attempt to enter debug fuse state.
- DFA/voltage-glitch attacks on the SCP `csecret(6)` production key: hardware,
  high risk, and unnecessary while the debug FMC route is open.
- Crafted COT/FMC input on a sacrificial card.
- A V67-style payload, if a PL3 primitive is ever found.

Each of these needs a stock boot entry, the stock firmware restored, and an
expectation of one reboot.

### 17.4 The one external input that would re-plan the work

The missing piece is not a register or an exploit — it is the **full-rate encoding**.
A Pro 6000 (`FEAT_READOUT_1`, `SS0`, `SS1`, and the fuse block if reachable) would
show what a full-rate part reads and settle whether a full-rate GB202 has
`FUSE_SS_FMLA32 = 0`. `0x82380c` is no longer part of the question (E56). No
full-rate GB202 is available locally and no public Pro 6000 dump exists (E56), so
this remains the one external input that would re-plan the work; the static pass
and the cheap local probes proceed without it. Until a card is obtained, every L3
effort is aimed at a target word we cannot state precisely.

### 17.5 What would count as a real unlock

1. `GET_SM_ISSUE_RATE_MODIFIER` reports `fmla32 = 0` (and relevant IMLA fields
   clear).
2. `FEAT_READOUT_1` decodes to zero effective selectors using a **Blackwell-correct**
   layout.
3. `SS0`/`SS1` read back the intended values.
4. BF16→FP32 issue rate ≈ 440 TF/s (roughly 2× stock), with FP16→FP16, INT8, FP8,
   and scalar controls unchanged.
5. A matched cuBLAS/CUTLASS BF16 GEMM shows a real gain, with numerical
   verification.
6. The override survives the reset/re-lock path — an FLR, a driver reload, and a
   device enable must not restore `0xfffffb8f` over it (E65 shows the GPU-side
   devinit re-locks the PLM on every enable); the driver loads without Xid or GSP
   errors.
7. The result reproduces on a second cold boot and, ideally, a second card.

Register-resident issue-rate numbers alone are not sufficient. The Ada results show
GEMM gains can be much smaller and shape-dependent.

## 18. Practical alternatives today

- **FP16 accumulation** where numerically acceptable
  (`torch.backends.cuda.matmul.allow_fp16_accumulation`, CUTLASS FP16-acc kernels).
  Full rate, but loses FP32 accumulation.
- **Chunked FP16 accumulation with periodic FP32 promotion:** recovers most of the
  FP32-accumulate rate with controlled precision loss; not numerically identical to
  BF16→FP32.
- **FP8/FP4/NVFP4 or INT8** where the workload allows; these are unthrottled.
- **A workstation/datacenter Blackwell part** (RTX PRO 6000, B200), where the
  consumer segmentation is absent.
- **An unlocked 4090** for smaller models: ~331 TF/s on the capped path, above a
  stock 5090's ~223 TF/s, with less memory and bandwidth.

---

## 19. Instrumentation and tracing

The question "can the driver dump what the firmware does" has a precise answer: not
on the path people usually mean, and only partly anywhere else (E55).

**There is no per-launch firmware operation.** A CUDA kernel launch is a pushbuffer
entry rung through the channel doorbell. The RM is not in that path; its
rate-relevant work happens once, at engine/context initialization (the `0x20800a34`
fetch, §2.5). A launch tracer would see host channel submissions, not GSP or FECS
work.

**What the host stack offers.**

| Facility | State |
|---|---|
| `NVreg_RegistryDwords` | forwards every key to RM/GSP-RM (`osapi.c:3352`); the instrument behind every oracle here |
| `EnableGpuFirmwareLogs` | module param; a release build honours only `1` (the `2` default means "on in DEBUG/DEVELOP" and is off here) |
| `RmGspLogBufferSizeTask{Init,Intr,Rm,Mnoc}` | sizes the host-allocated, host-mapped GSP log buffers |
| `RmGspPreserveUnloadLogs`, `RmGspTraceCrashLogging*` | GSP log retention and crash-trace masks |
| `RMNvLog`, `RMDumpNvLog` | host-RM NVLOG; dumped to dmesg on Xid/unload, not a GPU trace |
| `RMEnableEventTracer` | **no-op on Linux**: the `RMTRACE_*` macros are compiled out (`tracer.h`) |
| `nvidia-debugdump` | engine components include GSP/KGSP, but the external build lists only devices and emits an opaque blob |

**The GSP log is host-readable; its decoder is not shipped.** GSP-RM writes per-task
log buffers that the host allocates in unprotected sysmem and maps
(`_setupLogBufferBaremetal`). Decoding needs the `.fwlogging` section of
`gsp_log_ga10x.bin`; that file is absent from `/lib/firmware/nvidia/595.91.07/`,
the 580.105.08 `.run`, and the 570.153.02 `.run` (E57), and `kernel_gsp.c:3649`
skips logging when it is missing. `EnableGpuFirmwareLogs=1` therefore prints only
"Failed to load gsp_log_*.bin". The raw buffers can still be dumped from the
instrumented driver, but without the metadata their records carry numeric message
IDs rather than text. The IDs are compile-time constants at 33,640 call sites, so
an `{ID -> emitting function, operand count}` table can be built from the image and
joined to a raw dump: this recovers the function-level boot/GR-init trace without
the missing file (E57). This decoder is implemented in `gsp-analysis/logdecode/`:
`build_id_table.py` emits 30,568 decompiled call sites plus a 33,044-ID raw
fallback (58,736 distinct RM IDs, 184 INIT, 75 early), the CLI parses a raw ring
or a manifest, and `build_init_strings.py` recovers exact text for 31 early-writer
IDs from their per-statement literal fallbacks. A live capture resolves 141/173
records (E59). Message text and severity for RM and INIT records remain
unavailable, and the task-1 KERNEL section's base is still unknown.

**What can be added.** Two cheap instrumented-driver facilities: a host control/RPC
tracer (log every ctrl ID and GSP RPC function ID with its parameter size), and a raw
GSP log-buffer dump at a chosen point. Neither reaches FSP, FMC, or HS code. The
pre/post FEAT sampler (E54) is the worked example of instrumenting a boot stage: a
read-only sample at a chosen hook, printed to dmesg.

**Direct hardware debug.** The PRISCV ICD is a host-side MMIO debug port outside
the driver stack: E67 shows it executes commands and, after `STOP`, reads the
14.4 MB RM code segment of the halted core. It is not reachable on a running
core, and the halt requires a GPU reset.

---

# Appendices

## Appendix A — Register map

Values are stock on GB202 unless stated. Full maps for blocks measured in more than
one pass are consolidated here; the sections reference this appendix rather than
repeating it.

### A.1 Chip, WPR, and the Ada payload targets

| Offset | Name | Notes |
|---|---|---|
| `0x00000000` | `PMC_BOOT_0` | chip ID; `0x1b2000a1` on `41:00.0` |
| `0x001fa824` / `0x001fa828` | WPR2 low/high | firmware reservation |
| `0x001fa7cc` / `0x001fa7c4` | WPR_CFG / WPR PLM | Ada payload targets |
| `0x009a0148` | FBPA PLM | Ada payload target |
| `0x00840000` | SEC2 block | secure boot engine |

### A.2 FUSE / OTP (`0x820000`–`0x8207ff`)

| Offset | Name | Value / note |
|---|---|---|
| `0x00820000` | `FUSECTRL` | fuse controller |
| `0x00820040` | `EN_SW_OVERRIDE` | software override enable |
| `0x0082007c` | `DISABLE_FUSE_PROGRAM` | fuse programming disable |
| `0x008200d0`, `d8`, `dc`, `f8` | PLM-shaped | `0xfffffb8f` (read all / write L3) |
| `0x008200d4`, `e8`, `ec`, `f0` | PLM-shaped | `0xfffffbfc` (read L2–L3 / write all) |
| `0x008200e0`, `e4`, `f4` | PLM-shaped | `0x00800b8f` (read all / write L3) |
| **`0x008200fc`** | `FUSE_SS_PLM` (page-0 mask) | **`0xfffffbff`** — reads as write-all, but not the effective gate (§5.4) |
| `0x00820224` | `FUSE_SS_DP` | 0 |
| `0x0082038c` | `SECURE_FEAT_OVR_QUADRO_WR_SEC` | Quadro secure write |
| `0x008203f0` | `OPT_FEATURE_FUSES_OVERRIDE_DISABLE` | 0 |
| `0x0082059c` | `FUSE_SS_FFMA` | 0 |
| `0x0082074c` | `OPT_SECURE_GSP` / `..._DEBUG_DIS` | 1; writes dropped from PL0 and PL2 |
| `0x008207d4` | `FUSE_SS_FMLA16` | 0 |
| **`0x008207d8`** | **`FUSE_SS_FMLA32`** | **3**; writes dropped from PL0 and PL2 |
| `0x008207dc` | `FUSE_SS_IMLA0` | 0 |
| `0x008207e0` | `FUSE_SS_IMLA1` | 3 |
| `0x008207e4` | `FUSE_SS_IMLA2` | 3 |
| `0x008207e8` | `FUSE_SS_IMLA3` | 0 |
| `0x008207ec` | `FUSE_SS_IMLA4` | 3 |

Sentinel `0xBADF510C` clusters at `0x820158`–`0x8201ec`, `0x8204a8`–`0x8204b0`,
`0x820578`. Page 4 `0x824100`–`0x8241cc` reads a uniform `0x00000002`;
`0x8240fc` is a sentinel.

### A.3 FEAT bank (`0x823800`–`0x8238b0`)

| Offset | Name | Value / note |
|---|---|---|
| `0x00823800` | `FEAT_OVR_ECC_PLM` | `0xfffffb8f`; alias or second copy of the PLM (unresolved) |
| `0x00823804` | `FEAT_OVR_PLM` | `0xfffffb8f` — read all / **write L3 only**; `SOURCE_ENABLE = 0xfffff` (all sources), bit 10 is `SOURCE_READ_CONTROL`, not a source enable (E53) |
| `0x00823808` | `FEAT_OVR_QUADRO` | `0x01000280` (`41:00.0`) / `0x01000380` (`c1:00.0`); per-card bit 8; classification, not rate (E56) |
| `0x0082380c` | `FEAT_OVR_ECC` | `0x00888888`; consumer-GA10x stock ECC override; write dropped (§2.3, §5.3, E56) |
| `0x00823810` | `FEAT_OVR_ECC_1` | `0x002a2aaa` |
| `0x00823814` | `FEAT_READOUT_0` | `0x00000233`; **bit 16 = ECC enablement** (0 here) |
| `0x00823818` | `FEAT_READOUT_1` | `0x00c36180`; eight 3-bit selectors + DP (§2.3) |
| `0x0082381c` | `FEAT_OVR_SM_SS0` | `0x21240001` on `41:00.0`; `0x54226037` on `c1:00.0`; runtime state (E56) |
| `0x00823820` | `FEAT_OVR_SM_SS1` | `0x00000002` on `41:00.0`; `0x00026005` on `c1:00.0`; runtime state (E56) |
| `0x00823824` / `28` / `2c` | `FEAT_OVR_ROW_REMAP` / `FEAT_READOUT_2` / `FEAT_OVR_ECC_2` | `3` / `1` / `0xa`; identical to the RTX 3090 Ti triple (E56) |
| `0x00823840` / `44` | counters | `8` / `3` |
| `0x008238b0` | ID/version | `0x12800541` |

Within a boot every value above is final **before the FMC runs** (E54): a pre-FMC
sample and a post-boot sample are byte-identical on both cards, including the
per-card `0x823808`/`SS0`/`SS1` differences. The `SS0`/`SS1` values in the table are
the 2026-10-26 samples, not constants: `41:00.0` read `0x21240001`, `0x20240001`,
`0x20260041`, `0x21265047`, `0x21265043` across cold boots, while warm reboots
preserved the prior values and within-boot samples were invariant (E64). An FLR
resets the PLM pair to `0x80842bcf` (write mask L2+L3) and a GPU-side devinit
re-locks it to `0xfffffb8f` before the first open (E65). `FEAT_READOUT_1` was
`0x00c36180` in every sample.

**Read consumers (E58).** `0x3814` is read for bits 15, 16 (ECC), 18, 19 and 29;
`0x3818` feeds the nine-byte decoder and DP `[30:28]`/bit 6; `0x3828` is read for
bits 5 and 10. No code reads `0x381c`/`0x3820`; the only writer in the plaintext
GSP-RM is `FUN_ram_0160f1bc` (`obj+0x938`, E58).

Unimplemented offsets: `0x823858`, `0x823874`, `0x823898`, `0x82389c`, `0x8238b8`+
(`0xBADF5040`).

### A.4 FECS (`0x409000`–`0x409fff`)

| Offset | Name | Value / note |
|---|---|---|
| `0x00409600` / `624` / `65c` / `660` / `688` / `6d0` / `438` | FECS PLMs | `0x409660 = 0xfffffbef`; `0x409688 = 0xffffffcf`; `0x409438 = 0xffffffef`; `0x4096d0 = 0xffffffff`; writes dropped |
| `0x00409638` | implemented | `5` |
| `0x00409664` / `668` | selector/readout copies | `0xBADF5040` — unimplemented |
| `0x00409500` | command data | `0`; carries address/size words for the context commands |
| `0x00409504` | command ID | `0xBADF5545` — read-blocked (PRI `0xBADF55`) |
| `0x00409700`–`784` | adjacent config | `0x30, 0x40001010, 0x8097cbff, 0x658bba81, …`; under the open `0x4096d0` PLM |
| `0x00409800` | command status/payload | **GSP-writable**; polled at `0x9800 + 4*param` |
| `0x00409b00` / `04` / `b78` | DP/companion readout | `0x007e0f0a` / `0x007e0f0a` / `0` |

### A.5 SM / GR

| Offset | Name | Value / note |
|---|---|---|
| `0x00504204` | `SM_ISSUE_RATE_MODIFIER` | `5`; writable from PL0/PL2, reasserted at context init, inert (§5.5) |
| `0x00829668` | candidate twin-getter base | `0xBADF1100` — outside the decodable window |
| `0x00009668` | candidate absolute offset | `0xBADF5040` — decodable, unimplemented |

### A.6 GSP Falcon (`0x110000`–`0x110d4c`)

| Offset | Name | Value / note |
|---|---|---|
| `0x00110008` | `IRQSTAT` | `0` |
| `0x001100f4` | `HWCFG2` | `0x818787f7`; bit 10 = RISC-V core |
| `0x00110108` | `HWCFG` | `0x80420100` |
| `0x0011012c` | `HWCFG1` | `0xc2101136`; bits 21:25 = 1 → 512-byte EMEM blocks |
| `0x00110180`+ | `IMEMC/D(i)` | `0xBADF5610` — **no IMEM window** on the RISC-V GSP |
| `0x001101c0`+ | `DMEMC/D(i)` | `0xBADF5610` — **no DMEM window** |
| `0x001103c0` | `FALCON_ENGINE` | `0x00000200` (deasserted); host-blocked (`0xBADF5720`) while PRIV-locked |
| `0x001103c4` | `RESET_PRIV_LEVEL_MASK` | `0x00000f00`; level-0 enables clear |
| `0x00110abc` | EMEM geometry | `0x20` → 32 × 256 B = 8 KB |
| `0x00110ac0`–`0x110afc` | `EMEMC/D(0..7)` | 8 KB window; all zero at runtime |
| `0x00110b84` | GSP PLM | `0xffffff8f` — read all / write L3 only, same shape as `FEAT_OVR_PLM` |

`0x110d50–0x110ffc` is `0xBADF5040` — the Falcon block ends here, not at
`0x11172c`. The RISC-V PRISCV block starts at `0x111004` (E63).

### A.6b PRISCV (`0x111000`–`0x1117ff`)

Base `0x111000`; GB202 `dev_riscv_pri.h` offsets are relative to it (E63). All
values below are the GSP (PL2) view unless marked host; host-blocked means
`0xBADF5720`.

| Offset | Name | Value / note |
|---|---|---|
| `0x00111004`–`0x111094` | core state | GSP-only; includes address-like `0x0018df4c`/`0x0018dfc0` and a 16-byte run at `0x11106c` (`d0f6abf9 1f1b665b 9fc84de6 64658a97`, then `0x00010001`) |
| `0x00111128` | PLM-shaped | `0x00000f00` |
| `0x001111a8`–`0x1111e4` | host-only table | 16 × `0x00000002` |
| `0x00111320` | PLM | `0xffffff8f` — read all / write L3 only |
| `0x00111324` | PLM | `0xffffff0f` — read all / write none |
| `0x00111328` | PLM | `0xffffffff` — read/write all |
| **`0x00111388`** | `PRISCV_CPUCTL` | `0x00000180`; halt `[4]=0`, active `[7]=1` (same to both masters) |
| `0x001113d0`–`dc` | `ICD_CMD`/`ADDR0`/`ADDR1`/+`3dc` | host `0` (not blocked); GSP `0xbadfffff` |
| `0x001113e0`–`e8` | ICD data / reserved | `0` to both |
| **`0x001113ec`** | `PRISCV_RPC` | GSP `0x01404f66` (live PC, GSP-RM code); host `0x9300xxxx`, changes between reads |
| `0x00111400` | host-only control | host `0x51100000`; GSP `0xbadf5610` |
| `0x00111404`–`410` | `TRACE_RDIDX`/`WTIDX`/`TRACEPC_LO`/`HI` (inferred) | GSP `0x003f0000`/`0x3c000000`/`0x0100287c`/`0`; host-blocked |
| `0x00111420`–`430` | `PRIV_ERR_STAT`/`ADDR`/`ADDR_HI`/`HUB_ERR_STAT` | `0`; `PRIV_ERR_INFO` is `0xbadf5040` |
| `0x00111514` / `51c` / `550` | PLMs | `0xffffff0f` / `0xffffffff` / `0xffffffff` |
| **`0x00111528`** / `52c` | `IRQMASK` / `IRQDEST` | `0x810490d2` / `0x010800d0` (same to both) |
| `0x00111534` | `IRQDELEG` | `0xbadf5610` — no port |
| `0x00111700` | `FAULT_CONTAINMENT_SRCSTAT` | `0` |
| `0x00111f00`–`12c` | 4 × {`0x00000f00`, `0`, `0x11111111`} | `0x11111111` is an L0-read/write PLM shape |
| `0x00111f80`–`1ac` | 4 × {`0x00000f00`, `0x04000000`, `0`} | `0x111fb0`–`0x113ffc` is `0xBADF5040` |
| `0x00111610`+ | host-only pattern | `0x83bbbbbb`, `0x8bb9bbbb`, `0xbbbbbbbb`, `0x01000330` |

**ICD (E67).** The four registers `0x1113d0`–`0x1113dc` are host-writable at
PL0: `ADDR0/1` retain a written value, `CMD` retains the command, and the engine
executes. `RSTAT` idx 0/3/4 completes on a running core (`ERROR=0`, value 0);
`RREG`/`RCSR`/`RDM` are rejected on a running core (`CMD[14]=1`,
`RDATA=0xbadfbadf`) and succeed after `STOP`. `STOP` (`CMD=0`) halts the core;
`CPUCTL` moves `0x2a0` → `0x380` but `CPUCTL[4]` stays clear. With the core
halted, `RDM` reads the loaded RM code segment at `0x01000000`–`0x01DCD000`
(tested to `0x01B40000`); reads outside it, including the data segment at `0x04000000` and
the WPR/FRTS physical addresses, return `ERROR`. The address must be aligned to
the access size.

**Boot window (E68).** `CMD` and the host PC mirror read `0xbadf5620` from the
COT response until ~155 ms after it, while the Falcon `ENGINE` (`0x1103c0`)
reads `0xbadf5720`; `CPUCTL` (`0x180`) and the reset PLM (`0x00000f00`) are
readable throughout. The unblock coincides with the boot image (`0xefd0xxxx`,
`0x47000` bytes = `GspRmBoot`), and GSP-RM starts ~0.5–0.6 ms later. `STOP` then
leaves `CPUCTL=0x380` and `RPC`/`RREG` return the boot image's `pc`/`ra`/`sp`,
but **every `RDM` is refused** (`0xbadfbadfbadfbadf`), including the `0x01000000`
control; the same holds at the LS transition. After full boot the aperture is the
RM code segment only — `0xEFD00000`, `0x5DD00000`, `0x181D00000`, `0x04000000`
and `0x96000000` all return `ERROR`.

### A.7 FSP (`0x8f0000`–`0x8f3fff`)

No PRISCV core interface exists in this block: a full 16 KB sweep from host and
GSP finds `0xBADF5040` at the `+0x3d0` ICD layout (`0x8f0388`/`0x8f03d0`/…, the
handover's guess) and at the GSP-analogous `+0x1000` placement (`0x8f1388`/
`0x8f13d0`/…). Implemented outliers: `0x8f1274=0`, `0x8f1298=7`,
`0x8f129c=0xcbff`; two 12-byte-stride tables at `0x8f1f00`/`0x8f1f80`
(the GSP's `0x111f00`/`0x111f80` analogues); a `0x8f3000` block with
`0xffffff8f` PLMs. The FSP is not a debug-port target (E68).

| Offset | Name | Value / note |
|---|---|---|
| `0x008f0108` | RISC-V HWCFG | `0x80420100` |
| `0x008f0180` / `1c0` | FSP core IMEM/DMEM | `0xBADF5620` |
| `0x008f0320` / `032c` / `0330` / `0334` | scratch / version | `0x9f` / `0x0a` / `9` / `0x44c` |
| `0x008f03c0` | FALCON_ENGINE | `0x00000200` |
| `0x008f03c4` | FSP PLM | `0x00040bff` (read all / write all; source bit 10 set) |
| `0x008f0a58` / `5c` | core status/config | `0x6624b970` / `3` |
| `0x008f0a64` / `68` | core config | `0xffffffff` / `0x111` |
| **`0x008f0a90`** | FSP core PLM | **`0xffffff8f`** — read all / **write L3 only** |
| `0x008f0aa0` / `a4` | PLM-shaped pair | `0x00804bff` / `0x0001fffe` |
| `0x008f0ab0`–`abc` | unidentified constant | `e81dc861 98216d8b 803e5471 9e870bdf` |
| `0x008f0ac0`–`adc` | core EMEM ch0–3 control/data | ch0 `0x5536c785`/`0x6fd593dc`; ch1 `0xc79705f3`/`0x8f7a6cc2`; ch2 `0x5792ea26`/`0xf7cd4b7b`; ch3 `0xc1c4c375`/`0x21fa03ab` |
| `0x008f0ae0`–`aec` | core EMEM ch4–5 | `0` |
| `0x008f0af0`–`afc` | core EMEM ch6–7 | `0xBADF5620` |
| `0x008f2ac0` / `c4` | PFSP EMEM ch0 | MCTP/NVDM transport; host-driven |
| `0x008f2ac8`–`2afc` | PFSP EMEM ch1–7 | host: ch4–7 `0xBADF5720`, ch1–3 zero/`0xdead5ed0`; GSP: ch1/2/4/6/7 `0xBADF5723`, ch3/5 zero/`0xdead5ed0` |

### A.8 SEC2 (`0x840000`–`0x840fff`)

| Offset | Name | Value / note |
|---|---|---|
| `0x00840180` / `184` | DMEM port | host `0xBADF5720`, GSP `0xBADF5723` |
| `0x008401c0` / `1c4` | DMEM control/data | AINCR works; first 8 KB zero |
| `0x008403c4` | SEC2 PLM | `0x00000b0f` (read all / write none) |
| `0x00840ac0` / `ac4` | EMEM | `0x02000040` / `0`; empty |

### A.9 PMU and CMS2

| Offset | Name | Value / note |
|---|---|---|
| `0x0010a000` | PMU guess | all `0xBADF5040`; wrong base |
| `0x008aa374` / `378` | OOBHUB CMS2 indirect read | 448/8192 nonzero, repeating 128-dword block |

### A.10 Bad-read sentinels

Bits `[31:8]` are the PRI-ringstation error code (`NV_PPRIV_SYS_PRI_ERROR_CODE`,
field `31:8` in `dev_pri_ringstation_sys.h`); the low byte is undecoded.

| Value | PRI code | Observed when |
|---|---|---|
| `0xBADF5040` | `0xBADF50` `FECS_PRI_CLIENT_ERR` | offset not implemented |
| `0xBADF5610` | `0xBADF56` (not public) | no such Falcon port (GSP IMEM/DMEM) |
| `0xBADF5620` | `0xBADF56` (not public) | FSP core port/IMEM/DMEM present but inaccessible |
| `0xBADF5720` | `0xBADF57` (not public) | present but blocked to **this caller** (host) |
| `0xBADF5723` | `0xBADF57` (not public) | present but blocked to the **GSP** |
| `0xBADF510C` | `0xBADF51` generic PRI client/privilege error | fuse-block instance; not fuse-specific (E60) |
| `0xBADF5128` | `0xBADF51` generic PRI client/privilege error | refused PL2 access at BAR0 `0x137200` (E60) |
| `0xBADF4100` | `0xBADF41` PRI decode/access error | refused access to GSP `HWCFG2` `0x1100f4` (E60) |
| `0xBADF5545` | `0xBADF55` (not public) | FECS command-ID register read-blocked |
| `0xBADF1100` | `0xBADF11` `FECS_PRI_DECODE` | address not decodable |
| `0xBADFFFFF` | `0xBADFFF` (not public) | GSP-master read of the four PRISCV ICD registers; the host reads `0` there (E63) |

Three failure classes are distinguishable: **decode** (`0xBADF11xx`, `0xBADF41xx`),
**client error** (`0xBADF50xx`, `0xBADF51xx`), and **refused/blocked**
(`0xBADF57xx`). The `0xBADF56xx` values, the `0xBADF5720`/`0xBADF5723` pair, and
`0xBADF5545` show that the low byte also encodes the caller/engine for the blocked
and port cases. `0xBADF51` is a family, not a fuse marker: the low byte varies
(`0x0c` at the fuse block, `0x28` at `0x137200`).

---

## Appendix B — Firmware inventory

All "encrypted" entries show entropy ≥ 7.98 and no readable strings in the body;
the plaintext portion is limited to the container/ELF wrappers. Debug and production
variants are byte-identical outside the body.

| Path / symbol | Size | Format / measurement |
|---|---:|---|
| `gsp_ga10x.bin` | 72,830,976 B | GSP-RM RISC-V ELF, base `0x01000000`; `.fwimage` plaintext |
| `gb202/gsp/bootloader-570.144.bin` | 200,812 B | `0x10de` container, version 1; entropy 7.990 |
| `gb202/gsp/fmc-570.144.bin` | 199,820 B | ELF32; sections `hash` (0x30), `signature` (0x60), `publickey` (0x61), `image` (0x30a48); body `0x30A00` = code `0x25800` + data `0xA800` + `0xA00`; entropy 7.999; prod signature verifies |
| `GspRmBoot_GB202` PROD | 290,816 B (`0x47000`) | driver bindata, file `0x4d6a58`; fully encrypted, **no plaintext header**, entropy 7.999 (E68); this is the image observed executing at `0xefd00000` |
| `GspRmBoot_GB202` DEBUG | 290,816 B | file `0x51da78`; 98.4% of bytes differ from prod; entropy 7.999; prod/debug XOR at the chance rate (0.401% zeros), no keystream reuse (E68) |
| `GspRmFmcGfwProdSigned_GB202` | 287,304 B (`0x46248`) | header `03 04 48 00`; body `0x46200` = `0x37000` + `0xE800` + `0xA00`; SHA-384 + ECDSA P-384 verify (prod key `04 8bf118bb…`) |
| `GspRmFmcGfwDebugSigned_GB202` | 287,304 B | identical header; **99.6%** of body differs; signed by debug key `04 d30bd54b…`; signature verifies |
| `GspRmFmcGfwDebugSigned_GB20B` | 212,296 B (`0x33d48`) | 384-byte signature and public key |
| `ConcatenatedFMC_GB202` | 478,454 B (`0x74cf6`) | entropy 8.000 |
| `ksec2BinArchiveBlUcode_TU102` | 303 B | SEC2 booter, Turing only |
| `ksec2BinArchiveSecurescrubUcode_AD10X` | 6,233 B | secure scrub, Ada only |
| Board vBIOS (per card) | 819,200 B dumped of a ≥ 876,544 B image | at BAR0 + `0x338000`; PciAt `0xFA00` + EFI `0x18000` + FwSec `0xFA00` + FwSec `0x9E800`; µcode table image `0x64E9D`, encrypted, no FWSEC entries; `0xDC00` beyond the 1 MiB PROM aperture |
| PROM head blob (per card) | 218 KiB encrypted | `0x1400`–`0x36a40` of the 2 MiB aperture; `NVFW` marker at `+0x1000`; plaintext board metadata at `0x36a40` |
| FSP / GSP BootROM | — | no image in any package; immutable ROM |

---

## Appendix C — Error-code and sentinel reference

### C.1 FMC/FSP oracle codes

| Code | Channel | Trigger | Recovery |
|---|---|---|---|
| `0x83d` | `Fatal GSP-FMC Error`, partition 1 | vidmem FRTS withheld (`RmDisableCotCmd=0x4`) | clean |
| `0xd9` | FSP command response (Task `0x1`, cmd `0x14`) | COT `frtsVidmemSize != 0x100000` | clean |
| `0xd6` | FSP command response | COT FRTS offset not 128K-aligned | clean |
| `0x827` | `Fatal GSP-FMC Error`, partition 1 | `WprMeta.magic` wrong | clean |
| `0x82e` | `Fatal GSP-FMC Error`, partition 1 | `WprMeta.sizeOfBootloader` changed (`0x47000` + 1) | clean |
| `0x885` | `Fatal GSP-FMC Error`, partition 1 | `WprMeta.bootloaderManifestOffset` outside the image | clean |
| `0x377` | FSP command response | COT hash authentication failure | **WPR2 left up** |
| `0x1db` | FSP command response | COT public key not accepted (self-signed pair) | **WPR2 left up** |
| `0x33` | FSP command response (Task `0x1`, cmd `0x14`) | FMC container byte changed (header or body) while the COT hash is stock | **WPR2 left up** |
| `0xaff` | `Fatal GSP-FMC Error`, partition 1; additional info `0xb` | modified GSP-RM image **or bootloader image** | clean if firmware restored |

### C.2 NV status codes seen

| Code | Name | Context |
|---|---|---|
| `0x1f` | `NV_ERR_INVALID_ARGUMENT` | `GPU_EXEC_REG_OPS` with every `GR_CTX` regtype (E71) |
| `0x56` | `NV_ERR_NOT_SUPPORTED` | RISC-V debug stubs; `kernel_gsp_booter` paths; `GPU_EXEC_REG_OPS` `FB` regtype (E71) |
| `0x62` | `NV_ERR_RESET_REQUIRED` | RPCs to a fatal GSP |
| `0x65` | `NV_ERR_TIMEOUT` | GSP status queue after an undersized heap |

### C.3 Data sentinels

| Value | Meaning |
|---|---|
| `0xdead5ed0` | dummy/unimplemented EMEM channel data |
| `0xaddeadde` | uninitialized context-buffer poison |
| `0xffffc04c` | `NV_PROM_DATA(0)` read on this board; PROM not at the documented base |
| `0x00c36180` | stock `FEAT_READOUT_1`, not a sentinel but a constant used as a search key |
| `0xbadfbadf` / `0xbadfbadfbadfbadf` | ICD command rejected (`ERROR[14]` set); 32-/64-bit form (E67) |

---

## Appendix D — Experiment records

Each record gives the date, the hypothesis, the method (with the commands
needed to repeat it), the result, and the artifacts. Records are grouped by
the lever they test, in the same order as Part II. `E44` (the reassessment), the
cross-checks `E48`/`E49`, and the tracing audit `E55` are in D.H; the registry
records `E50`–`E52` are in D.B, the PLM decode `E53` and the E70/E71 window and
regtype follow-ups in D.A, and the pre-FMC sampler `E54` and the boot-buffer dump
`E72` in D.E.

### D.A Software register writes

#### E07 · `GPU_EXEC_REG_OPS` first attempt — invalidated

*2026-10-25 · Revision 7 · status: INCONCLUSIVE (superseded by E08)*

**Hypothesis.** A GSP-executed write can reach `FEAT_OVR_SM_SS0` and stick.

**Method.** `regops/regops.c`, an RM client on `/dev/nvidiactl`:
`NV_ESC_RM_ALLOC` (client `0x41`, device `0x80` with `deviceId`, subdevice
`0x2080`), then `NV_ESC_RM_CONTROL` with `0x20800122`. `hRoot` must be the client
handle for child allocations; the device allocation needs `NV_ESC_REGISTER_FD` on
`/dev/nvidiaN` first. Modes: `read` (8 × `READ_32`), `write`, `rate` (`0x20801230`),
`name` (`0x20800110`).

```bash
sudo ./regops 1 0000:41:00.0 read
sudo ./regops 1 0000:41:00.0 rate
```

**Baseline (direct BAR0 mmap, `41:00.0).** `PLM 0xfffffb8f`, `READOUT_1 0x00c36180`,
`SS0 0x21240001`, `SS1 0x00000002`, `FMLA32 3`, `SM_ISSUE_RATE 5`, `OPTVRDIS 0`.

**Result.** The register-op control returned `0x62` (`NV_ERR_RESET_REQUIRED`) on
every invocation, with no per-op status. A parameterless getter on the same client
returned `NV_OK`; `GET_NAME_STRING` returned `0x1F`.

**Cause.** `dmesg -T` showed both GSPs had crashed 36 minutes earlier:

| Time | GPU | Sequence |
|---|---|---|
| 16:13:40 | `41:00.0` | Xid 13 → Xid 120 → Xid 154 |
| 16:13:47 | `c1:00.0` | identical, 7 s later |

Xid 120: `GSP task exception: load access page fault (cause:0xd) @ pc:0x1368618,
partition:4#0`, `stval=0x250`. `_kgspRpcSanityCheck` returns `NV_ERR_RESET_REQUIRED`
for every RPC once the GSP is fatal. RM numbering: GPU0 = `c1:00.0` =
`/dev/nvidia0`; the first attempt used `deviceId 0`, the already-crashed card.

**Causation.** Not established. The crash window coincides with a read-only BAR0
page scan of `0x300000`–`0x400000` on `41:00.0`, but `c1:00.0` faulted 7 s later at
the same PC.

**Machine state.** Both GPUs `GPU Reset Required`; `nvidia-smi -r` not supported on
GeForce; `echo 1 > .../remove` spun in the driver. Recovery is a forced reboot.

**Artifacts.** `regops/regops.c`; the run's dmesg is in `dmesg.txt`.

#### E08 · `GPU_EXEC_REG_OPS` second attempt — the write is dropped

*2026-10-25 · Revision 8 · status: CLOSED-MEASURED*

**Method.** After a clean reboot (`uptime` 1 min, no Xid, both GSPs at 595.91.07).
Target `deviceId 1` = `41:00.0`. Modes: `one`, `read`, `wr <offset> <value>`
(`WRITE_32` with `regAndNMask = ~value`, then `READ_32`), `sc` (scratch dump plus
positive control).

```bash
sudo ./regops 1 0000:41:00.0 one
sudo ./regops 1 0000:41:00.0 read
sudo ./regops 1 0000:41:00.0 wr 82381c 0
sudo ./regops 1 0000:41:00.0 sc
```

**Results.**

| Step | Result |
|---|---|
| `one` | `SUCCESS`, `PMC_BOOT_0 = 0x1b2000a1`, matches BAR0 |
| `read` | all 8 ops `SUCCESS`; GSP and host values identical |
| `wr 82381c 0` | write `SUCCESS`; readback `0x21240001`; host BAR0 `0x21240001` |
| `sc` | selected `SCRATCH[15]` (`0x143c`): write `0x5A5AA5A5` → read `0x5A5AA5A5` → write `0` → read `0`, all in one RPC |

**Conclusion.** The path works and the FEAT write is silently dropped by
`FEAT_OVR_PLM`; success status cannot distinguish applied from dropped. This is the
negative/positive control pair reused by every later register claim.

**Artifacts.** `regops/regops.c`; no files written to the GPU.

#### E09 · The FEAT bank map and its write gate

*2026-10-25 · Revision 9 · status: CLOSED-MEASURED*

**Hypothesis.** Some register in the wider FEAT bank may have a different write
gate; `0x82380c = 0x00888888` was the candidate because it reads as an active
override.

**Method.**

```bash
sudo ./regops 1 0000:41:00.0 dump 823800 50        # bNonTransactional=1
sudo ./regops 1 0000:41:00.0 wr 82380c 88888888
```

**Result.** All 50 map ops returned `SUCCESS`; unimplemented offsets appear as
`0xBADF5040`, not as errors. The map is in Appendix A.3. The `0x88888888` write
returned `SUCCESS` and the readback stayed `0x00888888`.

**Symbol resolution.** A 4-byte scan found `0x00823814` once in `.text` at file
offset `0x2b5cb0`, inside `kmemsysCheckReadoutEccEnablement_GA100` (`0x2b2a10`,
40 bytes): `mov ecx, 0x823814 ; call <reg read> ; shr eax,16 ; and eax,1 ; ret`.
The GB100 variant (`0x2b3000`) computes `lea ecx,[rax+0x3814]` with `rax=0x820000`.
A targeted scan for `b9 imm32` in `0x820000`–`0x830000` and `8d 88 imm32` with
`imm` in `0x3000`–`0x3fff` finds only `0x820c04`, `0x82074c`, `0x823814`, and a run
of `0x8230xx` registers used by unrelated code.

**Artifacts.** `regops/results/` (map logs); decompiled snippets above.

#### E12 · The FUSE/OTP gate and `SM_ISSUE_RATE_MODIFIER`

*2026-10-25 · Revision 12 · status: CLOSED-MEASURED (both)*

**FUSE map.** Four non-transactional `dump` batches over `0x820000`–`0x8207ff`;
`regops/fuse_probe.sh` automates it and collapses sentinel runs. The map is in
Appendix A.2.

**FUSE write tests.**

```bash
sudo ./regops 1 0000:41:00.0 wrr 82074c 0 1     # GSP PL2: write/read/restore/read
sudo ./regops 1 0000:41:00.0 barw 82074c 0 1    # host PL0
sudo ./regops 1 0000:41:00.0 wrr 8207d8 0 3
sudo ./regops 1 0000:41:00.0 barw 8207d8 0 3
```

All four writes were issued; the registers stayed `1` and `3`. `wrr` submits the
four ops in one RPC; `barw` uses a read/write mmap of `resource0`.

**`SM_ISSUE_RATE_MODIFIER` write tests.**

```bash
sudo ./regops 1 0000:41:00.0 barw 504204 0 5     # host: 5 -> 0 -> 5
sudo ./regops 1 0000:41:00.0 wrr  504204 0 5     # GSP:  5 -> 0 -> 5
```

Both land. A pre-run write is overwritten at CUDA context creation, so the probe
pokes the register from inside the process after `cuCtxCreate` and before every
launch.

**The sm_120 probe.** PTX is generated with NVRTC and assembled with ptxas because
nvcc 13 rejects GCC 15's `noexcept` math declarations:

```bash
cd sm120-probe
python3 build_ptx.py
/usr/local/cuda-13.0/bin/ptxas -arch=sm_120 -O3 \
    -o tensor_modes_issue_sm120.cubin tensor_modes_issue_sm120.ptx
CUDA_VISIBLE_DEVICES=<UUID> python3 tensor_modes_driver_runner.py \
    tensor_modes_issue_sm120.cubin --sha256 <hash> --expect-uuid <UUID> \
    --expect-power-limit 575 --iters 20000 --reps 3 \
    --bdf 0000:41:00.0 --reg-offset 0x504204 --reg-value 0
```

The runner selects the card by UUID, checks the power cap, validates all 270,336
output cells per mode, records clocks/power, and emits JSON. `run_modifier_test.sh`
wraps set → measure → readback → restore.

**Result.** Cubin SHA-256 `099aecf4…`. Baseline (modifier 5): 227.1 / 227.1 / 113.6
TF/s and 596.5 TOPS; held at 0: 227.1 / 225.9 / 113.0 and 591.1. The register log
reads 0 at all 17 stages. Stock rates reproduce §1.2 within 1–2%.

**Artifacts.** `sm120-probe/` (`.cu`, `build_ptx.py`, runner, `run_modifier_test.sh`,
cubin, `results/revision12_summary.json`); `regops/regops.c` (`bar`, `barw`, `wrr`
modes); `regops/fuse_probe.sh`.

#### E53 · The PLM field decode

*2026-10-26 · status: CLOSED-STATIC (corrected)*

**Hypothesis.** The "cleared bit 10 names a removed source" reading of
`FEAT_OVR_PLM = 0xfffffb8f` is wrong; the field layout should be the Falcon v4 PLM
used by the other IP blocks.

**Method.** Apply the Falcon v4 privilege-mask fields from the open tree
(`dev_falcon_v4.h`, e.g. the nvswitch/ls10 copy) to the measured value, and compare
with Ada's `0xffffff8f` and with the low-byte semantics already established.

**Result.**

| Bits | Field | `0xfffffb8f` | Ada `0xffffff8f` |
|---|---|---|---|
| `3:0` | `READ_PROTECTION` | `0xf` (all levels) | same |
| `7:4` | `WRITE_PROTECTION` | `0x8` (**L3 only**) | same |
| `8` | `READ_VIOLATION` | report error | same |
| `9` | `WRITE_VIOLATION` | report error | same |
| `10` | `SOURCE_READ_CONTROL` | 0 = lowered | 1 = blocked |
| `11` | `SOURCE_WRITE_CONTROL` | 1 = blocked | same |
| `31:12` | `SOURCE_ENABLE` | `0xfffff` (**all 20 sources**) | same |

**Conclusion.** There is no removed source and no hidden `[23:8]` source-enable field
to hunt: the source-enable field is `[31:12]` and is fully populated. The only gate
is the write mask, `[7:4] = 8`, i.e. PL3. The bit-10 difference from Ada is
`SOURCE_READ_CONTROL`, a read-side control, not a writer.

**Caveat.** The FEAT block is not documented in the public headers. The low byte
matches the Falcon layout exactly; the names above it are applied by analogy and are
*(source)*, not a FEAT-specific definition.

**Artifacts.**
`open-gpu-kernel-modules/src/common/inc/swref/published/nvswitch/ls10/dev_falcon_v4.h`.

#### E70 · The post-FLR L2 window: 1.32 s, and no PL2 master inside it

*2026-10-28 · status: CLOSED-MEASURED (early-GSP-boot variant retracted)*

**Hypothesis.** The L2-writable PLM window E65 found after an FLR is reachable if
the host opens the device immediately after the bind and boots the GSP-RM inside
it: a PL2 `GPU_EXEC_REG_OPS` write to `SS0`/`SS1` issued then would land.

**Method.** `phase2b/plm_window_race.sh` (`measure` | `benign` | `payload`).
After an unbind and an FLR, a direct BAR0 poller (`regops ... plmpoll 5 6000`,
which re-maps `resource0` on every sample so it survives the bind) starts
*before* the bind and samples the FEAT bank plus GSP `ENGINE` (`0x1103c0`), the
reset PLM (`0x1103c4`) and the host PC mirror (`0x1113ec`). The bind probe runs
across the window; `nvidia-smi -L` triggers the first open.

```bash
sudo phase2b/plm_window_race.sh measure
```

**Result.** Three runs on `41:00.0`. The first started the poller after the bind
and missed the window (`first=0xfffffb8f`). The next two:

| Run | First sample | Re-lock | First GSP-RM PC |
|---|---|---:|---:|
| `..._225505_measure` | `0x80842bcf` at t=0 | **1156 ms** | not logged |
| `..._225752_measure` | `0x80842bcf` at t=0 | **1323 ms** | **3176 ms** |

The boot-image PC (`0xefd0xxxx`) was not sampled in either run; by E68 it can
only be the ~0.5–0.6 ms immediately before the first GSP-RM PC. The bind
consumes ~1.0 s of the 1.32 s
window; the open instant was not logged, but the open→GSP-RM path is ~2.1 s
(open inferred at ~1.05 s → GSP-RM at 3.18 s), which cannot fit the 1.32 s window
even with a zero-delay open. The re-lock is 1853 ms before the first GSP-RM PC.

**Conclusion.** The window is real and was previously only bracketed; it now has
a measured duration. It closes before the only PL2 master exists, and the re-lock
is a pre-boot GPU-side devinit (FSP/PMU/hardware), not the FMC and not the
GSP-RM. E65's "the PL2 window is real but not reachable" is confirmed with
timing, and the "boot the GSP early" variant is retracted: the GSP boot path is
longer than the window. `benign`/`payload` were not run because they cannot win;
they would only cost an FLR.

**Artifacts.** `phase2b/plm_window_race.sh`;
`phase2b/plmrace_20261028_225311_measure/` (missed),
`..._225505_measure/`, `..._225752_measure/` (`summary.txt`, `poll.txt`);
`regops/regops.c` modes `plmpoll` and `race`.

#### E71 · `GR_CTX`/`GR_CTX_SM`/`FB`: not reachable from PL0 without an RM channel

*2026-10-28 · status: CLOSED-MEASURED (caller-limited)*

**Hypothesis.** `NV2080_CTRL_CMD_GPU_EXEC_REG_OPS` reaches per-context/per-SM
registers through `regType = GR_CTX`, `GR_CTX_TPC`, `GR_CTX_SM` or
`GR_CTX_QUAD`, giving the per-SM selector path that open question #5 asks for.
Every earlier register pass (E08, E09, E12) used `GLOBAL` only.

**Method.** `regops` gained `gprobe`, `gprobe_route`, `gr`, `gw` and `race`.
`gprobe` reads `0x504204`, `SS0`, `SS1` and `PLM` under `GLOBAL`, `GR_CTX`,
`GR_CTX_TPC`, `GR_CTX_SM`, `GR_CTX_QUAD` and `FB`. `gprobe_route` repeats the
`GR_CTX` read with `grRouteInfo.flags` 0–3 (`TYPE_NONE`/`ENGID`/`CHANNEL`/both).
`phase2b/gprobe_with_ctx.sh` holds a CUDA context on `41:00.0` from plain C
(`cuda_ctx.c`, driver API) while the probe runs, to test whether a live channel
is the missing argument.

```bash
sudo regops/regops 1 0000:41:00.0 gprobe
sudo phase2b/gprobe_with_ctx.sh route
```

**Result.**

| `regType` | Control status | Per-op status |
|---|---|---|
| `GLOBAL` | 0 | SUCCESS; `0x504204=5`, `SS0=0x21265043`, `SS1=6`, `PLM=0xfffffb8f` |
| `GR_CTX`, `GR_CTX_TPC`, `GR_CTX_SM`, `GR_CTX_QUAD` | **`0x1f` `NV_ERR_INVALID_ARGUMENT`** | SUCCESS, value 0 |
| `FB` | **`0x56` `NV_ERR_NOT_SUPPORTED`** | SUCCESS, value 0 |

Root, a live CUDA context, and every `grRouteInfo` flag give the same `0x1f`.
The ctrl-table handler pointer for `0x20800122` (`0x1400740`) does not resolve to
a function start (it lands inside a GR feature/engine function), so the GSP
handler could not be decoded from the table.

**Conclusion.** The type is recognized (not `INVALID_TYPE`) but the batch is
rejected before execution; `FB` is not supported at all. The leading explanation
is that the GSP needs a channel owned by the calling RM client. A CUDA channel
is not addressable: RM handles are client-scoped, the CUDA client's handle is not
exposed, and the `hClientTarget=0` "all current and future channels" expansion is
not implemented for context ops on this GSP build. The only way to test the
explanation is a channel owned by our client (VA space + GPFIFO + UserD +
bind/schedule, a mini RM client) or a kernel hook that issues the op with a
channel handle; the GSP may still reject it. Open question #5 is not closed as a
physics question, but the cheap PL0 route is.

**Artifacts.** `regops/regops.c` (`gprobe`, `gprobe_route`, `gr`, `gw`, `race`);
`phase2b/gprobe_with_ctx.sh`, `phase2b/cuda_ctx.c`, `phase2b/cuda_ctx`;
`phase2b/gprobe_20261028_230324_probe/`, `..._230521_route/`.

### D.B Registry keys and the static audit

#### E01 · Static register audit and registry-key closure

*2026-10-25 · Revision 2 · status: CLOSED-STATIC (register audit); SUPERSEDED(E50) for the registry-key closure*

**Inputs.**

| Input | Identity |
|---|---|
| `gsp-analysis/input/gsp_fwimage.bin` | 72,830,976 B, `.fwimage` from `gsp_ga10x.bin`, base `0x01000000` |
| `gsp-analysis/out/gsp_decompiled.c` | 47 MB, 22,941 functions |
| `gsp-analysis/out/modules_v2/` | 69 module files |
| `nvidia.ko` (DKMS) | decompressed to 21,085,053 B, 595.91.07 |
| `open-gpu-kernel-modules/` | commit `10bdbad1`, 2024-12-07 |

**Method.**

1. Raw constant scan of the `.fwimage` for each FEAT/FUSE offset as 32- and 64-bit
   little-endian, plus a histogram of every aligned dword in
   `0x00800000`–`0x008fffff` (1,735 distinct values, mostly data-table false
   positives).
2. Decompiled-code scan: every `0x8xxxxx` constant in all 69 modules; 151 distinct
   values in `0x00800000`–`0x008fffff`; the `0x00823800`–`0x0082382f` window is
   empty.
3. String-index query with reference counts (`out/strings.csv`), then raw substring
   searches for `regOpCount`, `regOps`, `hChannelTarget`, `ExecRegOps`,
   `permission to access register`, `osIsAdministrator` (all absent).
4. Pointer scan for 4- and 8-byte absolute pointers to the registry strings.
5. Host-driver scan: `zstd -d nvidia.ko.zst`, then the same constant and string
   scans.
6. Ctrl method-table decode at RAM `0x01d16xxx`: 32-byte entries of the form
   `{ctrlId | paramSize<<32, classPtr, handlerPtr, <undecoded>}`; confirmed against
   `0x20800a34` → `0x48` and `0x20800122` → `0x30`.
7. Targeted decompilation with `gsp-analysis/scripts/DecompileAt.java` against the
   Ghidra project.
8. Source cross-reference in the open modules.

**Reproduce.**

```bash
cd /home/shutty/code/nvidia-unlock/gsp-analysis
python3 - <<'EOF'
import struct
d = open('input/gsp_fwimage.bin','rb').read()
for t in (0x00823804,0x00823818,0x0082381c,0x00823820,0x008207d8,0x00504204):
    n = d.count(struct.pack('<I', t)) + d.count(struct.pack('<Q', t))
    print(f"{t:#010x} {n}")
EOF

grep -rhoE '0x8[0-9a-f]{5}\b' out/modules_v2/mod_*.c | sort -u | wc -l
```

**Results.** Zero literal references in all components (§4.4). The registry keys
`RMOverrideSmSpeedSelect` and `_1` have zero code references, no absolute pointer,
and are not forwarded by the driver. **This registry-key conclusion is superseded by
E50**: the reference scan missed the sign-extended `auipc` materializations, and the
forwarding argument was wrong (§6.2). The ctrl-table entries are reliable; the
Ghidra-recovered handler bodies were **not** used as evidence (see limitations).

**Limitations.** Ghidra never created functions for table-referenced code; handler
pointers land 2 bytes before the first instruction (e.g. `0x1400740` vs
`0x1400742`), so decompiling there yields plausible but unusable bodies. A literal
scan cannot exclude a computed access — the blind spot that produced E13/E17.

**Artifacts.** `scripts/DecompileAt.java`; `out/handler_rate.c`,
`handler_rate2.c`, `handler_exec_regops.c`, `handler_exec_regops2.c`;
`out/strings.csv`; `out/modules_v2/`.

#### E11 · Host-driven boot path and the registry experiments

*2026-10-25 · Revision 11 · status: LIVE (input surface) / CLOSED-MEASURED (bootstrap)*

**Method.** Each test is one module reload with `NVreg_RegistryDwords` on the
**modprobe command line only**; no `/etc/modprobe.d` change. Values are parsed by
`os_strtoul(value, NULL, 0)`, entries separated by `;`.

```bash
cd ~/code/nvidia-unlock/bootpath
sudo ./gsp_bootpath_tests.sh --dry-run          # plan, no root needed
sudo ./gsp_bootpath_tests.sh --only gspfmc      # one test
sudo ./gsp_bootpath_tests.sh --restore          # unload + reload stock
```

The script unloads `nvidia_drm`/`nvidia_modeset`/`nvidia_uvm`/`nvidia`, reloads with
the key, waits 15 s, captures the `dmesg` delta **before** any health check, and
restores stock after every test.

**Results.** In §6.3. Key findings: withholding vidmem FRTS yields the structured
FMC report `0x83d`; the GSPFMC path deadlocks on the reset PLM; the host sees
`0xBADF5720` on `0x1103c0` in that state.

**Failure modes that shaped the harness.**

1. A SIGTERM-stopped `nvidia-smi` pins the module (`rmmod` reports "in use");
   fixed with `timeout -s KILL` and `pkill -9 -x nvidia-smi`.
2. The GSPFMC failure leaves an ioctl blocked even on SIGKILL; only a reboot exits.

**Source checkout for Phase 2b.** The local clone's origin is a fork without
NVIDIA's release tags, so the tag was fetched upstream:

```bash
git fetch https://github.com/NVIDIA/open-gpu-kernel-modules.git tag 595.91.07
git checkout -f 595.91.07        # detached HEAD at 9f087a6d
```

`version.mk` then reads `595.91.07`, matching the installed driver. Notes: stale
ignored artifacts from the 570 tree need `make clean` first; the tree contains
`kernel_gsp_gb202.c`, read in E16.

**Artifacts.** `bootpath_20261025_180449.txt` (harness validation),
`bootpath_20261025_180600.txt` (`frts-sys`, `frts-vid`), `bootpath_20261025_182141.txt`
plus the pasted kernel log (`gspfmc`).

#### E50 · Registry-key reachability, re-tested

*2026-10-26 · status: CLOSED-STATIC (keys are live)*

**Hypothesis.** The E01 closure of `RMOverrideSmSpeedSelect*` is wrong: E01 used the
same class of reference negative later withdrawn in E13 → E17, and its forwarding
argument was untested.

**Method.**

1. Re-run the raw reference scan with correct `auipc` sign extension over the
   72,830,976-byte `.fwimage`:

   ```bash
   cd /home/shutty/code/nvidia-unlock/gsp-analysis
   python3 scripts/refscan.py input/gsp_fwimage.bin 0x01f3a958 0x01f3a970
   # 0x015cf1be  auipc+addi -> 0x01f3a958
   # 0x015cf1ea  auipc+addi -> 0x01f3a970
   ```

2. Disassemble the sites (`DisasmRange.java 0x15cf1a0,46`) and resolve the callee.
3. Read the host forwarding path (`osapi.c:3352`) and check the driver binary for
   the strings.

**Result.** Both strings are materialized in 595.91.07 and parsed as registry keys.
The callee is `FUN_ram_011cfb2c`, the same registry-read primitive used for
`ForceP2P` (`mod_pcie_bif.c:167`). On success the parser stores:

| Key | Presence | Value |
|---|---|---|
| `RMOverrideSmSpeedSelect` | config+`0xE45` = 1 | config+`0xEA8` = parsed dword |
| `RMOverrideSmSpeedSelect1` | config+`0xE46` = 1 | config+`0xEAC` = parsed dword |

The forwarding argument is independently false: `rm_parse_option_string()` writes
every unrecognized `key=value` into the RM registry, and the host binary contains
zero occurrences of `RMDisableFeatureDisablement` although that key works.

**Status.** CLOSED-STATIC: the keys are live code paths. Their consumer was not
resolved (the containing region is unanalyzed, like the parser itself).

**Correction (E58).** `0x015cf1be` is an interior address of
`FUN_ram_015ce3e8` (the parse block is identical). The consumer is now resolved:
`config+0xEA8/0xEAC` are read by `FUN_ram_0216d680` and `FUN_ram_0217f718`,
reduced to booleans, and written to a GR context/ucode descriptor; EA8 is gated by
`config+0xEA4`.

**Artifacts.** `gsp-analysis/scripts/refscan.py`, `DisasmRange.java`;
`/home/shutty/open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/osapi.c`.

#### E51 · Registry-key hardware sweep

*2026-10-26 · status: CLOSED-MEASURED (inert)*

**Hypothesis.** If the parsed value reaches a rate writer, the issue rate or the
FEAT bank changes.

**Method.** `phase2b/regkey_rate_sweep.sh` — one stock-driver reload per variant,
the sm_120 probe on both cards, and a direct BAR0 read of `0x823800`–`0x823824`
before and after:

```bash
sudo ./phase2b/regkey_rate_sweep.sh --only speed88
sudo ./phase2b/regkey_rate_sweep.sh --only speed0
sudo ./phase2b/regkey_rate_sweep.sh --only featdis
sudo ./phase2b/regkey_rate_sweep.sh --only speedboth
# --bdf 0000:c1:00.0 fills the second card for a single variant
```

**Result.**

| Variant | `41:00.0` FP16/MHz | `c1:00.0` FP16/MHz | Bank |
|---|---:|---:|---|
| baseline (E49) | 0.07789 | 0.07771 | stock |
| `RMOverrideSmSpeedSelect=0x88888888` | 0.07821 | 0.07760 | identical |
| `RMOverrideSmSpeedSelect=0` | 0.07792 | 0.07755 | identical |
| `RMDisableFeatureDisablement=1` | 0.07782 | 0.07764 | identical |
| both keys (`0x88888888` / `0x8`) | 0.07782 | 0.07792 | identical |

All four probe modes were flat within ±0.4% per clock; `READOUT_1`, `SS0`, `SS1`,
the PLM and the static feature words at `0x823824/28/2c` (`FEAT_OVR_ROW_REMAP`/
`FEAT_READOUT_2`/`FEAT_OVR_ECC_2`, not counters; E56) were unchanged in every run.
No Xid, no GSP error.

**Artifacts.** `phase2b/regkey_20261026_205818`, `..._205904`, `..._210003`,
`..._210152`, `..._210237`, `..._210308`, `..._210340`;
`phase2b/regkey_rate_sweep.sh`.

#### E52 · The SKU feature-disable machinery in 595.91.07

*2026-10-26 · status: CLOSED-STATIC (display-only; no compute gate)*

**Hypothesis.** The rtx-p2p bypass (`RMDisableFeatureDisablement`) may gate the
full-rate tensor path the way it gates P2P on consumer parts.

**Method.** Static mapping of the 595.91.07 equivalents of the 590.48.01 structures:
locate the platform flag, the bypass byte, the checker and its feature table; trace
the call sites; enumerate the `ebreak` guards.

**Result.**

| Object | 595.91.07 | 590.48.01 |
|---|---|---|
| platform flag `is_geforce` | config+`0x4e58` | config+`0x4dd4` |
| bypass byte | config+`0x545a` | config+`0x53ca` |
| checker | `FUN_ram_015be840` (`0x148`) | `FUN_01418060` |
| feature table | `0x01d7ad48`, 10 × 24 B | same shape |

`is_geforce` is set by a PCI-device-ID → detector → switch inside the registry
parser `FUN_ram_011ac464`, not from a fuse. The checker's only GeForce special case
is **feature id 5 (IMP/HDMI/display)**; the table entries are byte-identical to
590.48.01 and contain no compute/tensor/SM-rate feature. The feature-5 call sites sit
next to `RMEnableIMP` and `RMSkipSnoozeFrames`. In 595 the nine inline bypass →
`ebreak` guards of 590 are gone; the bypass byte is read only by the parser and two
checkers. A second, separate checker (`FUN_ram_015be324`) uses different tables and
ids (`6,7,0x11,0x13,0x1d`) and is unrelated.

**Conclusion.** The p2p-style SKU bypass cannot reach a compute rate. Residual
unknown: the devinit branches in `gr_fecs` that test platform bytes (`+0x4e56`,
`+0x4e59`) are not conditioned on the bypass byte and look like assert/devinit paths.

**Artifacts.** `gsp-analysis/out/modules_v2/mod_registry.c`,
`mod_community_3_SmoothBrightnessDefaultE.c`; transient scripts under `/tmp/gspwork/`.

### D.C FECS and the GR context

#### E18 · Live FECS/FSP/SEC2 probes

*2026-10-25 · Revision 16 · status: LIVE (doorbell) / CLOSED (everything else)*

**Method.** `analysis-tmp/run_step1_2.sh` (read-only maps/streams) and
`analysis-tmp/run_step3.sh` (read-only streams plus four GSP `wrr` tests);
`analysis-tmp/hw_probe.c` does direct BAR0 reads and streams; `regops` does the GSP
reads/writes.

```bash
sudo ./regops 1 0000:41:00.0 dump 409660 8
sudo ./hw_probe fecs
sudo ./hw_probe fspemem 100 orig_regs.txt
sudo ./hw_probe falcon 8f0000 400
sudo ./hw_probe falcon 840000 800
sudo ./regops 1 0000:41:00.0 wrr 409688 ffffffff ffffffcf  # dropped
sudo ./regops 1 0000:41:00.0 wrr 409800 0 1               # landed; restored
```

**Results.** FECS values in §7.1 and Appendix A.4; FSP/SEC2 values in §8 and
Appendix A.7–A.8. 789/1024 FECS dwords are sentinels. All FECS PLM writes were
dropped; `0x409800` held its write. No new Xid.

**Static follow-up.** The GSP code around `mod_gr_fecs.c:65344`, `:69232`, `:86837`
uses the method at `obj+0x40`, then `FUN_ram_015e2724` with command IDs
`0x21/0x30/0x31/0x32/0x75/0x76`, then `FUN_ram_015cc798`.

**Artifacts.** `analysis-tmp/hw_probe.c`, `run_step1_2.sh`, `run_step3.sh`;
`analysis-tmp/hwprobe_20261025_232419/`, `hwprobe_20261025_233232/`.

#### E19 · The FECS command protocol, statically

*2026-10-25 · Revision 17 · status: mapped; not a host lever*

**Method.** Decompile `FUN_ram_015e2724` and `FUN_ram_015cc798`; correlate their
HAL-relative offsets with the measured absolute FECS map.

**Result.** Sender writes data `0x9500`, command ID `0x9504` (`cmd & 0xfff`), and
optional payload `0x9800 + 4*param`; waiter polls the status slot with
equality/mask/min/max match modes. Absolute map: `0x409500`/`0x409504`/`0x409800`
(§7.2). Known command IDs are listed in §7.2; none writes the FEAT selectors or
`SS0`/`SS1`.

**Ucode availability.** No FECS/GPCCS handler or vBIOS descriptor fingerprint exists
in the plaintext GSP-RM; the vBIOS µcode entries are encrypted.

**Artifacts.** `gsp-analysis/out/gsp_decompiled.c:495366` (`FUN_ram_015e2724`),
`:487902` (`FUN_ram_015cc798`); `mod_gr_fecs.c:40378`, `:36936`.

#### E20 · The FECS context path and the host GR structures

*2026-10-26 · Revision 18 · status: CLOSED-STATIC (no rate field)*

**Method.** `gsp-analysis/scripts/refscan.py` scans every 2-byte offset for `JAL`,
`AUIPC+ADDI`, `LUI+ADDI`, and raw 32/64-bit values with correct 20-bit sign
extension. Survivors are disassembled/decompiled with `DecompileAt.java`.

**Result.** Four materializations of the two context functions, all inside
`FUN_ram_01c1c374`; installed at `obj+0xD00`; caller `FUN_ram_0184499c`
(`mod_gr_fecs.c:85481`). The sequence and descriptor layout are in §7.3.

**Host structures checked at 595.91.07.** `GR_GLOBALCTX_BUFFERS`
(`g_kernel_graphics_context_nvoc.h:114-121`), `NV2080_CTRL_GR_CTX_BUFFER_INFO`
(`g_sdk-structures.h:2986-3002`), `kgrctxFillCtxBufferInfo_IMPL`
(`kernel_graphics_context.c:387-459`), `kgrctxPrepareInitializeCtxBuffer_IMPL`
(`:1701-1867`), `kgrctxMarkCtxBufferInitialized_IMPL` (`:1972-2054`). The only
`portMemCopy` calls are the UUID copy (`:373`) and a sort swap (`:984-986`).

**Artifacts.** `scripts/refscan.py`; `/tmp/fun_1c1c374.c` (transient);
`phase2b/bf16_ctxdump.patch`, `phase2b/dump_ctx.sh`, `phase2b/parse_ctxdump.py`.

#### E22 · First live GR context-buffer dump

*2026-10-26 · Revision 20 · status: partial*

**Method.** `phase2b/dump_ctx.sh` applies `bf16_ctxdump.patch`, builds the exact
595.91.07 tree, loads it, runs the sm_120 probe (`--iters 1 --reps 1`), captures
dmesg, and restores stock.

**Result.** GPU0 booted and produced four dumps; GPU1 failed with `_kgspBootGspRm:
unexpected WPR2 already up` and `RmInitAdapter failed! (0x62:0x40:2168)`. The probe
targeted GPU1's UUID and never ran, so the dumps are GPU0 driver-init contexts.

| Dump | Tag | Size | Phys | First 4 KB |
|---|---|---:|---|---|
| 1 | main | `0x377000` | `0x7e0b79000` | zero |
| 2 | patch | `0x9000` | `0x7e0f00000` | all `0xaddeadde` |
| 3 | main | `0x377000` | `0x7e0b92000` | 10 nonzero bytes; first word `0x02400000` |
| 4 | patch | `0x9000` | `0x7e0a47000` | `0x8f8` bytes initialized, 287 entries |

No known rate constant in the 4 KB windows. The patch buffer parses as
`{address, value}` VA clusters; values are context defaults (`0x00120000` 88×,
`0x40260000` 44×, `0x00400000` 41×).

**Artifacts.** `phase2b/ctxdump_20261026_000239/`.

#### E23 · Post-use patch buffer differential

*2026-10-26 · Revision 21 · status: negative for rate*

**Method.** Post-use hooks (`kgrctxUnmapMainCtxBuffer`, `kgrctxFreePatchBuffer`),
`BF16_CTXDUMP_CREATE=0`, GPU0.

**Result.** The main-exit dump lost its header to the dmesg ring; the patch-exit
dump is complete. Both buffers have 287 entries; exactly **10 values differ and no
address differs**:

| Address | Driver-init | Post-use |
|---|---:|---:|
| `0x0c804000` | `0x00422001` | `0x00280602` |
| `0x04104200` | `0x00422001` | `0x00280602` |
| `0x04804000` | `0xa0002001` | `0x303e0602` |
| `0x240e4200` | `0xa0002001` | `0x303e0602` |
| `0x10084200` | `0x00401280` | `0x002e2080` |
| `0x48404200` | `0x00401210` | `0x002e2010` |
| `0x2c444200` | `0x00401210` | `0x002e2010` |
| `0x00464200` | `0x00401200` | `0x002e2000` |
| `0x70804000` | `0x00442001` | `0x00320602` |
| `0x34104200` | `0x00442001` | `0x00320602` |

The changed slots are global-buffer address overrides, not selectors.

**Artifacts.** `phase2b/ctxdump_20261026_001052/`.

#### E24 · The main window at `0x4000` is zero

*2026-10-26 · Revision 22 · status: negative*

**Method.** Bounded 8 KB window at `BF16_CTXDUMP_MAIN_OFFSET=0x4000`, GPU0.

**Result.** Zero for both the uninitialized and the compute context. The patch-exit
buffer is byte-identical to E23's. The main buffer is a per-channel save area, not
the initialized image.

**Artifacts.** `phase2b/ctxdump_20261026_001610/`.

#### E25 · Global buffers and the switch to file dumps

*2026-10-26 · Revision 23 · status: transport fix*

**Result.** Only `global seq=8` (`UNRESTRICTED_PRIV_ACCESS_MAP`) survived the dmesg
ring; the first six global dumps were discarded. The harness was changed to write
each mapped buffer to `/tmp/bf16_ctxdump_<tag>_<gpu>_<seq>.bin` through new
`osOpenWriteFile`/`osWriteToFile` paths, with a 4 MB per-file cap and a parser that
scans for the known rate constants.

**Artifacts.** `phase2b/ctxdump_20261026_002058/`; `phase2b/parse_ctxfiles.py`;
`kernel-open/nvidia/os-interface.c`, `arch/nvalloc/unix/src/os.c`,
`os-interface.h` changes.

#### E26 · The full context image and the `0x88888888` false positive

*2026-10-26 · Revision 24 · status: negative*

**Method.** Full file dump, GPU0.

| File | Size | Nonzero | Notes |
|---|---:|---:|---|
| `main-exit_0_1` | 3,633,152 | 311,213 | driver-init |
| `main-exit_0_2` | 3,633,152 | 180,373 | compute |
| `patch-exit_0_1` | 36,864 | 36,864 | all poison |
| `patch-exit_0_2` | 36,864 | 1,336 | 287-entry list |
| `global_0_6` | 65,536 | 0 | `FECS_EVENT` |
| `global_0_7` | 524,288 | 0 | `PRIV_ACCESS_MAP` |
| `global_0_8` | 524,288 | 15,063 | `UNRESTRICTED_PRIV_ACCESS_MAP` |

The first six global context buffers were not captured (memdescs NULL or not
promoted). The main image contains **0** occurrences of `0x00c36180`,
`0xfffffb8f`, `0x00504204`, and either stock `SS0` word. `0x88888888` occurs 1,076
times aligned and 157 times in sixteen-byte runs: a fill pattern, not the Ada
payload.

**Artifacts.** `phase2b/ctxdump_20261026_002831/`.

#### E27 · Cross-card context comparison

*2026-10-26 · Revision 26 · status: CLOSED-MEASURED*

**Method.** Cold power cycle to clear GPU1's WPR2 state; one run with defaults
(`BDF=0000:41:00.0`, full-file dump, `EXITMAX=2`, `GLOBALMAX=6`). Both cards
initialized; the two main images were the first driver-init unmaps, captured before
the CUDA probe.

**Result.**

| Metric | Value |
|---|---:|
| Words compared | 908,288 |
| Differing words | 618 (0.068%) |
| Pages with a difference | 235 |
| Diffs below `0x4000` | 0 |
| Diffs `0x4000`–`0x1d0000` | 191 |
| Diffs `0x1d0000`–`0x330000` | 427 |
| Diffs above `0x330000` | 0 |

The first `0x4000` and last ~`0x47000` bytes are identical. 427 diffs are a 4-bit
index field at `[30:27]` in a `~0x3b00`-stride record array; 191 are 52-byte-stride
table words plus per-boot random values. No word decodes to the FEAT vector; no
known constant; `0x88888888` appears 1,000 times at identical offsets in both;
`UNRESTRICTED_PRIV_ACCESS_MAP` is byte-identical to the previous boot.

**Conclusion.** No card-dependent selector-shaped or rate-shaped field in the GR
context image.

**Artifacts.** `phase2b/ctxdump_20261026_003659/`; `phase2b/analyze_crosscard.py`.

### D.D HS / SEC2 / FSP memory windows

#### E10 · The HS memory-read route

*2026-10-25 · Revision 10 · status: CLOSED-MEASURED*

**Hypothesis.** A PL2 primitive can read decrypted FMC plaintext out of HS memory.

**Source basis.** The open checkpoint is 570.153.02; every quoted function was
confirmed in the running binary (`kgspPrepareBootBinaryImage_IMPL` at `0x25b840`,
`kgspResetHw_GB100` at `0x24f660`). `kgspPrepareBootBinaryImage_IMPL` allocates
`ADDR_SYSMEM` with `MEMDESC_FLAGS_ALLOC_IN_UNPROTECTED_MEMORY` and copies the bindata
verbatim; `_kgspBootstrapGspFmc_GH100` points the BootROM at it via
`BCR_DMAADDR_FMCCODE`. The host buffer is ciphertext by construction.

**Debug check.**

```bash
objdump -d nvidia.ko --start-address=0x68340 --stop-address=0x683b0
# kflcnRiscvIcd{WaitForIdle,ReadMem,ReadReg,Rpc}: mov $0x56,%eax ; ret
```

**Register map and streams.**

```bash
sudo ./regops/gsp_probe.sh
sudo ./regops/gsp_emem_stream.sh
sudo ./regops/gsp_emem_write.sh
```

Register values are in Appendix A.6. The stream arms `EMEMC(0) = 0x02000000`
(`AINCR` | 0), issues 32 × 64 reads of the same data address `0x110ac4`, and gets
`0x02000000 → 0x02002000` (4 B/read), 2048 words, all zero. The storage
discriminator is a 5/5 pass (§8.1).

**Notes.** `regops dump` walks addresses; `rep <off> <count>` was added to stream
one. Counts are parsed as hex. The arm value must be `0x01001ffc`, not `0x00011ffc`
(a malformed format string silently disables `AINCW`).

**Artifacts.** `regops/gsp_probe_20261025_174406.txt`,
`gsp_emem_20261025_174650.txt`, `gsp_emem_stream_20261025_174904.txt`,
`gsp_emem_write_20261025_175111.txt`; scripts `gsp_probe.sh`, `gsp_emem.sh`,
`gsp_emem_stream.sh`, `gsp_emem_write.sh`.

#### E21 · The FSP core EMEM port

*2026-10-26 · Revision 19 · status: CLOSED-MEASURED*

**Method.** Read-only maps on both cards; two write/read/restore/read batches on
`41:00.0`, each inside a single non-transactional RPC.

```bash
sudo ./regops 1 0000:41:00.0 ememstream 8f0ac0 8f0ac4 5736c785 5536c785 1
sudo ./regops 1 0000:41:00.0 ememstream 8f0ac0 8f0ac4 55360001 5536c785 1
```

**Result.** Both writes returned `SUCCESS` and read back unchanged; the data word
stayed `0x6fd593dc`; restore verified by the trap. The same path writes `0x409800`
and PBUS scratch, so this is a hardware/PLM drop. Map in Appendix A.7. The
`0x8f0a90` PLM (`0xffffff8f`) is the likely gate, inferred from proximity.

**Offline check of the 16-byte constant.** Not present in GSP-RM, `nvidia.ko`, the
vBIOS, the FMC containers, or their keys; not an MD5/SHA prefix; not an AES-128 key
for the FMC/bootloader in ECB/CBC/CTR with several key/IV variants.

**Script note.** `dump`/`bar` parse counts as hex; the first pass passed decimal
`64`/`128` and those dumps failed.

**Artifacts.** `analysis-tmp/fsp_emem_20261025_235825/`;
`analysis-tmp/run_step4_fsp_emem.sh`; `regops/regops.c` (`ememstream`).

#### E63 · The RISC-V PRISCV block and its two-sided host/GSP map

*2026-10-27 · Revision 64 · status: OPEN (map measured; ICD command path not tested)*

**Hypothesis.** The GSP's RISC-V core may expose a debug module (RISC-V DM or
Falcon ICD) above the `0x110000–0x11172c` window E10 swept. The public
`dev_riscv_pri.h` gives PRISCV offsets (`CPUCTL 0x388`, `RPC 0x3ec`,
`IRQMASK 0x528`, `IRQDEST 0x52c`, `PRIV_ERR 0x420–0x430`) and the Ampere/Turing
ICD layout (`CMD 0x3d0`, `ADDR0/1 0x3d4/0x3d8`, `RDATA0/1 0x3e4/0x3e8`), with
opcodes STOP/RREG/RDM/RSTAT/RCSR/RPC.

**Method.** `regops/riscv_dm_probe.sh` sweeps a half-open range in 128-dword
chunks through `GPU_EXEC_REG_OPS` (READ_32 only; the GSP is the bus master) and
prints a collapsed map, every implemented value, and a named check of the
header offsets. The host view is `regops ... bar <off> 40` (direct BAR0 read),
eight calls for `0x111000–0x1117ff`.

```bash
sudo regops/riscv_dm_probe.sh                 # 0x110000..0x113fff, GSP master
for o in 111000 111100 111200 111300 111400 111500 111600 111700; do
  sudo regops/regops 1 0000:41:00.0 bar $o 40
done
```

**Result — the base is `0x111000`, not `0x110000`.** The GB202 offsets land
there and match: `CPUCTL 0x111388 = 0x180` (halted `[4]=0`, active `[7]=1`),
`RPC 0x1113ec = 0x01404f66` (Ghidra decodes it as GSP-RM code: `slliw`,
`c.or`, `beq`, `c.ld`, `c.jalr a5`), `IRQMASK/IRQDEST 0x111528/52c =
0x810490d2/0x010800d0`, `PRIV_ERR_*` zero, and E10's `0x111700` is
`FAULT_CONTAINMENT_SRCSTAT` at offset `0x700`. The Falcon block ends at
`0x110d4c`; `0x110d50–0x110ffc` is unimplemented.

**Result — the block is partitioned per master.** 4,096 GSP reads and 512 host
reads over the same offsets; over the 512 common offsets: 66 identical, 199
differing, 69 host-value/GSP-sentinel, 80 GSP-value/host-sentinel. The host is
blocked (`0xBADF5720`) from the core-state half (`0x111004–0x111094`,
`0x111100–0x11115c`) and from the trace registers (`0x111404–0x111410`); the GSP
is refused (`0xBADFFFFF`) at the ICD and sees no port at `0x111400`. The host
has its own half: `0x1111a8–0x1111e4` (16 × `0x2`), `0x111610+`
(`0x83bbbbbb`/`0x8bb9bbbb`/`0xbbbbbbbb`), and the ICD.

**Result — no debug module in the requested window.** `0x111800–0x113fff`
contains 16 implemented dwords only: two 12-byte-stride tables at `0x111f00`
(4 × {`0x00000f00`, `0`, `0x11111111`}) and `0x111f80` (4 × {`0x00000f00`,
`0x04000000`, `0`}). `0x111fb0–0x113fff` is `0xBADF5040`.

**Result — the PC is one-sided.** `RPC` is visible only to the GSP and reads a
live code address. The host's `0x1113ec` is a different register: it changed
between two reads (`0x93002eb8` → `0x9300338a`, Δ`0x4d2`) and is not a PC. The
host therefore cannot sample the core's PC, and the GSP-side view exists only at
PL2 (GSP-RM up), so it cannot observe the FMC/HS phase.

**Result — the ICD is host-facing and uncommanded.** At `0x1113d0–0x1113e8`
the host reads zero and is not blocked, while the GSP gets `0xBADFFFFF` — a new
class, observed at exactly these four registers. `TRACEPC_LO 0x11140c =
0x0100287c` (inferred offsets) does not decode at its stated address, so the
trace association is unconfirmed.

**What this does and does not give.** Gives: the correct PRISCV base and a
measured host/GSP partition; a live `RPC` for PL2; a host-facing ICD in reset
state. Does not give: a memory-mapped debug module, host-side PC sampling, or
any read of HS memory. Whether the ICD accepts a command is **OPEN** — it is the
only remaining question in this block, and the only way to answer it is a write
to `ICD_CMD` (STOP is opcode 0, so a write/restore test is unsafe; one guarded
`RSTAT` write with no restore is the minimal probe). The write gates are
`0x111320 = 0xffffff8f` (L3 only) and `0x111328 = 0xffffffff` (all); which one
covers the ICD is unknown.

**Artifacts.** `regops/riscv_dm_probe.sh`;
`regops/results/riscv_dm_20261027_235315.txt`; `regops/log.txt` (host map);
`regops/regops.c` (`bar` mode); Ghidra `DisasmRange.java` on `0x1404f66`;
`src/common/inc/swref/published/blackwell/gb202/dev_riscv_pri.h`,
`.../ampere/ga102/dev_riscv_pri.h`, `.../turing/tu102/dev_riscv_pri.h`.

#### E67 · The PRISCV ICD is live: host command execution and a 14.4 MB halted-core read window

*2026-10-28 · status: CLOSED-MEASURED (ICD live; RDM window measured)*

**Hypothesis.** The PRISCV ICD at `0x1113d0`–`0x1113e8`, which E63 found
host-readable but idle and refused to the GSP, may be a working debug command
engine, and `RDM` may give a host read path into the core's memory.

**Method.** Direct BAR0 MMIO from the host, with no RM/GSP involvement:
`phase2b/icd_cmd.c`, `icd_rdm.c`, `icd_dump.c`, `icd_halt_probe.c`, and the
wrapper scripts. The command word is the Ampere encoding from `dev_riscv_pri.h`
(GA102): `OPC[4:0]`, `SZ[7:6]`, `IDX[12:8]`, `ERROR[14]`, `BUSY[15]`,
`PARM[31:16]`; opcodes STOP `0x0`, RREG `0x8`, RDM `0xa`, RSTAT `0xe`,
RCSR `0x10`, RPC `0x12`. Reads must be aligned to the access size. No `STOP`
was issued until the deliberate halt run.

**Result 1 — the register file is host-writable.** With GSP-RM up, `ADDR0`/
`ADDR1` (`0x1113d4`/`0x1113d8`) accepted `0xdeadbe00`, read it back, and
restored to `0`; `CMD` retained `0x0000000e`. No Xid, and a concurrent CUDA
workload (`key37_cuda` on both cards) was unaffected.

**Result 2 — commands execute, with a new rejection sentinel.** While the core
ran, `RSTAT` idx 0/3/4 completed (`ERROR=0`, `RDATA=0`). `RREG x1/x2`, `RCSR
misa` and `RDM` completed with `CMD[14]=1` and `RDATA=0xbadfbadf`
(`0xbadfbadfbadfbadf` for 8-byte reads). A plain latch cannot set `ERROR` and
return a sentinel; the command engine is real, and the rejection is the
halted-hart requirement.

**Result 3 — STOP enters ICD mode; RDM then works.** `CMD=0` halted the core.
`CPUCTL` moved `0x2a0` → `0x380`, but `CPUCTL[4]` stayed clear, so the GA102
`HALTED` bit is not the indicator on GB202. After `STOP`, `RREG`/`RDM` completed
with `ERROR=0`:

| Read | Value |
|---|---|
| `RPC` | `0xffffffff93002ebc` |
| `RREG x1` (ra) | `0xffffffff93002ea6` |
| `RREG x2` (sp) | `0xffffffffa3003ed0` |
| `RSTAT` 0/3 | 0 |
| `RDM 0x01400000`/8 | `0x96be52c70693b9e7` |
| `RDM 0x01404f64`/4 | `0x4208962a` |
| `RDM 0x01404f66`/2 | `0x4208` |

The host-side `0x1113ec` read `0x93002ebc`, matching the ICD `RPC`; the GSP
master's `0x1113ec` read `0x01404f66`. The RDM translation below shows
`0x93002ebc` is the true halted PC and `0x01404f66` is a different, per-master
register (corrects E63).

**Result 4 — the driver's own core dump uses the ICD.** After the `STOP` the GSP
heartbeat timed out and `kflcnCoreDumpDestructive_IMPL` ran: it read
`csr[0x897]=5`, `0x899=1`, `0x89a=0`, `0x8b4=0`, `0x8b5=0`,
`csr[0xc00]=0x48bc3341d37e`, `0xc01=0x292d5e5f1480`, `0xc02=0x23`, attempted a
stack unwind with `RDM`, got 0, and the driver raised Xid 154 (GPU Reset
Required). The Linux `kflcnRiscvIcd*` stubs of E10 are an API layer, not a
hardware gate.

**Result 5 — the RDM window.** With the core halted, reads succeed over the RM
code segment `0x01000000`–`0x01DCD000` (tested at and between `0x01000000` and
`0x01B40000`) and fail outside it: `0x01000000` =
`7f454c4602010100` (ELF magic), `0x01400000` = the image bytes at file
`0x58F000` (unique 1 KB match), `0x01800000` OK, `0x02000000` ERROR;
`0x04000000` (data segment), `0x13ec00000`, `0x7dd580000`, `0x7e72e0000`,
`0x7f0000000`, `0x7f42c0000` all ERROR. The window is the loaded RM code
segment, not arbitrary FB; the WPR/FRTS remain unreachable.

**Result 6 — the address model (corrects Appendix G.2).** The `.fwimage` has a
`0x18F000`-byte wrapper; at file `0x18F000` is an ELF64 RISC-V image with
`p_vaddr 0x01000000` (code, `filesz 0xDCD000`, RX), `p_vaddr 0x04000000`
(data, `filesz 0x1A1000`, RW), entry `0x01A0F3DA`. It is loaded
at core address `0x01000000` (identity in the core's address space; not host FB
PA `0x01000000`, which is empty — E74) and runs at runtime VA
`link + 0x92000000`. The relocation was confirmed: `RPC 0x93002ebc` → link
`0x01002ebc`; RDM at
`0x01002ebc`/4 returned `0x071300b7` and at `0x01002ea6`/2 returned `0xe11c`,
matching file `0x191EBC`/`0x191EA6` exactly. Hence:

```
file offset = link VA - 0x00E71000 = PA - 0x00E71000
runtime VA  = link VA + 0x92000000 = PA + 0x92000000
```

The Ghidra file-offset formula (`file offset = Ghidra VA - 0x01000000`) is
correct for the file, but a Ghidra address is not a runtime address: it is
`0x18F000` above the link/runtime VA (`link VA = Ghidra VA - 0x18F000`). This is
the live/static delta E60 observed.

**Conclusion.** The PRISCV ICD is a live, host-facing PL0 debug port. It
provides register access and a 14.4 MB read window over the halted core's RM
code segment, and the driver itself uses it for core dumps. It does not reach the
WPR/FRTS, and it does not change the FEAT/PL3 analysis. Its value is the next
experiment: halt the core during the FMC window on a boot/resume and read the
window, which may expose the decrypted FMC plaintext. *(Answered by E68: the
window is not readable — the ICD is blocked through HS, `RDM` is refused there,
and the post-boot aperture is the RM code segment only.)*

**Artifacts.** `phase2b/icd_cmd.c`, `icd_rdm.c`, `icd_dump.c`,
`icd_halt_probe.c`; `phase2b/icd_rstat_probe.sh`, `icd_probe2.sh`,
`icd_rdm_probe.sh`, `icd_scan.sh`, `icd_map_probe.sh`; run logs
`/tmp/safe_probe_20261028_203207.log`, `/tmp/safe_probe_20261028_203548.log`;
driver source `kernel_falcon.c`, `arch/turing/kernel_falcon_tu102.c`,
`arch/ampere/kernel_falcon_ga102.c`,
`src/common/inc/swref/published/ampere/ga102/dev_riscv_pri.h`,
`.../blackwell/gb202/dev_riscv_pri.h`.

#### E68 · The boot window: ICD blocked through HS, RDM gated, the boot image at `0xefd00000`

*2026-10-28 · status: CLOSED-MEASURED (ICD memory path; FSP has no ICD)*

**Hypothesis.** The handover's Step C: the ICD can be commanded during the
FMC/BootROM window and `RDM` can read the decrypted boot image, either by a
delay sweep or by halting when the image executes.

**Method.** Three instruments, all on `41:00.0` (gpuInstance 1):

1. **Read-only PC trace** (`BF16_ICD_TRACE`, `phase2b/icd_trace_run.sh`). Armed
   immediately after the COT response; samples `CPUCTL 0x111388`, the host PC
   mirror `0x1113ec`, `ICD_CMD 0x1113d0`, `ENGINE 0x1103c0` and the reset PLM
   `0x1103c4` every 100 µs for 1.5 s to `phase2b/icd_trace/pc_<gpu>_cot.csv`.
2. **Targeted halt** (`BF16_ICD_HALT`, `phase2b/icd_halt_run.sh`). Polls the PC
   mirror every 10 µs; mode 0 stops on the first valid PC (boot image), mode 1 on
   the first PC inside the GSP-RM ranges (LS transition). Then `STOP`, RPC/RREG/
   RSTAT, probes of the boot-image hypotheses, and a 0x48000-byte dump at the
   first working address.
3. **Post-boot halt** (`phase2b/icd_bootimg_probe.c`). Reproduces the E67 halt on
   a healthy system and probes `0xEFD00000`, `0x5DD00000`, `0x181D00000`, the
   data segment and its runtime VA.

The FSP was swept separately: the full PFSP window `0x8f0000`–`0x8f3fff`
(4,096 dwords per view) through host BAR0 and through the GSP master
(`phase2b/icd_fsp_probe2.sh`).

**Result 1 — the block is closed through the HS phase.** Both cards, same
sequence:

| t (after COT) | `CPUCTL` | PC `0x1113ec` | `ICD_CMD` | `ENGINE` | note |
|---|---|---|---|---|---|
| 0–1.6 ms | `0xbadf4100` | `0xbadf4100` | — | `0xbadf4100` | all refused |
| 1.6–155 ms | `0x180` | `0xbadf5620` | `0xbadf5620` | `0xbadf5720` | HS window |
| ~155–157.5 ms | `0x180` | `0xefd00174`… | `0` | `0xbadf5720` | unblock, boot image |
| ~158 ms | `0x180` | `0x9300xxxx` | `0` | `0xbadf5720` | GSP-RM |

The first valid PCs on the two cards were `0xefd00174`/`0xefd00894`/`0xefd029b6`
and `0xefd018c4`/`0xefd0073e`/`0xefd01c98`; GSP-RM followed 0.5–0.6 ms later.
The boot image is `0x47000` bytes: the journal records
`WprMeta bootloader{addr=… size=290816}` and the `GspRmBoot` bindata is
290,816 bytes; one run sampled `0xefd47000`, base+0x47000.

**Result 2 — `STOP` works in that window; `RDM` does not.** Both halts leave
`CPUCTL=0x380` (`CPUCTL[4]` clear) and let the register path complete, but every
memory read is refused:

| Halt (mode) | Trigger PC / time | `rpc` / `ra` / `sp` | `RDM` incl. `0x01000000` |
|---|---|---|---|
| 0, HS image | `0xefd017ee` / 114.2 ms | `0xefd00eb8` / `0xefd00ca0` / `0xefd1f730` | refused, `0xbadfbadfbadfbadf` |
| 1, early GSP-RM | `0x930014bc` / 114.9 ms | `0x93001628` / `0x930015a0` / `0xa3007ed0` | refused, `0xbadfbadfbadfbadf` |

The register values confirm the image and its stack (`ra`/`sp` inside
`0xefd00000`). `RDM` is enabled later in GSP-RM init, not by the HS→LS
transition.

**Result 3 — the post-boot aperture is the RM code segment.** In the E67 halt
state (`PC=0x93002ebc`, `ra=0x93002ea6`, `sp=0xa3003ed0`, byte-identical to E67):

| Address | Result |
|---|---|
| `0x01000000` | `0x00010102464c457f` — ELF magic (control) |
| `0x00000000` | refused |
| `0xEFD00000`, `0xEFD00170`, `0xEFD40000`, `0xEFD46FF8` | refused |
| `0x5DD00000`, `0x5DD40000` | refused |
| `0x181D00000` | refused |
| `0x04000000` (data link), `0x96000000` (data runtime) | refused |

**Result 4 — no firmware unlock.** The plaintext GSP-RM contains no ICD-enable
write. Its only PRISCV references (`mod_community_38.c`) are `IRQDEST[22]` and
`0x111520 = 0x400000` plus `ICD_CMD = 0` in fatal self-halt paths followed by
`ebreak`. The driver's `kflcnRiscvIcdReadMem_TU102` gates `RDM` on the same
active/idle conditions and documents `0xbadf…` values as expected, so the refusal
is a hardware/firmware privilege gate, not a driver artifact.

**Result 5 — the FSP has no debug port.** The full 16 KB PFSP window has no
PRISCV core interface: `0x8f0388`/`0x8f03d0`/… (Falcon+`0x3d0`) and
`0x8f1388`/`0x8f13d0`/… (the GSP-analogous `+0x1000`) all read `0xBADF5040`.
Implemented outliers are `0x8f1274/98/9c` and two 12-byte tables at
`0x8f1f00`/`0x8f1f80`; the `0x8f3000` block carries `0xffffff8f` PLMs. The FSP
ICD route is closed.

**Result 6 — `GspRmBoot` is opaque.** The driver bindata contains the prod and
debug images as raw 290,816-byte blobs (file `0x4d6a58` / `0x51da78`), entropy
7.999, no plaintext header, and a prod/debug XOR with 1,167 zero bytes in
290,816 (0.401%, chance rate): no shared keystream.

**Conclusion.** The ICD is a register/PC debug port whose memory path is
privilege-gated: it cannot read the boot image in the only window where that
image executes, and after boot its aperture is the RM code segment. The FSP has
no ICD at either PRISCV placement. The E67 follow-up and the handover's Step C
are closed; the ICD is not a route to decrypted HS firmware.

**Artifacts.** `phase2b/icd_trace_run.sh`, `phase2b/icd_trace_analyze.py`,
`phase2b/icd_halt_run.sh`, `phase2b/icd_fsp_probe2.sh`,
`phase2b/icd_bootimg_probe.c` (binary `phase2b/icd_bootimg_probe`); run dirs
`phase2b/icd_trace/`, `phase2b/icd_boot/halt_1.txt`,
`phase2b/ctxdump_20261028_212158/` (trace), `..._212953/` and `..._215333/`
(halts), `regops/results/icd_fsp_sweep_20261028_211521.txt`,
`..._212157.txt`; hooks in `kern_fsp_gh100.c` (`BF16_ICD_TRACE`,
`BF16_ICD_HALT`) and `kernel_falcon*.c`.

### D.E The FMC/FSP boot-input surface

#### E14 · Host-side boot and static-info instrumentation

*2026-10-25 · Revision 13b · status: negative for host-supplied rate*

**Method.** Built the open modules at exact tag 595.91.07 (`make clean && make
modules -j`) and added `NV_PRINTF(LEVEL_ERROR, "BF16: ...")` to
`kgraphicsLoadStaticInfo_KERNEL` (V1/V2 fetch), `kgspSetupLibosInitArgs_IMPL`, and
`_kgspSetupGspFmcArgs_GH100`. Loaded the built modules from the tree; Secure Boot is
disabled and vermagic matches; DKMS modules untouched as recovery.

**Result.** On both GPUs, at module load and before any CUDA context:

```
NVRM: GPU0 kgraphicsLoadStaticInfo_KERNEL: BF16: KGR SM issue rate modifier grIdx=0:
  imla0=0 fmla16=0 dp=0 fmla32=3 ffma=0 imla1=3 imla2=3 imla3=0 imla4=3
NVRM: GPU0 kgraphicsLoadStaticInfo_KERNEL: BF16: KGR SM issue rate modifier V2 grIdx=0 size=10
```

The FMC boot params contain `regkeys` and descriptor/address fields; the libos init
args are task-log regions plus the RMARGS region. `GSP_ARGUMENTS_CACHED` has no rate
field. The host does not supply the nine values; the GSP returns them at boot.

**Method note.** `NV_PRINTF` prints `%#x`/`%#llx` literally in this codebase; use
`%u`/`%x`.

**Artifacts.** `phase2b/load_patched.sh`, `phase2b/phase2b_20261025_223815.txt`,
`phase2b/dmesg_20261025_223841.txt`.

#### E15 · A patched GSP-RM image is rejected by the FMC

*2026-10-25 · Revision 13c · status: CLOSED-MEASURED*

**Method.** Copy `/lib/firmware/nvidia/595.91.07/gsp_ga10x.bin`; replace the first
instruction of `FUN_ram_015ffae8` with `ret` (`jalr x0, 0(ra)` = `0x00008067`).

- flat `0x015ffae8` → `.fwimage` offset `0x5ffae8` → ELF file offset `0x5ffb28`
  (section starts at file offset `0x40`);
- original bytes `39 71 06 fc` verified in both the extracted image and the ELF;
- patched to `67 80 00 00`; rest unchanged (SHA-256 `abc943c4…` vs `df08a208…`).

Installed the patched image, loaded the instrumented modules.

**Result.** Both GPUs failed on every attempt:

```
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
Max GSP-RM boot attempts exceeded: 4/4
RmInitAdapter failed! (0x62:0x55:2168)
```

**Recovery.** The script restored the original firmware immediately and reloaded
the stock DKMS driver; both GPUs returned without a reboot.

**Artifacts.** `phase2b/run_gsp_patch_test.sh`,
`phase2b/gsp_patch_test_20261025_224233.txt`, `gsp_ga10x.bin.orig`,
`gsp_ga10x.bin.patched` (local only; do not redistribute).

#### E28 · Boot-input baseline and the ordinary FMC path

*2026-10-26 · Revision 27 · read-only · status: baseline*

**Method.** Two prints and an inert one-field COT override hook
(`phase2b/bf16_boot_instr.patch`). `dump_ctx.sh` with `EXITMAX=0 MAXDUMPS=0
GLOBALMAX=0 --no-trigger`, so no context buffers and no CUDA contexts.

**Result.** Values in §9.1. Key identity: the COT hash bytes `fe8809ee c43228a6 …`
match `fmc-analysis/out/c04_hash.bin`, and the public-key bytes `048bf118 bbeb9c0f …`
match `c04_pkey.bin`; `c04` is the 287,304-byte `GspRmFmcGfwProdSigned_GB202`.
The ordinary boot path uses the production-signed FMC.

**Oracle hook.**

```c
#ifndef BF16_COT_VARY
#define BF16_COT_VARY 0
#endif
#ifndef BF16_COT_VALUE
#define BF16_COT_VALUE 0ULL
#endif
```

`BF16_COT_VARY` selects exactly one field immediately before
`kfspSendAndReadMessage` (1 size, 2 offset, 3 boot-args pointer, 4 FMC pointer,
5 hash flip). The applied variant is printed; defaults are inert.
`phase2b/fmc_oracle.sh <field> [value]` sets the defines, rebuilds, loads, captures
dmesg, and restores stock in the trap.

**Artifacts.** `phase2b/ctxdump_20261026_004501/`; `phase2b/bf16_boot_instr.patch`;
`phase2b/fmc_oracle.sh`; `fmc-analysis/out/c04_hash.bin`, `c04_pkey.bin`.

#### E29 · First COT oracle: FRTS size rejected by the FSP (`0xd9`)

*2026-10-26 · Revision 28 · status: FSP validation mapped*

**Method.** `phase2b/fmc_oracle.sh 1 0x80000` (half the stock 1 MB size).

**Result.**

```
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
FSP boot cmds failed. RM cannot boot.
```

The rejection repeated on the retry, which recomputed `frtsVidmemOffset` to
`0x10520000`.

**Driver bug exposed.** After the first failure, `kfspCleanupBootState_IMPL`
(`kern_fsp.c:253`) destroyed the engine-lifetime `pPollEvent`; the retry scheduled
and destroyed the freed event and oopsed in `hrtimer_active` (NULL `hrtimer.base`),
wedging the module. The fix moves the destroy into `kfspStateDestroy_IMPL`
(NULL-guarded).

**Artifacts.** `phase2b/ctxdump_20261026_004836/`;
`phase2b/fmc_oracle_0xd9_journal.txt`; `dmesg.txt` (full oops).

#### E30 · FRTS size: the control boots, a larger size is refused

*2026-10-26 · Revision 29 · status: size check closed*

```bash
phase2b/fmc_oracle.sh 1 0x100000    # control
phase2b/fmc_oracle.sh 1 0x200000    # upper bound
```

**Control.** Both GPUs initialized, `nvidia-drm` on both minors, zero error/Xid/oops
lines, `nvidia-smi -L` lists both. The COT was byte-for-byte the E28 baseline apart
from per-boot addresses. The override plumbing is correct; `0xd9` is attributable to
the value.

**Upper bound.** 16 sends on GPU0, 8 on GPU1, all `0xd9`. The driver cycled four
distinct FRTS placements (`0x1b40000`, `0x10520000`, `0x1ef00000`, `0x2d8e0000`)
and the rejection repeated at each: the check is keyed to size, not placement. No
oops — the event-lifetime fix held over a 24-send failure path.

**Artifacts.** `phase2b/ctxdump_20261026_010010/`, `phase2b/ctxdump_20261026_010112/`.

#### E31 · A relocated FRTS base boots

*2026-10-26 · Revision 30 · status: offset is not pinned*

**Method.** `fmc_oracle.sh 2 0x10520000` — aligned, in range, stock size.

**Result.** Both cards booted; one COT send per card; no error lines; both minors
up. The FSP does not pin the offset to stock. Caveat: acceptance is not consumption;
the units and consumption test came in E33/E34.

**Artifacts.** `phase2b/ctxdump_20261026_010408/`.

#### E32 · A misaligned base draws `0xd6`

*2026-10-26 · Revision 31 · status: alignment check mapped*

**Method.** `fmc_oracle.sh 2 0x10520001` — the E31 base plus one byte.

**Result.** 24 sends, 24 × `0xd6` (16 GPU0, 8 GPU1); no boot; no Xid/oops; stock
restored and both cards listed. The FSP rejects rather than rounds.

| COT state | Code |
|---|---|
| `frtsVidmemSize != 0x100000` | `0xd9` |
| offset misaligned | `0xd6` |
| offset aligned and accepted | — |

**Artifacts.** `phase2b/ctxdump_20261026_010701/`.

#### E33 · A second accepted base, and the from-end units correction

*2026-10-26 · Revision 32 · status: model corrected*

**Method.** `fmc_oracle.sh 2 0x10500000`; extended print of the post-boot GSCI
layout.

**Result.** Both cards booted; the readback fired:

```
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7d8920000 frts=0x7e5900000
```

The pre-ACR `WprMeta` still showed `frts{off=0x0 ...}`.

**Units correction.** `frtsVidmemOffset` is **from the end of FB**, not an absolute
address (`kern_fsp_gh100.c:1450–1492`, aligned up to 128K):

| Value | Meaning |
|---|---|
| stock `0x1b40000` | 27.25 MiB from the end |
| `0x10520000` | 261.1 MiB from the end |
| `0x10500000` | 261.0 MiB from the end |
| `0x10520001` | same, misaligned → `0xd6` |

The accepted base is 233.75 MiB *below* the driver's own end-reserve estimate, so
the FSP does not enforce that policy. The readback cannot answer consumption in the
proposed form: the GSCI value is an absolute FB offset for the WPR block, while the
COT region is a different object 162 MiB away. E34 supplies the stock control.

**Artifacts.** `phase2b/ctxdump_20261026_010949/`.

#### E34 · The COT offset positions the whole GSP-RM layout

*2026-10-26 · Revision 33 · status: consumption proven*

**Method.** Stock control `fmc_oracle.sh 0` with the extended print.

**Result.**

| Field | Stock, COT `0x1b40000` | Moved, COT `0x10500000` | Δ |
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
does not reflect the ACR's patch, so the GSCI RPC is the only post-boot layout
source.

**Artifacts.** `phase2b/ctxdump_20261026_011302/`.

#### E35 · The placement window reaches 1 GiB

*2026-10-26 · Revision 34 · status: model predictive*

**Method.** `fmc_oracle.sh 2 0x40000000`.

**Result.**

| Published field | Prediction | Measured |
|---|---:|---:|
| GSCI `frts` | `0x7b5e00000` | `0x7b5e00000` |
| GSCI `nonWprHeap` | `0x7a8e20000` | `0x7a8e20000` |

The WPR spans 1.16–1.37 GiB from the FB end. The window is at least 1 GiB, with no
range check observed in either direction; the granularity below 128K and the small
end are untested.

**Artifacts.** `phase2b/ctxdump_20261026_011547/`; `phase2b/wpr_oracle.sh`.

#### E36 · `WprMeta.magic` is enforced (`0x827`); `verified` is accepted

*2026-10-26 · Revision 35 · status: magic closed; verified deferred*

**Field 1.** `wpr_oracle.sh 1` (`magic = 0xdeadbeefdeadbeef`):

```
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x827, additional info=0x0
```

Boot failed 4/4 per card; stock restored; no oops. The retry path showed its FRTS
margin: each failed attempt moves the COT base by `0xE9C0000` (`0x1b40000` →
`0x10520000` → `0x1ef00000` → `0x2d8e0000`), and `WprMeta.flags` reads `0x12` from
the second attempt on.

**Field 3.** `wpr_oracle.sh 3` (`verified = 0xa0a0a0a0a0a0a0a0`): both cards booted
cleanly, zero error/Xid/oops, and the readback shows the flag reached the FMC. No
visible effect on initial boot.

**Artifacts.** `phase2b/ctxdump_20261026_082736/`, `..._082830/`.

#### E37 · `WprMeta` and COT sizes may disagree

*2026-10-26 · Revision 36 · status: missing cross-check, inert*

**Method.** `wpr_oracle.sh 5` (`WprMeta.frtsSize = 0x200000`, COT `0x100000`).

**Result.** Both cards boot with no error; layout identical to stock
(`nonWprHeap 0x7e72e0000`, `frts 0x7f42c0000`). The FMC accepts the disagreement and
builds from the COT value. The struct field is decorative on GH100.

**Artifacts.** `phase2b/ctxdump_20261026_083049/`.

#### E38 · The heap-size request is honoured, downward

*2026-10-26 · Revision 37 · status: live layout lever*

**Method.** `wpr_oracle.sh 6 0x10000000` (256 MiB vs stock 135 MiB).

**Result.**

| Field | Stock | This run | Δ |
|---|---:|---:|---:|
| `gspFwHeapSize` | `0x8700000` | `0x10000000` | `0x7900000` (121 MiB) |
| GSCI `frts` | `0x7f42c0000` | `0x7f42c0000` | 0 |
| GSCI `nonWprHeap` | `0x7e72e0000` | `0x7df9e0000` | `0x7900000` |
| WPR span | 207.875 MiB | 328.875 MiB | 121 MiB |

The extra request is honoured to the byte; the top stays anchored to the COT base
and the block grows downward. `span = 0xCFE0000 + (gspFwHeapSize − 0x8700000)`.

**Artifacts.** `phase2b/ctxdump_20261026_083237/`.

#### E39 · A 16 MiB heap request wedges the boot

*2026-10-26 · Revision 38 · status: wedge, not a refusal*

**Method.** `wpr_oracle.sh 6 0x1000000`.

**Result.** The FMC accepted the COT and applied the layout (no error code), then:

```
GspStatusQueueInit: msgqRxLink failed: -7, nvStatus 0x00000065, retries: 2697191
Assertion failed: Call timed out [NV_ERR_TIMEOUT] ... @ kernel_gsp_gh100.c:1190
_kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
RmInitAdapter failed! (0x62:0x40:2168)
```

Both cards failed identically; subsequent attempts hit WPR2-up; the stock restore
reported `No devices found.` Reboot required (`systemctl reboot -f`; cold power
cycle if WPR2 survives).

**Consequence.** The FMC does not sanity-check the heap against GSP-RM's needs. The
failure is a hard wedge, one reboot per point below the minimum; bisect from above.
Oracle defines were reset to stock after the run.

**Artifacts.** `phase2b/ctxdump_20261026_083517/`.

#### E40 · `verified` does not bypass image verification

*2026-10-26 · Revision 39 · status: CLOSED-MEASURED*

**Method.** `phase2b/wpr_verified_patch_test.sh`: install the E15 patched GSP-RM,
preset `WprMeta.verified = 0xa0a0a0a0a0a0a0a0` (visible in the struct print), stock
COT.

**Result.** The FMC refused the image on every attempt, both cards:
`0xaff`, additional info `0xb`, 16 occurrences over four attempts per card. The flag
was preset each time and changed nothing.

**Recovery.** Clean, unlike E15: firmware restored before the stock restore, both
cards back, installed hash `df08a208…`, oracle defines reset.

**Artifacts.** `phase2b/wpr_verified_patch_20261026_084337/`;
`phase2b/wpr_verified_patch_test.sh`.

#### E41 · The COT hash is authenticated (`0x377`), and auth failure wedges

*2026-10-26 · Revision 40 · status: auth closed*

**Method.** `fmc_oracle.sh 5` (`hash384[0] ^= 1`).

**Result.** The COT printed `hash=ee0988ff…`; the FSP refused with `0x377` (Task
`0x1`, command `0x14`). Two sends, one per card, then every retry hit `unexpected
WPR2 already up`; the stock restore found no devices. Reboot required.

**Ordering result.** Size, alignment and magic rejections restore cleanly; auth
failure leaves WPR2 up. The FSP arms WPR2 before authenticating. Code map after
this run: `0x83d`, `0xd9`, `0xd6`, `0x827`, `0x377`, `0xaff`.

**Artifacts.** `phase2b/ctxdump_20261026_084605/`.

#### E54 · The FEAT bank is final before the FMC runs

*2026-10-26 · status: CLOSED-MEASURED (writer is pre-driver)*

**Hypothesis.** Something in the mutable boot chain (the FMC or GSP-RM) writes
`FEAT_OVR_PLM`, `FEAT_READOUT_1`, `SS0` or `SS1`.

**Method.** Two read-only samples in one cold boot, behind a compile-time define
(`BF16_FEAT_PREBOOT`, default 0), plus a script:

- **pre-FMC** in `kgspSetupGspFmcArgs_GH100`: the FSP has executed, the COT has not
  been sent, and the FMC does not exist yet;
- **post-boot** in `_kgspSetFwWprLayoutOffset`, after `GET_GSP_STATIC_INFO`: GSP-RM is
  up.

Each sample reads `0x823800`–`0x823824` (10 dwords).

```bash
sudo ./phase2b/feat_preboot.sh
```

**Result.** Byte-identical at both points, on both cards:

```
GPU0 (c1:00.0)  fffffb8f fffffb8f 01000380 00888888 002a2aaa 00000233 00c36180 54226037 00026005 00000003
GPU1 (41:00.0)  fffffb8f fffffb8f 01000280 00888888 002a2aaa 00000233 00c36180 21240001 00000002 00000003
```

(`0x823800`, `804`, `808`, `80c`, `810`, `814`, `818`, `81c`, `820`, `824`.) The
per-card `SS0`/`SS1` and the `0x823808` bit-8 difference are already present before
the FMC runs.

**Conclusion.** Neither the FMC nor GSP-RM writes the bank. The writer is pre-driver
— a GPU-side devinit action; the PMU (PL2) is the leading candidate, with the
FSP/BootROM or hardware not excluded (E64/E65) — so the rate selectors are fixed
before any mutable firmware executes. This also explains why no plaintext component
contains a write path and why the GSP is telemetry only. Both the power-on state and
the reset re-lock are outside the mutable chain.

**Artifacts.** `phase2b/ctxdump_20261026_210745/` (`dmesg.txt`, `run.log`);
`phase2b/feat_preboot.sh`;
`kernel_gsp_gh100.c` (`kgspSetupGspFmcArgs_GH100`),
`kernel_gsp.c` (`_kgspSetFwWprLayoutOffset`).

#### E61 · The COT public key is anchored (`0x1db`)

*2026-10-27 · Revision 62 · status: CLOSED-MEASURED (key anchor)*

**Hypothesis.** The COT's `publicKey` field is host-authoritative: a self-signed
P-384 pair over the stock hash boots the stock FMC, and a re-signed container would
boot a custom one.

**Method.** `phase2b/cotkey/gen_cot_key.py` generates a secp384r1 key pair, signs
the 48-byte SHA-384 of `c04_cont.bin`, and writes the 97-byte uncompressed point and
the 96-byte `r || s` signature as C arrays (`bf16_cot_key.h`). The production
artifacts were reproduced first: `openssl pkeyutl -verify -pkeyopt digest:sha384`
accepts `c04_hash.bin` against `c04_pkey.bin`/`c04_sig.bin`, and `openssl dgst
-sha384 -verify` accepts the whole container, so the encoding matches stock. A new
`BF16_COT_VARY=6` case in `kern_fsp_gh100.c` overwrites only `publicKey` and
`signature` immediately before `kfspSendAndReadMessage`; the image, hash, and every
layout field are stock.

```bash
python3 -I phase2b/cotkey/gen_cot_key.py
sudo ./phase2b/fmc_oracle.sh 6
```

**Result.** Both cards sent the substituted pair (`key=04f20be3`, `sig=65bb6753` in
the echo) and the FSP refused with a new code:

```
FSP response reported error. Task ID: 0x1, Command type: 0x14, Error code: 0x1db
```

one send per card, followed by `unexpected WPR2 already up` on every retry and
`RmInitAdapter failed! (0x62:0x40:2168)`. Reboot required. The driver maps `0x1db`
to `NV_ERR_GENERIC` (`0x40`) because it is not in `kern_fsp_retval.h`.

**Interpretation.** `0x1db` is distinct from the `0x377` hash failure (E41). Had the
FSP ignored the supplied key and verified with a fixed production key, our signature
would have failed on the same path as E41. The separate code means the key is
validated by its own stage, against a root the host cannot supply, before the hash
and signature check. Like `0x377`, it leaves WPR2 armed.

**The GSP-RM anchor has no substitution target either.** `.fwsignature_gb20x` is
`0x1000` bytes: a 20-byte header (`0x00020001`, size `0x8c8`, count `0x0c`, `0x0101`,
stride `0x200`) and four 384-byte high-entropy blocks on a `0x200` stride. It holds
no SHA-384 of `.fwimage`, no valid P-384 point at any `0x04` candidate, and no block
shared across the ten chip sections; only the header is constant. The key is fused
or in the FMC, not in the host image.

**And the resume path reuses the cold-boot image.** `kgspBootstrap_GH100` re-sends
the existing `pCotPayload` and keeps the mapped image on `KGSP_BOOT_MODE_SR_RESUME`;
it does not re-read `gsp_ga10x.bin`. A file swap between load and resume cannot
change what runs; only the restored state can (→ E45/E46).

**Artifacts.** `phase2b/ctxdump_20261027_225255/` (`dmesg.txt`, `run.log`);
`phase2b/cotkey/` (`gen_cot_key.py`, `bf16_cot_key.h`, key material);
`phase2b/fmc_oracle.sh` field 6; `kern_fsp_gh100.c` (`BF16_COT_VARY` case 6).

#### E62 · The FMC container is read back and tampered

*2026-10-27 · Revision 63 · status: CLOSED-MEASURED (image authenticated; no
fault-injection primitive)*

**Hypothesis.** Two things were never measured. (1) `kfspSetupGspImages` copies the
FMC container into unprotected sysmem at `COT.gspFmcSysmemOffset` and nothing reads
it back; if the FSP decrypts in place, the FMC corpus is readable at PL0. (2) The
COT hash, signature and key are copied verbatim from driver bindata and the driver
never computes or checks them; if secure firmware trusts that hash without binding
it to the image bytes, a corrupted ciphertext byte becomes a plaintext bit flip in
HS code.

**Method.** `phase2b/fmc_buffer_probe.sh` sets the dump/tamper defines, rebuilds
595.91.07, loads the instrumented modules with `dump_ctx.sh --no-trigger`, captures
dmesg and restores stock in the trap. `bf16DumpFmcBuffer()` maps
`pKernelFsp->pGspFmcMemdesc` read-only and writes it to disk at three points:
`copy` (after `bindataWriteToBuffer`), `postsend` (after the FSP response) and
`release` (`kfspReleaseProxyImage_IMPL`, before the memdesc is freed, so it also
fires on the refused-boot cleanup path). `BF16_FMCTAMPER` then changes one byte of
the container after the copy-in, leaving the COT hash/signature/key stock:

| Mode | Change |
|---|---|
| 1 | flip one ciphertext byte in the body (`BF16_TAMPER_OFF`, stock `0x1048`) |
| 2 | overwrite the plaintext body-size field at `0x04` |
| 3 | flip one bit of the plaintext container magic at `0x00` |

```bash
sudo phase2b/fmc_buffer_probe.sh dump            # read-only
sudo phase2b/fmc_buffer_probe.sh tamper 1        # ciphertext byte
sudo phase2b/fmc_buffer_probe.sh tamper 3        # header magic
```

**Result — the buffer is never touched.** All six dumps (three points × two cards)
are one SHA-256, `6e88068f…`, byte-identical to `c04_cont.bin`, with the tail
`[0x46248, 0x47000)` zero. The header reads `00480403 00046200 00000000 00037000
00000000 0000e800 00000104 00000000` (LE dwords). The FSP does not decrypt in
place and does not scrub: the plaintext stays in HS.

**Result — any change is refused with a new code.** With one byte changed and the
COT stock:

| Change | FSP response | WPR2 | Release dump |
|---|---|---|---|
| ciphertext `0x1048` `0xee`→`0xef` | **`0x33`** (task `0x1`, cmd `0x14`) | left up | identical to tampered |
| header `0x00` `0x03`→`0x02` | **`0x33`** | left up | identical to tampered |

The tamper is applied and visible in the `tampered` dump; `cmp` finds exactly one
byte against `c04` in each run. The FSP debug state reports microcode v4.76 and the
CMS2 log carries `… 14 00 33 …`. Mode 2 was not run: the body-size field lies
inside the same container, so both candidate explanations (a hash range derived
from the field, or a fixed range) predict `0x33` and the run cannot discriminate.

**Interpretation.** E41 (COT hash field flipped, image stock) returns `0x377`,
i.e. the signature over the *claimed* hash fails. Here the claimed hash is stock
and correct, the signature passes, and the image byte is rejected with a distinct
code. The order is: verify the signature over the claimed hash, then bind the image
to that hash. The binding covers the plaintext header (`0x33` for the magic flip),
and no header-magic parse error surfaces first, so the container is not a pre-auth
parser surface in the Ada sense. A corrupted ciphertext byte therefore never
reaches the decrypted image, and the FMC container is not a fault-injection
primitive.

**What this closes and what it leaves.** Closes: in-place decryption as a corpus
source; header/body tampering as a fault-injection route; the "verification
delegation" reading of §9.7. Leaves: the COT *fields* (`0xd9`, `0xd6`, `0x377`,
`0x1db`), the FSP message framing (§9.7), `WprMeta`, and the SR/radix3 surface.
The one residual use of the primitive would be a TOCTOU race between the FSP's hash
read and its decrypt read; the uniform `0x33` behaviour suggests a local copy and
the window is not characterised, so it is not worth a campaign.

**Repro caveat.** A `0x33` failure arms WPR2 like an authentication failure: every
retry prints `unexpected WPR2 already up` and the machine needs a reboot. The
harness restores the stock DKMS driver; the built tree stays instrumented.

**Artifacts.** `phase2b/fmc_buffer_probe.sh`; `phase2b/fmcprobe_20261027_233215/`,
`..._233405/`, `..._234052/`; `phase2b/artifacts/fmc_*.bin`;
`kern_fsp_gh100.c` (`bf16DumpFmcBuffer`, `BF16_FMCDUMP`, `BF16_FMCTAMPER`),
`kern_fsp.c` (`kfspReleaseProxyImage_IMPL` hook).

#### E64 · The FEAT bank across cold boots, warm reboots, and an FLR

*2026-10-28 · status: CLOSED-MEASURED (SS writer is power-cycle-tied; words inert)*

**Hypothesis.** The GB203M boot-to-boot `SS0` movement means a mutable pre-FMC
writer exists, and the bank's reset behavior can be separated from its power-on
initialization.

**Method.** `phase2b/featbank_writer_probe.sh` reads only `0x823800–0x823824` plus
documented controls (`PMC_BOOT_0`, WPR2, FSP scratch/status, GSP engine/reset PLM)
through BAR0. Early-boot (`pre`, before `systemd-udev-trigger`), post-driver, 60 s
(`late`) and shutdown samples were collected on both cards across five cold power
cycles and two warm reboots; `41:00.0` was additionally FLR'd with the driver
unbound and rebound. PCIe link speed/width is recorded at every sample. The cycle
order for the last four boots was confirmed **W W C C**.

**Result.** In every boot `pre == post == late == shutdown`; the SS words were
invariant for the whole boot, including a 7.5 h run and its shutdown sample. Across
boots:

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
`FEAT_READOUT_1` was `0x00c36180` in every sample and every nibble of every SS word
stayed below 8 (no override enable). Link speed/width was constant `16.0 GT/s x16`,
so the moving bits do not track link training.

**FLR.** With `41:00.0` unbound and FLR'd, SS0/SS1/`0x823808`/`READOUT_1` persisted
unchanged while WPR2 reset and the GSP became inaccessible; `FEAT_OVR_PLM`
(`0x823800`/`0x823804`) changed from `0xfffffb8f` to `0x80842bcf` and was restored
to `0xfffffb8f` after the rebind (E65). `0x80842bcf` decodes as read mask `0xf`, write mask
`0xc` (L2+L3), source-enable `0x80842`; `0xfffffb8f` is read-all / write-L3.

**Conclusion.** The SS words are initialized at GPU power-on by a source with a fixed
per-card base and a small variable component. They are not written by the driver,
the FMC, GSP-RM, the host POST, or the warm-boot path. The FLR leaves them outside
its reset domain but resets the PLM, which the boot path re-locks (E65).

**Artifacts.** `phase2b/featbank_writer_probe.sh`; `/var/log/featbank/samples.csv`
and `flr-*.csv`; run dirs `featpreflr_*`; the W W C C cycle labels.

#### E65 · The PLM re-lock is autonomous GPU-side devinit

*2026-10-28 · status: CLOSED-MEASURED (pre-COT, pre-open; host and GSP-RM excluded)*

**Hypothesis.** The `0x80842bcf` left by an FLR is re-locked by the FSP at the COT,
by the FMC after it, or by early GPU init.

**Method.** `phase2b/feat_preboot_flr.sh` builds 595.91.07 with
`BF16_FEAT_PREBOOT=1`, `BF16_FEAT_NVPROBE=1` and `BF16_FEAT_RMINIT=1`. Bracket
samples read the 10 FEAT words at `nv_pci_probe` (after `pci_enable_device`/BAR0
request), `nv-pre-set-master`/`nv-post-set-master`, `nv_start_device-entry` (first
open), `nv-pre-rm-init`, `RmInitAdapter` entry (after `RmSetupRegisters` maps
BAR0), `rm-gpu-got` (after `osInitNvMapping`), `kgspInitRm_IMPL` entry, before
`_kgspBootGspRm`, `_kgspBootGspRm` entry, `kgspPrepareForBootstrap_GH100` entry and
`kgspSetupGspFmcArgs_GH100` (pre-COT); the post-boot hook fires after GSP-RM. The
target is unbound, FLR'd and rebound; the first open is triggered by `nvidia-smi`.

**Result.** After the FLR, `0x823804 = 0x80842bcf`. It stayed `0x80842bcf` through
`nv_pci_probe`, `nv-pre-set-master` and `nv-post-set-master` (all at the bind), and
was already `0xfffffb8f` at `nv_start_device-entry` three seconds later — before any
`nv_start_device`, `rm_init_adapter`, `RmInitAdapter` or GSP code ran. Every later
bracket (`nv-pre-rm-init`, `rmInit-entry`, `rm-gpu-got`, `initRm-entry`, pre-FMC,
post-boot) read `0xfffffb8f`. SS0/SS1/`0x823808`/`READOUT_1` were unchanged at every
point. The module-load control (before the unbind) was already `0xfffffb8f`.

**Conclusion.** The FLR's `0x80842bcf` is not re-locked by the COT, the FMC or any
GSP-RM code. The re-lock happens inside the ~3 s after the PCI probe and before the
first open, with no host code executing; the host is PL0 and neither PLM value admits
L0 writes. The writer is a GPU-side master acting on the enabled function, using the
reset mask's L2 permission. The **PMU devinit** is the leading candidate (PL2,
resident, devinit engine); the FSP/BootROM (PL3) or a hardware re-latch are not
excluded. The PL2 window is real but not reachable from the host or from GSP-RM, and
a runtime PLM-opening write is undone at the next device enable/reset.

**Artifacts.** `phase2b/feat_preboot_flr.sh`; the hooks in `kernel_gsp.c`,
`kernel_gsp_gh100.c`, `osinit.c`, `nv-pci.c`, `nv.c` (all guarded by the BF16
defines and reset by the harness); run dirs `featpreflr_20261028_083139` (pre-COT),
`..._090159` and `..._090518` (attach brackets); `build.log`, `dmesg_final.txt`,
`run.log`.

#### E66 · The vBIOS devinit-table scan: no FEAT address, authenticated tables

*2026-10-28 · status: CLOSED-STATIC (table route)*

**Question.** E65 leaves the pre-lock FEAT writer as a GPU-side devinit. If its
writes are table-driven by plaintext vBIOS tables, the custom-VBIOS no-flash route
(§4.6) could become a PL2 lever. This record scans the vBIOS for the FEAT address,
for devinit opcodes, for register-address lists, and for the PLM values, and checks
whether the DEVINIT tables/scripts can be edited on the host side.

**Sources used before the scan.** NVIDIA `open-gpu-doc/Devinit/1/devinit.xml` (the
opcode encoding and the `DEVINIT_USE_*` flags in the address's upper nibble), the
`BIOS-Information-Table` spec (12-byte BIT header, 6-byte tokens), nova-core
`vbios.rst` (PciAt/EFI/FwSec image chain, PMU lookup table, FALCON_DATA token
`0x70`), `kernel_gsp_fwsec.c` (`FALCON_UCODE_TABLE_HDR_V1`,
`FALCON_UCODE_DESC_V3`), and `gpu-unlock-ada/.../vbios_610.c` (the `adjust` =
first-FwSec − PciAt-size correction).

**Tool.** `vbios-analysis/scripts/devinit_scan.py` (new). It parses the ROM chain
with the NPDE override, finds the BIT and the `0x70` token, parses the 35-entry
PMU lookup table and the v6 descriptors, then scans every byte of the image for:
the FEAT addresses in both endiannesses and the eight `DEVINIT_USE_*` flag forms;
every devinit opcode whose 32-bit address lands in `0x823800`–`0x8238FF`; u32/u64
register-address lists in `0x820000`–`0x824000`; and the known PLM values, mapping
each hit to its ucode body. Inputs: `flash1m_41.bin`, `prom_full_41.bin`,
`prom_full_c1.bin`, `flash_41.bin`, `flash_c1.bin`.

**Layout (1 MiB image; the 2 MiB aperture is the same image at `+0x38000`).**

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

**Results.**

- **Zero FEAT address literals.** No `0x00823800/04/08/0c/10/14/18/1c/20` in the
  1 MiB image or the 2 MiB aperture, on either card, in either endianness, raw or
  OR'd with `0x20000000`/`0x40000000`/`0x80000000`.
- **Zero devinit opcodes with a FEAT address.** `0x6E`, `0x7A`, `0x48`, `0x47`,
  `0x10`–`0x13`, `0x20`–`0x23`, `0x2C`, `0x58`, `0x91` were all tested; none
  resolves into `0x823800`–`0x8238FF`.
- **One register-address list.** A 72-entry 64-bit table at `0x638E5`
  (`0x820800`–`0x8221A4`, the FUSE/strap block). No FEAT entry.
- **The PLM values are in app `0x23`/target `0x0E` only.** `0xFFFFFB8F` (4 hits),
  `0xFFFFFBFF` (7), `0xFFFFFF8F` (9), `0xFFFFFF0F` (7), all inside
  `0xB780C`–`0xD5A0C`; e.g. `0xFFFFFB8F` at `0xD40E8`, `0xFFFFFF8F` at `0xCDB08`
  and `0xD4190`, `0xFFFFFF0F` at `0xD41E0`. The other three bodies are encrypted
  throughout and contain none.
- **The tail tables are not a FEAT write table.** Two copies at `0xE8300` and
  `0xE9400`, in the InfoROM/tail beyond the FwSec image (`0xD5C00`), hold
  `0x0884CB8F`, `0x0884CBCF`, `0xFFFFFB8F`, `0x0085CB8F` but no addresses; the
  only per-card difference is the word at `+0x20` (`0x2000C001` on `41:00.0`,
  `0x0006F2D9` on `c1:00.0`), which is board/license data.
- **Two-card diff.** App `0x23`'s code is byte-identical; its data differs by 65
  bytes (per-card calibration); the PLM anchors are identical.

**Why the table route is closed.** The GSP-RM string table
(`gsp-analysis/input/gsp_fwimage.bin`, file `0xEEF4C0`+) carries the DEVINIT
authentication errors:

```
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
plaintext edit of a table or a data section fails authentication. The no-flash
custom-VBIOS route is a host-side table override at PL2 (§4.6); it changes what the
host driver parses, not what the GPU's HS firmware authenticates from the flash.

**Interpretation.** The public cmp170hx analysis names `0x00823804`
`SEC2_DEBUG_PRI_FEATURE_OVERRIDE_PLM` and states that the **SEC2 Booter** (HS), not
FWSEC/DEVINIT/PMU/GSP-RM, raises the PLMs. The only PLM-bearing vBIOS image is app
`0x23`/target `0x0E`; the target-ID→engine mapping is not public, so this is
consistent with the SEC2 class but not a confirmed identification. The scan does
not name the E65 writer; it removes the table-driven hypothesis and points the
remaining static work at the encrypted app `0x23` code (a key problem, with the
FACEB13D AES-ECB precedent; E06 already closed the GA100 key transfer to GB202).

**Caveats.** The target-ID mapping is not public. The GSP-RM strings are a static
corpus, not a live trace. The 2 MiB aperture and the 1 MiB dump agree, but the
1 MiB dump's tail (`0xD5C00`–`0x100000`) is InfoROM/board data, not the vBIOS
image.

**Artifacts.** `vbios-analysis/scripts/devinit_scan.py`;
`vbios-analysis/out/devinit_scan_1m_41.txt`,
`devinit_scan_2m_41.txt`, `devinit_scan_2m_c1.txt`; input dumps above.

#### E69 · The `WprMeta` bootloader description and both boot images

*2026-10-28 · status: CLOSED-MEASURED (fields checked; images authenticated)*

**Hypothesis.** The FMC consumes the host-filled bootloader description
(`sysmemAddrOfBootloader`, `sizeOfBootloader`, and the in-image code/data/
manifest offsets) plus a separate 4 KB signature buffer before or while it
authenticates. A host-controlled length or offset used in a copy/parse ahead of
the check would be the GB202 analogue of the Ada `BooterLoadUcode` bug.

**Method.** The `WprMeta` oracle (`phase2b/wpr_oracle.sh`) was extended from
fields 1–7 to 8–16 in `kgspPopulateWprMeta_GH100` (`kernel_gsp_gh100.c`):
`sizeOfBootloader`, `sysmemAddrOfBootloader`, `bootloaderCodeOffset`,
`bootloaderDataOffset`, `bootloaderManifestOffset`, `sysmemAddrOfSignature`,
`sizeOfSignature`, `sysmemAddrOfRadix3Elf`, `sizeOfRadix3Elf`. The WprMeta log
line now prints the offsets and the signature descriptor. A separate hook
(`BF16_BOOT_TAMPER`, `phase2b/boot_tamper_run.sh`) flips one ciphertext byte in
`pKernelGsp->pGspRmBootUcodeImage` — the driver keeps the image mapped writable —
once per GPU per module load, with the COT hash, FMC container, signature buffer
and every other `WprMeta` field stock.

**Result — stock layout (both cards).** `sizeOfBootloader = 0x47000`,
`cOff = 0xf200`, `dOff = 0xa00`, `mOff = 0`,
`sig{size = 0x1000}`. The manifest is the first structure of the image, data
follows at `0xa00`, code at `0xf200`.

**Result — the field matrix.** One field per run, one module reload each:

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

The `0x82e` and `0x885` codes are new; both are FMC/partition-1 structured
refusals with clean recovery. The offsets that are not used are decorative on
this path.

**Result — the image is authenticated.** With everything else stock, flipping the
first ciphertext byte of the bootloader image (`0x84`→`0x85`) is refused with
**`0xaff`, additional info `0xb`** on all four attempts — the same code a patched
GSP-RM ELF draws (E15/E40). The second card was not tampered because the hook's
"once" flag was module-global at the time (since fixed to per-GPU) and booted
normally, a within-boot control: the refusal is attributable to the byte flip,
not the instrumented driver.

**Conclusion.** The FMC validates the bootloader description it consumes (size,
manifest offset), ignores the code/data offsets and the signature size, and binds
the GSP-RM image size into authentication. The bootloader image itself is
authenticated: a corrupted ciphertext never reaches execution. No host-controlled
length or offset reaches a pre-authentication copy, and the bootloader surface has
no fault-injection primitive. The E62 result for the FMC container is the analogue
for the other image.

**Artifacts.** `phase2b/wpr_oracle.sh` fields 8–16; `phase2b/boot_tamper_run.sh`;
run dirs `phase2b/ctxdump_20261028_221102` (`0x82e`), `..._221229` (code offset),
`..._221418` (`0x885`), `..._221454` (data offset), `..._221628` (stock print),
`..._221804` (signature size), `..._221920` (ELF size), `..._222318` (image
tamper); hooks in `kernel_gsp_gh100.c` (`BF16_WPR_VARY` 8–16,
`BF16_BOOT_TAMPER`) and `kern_fsp_gh100.c`.

#### E72 · The bootloader host buffer is not decrypted in place

*2026-10-28 · status: CLOSED-MEASURED*

**Hypothesis.** The FMC consumes the host-supplied `GspRmBoot` image from
unprotected sysmem (`WprMeta.sysmemAddrOfBootloader` =
`pGspRmBootUcodeImage`). If it decrypts in place, the 290,816-byte HS plaintext
is readable at PL0 after the boot — the cheapest possible decrypted-firmware
route.

**Method.** `phase2b/bootbuf_dump.sh` builds 595.91.07 with `BF16_BOOTDUMP=1`,
loads the instrumented modules, triggers a normal boot, restores the stock
driver in its trap, and dumps `pGspRmBootUcodeImage` at
`kgspPopulateWprMeta_GH100` (pre-COT, before the FMC consumes it) and
`_kgspSetFwWprLayoutOffset` (post-boot, after GSP-RM is up).

```bash
sudo phase2b/bootbuf_dump.sh
```

**Result.** Both cards, both sample points:

| Field | Value |
|---|---|
| Size | 290,816 B (`0x47000`) |
| Nonzero bytes | 286,069 |
| SHA-256 | `f5f63a71bb17b07d…` (identical pre/post and across cards) |
| Entropy | 7.9835 bits/byte pre and post |
| `diff_bytes` | **0** |
| Head | `840e559669372140` at both points |

The `nvidia-drm.ko: File exists` line in `load.log` is benign (the module was
already loaded); the dump fired for gpu0 and gpu1 (23:07:09 and 23:07:11) and
the stock DKMS driver was restored.

**Conclusion.** The FMC does not decrypt the bootloader in place in the host
sysmem buffer, and does not scrub it either. It leaves the stock ciphertext,
matching E62 for the FMC container. No host-side plaintext is produced by the
boot path; the decrypted image lives in protected memory (or FB). The FB capture
at PA `0x5dd00000` (open question #16) was the remaining memory route; E74 then
measured it shut.

**Artifacts.** `phase2b/bootbuf_dump.sh`; hooks `BF16_BOOTDUMP` in
`kernel_gsp_gh100.c` (`pre`) and `kernel_gsp.c` (`post`);
`phase2b/bootdump_20261028_230658/` (`compare.txt`, `dmesg_post.txt`,
`run.log`); `phase2b/bootbuf/` (`boot_{pre,post}_gpu{0,1}.bin`).

#### E74 · The FB route is shut: BAR1 has no boot-time VAS, and the WPR returns `0xbad0ac00`

*2026-10-28 · Revision 86 · status: CLOSED-MEASURED (negative, structural)*

**Question.** The last memory route to the decrypted bootloader: can a host read
of FB reach it? The document's model put the boot image at runtime VA
`0xefd00000`, hence PA `0x5dd00000` (subtracting the GSP-RM `+0x92000000`
offset), outside the WPR. E48's BAR1 attempt had failed its positive control.

**Method.** Three instrumented-driver runs on both cards, each triggered by
`nvidia-smi`/`nvidia-drm` opening the GPUs (`NVreg_GpuInitOnProbe=0`, so the
boot happens on first open):

1. **BAR1 mapping at `kgspPopulateWprMeta_GH100`** (before the COT). The hook
   published the BAR1 translation for `0x01000000`, `0x5DC00000` and
   `0x181C0000` and left the mappings for a userspace poller.
2. **BAR0 PRAMIN window read** in `_kgspSetFwWprLayoutOffset` (after GSP-RM is
   up): 64 KiB at a time at BAR0 `0x700000`, base moved with
   `kbusSetBAR0WindowVidOffset` (cache-consistent) and restored; window
   base/status are read back and printed.
3. **WPR read**: the same window over `[frts − 0x50000, frts)` and FRTS, with the
   non-WPR heap at GSCI `nonWprHeapOffset` as the control.

**Result 1 — BAR1 does not exist during the boot.** At
`kgspPopulateWprMeta_GH100` the bus reports `static=0 start=0x0 size=0x0
aperture=0x0`; `kbusInitBar1` is called from `kbusStatePostLoad` in
`gpuStateLoad`, which runs *after* `kgspInitRm` (E74a). Constructing a mapping
there dereferences a NULL PTE array:

```
BUG: kernel NULL pointer dereference, address: 0000000000000000
RIP: dmaAllocMapping_GM107+0xfd/0x2300
Call Trace: _kbusMapAperture_GM107 -> kbusMapFbAperture_GM107 ->
            bf16FbMapRanges -> kgspPopulateWprMeta_GH100 -> kgspInitRm_IMPL
```

This is the structural answer to E48's "inconclusive": BAR1 offsets are BAR1-VAS
offsets, not FB physical addresses, and the VAS is not even built when the HS
boot runs. The oops killed the loading thread and the harness could not restore
itself; the machine was rebooted before the next run. No GPU state was corrupted
by the fault itself.

**Result 2 — the BAR0 window is the working host FB path.** Post-boot, the
window write lands and reads back: `want=0x100 after=0x100` for PA
`0x01000000`, `want=0x5dd0 after=0x5dd0`, `want=0x7e72e after=0x7e72e`. The
control at the GSP-RM non-WPR heap (`0x7e72e0000`, outside the WPR) returns
**58,707 nonzero bytes, entropy 7.6408**, identical on both cards. The mechanism
works, and it is the same one RM uses before BAR1 exists. The window the
driver had left pointed at `0x7f5e00000` (the VGA workspace above the WPR) and
is restored to that value after every dump.

**Result 3 — the candidate PAs are empty.** Through that proven window, on both
cards:

| PA | Content |
|---|---|
| `0x01000000` | all zero (`nz=0`) |
| `0x5dd00000` | all zero (`nz=0`) |
| `0x181d0000` | all zero (`nz=0`) |

`0x01000000` was the "GSP-RM ELF identity-mapped at PA" control from E67; it is
empty, so the ICD's `0x01000000` is a core-space address, not a host FB PA. The
`VA 0xefd00000 → PA 0x5dd00000` inference is likewise dead.

**Result 4 — the boot image is inside the WPR, and the WPR is poison to the
host.** GSP-RM publishes `nonWprHeap=0x7e72e0000`, `frts=0x7f42c0000` on both
cards (the same layout values as E31–E35). The WPR layout puts the boot bin at
`frts − sizeOfBootloader` = `0x7f4279000`. Reading `[frts − 0x50000, frts)` and
FRTS itself returns a uniform fill:

| Window | Size | Nonzero | Entropy | Head |
|---|---:|---:|---:|---|
| `[frts − 0x50000, frts)` | 320 KiB | 245,760 (exactly 3/4) | exactly 2.0000 | `00acd0ba` ×4 |
| FRTS `0x7f42c0000` | 64 KiB | 49,152 (exactly 3/4) | exactly 2.0000 | `00acd0ba` ×4 |

`00acd0ba` little-endian is the dword `0xbad0ac00`, a deliberate
access-denied sentinel (three nonzero bytes per dword, hence the 3/4 count and
entropy 2.0). The same values appear on both cards. This is a protection
response, not firmware: the FMC writes FRTS, and the boot bin must hold code.

**Conclusion.** The decrypted bootloader is inside the WPR
(`frts − sizeOfBootloader`, `0x7f4279000`); every host read of that range returns
`0xbad0ac00`, while reads of ordinary FB through the same window return real
data. The FB/BAR1 route to the boot image is closed by hardware, not by a wrong
address or a broken probe. Open question #16 is answered negative; the memory
route is exhausted and the remaining class is PL3 code execution.

**Corrections recorded.** (1) BAR1 offsets are VAS offsets and BAR1 does not
exist during the boot. (2) The GSP-RM ELF is not identity-mapped at FB PA
`0x01000000`. (3) The boot image is not at PA `0x5dd00000`; the `+0x92000000`
subtraction applies to the core's address space, not to host FB.

**Hazards.** Reading inside the WPR through the window returns the sentinel and
did **not** wedge either GPU; the window is restored and the stock driver loads
afterwards. The BAR1 mapping attempt oopses the kernel (`dmaAllocMapping_GM107`,
NULL PTE array) — do not repeat it before `gpuStateLoad`.

**Artifacts.** `phase2b/fb_capture.sh`; hooks `BF16_FBREAD` and `BF16_WPRLAYOUT`
in `kernel_gsp.c`; `phase2b/fbcapture_20261028_233108/` (BAR1 oops),
`phase2b/fbread_20261028_234642/` and `..._235114/` (window + controls),
`phase2b/fbread_20261028_235405/` (WPR poison); dumps in `phase2b/fbread/`
(`fb_{nwpr,boot1,frts,wprbin}_gpu{0,1}_*.bin`); `oops.txt`.

#### E75 · The non-WPR heap holds no live RM objects

*2026-10-29 · Revision 87 · status: CLOSED-MEASURED (negative)*

**Question.** E74 gave a working host read of unprotected FB. Does the 3 MiB
GSP-RM non-WPR heap (`GSCI nonWprHeapOffset`) contain the live RM objects behind
open questions #10–#12 — the `obj+0x938` FEAT method, the config object with
`+0xEA4/+0xEA8/+0xEAC`, the GR context/ucode descriptor?

**Method.** Dump the whole 3 MiB heap plus three 64 KiB windows (below the start,
the start, and one window past the end) through the E74 BAR0 window, both cards,
immediately after GSP-RM is up; then mine it offline (`phase2b/fbread_analyze.py`:
pointer census by region, ASCII/UTF-16 strings, known E58 handler runtime VAs,
FEAT constants).

**Result.** 3,145,728 bytes; 1,686,643 nonzero; both cards **byte-identical**
(SHA-256 `dacca64f…`). Structure by block:

| Range | Content |
|---|---|
| `+0x000000`–`+0x010000` | 64 KiB structured header (90% nonzero, entropy 7.64) |
| `+0x010000`–`+0x1A10A2` | 0x1910A2 bytes of uniform random (entropy 7.999–8.000), one 8,288-byte zero hole at `blob+0x18F000` |
| `+0x1A10A2`–`+0x300000` | zero |

The 64 KiB prefix equals an independently read 64 KiB window at the same PA, so
the read path is consistent. There is **no object structure**: 3,324 dwords fall
in the code VA range and every one is distinct (the chance rate for the random
span), the 16-byte block histogram is 102,149 distinct values in 102,666 blocks,
no ASCII/UTF-16 identifiers, and **none** of the eight known handler runtime VAs
(`FUN_ram_0160f1bc` = `0x934801bc`, `FUN_ram_01c1f378` = `0x93a90378`, …) appears
anywhere in the 3 MiB.

**Boundary.** The WPR sentinel `0xbad0ac00` starts at `0x7e75e0000`, exactly
`nonWprHeapOffset + 0x300000`: the published non-WPR heap size is the whole heap,
and the WPR starts at `0x7e75e0000`. The 64 KiB window below the published
start also holds data (6,766 nonzero bytes), so the start is an allocation
boundary, not the edge of FB. The captured GSP log corroborates the region
(`INIT id=0x20187640 args=[0x7e72e0000, 0x300000]`).

**Interpretation.** The 3 MiB non-WPR heap is not where GSP-RM's RM objects live:
it holds a small structured header and one ~1.6 MiB high-entropy allocation of
unknown provenance (deterministic across both cards in this boot, not object
memory), and is otherwise zero/uninitialized. The RM objects are allocated from
the **WPR heap** (`gspFwHeapOffset`, 135 MiB), which is inside the protected
region and returns the sentinel. #10–#12 therefore stay static; a runtime view
would need GSP-RM cooperation (an RPC that reads/copies its heap) or a PL3
primitive, not a host FB read.

**Artifacts.** `phase2b/fb_capture.sh`, `phase2b/fbread_analyze.py`;
`phase2b/fbread_20261029_002110/` (`heap_report.txt`, `compare.txt`,
`dmesg_post.txt`); dumps `phase2b/fbread/fb_{heap,nwpr,nwprev,wprstart}_gpu{0,1}_*.bin`.

### D.F The SR-resume path

#### E42 · The SR path is live and host-driven

*2026-10-26 · Revision 41 · status: LIVE*

**Method.** `phase2b/sr_resume_test.sh`. Trigger: a device-level s2idle test cycle:

```bash
echo devices > /sys/power/pm_test
echo mem > /sys/power/state
```

The kernel runs the device callbacks, waits 5 s, resumes, and the machine stays up;
the cycle took ~8 s and both cards returned.

**Result.**

```
BF16: SRMeta magic=0x8a3bb9e6c6c39d93 rev=2 size=0xcde0000 flags=0x0 radix3Addr=0x148c00000  (GPU0)
BF16: SRMeta magic=0x8a3bb9e6c6c39d93 rev=2 size=0xcde0000 flags=0x0 radix3Addr=0x1af000000  (GPU1)
BF16: SRMeta inputs frts{off=0x7f42c0000 size=0x100000} nonWpr{off=0x7e72e0000 size=0x300000}
BF16: FMC boot params: bootMode=1 ... bootGspRm{desc=0x1ae65c000 size=0x100 target=2 bBoot=1}
```

The host builds `SRMeta` and the radix3 in unprotected sysmem and hands the
descriptor to the FMC on resume. The size equals the WPR span measured at boot.

**Artifacts.** `phase2b/sr_resume_20261026_085922/`; `phase2b/sr_resume_test.sh`;
`phase2b/sr_oracle.sh`.

#### E43 · A bad SRMeta magic hangs the resume

*2026-10-26 · Revision 42 · status: hang, blind*

**Method.** `sr_oracle.sh 1` (`magic = 0xdeadbeefdeadbeef`).

**Result.** The `pm_test=devices` cycle entered suspend at 09:02:57 and never came
back; the user rebooted at ~09:07. The previous boot's journal ends at:

```
PM: suspend entry (s2idle)
Filesystems sync: 0.039 seconds
```

journald is frozen immediately after that point, and post-freeze printk is only
flushed on a successful resume. A failed resume leaves no host-visible log.

**Attribution.** The stock cycle (E42) completed with the same trigger and build; the
only change was the magic. Secure ucode consumes it; the failure mode is a hang.

**Consequences.** The SR oracle is binary until netconsole/serial or phase markers
are added. On a hang the traps do not run, so the tree must be reset manually; the
COT/WprMeta oracles now clear the SR defines on entry.

**Artifacts.** `phase2b/sr_oracle_20261026_090227/`; journal of the failed boot
(`journalctl -k -b -1`).

#### E45 · The SR suspend image is encrypted

*2026-10-26 · Revision 44 · status: state editing closed*

**Method.** `phase2b/sr_dump_test.sh`: at the resume FMC setup, read `SRMeta`, compute
the data region as the tail of the radix3 allocation
(`dataOff = totalSize − align_up(size, 4K) = 0xce49000 − 0xcde0000 = 0x69000`), map
it in 16 MiB chunks through `memdescMap`, write to disk, and scan every 32-bit word.

**Result.** 231.875 MiB per card.

| Metric | Value |
|---|---|
| Zero 1-MiB chunks | 97 / 205, identical mask on both cards |
| Nonzero spans | 0–7, 11–17, 112–204 MiB |
| Entropy, nonzero chunks | **7.9998 bits/byte** |
| ELF / WprMeta / SRMeta magic / vendor strings | none |
| zstd / gzip / lz4 / xz headers | none |
| Bytes equal between cards outside zero chunks | 2,258,261 of ~108 MiB |
| FEAT/selector constants | 0 |

**Artifacts.** `phase2b/sr_dump_20261026_092916/`; `phase2b/sr_dump_test.sh`;
`phase2b/analyze_srdump.py`, `analyze_srdump2.py`.

#### E46 · Plaintext radix3, per-boot ciphertext

*2026-10-26 · Revision 45 · status: structure mapped*

**Method.** Second dump with the hook extended to the whole descriptor
(`0xce49000` = 216,305,664 B per card; state `0xcde0000`, data at `0x69000`).

**Result.**

| Level | Content |
|---|---|
| root (1 page) | `root[0]` → L1 at `+0x1000` |
| L1 (1 page) | `L1[0..102]` → 103 L2 pages |
| L2 (103 pages) | 52,704 nonzero, unique, 4K-aligned PTEs in 52,736 slots |

The data pages sit in 52 physical runs, mostly 1,024 pages (4 MiB); card0 starts at
`0x1c2c69000`. 25,277 of the 52,704 state pages are zero, with the same mask every
run.

| Comparison | Nonzero pages | Equal |
|---|---:|---:|
| Same card, previous boot | 27,322 | **0** |
| Other card, same cycle | 27,427 | **0** |

**Artifacts.** `phase2b/sr_dump_20261026_093539/`; `phase2b/analyze_ptes.py`.

### D.G The plaintext corpus

#### E02 · PL3 component inventory

*2026-10-25 · Revision 2b · status: static*

**Method.**

1. `readelf -sW nvidia.ko` for `ksec2BinArchive*`, `kgspBinArchiveGspRmBoot_*`,
   `kgspBinArchiveGspRmFmc*`, `kgspBinArchiveConcatenatedFMC*`.
2. Extraction: symbols are in section 20 (`.rodata`, file offset `0x434558`); file
   offset = `0x434558 + st_value`.
3. Shannon entropy, printable-string counts, debug/prod byte differencing.
4. FMC wrapper parse with `readelf -SW fmc.bin`.
5. Host interface review: `kern_fsp_cot_payload.h`, `kern_fsp.c`,
   `kernel_gsp_booter.c`, `kernel_gsp_gb100.c`.
6. Boot-path check: in the open GB100 HAL, `ConcatenatedFMC` is selected only under
   confidential compute. Resolved on this SKU by E28.

**Result.** Only TU102 (303 B) and AD10X (6,233 B) SEC2 images exist; GB202 ships
prod and debug GspRmBoot and FMC. All bodies ≥ 7.98 bits/byte; FMC prod vs debug
differ in 99.6% of bytes, GspRmBoot in 98.4%.

**Reproduce (entropy).**

```bash
python3 - <<'EOF'
import collections, math
d = open('/tmp/nvk/nvidia.ko','rb').read()
sec = 0x434558
for name, off, size in (
    ('GspRmBoot PROD', 0x4d6a58, 0x47000),
    ('GspRmBoot DBG',  0x51da78, 0x47000),
    ('FMC PROD',       0x15b040, 0x46248),
    ('FMC DEBUG',      0x25cf28, 0x46248),
):
    b = d[sec+off:sec+off+size]
    c = collections.Counter(b); n = len(b)
    h = -sum(v/n*math.log2(v/n) for v in c.values())
    print(f"{name}: entropy={h:.3f} head={b[:8].hex()}")
EOF
```

#### E03 · Boot-chain availability research

*2026-10-25 · Revision 3 · status: static; no ROM obtained*

**Method.** Read nova-core `fsp.rst`, `vbios.rst`, `falcon.rst`, the August 2026
secure-boot correction, and the FMC firmware patch. Inventory
`/lib/firmware/nvidia/gb202/gsp/`; audit `nvidia-debugdump --help` and its strings;
check for `/dev/nvdebug`; check `/sys/bus/pci/devices/<bdf>/rom`. Read the gspwn
knowledgebase, the cmp170hx Falcon/booter write-up, and the October 2026 no-flash
VBIOS coverage.

**Result.** No FSP or BootROM image exists in any package; no documented running-
system read path. Obtainable: the board vBIOS, the encrypted FMC, the plaintext
GSP-RM. The ROM BAR read was later superseded by E04 (it stops at `0x27A00`).

**Artifacts.** None beyond the source reads.

#### E04 · The vBIOS dump and analysis

*2026-10-25 · Revision 4 · status: static*

**Method.** Read-only; the only config-space change was setting and clearing the
PCI ROM BAR enable bit.

1. PCI ROM BAR returns 162,304 B (PciAt + EFI), all `FF` after `0x27A00`. `echo 1 >
   rom` does not set the enable bit on this kernel; it was written directly at
   config offset `0x30`.
2. PROM aperture scan over BAR0 `0x300000`–`0x400000`; found the image at
   `0x338000`; no ERoT (`NV_PBUS_SW_GLOBAL_EROT_GRANT = 0x5`, `VALID=0`).
3. Dump of `0xC8000` B, then `0x100000` to probe the boundary (`0xBADF…` past BAR0
   `0x400000`).
4. Parse: image chain, PCIR/NPDS/NPDE walk, BIT at `0xDF0`, ucode table at
   `0x64E9D`, descriptor decode, constant scan, x86 store scan, two-card diff.
5. Ghidra on the x86 PciAt image (85 functions); the real-mode pass recovers little;
   its purpose was the MMIO-store scan.

```bash
cd /home/shutty/code/nvidia-unlock/vbios-analysis
sudo ./scripts/vbios_probe 0000:41:00.0 300000 100000
sudo ./scripts/vbios_read  0000:41:00.0 input/flash_41.bin
python3 -I scripts/parse_flash.py input/flash_41.bin
```

**Result.** In §11.1: image chain, six populated µcode entries all encrypted, no
FWSEC app IDs, zero FEAT/FUSE constants, 1,375 bytes differing between cards.
*(E66 corrects the census: four real images plus the `0x18`/`0x24` placeholders,
which point at `0xBADF1100`; the body offsets and targets are in E66.)*

**Artifacts.** `vbios-analysis/scripts/`; `input/flash_41.bin`, `flash_c1.bin`.

#### E05 · FMC container and signature analysis

*2026-10-25 · Revision 5 · status: static*

**Method.** Inputs: `gb202/gsp/fmc-570.144.bin` (ELF32 wrapper) and the 13 FMC
containers in `nvidia.ko` 595.91.07, located by scanning for `03 04 48 00` (each is
`0x48 + u32@+4` bytes). For signed images, extract the `0xF8` bytes before the
container as `publickey[97] || pad[7] || signature[96] || hash[48]`. DER-encode the
key as SPKI (`ecPublicKey` + `secp384r1`) and the signature as
`SEQUENCE{INTEGER r, INTEGER s}`.

```bash
openssl pkey  -pubin -inform DER -in pub.der -out pub.pem
openssl dgst -sha384 -verify pub.pem -signature sig.der container.bin        # Verified OK
openssl pkeyutl -verify -pubin -inkey pub.pem -in hash.bin \
         -sigfile sig.der -pkeyopt digest:sha384                              # Verified OK
```

**Result.** For all 14 samples `body = code + data + 0xA00`. `hash` is SHA-384 over
the whole container, header included; `s || r` ordering fails, so the layout is
`r || s`. Two keys verify: production `04 8bf118bb…` (c00, c01, c04, c06) and debug
`04 d30bd54b…` (c09, c11). The other seven containers have a valid hash but no inline
key block. Body entropy 7.999; ≤ 1 repeated 16-byte block per image; prod/debug XOR
zero count 1,154 in 287,232 (chance rate).

**Artifacts.** `fmc-analysis/` (containers, keys, `fmc_image.bin`,
`bootloader.bin`).

#### E06 · The GA100 test-key route, tested

*2026-10-25 · Revision 6 · status: CLOSED-STATIC*

**Method.** Three offline tests against the published known-answer test
`AES-ECB(key37, 0×16) = 717d1494eaca317ff106195258b38377`:

1. Fingerprint scan for the 16-byte KAT constant in all FMC containers, the
   ELF-wrapped FMC, the linux-firmware bootloader, the 1 MiB vBIOS dump, and the
   decompressed `nvidia.ko`.
2. Repeated-16-byte-block count (ECB structure); the four vBIOS µcode bodies at
   descriptor `+0x50`, 8 KiB each.
3. 132,240 structured candidates derived from the MD5 IV, tested with
   `pycryptodome` AES-ECB: word orders, byte orders, rotations, full per-byte
   nibble-swap masks (65,536), ShiftRows permutations, key-schedule words,
   XOR/add constants, key-index variants.

**Result.** 0 fingerprint hits; ≤ 1 repeated block per FMC; vBIOS bodies 512/512
distinct; no key candidate matches. Hashcat cannot express "each of the 16 known
bytes exactly once" (a position mask is 16¹⁶ ≈ 1.8 × 10¹⁹ vs 16! ≈ 2.09 × 10¹³).
The full permutation is ~1–3 h on two 5090s with a custom factoradic OpenCL kernel,
with no GB202 target.

**Artifacts.** `fmc-analysis/scripts/key37_search.py`, `key37_search2.py`.

#### E13 · The computed FEAT readout path and the control-table audit

*2026-10-25 · Revision 13 · status: decoder found; audit corrected by E17*

**Control-table audit.** Decode every 32-byte record in `0x20801200`–`0x208012ff` as
`{ctrlId, paramSize}` and compare with `ctrl2080gr.h`: **44 table IDs and 44 public
IDs, an exact match**. `0x2080123e` is `GR_TEST_CTXSW_ERROR_LOGS`. The internal
static-info entries `0x20800b03` and `0x20800b05` are GET-only.

**V2 and throttle.** `regops ratev2` (`0x2080123c`) returns 10 entries; `throttle`
(`0x2080123d`) returns one `MASK=0` entry.

**The computed access.** Searching the fused sub-offsets as call arguments found
`0x3818` in `FUN_ram_015ffae8` (`mod_community_0_KDASHARE.c:41858`):

```c
pcVar3 = *(code **)(*(long *)(param_1 + 0x1d70) + 0x100);
(*pcVar3)(param_1, *(long *)(param_1 + 0x1d70), 0x3818, &local_40, 0,0,0, pcVar3);
param_3[5] = (byte)(local_40 >> 0xd) & 7;
...
param_3[2] = local_3c[0];   /* DP, second call through object +0xc38 */
```

The decode fills the V1 getter's nine bytes in order and matches stock exactly.

**Reference audit — withdrawn.** This pass reported zero references to
`FUN_ram_015ffae8`; the scan mishandled the negative 20-bit `auipc` immediate, and
Ghidra had never disassembled the containing function. E17 corrects it.

**Artifacts.** `regops/results/ratev2_throttle_20261025.txt`;
`out/handlers_rate_internal.c`; `out/handlers_rate_getters.c`;
`out/revision13_reference_audit.txt`; `out/modules_v2/mod_community_0_KDASHARE.c:41858`.

#### E16 · Host-driver source audit

*2026-10-25 · Revision 14 · status: CLOSED-STATIC*

**Method.**

1. Read `kernel_gsp_gb202.c` and its build object: `nm -g --defined-only` returns
   exactly `kgspVgpuFwHeapSize_GB202` and `kgspVgpuNumVgpuPartitions_GB202`; `size`
   reports 326 bytes of text.
2. Trace HAL dispatch in `generated/g_kernel_gsp_nvoc.c`: GB202 → `kgspResetHw_GB100`
   (1158), `kgspSetupGspFmcArgs_GH100` (1918), `kgspBootstrap_GH100` (803).
3. Trace the vGPU call site: `kernel_gsp.c:6264-6266`, only when
   `bVgpuGspPluginOffloadEnabled`.
4. History: `git log --diff-filter=A --follow` shows the file introduced in
   `580.65.06` (2025-08-04).
5. Grep the tree for every rate literal: zero hits. Enumerate `NV_FUSE_ZB_*` uses:
   `kern_mem_sys_gb100.c:271` (`0x3814`, ECC), `kernel_gsp_gb100.c:296` (`0x74c`),
   `:318-320` (ucode version). All reads.
6. Diff `570.153.02 → 595.91.07` for `kernel_graphics.c` and `ctrl2080gr.h`: V2 and
   throttle GETs added; no SET.

**Result.** The host driver contains no rate writer. `nm` on the installed
`nvidia.ko` finds the two GB202 vGPU functions at `0x24fd20` and `0x24fda0`.

**Artifacts.** Source paths above; no GPU or firmware changes.

#### E17 · The decoder is a table-installed HAL method

*2026-10-25 · Revision 15 · status: corrected static model*

**Where the audit went wrong.**

```
015c1c4a8: auipc a4, 0xff9e3      ; a4 = pc - 0x61d000 = 0x015ff4a8
015c1c4ac: addi  a4, a4, 0x640    ; a4 = 0x015ffae8
015c1c4b0: sd    a4, -0x3e0(a5)   ; *(void**)(obj + 0xC20) = FUN_ram_015ffae8
```

**Method.** Decode every 2-byte-aligned word of the 72,830,976-byte image and test
`JAL`, `AUIPC+ADDI`, `AUIPC+JALR`, `LUI+ADDI` with correct sign extension, plus raw
u32/u64 and table forms. Disassemble and decompile survivors with
`scripts/DisasmRange.java` and `DecompileAt.java`.

**Result.** `0x015ffae8` is materialized at five sites (`0x1c1c4a8`, `0x1c1db74`,
`0x1c1dcf0`, `0x1c1ddda`, `0x1c1e40c`), all inside `FUN_ram_01c1c374` (`0x21fc`
bytes). Each stores into `obj+0xC20`. The initializer fills `obj+0xB78…0xDE8` from
`desc+0x10`: family `(>>5)`, variant `(&0x1f)`. The object is `0x3E40` bytes, built
by `FUN_ram_01acd340` (`0x527c`), which calls the initializer at `0x1acde76`.

| Variant (`desc[0x10] & 0x1f`) | `obj+0xC20` | Register source |
|---|---|---|
| not in `{5..9}` | `FUN_ram_015ffae8` | fuse `0x3818` via `gpu+0x1D70 → +0x100` |
| in `{5..9}` | `FUN_ram_015ff1dc` | register `0x9668` via `obj+0xF20 → +0x28` |

Both produce the same nine bytes. Slot `+0xC38` (DP) is set to `FUN_ram_01615a40`
on matched paths; it extracts `[30:28]`.

**Still open.** `FUN_ram_01acd340` has no static references in any encoding tested,
so the instantiation path is unresolved. The decoder's caller is whatever invokes
`obj+0xC20`; a scan for indirect calls through `-0x3e0(base+0x1000)` finds 19 sites,
nearly all using the value as an engine bitmask and not tied to this table.

**Register probe.** `0x829668` reads `0xBADF1100` (outside the decodable window);
`0x009668` reads `0xBADF5040` (decodable, unimplemented). `0x9668` is not a plain
BAR0 offset; the `obj+0xF20` interface translates it.

**Artifacts.** `scripts/DisasmRange.java`; decompilations of
`FUN_ram_01c1c374`, `FUN_ram_01acd340`, `FUN_ram_015ff1dc`, `FUN_ram_015ffbd0`.

#### E47 · The full vBIOS aperture

*2026-10-26 · Revision 46 · status: static corpus closed*

**Tools.** `vbios-analysis/scripts/prom_read_raw.c` (read-only dump of any range of
the 2 MiB PROM aperture) and `bit_tokens.py` (image-base-aware BIT decode and
two-card diff).

**Result.** Aperture map in §11.1: `0x00000`–`0x38000` head (`NVFW` at `+0x1000`,
218 KiB encrypted blob, plaintext board metadata), `0x38000`–`0x138000` the vBIOS
image, `0x138000`–`0x200000` the `0xBADF1100` sentinel. Head 99.65% identical
between cards (228,586/229,376). All 20 BIT tokens resolve to configuration data;
no FEAT/`SS0`/`SS1` constants anywhere in the aperture, in either endianness, on
either card.

**Artifacts.** `vbios-analysis/input/prom_full_41.bin`, `prom_full_c1.bin`;
`scripts/prom_read_raw.c`, `prom_read_raw`, `bit_tokens.py`.

#### E73 · FMC body layout and the RISC-V-validity key oracle

*2026-10-28 · status: layout CLOSED-MEASURED; oracle built and self-tested;
c09/c11 16! passes complete and negative under five hypotheses (2026-10-29)*

**Hypothesis.** The previous FMC 16! oracle accepted a key only if its first
decrypted block was a container/compression magic. If the encrypted body starts
with code — as the 0xA00 size algebra and the GspRmBoot geometry suggested — a
correct key could have been discarded, and "family exhausted" would not be
established.

**Method — layout.** Extract the GB202 FMC containers (`c04` prod, `c09` debug)
and the `GspRmBoot_GB202` prod/debug images from the 595.91.07 `nvidia.ko`
(`.rodata` at file `0x434558`; symbols
`kgspBinArchiveGspRmBoot_GB202_BINDATA_LABEL_UCODE_IMAGE_{PROD,DBG}_data` at
`0x4d6a58`/`0x51da78`; FMC prod/debug at `0x15b040`/`0x25cf28`). Parse the
container header (`codeSize` at `+0x0C`, `dataSize` at `+0x14`) and the
GspRmBoot `WprMeta` geometry (manifest 0, data `0xA00`, code `0xF200`, size
`0x47000`) and compare region by region for both the prod and debug pairs.

**Result — layout.** Both pairs agree on every region:

| Region | Comparison | Prod | Debug |
|---|---|---|---|
| FMC `body[0 : codeSize]` | GspRmBoot `[0xA00+dataSize : ...]` | identical prefix (`0x37000`) | identical prefix (`0x37000`) |
| FMC `body[codeSize : codeSize+dataSize]` | GspRmBoot `[0xA00 : 0xA00+dataSize]` | **identical** (`0xE800`) | **identical** (`0xE800`) |
| FMC `body[codeSize+dataSize : ]` | GspRmBoot `[0 : 0xA00]` | **identical** (`0xA00`) | **identical** (`0xA00`) |

The body is `[code][data][manifest 0xA00]`; the manifest is the GspRmBoot
manifest; the FMC code is a prefix of the GspRmBoot code. The data and manifest
ciphertexts are identical although their absolute offsets differ between the
two images, so there is no cross-component chaining: the mode is ECB or a
per-component reset. The first block of the body is code, and under CTR its
plaintext is `E(K,0) XOR C0` — the same two hypotheses the old oracle tested,
but with the correct plaintext class.

**Method — oracle.** `phase2b/build_riscv_logp.py` extracts the loaded GSP-RM
code segment (the ELF at file `0x18F000`, `p_vaddr 0x01000000`, `0xDCD000`
bytes; the largest of the 11 embedded ELF64 headers) and builds a 16-bit parcel
histogram (7,233,536 parcels, entropy 11.588 bits, `p = (count+1)/(n+65536)`,
quantized to `round(2*log2 p)`). `key37_cuda.cu` gains `--fmc-riscv`: Stage 1
decrypts block 0 in the ECB/CBC-zero and CTR-zero hypotheses and sums eight
table entries; Stage 2 decrypts 8 blocks for Stage-1 survivors, scores the ECB
and CBC-zero streams (mode 0) or the CTR stream with counter = block index
(mode 1), and records hits with mode 0/1/2 and the score. The compact
(non-RF16) AES kernel uses 12,872 B shared, 118 registers, 2 blocks/SM, so the
64 KB table stays in L1.

**Calibration (GSP-RM function starts, 19,481).** Stage 1 `t1 = -256`
(3.8 σ of the 8-parcel random sum): 97.0% overall, 99.3% on clean code
(`< 0xC00000`; the excluded `0xC00000–0xCA0000` region is data-like). Stage 2
8 blocks, `t2 = -2102` (9 σ): 99.92% of clean code. The staged random tail is
the joint probability `P(S0 > t1 and S64 > t2)`, computed exactly over the
quantized parcel distribution (not the Gaussian approximation, which is far too
optimistic in this bounded-support tail): `1.2e-14`, i.e. ~0.5 records per
hypothesis over 16! (ECB, CBC-zero and CTR-zero each tested). The GSP-RM entry
block scores -185 Q (well above `t1`).

**Controls.** A synthetic container with the real GSP-RM code component,
encrypted under the rank-0 key (`POOL` in order), is recovered as exactly one
hit with key `01102332455467768998abbacddceffe`, rank 0, score -1533, in all
three modes — ECB (0), CBC-zero (1) and CTR-zero (2) — and
`fmc_riscv_verify.py` accepts each decryption. The same key over random
plaintext: `hits=0`. The first full-code run exposed two stage-2 bugs the
one-block path could not see: CBC must XOR with the previous *ciphertext* block,
and the CTR counter word is the block index itself (big-endian word 3), not a
byte-swapped value; both were fixed and the controls re-run. A full-code
synthetic passes the instruction walk at 0.046% invalid (`prefix_bad` 0.28%,
longest invalid run 1, 53 out-of-image branch targets from literal pools); a
random key is rejected at 8.8% invalid.

**Legacy-hit re-score.** Each of the 12,260 old c09/c11 first-block hits carries
its plaintext block. Scoring those blocks with the parcel model gives c09
median -297 Q (p1 -315, min -323, max -246) and c11 median -297 (p1 -315,
min -325, max -248) — the random mean is -296.4 Q (σ 10.6). Only 5/6,115 and
2/6,145 exceed `t1 = -256`, the chance rate. Every recorded legacy hit is a
random-magic false positive.

**Rate.** 8.50 G keys/s per 5090 with Stage 2 enabled (9.02 G/s with Stage 2
disabled); the RF16 table layout is 4.36 G/s because the 37.4 KB shared tables
push the 64 KB parcel table out of L1. A two-GPU 16! half is ~20 min.

**Result — c09 16!, negative (2026-10-29).** Both GPUs, disjoint halves of the
whole 16! space, `t1=-256`, 8-block Stage 2 `t2=-2102`, all three hypotheses
(ECB, CBC-zero, CTR-zero). Start `2026-10-28T23:57:54Z`, end `00:20:49Z`;
**1375 s wall**, **7.61 G keys/s per 5090** sustained (15.2 G/s combined), both
rc 0. **0 hits** — no candidate reached even the recording threshold (the
exact-DP expectation for the whole run is ~1.5 chance records; P(0 | 1.5) = 0.22,
so the count is within Poisson expectation and on the low side). Nothing to send
to `fmc_riscv_verify.py`. The c09 debug FMC is therefore not decrypted by any
MD5-IV permutation under ECB, per-component CBC-zero or CTR-zero, with the
code-first oracle: the first FMC negative that does not rest on a magic filter.

**Mode completeness (2026-10-29).** The zero-IV pass leaves one assumption open:
a per-component non-zero IV or counter start. The compact kernel now evaluates
five hypotheses per key — ECB (0), CBC-zero (1), CBC with IV = container bytes
`0..15` (3), CTR start 0 (2), CTR start 1 (4) — using one CBC stream (an IV only
changes block 0) and one extra encrypt for CTR start 1. Hit modes in `fmc_hit`:
0/1/3 decrypt, 2/4 CTR. `fmc_riscv_verify.py` knows modes 3 and 4 (CBC with the
container header IV; CTR with a 16-byte big-endian IV of 1). A true CBC key
legitimately hits both CBC modes because the header IV is a small mask; the pair
is expected and the genuine IV is the higher-scoring one. Controls (rank-0
synthetic, all five modes) recover the key and pass the full-code walk; random
plaintext yields no hit. Rate with all five hypotheses: **6.0 G keys/s per
5090** (the extra CTR encrypt costs ~30%).

**Combined runs, both negative (2026-10-29).** c09 ran
`00:31:30Z → 01:03:12Z` (1902 s), c11 `01:03:12Z → 01:34:59Z` (1907 s), both
GPUs rc 0 on both, ≈5.50 G keys/s per 5090 (11.0 G/s combined; 5.50 because the
extra CTR encrypt is paid on every key). Three chance records total, all
rejected by the full-code walk at 8.6–8.9% invalid:

| Container | Hit | Rank | Score | Verifier |
|---|---|---|---:|---|
| c09 | mode 4 (CTR start 1) | 13,567,028,728,510 | -2097 | reject |
| c11 | mode 0 (ECB) | 5,123,222,474,751 | -2089 | reject |
| c11 | mode 4 (CTR start 1) | 14,469,189,879,912 | -2094 | reject |

The counts match the exact-DP expectation (~2.5 per container across five
hypotheses). **The debug GB202 (`c09`) and 0x30500 (`c11`) FMCs are not
decrypted by any MD5-IV permutation under ECB, per-component CBC with a zero or
header IV, or CTR with counter start 0 or 1.**

**Status.** The IV-permutation avenue is exhausted for the FMC under all tested
modes. Remaining options are a different key derivation/family/source (the
intermediate round keys 1–9 are the only literal remainder, ~1.9 h, speculative)
or hardware; more permutations are not supported.

**Reproduce.**

```bash
# table + five-mode controls (rank-0 synthetic; the second run must find nothing)
python3 -I phase2b/build_riscv_logp.py --fw gsp-analysis/input/gsp_fwimage.bin \
    --out phase2b/riscv_logp_q.bin
python3 -I phase2b/riscv_oracle_selftest.py --bin phase2b/key37_cuda --blocks 8

# full 16! passes: c09 then c11, five hypotheses, both GPUs
fmc-analysis/scripts/run_fmc_riscv_2gpu.sh \
    fmc-analysis/input/containers/c09_00691480_046200.bin \
    fmc-analysis/out/fmc_riscv_c09_modes
fmc-analysis/scripts/run_fmc_riscv_2gpu.sh \
    fmc-analysis/input/containers/c11_00706338_030500.bin \
    fmc-analysis/out/fmc_riscv_c11_modes \
    fmc-analysis/input/containers/c09_00691480_046200.bin
```

Build note: CUDA 13 + GCC 15 needs `-U_GNU_SOURCE` (glibc's `rsqrt` noexcept
declarations otherwise conflict with CUDA's math headers):
`nvcc -O3 -arch=sm_120 -U_GNU_SOURCE -o phase2b/key37_cuda phase2b/key37_cuda.cu`.

**Artifacts.** `phase2b/build_riscv_logp.py`, `phase2b/riscv_logp_q.bin`;
`phase2b/key37_cuda.cu` (`--fmc-riscv`, `--t1`, `--t2`, `--riscv-blocks`,
`--fmc-riscv-rf`); `phase2b/riscv_oracle_selftest.py`;
`phase2b/fmc_riscv_verify.py`;
`fmc-analysis/scripts/run_fmc_riscv_2gpu.sh`;
run dirs `fmc-analysis/out/fmc_riscv_c09/` (three-hypothesis),
`..._c09_modes/` and `..._c11_modes/` (five-hypothesis).

### D.H Assessment and cross-checks

#### E44 · Critical reassessment

*2026-10-26 · Revision 43 · status: assessment*

**Purpose.** Re-read the document against external evidence and separate what is
proven from what is asserted by analogy. Findings:

1. The premise is proven by the RTX PRO 6000 (same die, full rate); the half rate is
   product segmentation.
2. Weak points: the readout→rate mapping is unproven; `0x82380c` is under-analysed
   (since resolved by E56);
   the FECS-context closure rests on an assumed layout and a cross-card diff that
   cannot see shared constants; the local baseline was thin; the per-SM selector was
   not swept.
3. Route ranking at the time: SR-resume trust first, FSP/FMC parser second, per-SM
   selectors third, `0x82380c`/aliases fourth, firmware-mediated buffers fifth,
   Pro-card reference sixth.
4. Next experiments, cheapest first: two-card rate probe and FP16-accumulate mode;
   Pro-6000 reference; SR dump; broaden FSP fuzzing to framing; decode `0x82380c`;
   then netconsole plus SR structure probes.

**Updated since.** The two-card probe is E49 (the "differing `SS0`/`SS1`" weak point
is resolved). The SR state dump is E45 (state editing closed). E56 resolves
`0x82380c` as the ECC override and supplies the A100 full-rate reference. The SR
structure probes remain open. The FP16-accumulate local mode, the Pro-card
reference, and the per-SM sweep are still not done.

#### E48 · The BAR1 FB-read probe

*2026-10-26 · Revision 47 · status: INCONCLUSIVE + hazard*

**Method.** `phase2b/fb_peek.py` maps `resource1` (BAR1: `0x28800000000`, 32 GiB,
ReBAR) read-only at chosen FB offsets and reports entropy/nonzero/FF counts.

**Result.** All four offsets returned 4096 zero bytes: `0x1000000` (control),
`0x7e72e0000` (non-WPR heap), `0x7f0000000` (mid-WPR), `0x7f42c0000` (FRTS). The
intended positive control — the GSP access-map buffer at physical `0x7dd580000`,
known to hold 15,063 nonzero bytes — also returned zeros.

**Interpretation.** BAR1 offsets are not a 1:1 window onto FB physical addresses;
the driver reaches FB through its own aperture/PTE mapping. The probe says nothing
about whether the WPR is readable, and it does not reopen the firmware-read route.
**Resolved by E74:** BAR1 is a VAS; the VAS is absent during the boot and its
offsets are VAS offsets, so this test could never have worked. The BAR0 PRAMIN
window is the correct mechanism, and through it the WPR returns `0xbad0ac00`.

**Hazard.** After the reads both GPUs reported `GPU requires reset`; telemetry was
unavailable and CUDA no longer initialized. The previous boot's journal shows the
same Xid 13/120/154 signature as the BAR0 scan (confirmed in E49).

**Artifacts.** `phase2b/fb_peek.py`; `phase2b/ctxdump_20261026_003659/`.

#### E49 · Same-boot two-card issue-rate probe

*2026-10-26 · Revision 48 · status: resolves the per-card-selector hypothesis*

**Method.** The sm_120 probe on both cards in the same boot, stock driver, no
register poke (omitting `--reg-offset` skips it; no root needed). Cubin SHA-256
`099aecf4…`, 20,000 iterations × 3 reps, 0 mismatches in 270,336 cells per mode.

```bash
CUDA_VISIBLE_DEVICES=<UUID> python3 tensor_modes_driver_runner.py \
    tensor_modes_issue_sm120.cubin --sha256 <hash> --expect-uuid <UUID> \
    --expect-power-limit 575 --iters 20000 --reps 3
```

**Result.** Rates and per-clock normalisation in §1.2.3. `BF16/FP16 = 1.000` and
`TF32/FP16 = 0.500` on both cards; all four modes agree within 0.23% per clock. The
differing `SS0`/`SS1` nibbles do not encode the effective selector.

**Also confirmed.** The previous boot's journal shows the BAR1 probe's fault
signature: Xid 13 (`Graphics FECS Exception: UCODE Error`), Xid 120 (`load access
page fault (cause:0xd) @ pc:0x1368618, partition:4#0, task:3`), Xid 154 (`GPU Reset
Required`).

**Artifacts.** `sm120-probe/results/revision48_41.json`, `revision48_c1.json`.

#### E55 · Tracing-facility audit

*2026-10-26 · status: static*

**Question.** Does the open driver have a debug mode that dumps its firmware
operations on a CUDA kernel invocation, or can one be added?

**Method.** Source audit of the 595.91.07 tree: the launch path, the RM tracing
macros, the GSP log allocation and decode, the NVLOG path, and the debug-dump tool.
Check the firmware directory for the log metadata.

**Result.** There is no per-launch firmware operation to trace: a launch is a
pushbuffer entry plus a doorbell, and the RM is not in that path. The available
facilities and their state are tabulated in §19. The two useful facts:

- `RMEnableEventTracer` is a compile-time no-op on Linux (`tracer.h` defines every
  `RMTRACE_*` macro empty outside the Windows ETW build).
- The GSP task log buffers are host-allocated and host-readable, but decoding needs
  the `.fwlogging` section of `gsp_log_ga10x.bin`, which is absent from the
  installed firmware package, the 580.105.08 `.run`, and the 570.153.02 `.run`;
  `kernel_gsp.c:3649` skips logging when it is missing, so
  `EnableGpuFirmwareLogs=1` prints only the missing-file message. E57 adds a
  fallback: the 33,640 log call sites carry literal metadata IDs, so an
  `{ID -> emitting function, operand count}` table can symbolize a raw dump even
  without the format strings or severity.

**Conclusion.** A firmware *text* trace is not available on this installation. What
can be added with modest instrumentation is a host control/RPC tracer and a raw dump
of the GSP log buffers (§19); E57's ID-to-call-site table turns that dump into a
function-level trace without the missing metadata file.

**Artifacts.** `open-gpu-kernel-modules/src/nvidia/arch/nvalloc/unix/src/osapi.c`;
`src/nvidia/inc/kernel/diagnostics/tracer.h`;
`src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` (`_kgspInitLibosLoggingStructures`,
`_setupLogBufferBaremetal`, `kgspDumpGspLogs_IMPL`);
`src/nvidia/src/kernel/diagnostics/nvlog.c`.

#### E56 · External cross-part register corpus

*2026-10-26 · status: external static; corrects E09/E51 and the `0x82380c`
hypothesis*

**Purpose.** The FEAT block is the same IP on Ampere, Ada and Blackwell. A public
CMP-170HX register survey (`Consensus-Protocol/cmp170hx`,
`docs/hardware/fuses-and-otp.md`, commit `879454d6`) carries the full
`0x823800`–`0x82382c` block with stock values from thirteen parts, including three
A100s, a Drive A100, two 170HX units and the consumer GA10x cards. The
gpu-unlock-ada issue #12 thread adds a complete GB203M laptop cold-boot dump and
confirms that no RTX PRO 6000 dump is public.

**Register names and cross-part values.**

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

**Fuse values and the full-rate reference.**

| Fuse | A100 (all) | Consumer Ampere | GB202/GB203M |
|---|---:|---:|---:|
| `FUSE_SS_FMLA32` | **0** | 1 | **3** |
| `FUSE_SS_IMLA4` | **0** | 1 | **3** |
| `FUSE_SS_IMLA2` | **0** | 0 | **3** |
| `FUSE_SS_IMLA1` | **0** | 0 | **3** |
| all other `FUSE_SS_*` | **0** | 0 | 0 |

The A100 is a full-rate part and reads `FEAT_READOUT_1 = 0` with every arithmetic
speed fuse at 0. Consumer Ampere reads `0x00400080` (`FMLA32 = IMLA4 = 1`); Ada
reads `0x00410080`, which adds `IMLA2 = 1` (its fuse dump was not taken). On every
generation the readout mirrors the fuse words, and `0` is the full-rate encoding.
The Ampere code scale is documented as a divisor family (`0` full, `5` = 1/32);
under that family a Blackwell `3` would be 1/8, yet the measured `FMLA32` penalty
is ~2× and INT8 is full rate with `IMLA1/2/4 = 3`. The code→rate law, not the
readout, changed.

**Corrections to this document.**

1. `0x82380c` is `FEAT_OVR_ECC`, not an override-shaped speed word. `0x00888888`
   is the stock value on every consumer GA10x part and is an ECC configuration,
   not the Ada speed payload. The two hypotheses in §14.4 and §16.2 are withdrawn.
2. `0x823810` is `FEAT_OVR_ECC_1`; `0x823824/28/2c` are
   `FEAT_OVR_ROW_REMAP`/`FEAT_READOUT_2`/`FEAT_OVR_ECC_2`, not counters. GB202's
   `3/1/0xa` is byte-identical to the RTX 3090 Ti triple. The E51 observation that
   the words do not move is still true, but it is not evidence about a blocked
   write attempt: these are static feature words.
3. `0x823808` is `FEAT_OVR_QUADRO`, a Quadro/consumer classification word. The
   per-card bit-8 difference is binning, not a rate selector.
4. The readout is a fuse mirror across generations, and the A100 confirms the
   all-zero target. This strengthens §2.4's target without validating the Blackwell
   override payload format.
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

**Artifacts.** None local. Sources:
`https://raw.githubusercontent.com/Consensus-Protocol/cmp170hx/879454d6cc221e06331708fba9540300c76b1d63/docs/hardware/fuses-and-otp.md`
and `https://github.com/JustAResearcher/gpu-unlock-ada/issues/12`.

#### E57 · GSP log decoding without `gsp_log_ga10x.bin`

*2026-10-26 · status: static + implementation; corrects the writer semantics in
Appendix G.7 and the record layout below*

**Purpose.** Determine whether the host-side GSP log buffers can be decoded
without the missing logging ELF.

**Method.** Exhaustive scoped filesystem search for `gsp_log_*.bin` /
`*.fwlogging`; read the host allocation and decoder path
(`_setupLogBufferBaremetal`, `_kgspInitLibosLoggingStructures`,
`_kgspInitLibosLogDecoder`, `liblogdecode.c`) and the decompiled writer
`FUN_ram_01b9e86e`; scan the 72.8 MB image for a metadata table and for image-VA
metadata pointers.

**Result — the raw format is known.**

- Per-task buffer: `word0` = total u64 words written (monotonic, not a ring
  index); `word1` initially holds the GPU physical address and is then the first
  record slot; capacity = `size/8 - 1`.
- Record: `[args...][meta][time]`, all u64. The metadata word is **second-to-last**,
  immediately before the timestamp. The writer emits operands, then the metadata
  operand, then `time`; the host reader confirms it by reading timestamp, meta,
  then walking backwards through the arguments. An earlier draft had the meta word
  first; that is wrong for `N > 2` and was caught by the decoder's round-trip test
  (§E57 implementation below).
- Meta: bits 47:0 = metadata VA minus the per-task base (RM `0x2018F000`,
  INIT `0x20183000`, early writer `0x20178000`); 55:48 = N (2..22); 63:56 = task
  ID. The task-1 KERNEL buffer uses a section whose base is still unknown (E59).
- `FUN_ram_01b9e86e(n, ...)` takes an **operand count**, not a level; it writes
  `N = n + 1` entries and packs the *last* vararg (the metadata struct pointer)
  into the meta word. `argumentCount = n - 1 = N - 2`.
- The level and format string live only in the metadata struct, which is in the
  missing logging ELF.

**Result — the metadata is not in the firmware image.** All 29,371 RM literal
metadata IDs lie in `0x20300000`–`0x205217b8` (the INIT and early writers use
`0x2018xxxx`/`0x2017xxxx`), outside the image's load range
`[0x01000000, 0x01457A0C0)`; the 11 embedded ELFs have no `PT_LOAD` there; there is
no `.logging`/`.logging_metadata`/`.fwlogging` section (only the per-task section
*names* near `0x0118A000`); a content scan for metadata tuples finds 112 incidental
hits versus ~33k expected. `gsp_log_ga10x.bin` is absent from the installed package
and from both local `.run` packages (580.105.08 and 570.153.02).

**Result — a function-level trace is still recoverable.** The 33,640 log call sites
include 29,371 that carry literal metadata IDs (4,269 pass a variable). Building
`{metadata ID -> call site, enclosing function, operand count}` from the image and
joining it to a raw dump yields `RM: FUN_ram_0119bc28(args...) id=0x203b9b10` for
each record — the emitting function, argument values, task, and timestamp, without
the message text or severity. 49 INIT/debug sites also have a literal-string
fallback; 41 of them pair to a literal ring call, so their exact text is
recoverable.

**Corrections.** Appendix G.7 and §19/E55 are updated: `FUN_ram_01b9e86e`'s first
argument is the operand count, not a level; the metadata operand is a struct
pointer, not a string; the 580 and 570 `.run` packages are also missing the logging
ELF. E59 adds a second correction: `0x20178000` is the early writer's base, not
INIT's. INIT uses `FUN_ram_011849a6` at `0x20183000`.

**Decoder plan.** Build `id_table.csv` from the decompiled call sites; capture the
buffers via `kgspDumpGspLogs_IMPL` or `libosLogAddLogEx`; parse each ring backwards
from `put`, validating `N` and ID membership; join to the table.

**Implementation.** `gsp-analysis/logdecode/` now implements this plan and is
self-contained:

- `build_id_table.py` parses the decompiled image (~3 s) and scans the raw image
  (~30 s), emitting 30,568 decompiled call
  sites (30,451 RM + 75 INIT + 42 early) plus a raw-instruction fallback of 33,044
  metadata IDs whose call sites Ghidra never analyzed. The table has 58,736
  distinct RM IDs, 184 INIT and 75 early, with enclosing function, module and
  (for decompiled rows) recovered argument count. Raw rows carry `source=raw` and
  `n_args=-1`, and their function attribution is flagged `raw_function`. 2,910 RM,
  10 INIT and 6 early decompiled sites pass the metadata operand in a variable and
  are not tabulated.
- `gsp_log_decode.py` parses one ring or a manifest of rings: monotonic put,
  circular index, backward walk, `N` and ID validation, `--resync` for a corrupt
  boundary, `--put auto`, per-task base selection and flags for inferred or
  mismatched bases. Output is text, JSONL or CSV.
- `build_init_strings.py` recovers exact message text for 31 early-writer IDs by
  pairing each ring call with its adjacent literal-printf fallback
  (`FUN_ram_01179be4(format, file, line, ...)`), with a proximity and
  argument-count check. The INIT writer has no per-statement fallback; RM and INIT
  text remains unavailable.
- `selftest.py` round-trips synthetic rings using the firmware's forward-write
  geometry, including wrap, unknown IDs, a bad boundary/resync, auto-put and the
  text join. All tests pass.
- E59 adds the live capture: 173 records per card with identical
  `(task, ID, argc)` sequences, confirming the layout and the INIT/RM bases;
  141/173 records resolve (96/98 RM, 41/42 INIT).

The implementation corrected one fact in this record: the meta word is
second-to-last, not first. The corrected layout, task/base table and capture patch
are in `gsp-analysis/logdecode/README.md` and `CAPTURE.md`.

**Artifacts.** `/home/shutty/open-gpu-kernel-modules/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c`
(`_setupLogBufferBaremetal`, `_kgspInitLibosLoggingStructures`,
`_kgspInitLibosLogDecoder`, `kgspDumpGspLogs_IMPL`),
`src/common/uproc/os/libos-v3.1.0/lib/liblogdecode.c`, `libos_log.h`,
`liblogdecode.h`; the GSP-RM image in Appendix E; the decoder, ID tables,
capture guide and selftest in `gsp-analysis/logdecode/`.

#### E58 · Static pass: FEAT consumers, decoder selection, registry consumers, FSP surface, GR init

*2026-10-26 · status: static; corrects the "no `SS0`/`SS1` write path" and E50
producer claims*

**Scope.** Independent static directions against the 595.91.07 image and the host
source. The GSP log direction is E57.

**Results.**

| Direction | Finding | Status |
|---|---|---|
| FEAT consumers | `FUN_ram_0160f1bc` writes `0x381c`/`0x3820` through `FUN_ram_01c60868`; installed at `obj+0x938` for variants not in `{5..9}`; the helper's fallback is a direct BAR0 MMIO store (not a shadow), but there is no visible 4-argument caller. Bit 6 is the alternate ninth byte. Read consumers: `0x3814` bits 15/16/18/19/29, `0x3818` decoder + DP/bit 6, `0x3828` bits 5/10. | CLOSED-STATIC (write method exists; unreachable/PLM-blocked) |
| Static-info controls | Control table confirms V1 internal `0x48` (8x9), V2 internal `0x3fe0`, public V1 `0x20`, V2 `0x7fc`; the getter is a copy-out/cache. Handler pointers are 2 bytes early, so the reader trace is partial; no second consumer proven. | PARTIAL |
| Decoder selection | `{5..9}` twin confirmed by `0x3e0 >> variant & 1`. `0xC38` is variant-dependent: `FUN_ram_01615a40` (DP `[30:28]`) or `FUN_ram_015ffbd0` (bit 6). The descriptor is a runtime class object (`0x74bc71`) looked up from the parent, so the variant is runtime state, not a static table. The pass resolves GB202: `GPU_IMPLEMENTATION_GB202 = 0x02` (not in `{5..9}`), so it installs `FUN_ram_015ffae8` / `0x3818`; the twin is the GB205/206/207 path. | CLOSED-STATIC |
| Registry consumers | `config+0xEA8/0xEAC` are read by `FUN_ram_0216d680` and `FUN_ram_0217f718`, reduced to booleans, and written to a GR context/ucode descriptor, not MMIO; EA8 is gated by `+0xEA4`. No reach to `0x823xxx`/`0x409xxx`. `0x504204` has **no writer** in host or GSP-RM. | CLOSED-STATIC |
| FSP surface | Only COT `0x14`, caps `0x16`, clock `0x20` are live; PRC `0x13` is GH100-only; nine NVDM types unused. No length field; the host controls TX length via `QUEUE_TAIL`; response identity (task/command/tag) is unchecked; no memory/fuse/register command. | CLOSED-STATIC |
| GR init | 29 FECS command IDs, all init/context/feature; no selector; no per-SM rate loop; no `0x504204` writer. | CLOSED-STATIC |
| GSP log | See E57. | CLOSED-STATIC |

**Corrections.**

1. §4.4/§11.2: "no computed-offset write to `SS0`/`SS1`" is too strong. A write
   method exists (`FUN_ram_0160f1bc`, installed at `obj+0x938`) and attempts a
   direct BAR0 MMIO store, but it has no visible 4-argument caller, and any PL2
   write is dropped by `FEAT_OVR_PLM` (E08). It is not a usable lever.
2. E50: the producer is `FUN_ram_015ce3e8`, not `0x015cf1be` (an interior
   address). The keys are inert because the value is boolean-ized and EA8 is gated
   by `+0xEA4`, not because the consumer is absent or PLM-dropped.
3. §5.5/E12: no RM code writes `0x504204`; the value 5 comes from
   firmware/devinit or a ctxsw/golden-context restore. The per-context scope is an
   inference.
4. §16.3: bit 6 of `FEAT_READOUT_1` is resolved — it is the alternate ninth byte
   (`FUN_ram_015ffbd0` / the twin's `param_3[2]`), not an unexplained gap.
5. §2.5/E17: the `0xC38` slot is variant-dependent; on some variants it is the
   bit-6 reader, not `FUN_ram_01615a40` (DP).
6. §9.1/§15.1: the FSP command surface is enumerated; there is no memory, fuse,
   register, or debug command, and the only data-returning command (PRC) is
   GH100-only. The framing/identity issues are the remaining surface.
7. GB202's implementation constant is `0x02` (`nv_arch.h`), not in `{5..9}`;
   it installs `FUN_ram_015ffae8` and reads `0x3818`. The `0x9668` twin is the
   GB205/GB206/GB207 path, which is why the direct `0x009668` read on GB202 is
   unimplemented. The `obj+0xF20 -> +0x28` translation of `0x9668` remains
   unresolved, but it is only on that path.
8. The helper's `+0xb48` field is the BAR0 base, not a shadow; the fallback
   is a direct MMIO store. The method is installed on GB202 but has no visible
   4-argument caller. On GeForce, the `is_geforce` byte skips the `fuse+0x108`
   access callback; the `s7+0x108` check can still assert before the store, and a
   PL2 `SS0`/`SS1` write is dropped by `FEAT_OVR_PLM`.

**Artifacts.** The decompiled GSP-RM image and host source tree in Appendix E; the
`0x1c1f378` initializer and the `0x1c60868`/`0x1c60724` helpers can be regenerated
with `DecompileAt.java`/`DisasmRange.java` in `gsp-analysis/scripts/`.

#### E59 · Live GSP log capture and decode

*2026-10-26 · status: measured (host-side read only)*

**Hypothesis.** The E57 format and ID->call-site table are correct, and a real
capture can be decoded to a function-level boot/GR-init trace.

**Method.** Added a dump hook to the instrumented 595.91.07 `kernel_gsp.c` at
`_kgspFreeLibosLoggingStructures` (before the buffers are unmapped). It writes
each `rmLibosLogMem[idx].pTaskLogBuffer` to `phase2b/gsplog/` and logs the put
counter. `phase2b/gsp_log_capture.sh` unloads the stock modules, loads only the
instrumented `nvidia.ko`, waits for both cards, issues a few RM queries, unloads
(firing the hook) and restores stock in a trap. The decoder then reads the raw
rings. No firmware was modified and no GPU register was written.

**Result.** Both cards produced **173 records with an identical (task, ID, argc)
sequence**, which independently confirms the ring framing and the ID table.

| Buffer | Records | Resolved | Base | Note |
|---|---:|---:|---:|---|
| RM (`task 3`) | 98 | 96 | `0x2018F000` | registry, inforom, SEC2/ACR, GR/FECS, display; 27 via raw fallback |
| INIT (`task 2`) | 42 | 41 | **`0x20183000`** | WPR/buffer layout |
| KERNEL (`task 1`) | 26 | 0 | unknown | IDs `0x2017c3c0`–`0x2017ccf0` not referenced in `.fwimage` |
| INTR (`task 4`) | 2 | 2 | `0x2018F000` | |
| ROOT (`task 8`) | 3 | 0 | `0x2018F000`? | IDs `0x2018fea0`/`0x2018fff0`/`0x2018ff30` not referenced |
| RMON (`task 9`) | 2 | 2 | `0x2018F000` | |
| MNOC / DEBUG | 0 | — | unknown | empty at capture time |

Total: 141/173 (81.5%) resolved.

**Findings.**

1. **The record layout is confirmed on hardware.** `[args...][meta][time]`, with
   the meta word second-to-last, decodes every buffer with no bad boundary. The
   earlier `[meta][args...]` draft would have misparsed every `N > 2` record.
2. **INIT uses a third writer, `FUN_ram_011849a6`, with base `0x20183000`.** The
   earlier assumption that INIT uses the `0x20178000` writer is wrong. This is
   why the first decode produced plausible but unresolved `0x2017cxxx` IDs.
   After the correction, 41 of 42 INIT records resolve.
3. **The RM base `0x2018F000` is confirmed.** 96 of 98 records resolve. The first
   decoder pass resolved only 69; the rest were call sites in regions Ghidra never
   analyzed. A raw `AUIPC+ADDI`/`LUI+ADDI` scan over the metadata ranges recovers
   33,044 extra IDs (58,736 distinct RM IDs vs 25,835 from decompiled call sites),
   with the enclosing function from a prologue scan and a `raw_function` flag.
4. **The KERNEL buffer is a separate metadata section.** Task-1 records use
   `0x2017c3c0`–`0x2017ccf0`; none of those VAs appears as a literal, a
   PC-relative target, or a pointer anywhere in `.fwimage`. The base cannot be
   recovered without `gsp_log_ga10x.bin`. The `0x20178000` writer's 41 IDs do not
   appear in this buffer.
5. **The trace is deterministic across cards.** The two GPUs agree
   record-for-record by task, ID and argument count.
6. **The RM timeline is usable without text.** Relative to the earliest captured
   record: registry at ~65 ms, inforom ~89–345 ms, SEC2/ACR ~365–385 ms, GR/FECS
   init ~435–484 ms, display ~462 ms and ~1723 ms. Module attribution is
   dominated by display (22), `community_4_vgpuAllocFecsTraceStagin` (13),
   inforom (8) and rm_core (7).

**Limitations.** RM and INIT message text, level and source line remain
unavailable: the metadata structs are in the missing ELF. Only 31 early-writer
IDs have a per-statement literal fallback and exact text; the INIT writer logs
unconditionally, so its text is not recoverable. The KERNEL section is the one
buffer whose base is still unknown.

**Artifacts.** `phase2b/gsp_log_capture.sh`; `phase2b/gsplog/` (16 rings,
`manifest.json`, `decode_gpu{0,1}.{txt,jsonl}`, `dmesg_loaded.txt`,
`dmesg_unload.txt`, `capture_*.log`); the hook in
`src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c`; decoder in
`gsp-analysis/logdecode/`.

#### E60 · Sentinel and raw-function analysis of the log trace

*2026-10-26 · status: static analysis of the E59 capture*

**Method.** Verified and decompiled the 17 raw-attributed functions in the E59
trace, and mapped the three producers of the `0xBADFxxxx` records. Read-only; no
GPU or driver access.

**Raw-function verification.**

- All 17 reported starts are genuine prologues; no attribution moved to a
  different function. Six extents were corrected where Ghidra's created body
  over-merged into the next function (e.g. `0x01bc6320` true span `0x11f0`,
  `0x0198c9cc` `0x1ee4`, `0x01931684` `0x81c`).
- All 70 captured raw-attributed records matched a real writer call site
  (`0x01b9e86e`, `0x011849a6` or `0x01179c62`) with the expected argument count.
- One decoder attribution was wrong: `0x01187eae` is an inner stack adjustment
  inside `FUN_ram_01187426` (`0x01187426`–`0x011898f1`), not a function. The
  table builder now maps it to `0x01187426`; 19 rows moved.

**The `0xBADF` records are PRI error telemetry, not feature probes.**

- `FUN_ram_016ea930` is a PRI ringmaster/ringstation global-write-error dumper.
  It reads `BAR0+0x120058`/`+0x12005c`, walks the per-station records at
  `0x122120+0x800*n`, and logs `[station, ADR, WRDAT, INFO, CODE]`. The captured
  `0x20471930` record `[0, 0x137200, 0, 0x14252215, 0xbadf5128]` is a **refused
  PL2 access at `0x137200`**: `0x14252215` decodes as SUBID 20, PRIV_LEVEL 2,
  SENDING_RS 18, PENDING 1, PRIV_MASTER 21; `0xbadf5128` is
  `NV_PPRIV_SYS_PRIV_ERROR_CODE`. The adjacent `0x20471918` record is
  `GBL_WRITE_ERROR_SYS = 1`.
- `FUN_ram_01230c00` logs `[direction, PRI_CODE, ADR, valid]`; the captured
  `[0x1d5e9d0, 0xbadf4100, 0x1100f4, 1]` is a refused access to GSP `HWCFG2`
  (`0x1100f4`), with PRI error `0xbadf4100`. (`0x1d5e9d0` is most likely the
  live address of the `"read"` string; live/static delta `0x18F000`, medium
  confidence.)
- `FUN_ram_016d80c8` is a generic GSP ucode event pump, not a register probe:
  events 14 and 3 each had one >1 ms dispatch (max 1.886 ms / 1.149 ms).

**Feature-mask functions found.** None reads the FEAT/FMLA32 path, but these are
the feature-related bodies in the trace:

| Function | Behaviour |
|---|---|
| `0x016ec3d0` | Sets bit `(index&0x1f)` in a 32-bit enable mask at `param_2+0x198`; live index 26 |
| `0x01976d44` | Logs/tests a 32-bit mask at `param_3+0x4c` (live `0xf`); bit 0 gates a handler |
| `0x01bc6320` | Unpacks a 38-bit GR/FECS feature bitmap at `0x042f5970` into flag bytes at `+0x48..+0x6f`, plus 16/32-bit tokens at `+0xa8..+0xe0`; reads 21 registry values |
| `0x015acb70` | `0xBADF0200` sentinel probe plus 3-bit feature mask `(+0x10f100)&0xe`; live log shows `0xBADF4100` |
| `0x0157107c`, `0x013fc2f4` | PCIe link-speed/status probing |
| `0x01931684`, `0x0198c9cc` | FWSECLIC/ECID/EDID and registry feature gating; GR error bit `0x400000` |

**Decode of `0x042f5970`.** The table is a 38-bit flag array
(`0x042f5970`–`0x042f5977`) followed by 16/32-bit tokens
(`0x042f5978`–`0x042f599c`). `FUN_ram_01bc6320` copies each bit to one byte at
object `+0x48..+0x6f`; the mapping is sequential except bit 1 → `+0x4e` and
bit 37 → `+0x6c`. In the static image, 23 of 38 flags are set: bits
2, 5, 7, 8, 9, 11, 14, 16, 17, 18, 19, 22, 24, 25, 26, 27, 28, 31, 32, 33, 35,
36, 37, i.e. `+0x49, +0x4c, +0x4f, +0x50, +0x51, +0x53, +0x56, +0x58, +0x59,
+0x5a, +0x5d, +0x60, +0x62, +0x63, +0x64, +0x65, +0x66, +0x69, +0x6a, +0x6b,
+0x6e, +0x6f, +0x6c`.

The tokens copied to `+0xa8..+0xe0` are `0x3b9e`, `0x0493`, `0x2cfb`, `0xd7e6`,
`0xabf8`, `0xfa1f4936`, `0x68a19441`, `0xd2f674a2`, `0x20d5`. The `+0xb4` token
(`0xfa1f4936` in the image) is compared in `FUN_ram_01216408` against `0x102e`;
on the static image that check fails, so either the token intentionally disables
that path on this configuration or the table is patched at boot. There is no host
read path to the GSP data segment, so the image values are the best available.

Known consumers: `+0x65` gates the register read/update in
`FUN_ram_012146f8`/`FUN_ram_012123a0` (FECS-side offsets `0x24c`/`0x27c`);
`+0x6a` is folded into a GPU-management message in `FUN_ram_01bf229c`;
`+0x6e` is a predicate in `FUN_ram_011fdfe0`; `+0x6f` is exposed by
`FUN_ram_0121326c`. None is a rate/selector field.

No `0x8238xx` FEAT register, `FUSE_SS_FMLA32`, `FEAT_READOUT_1` (`0x3818`/
`0x3814`), `SM_ISSUE_RATE_MODIFIER` (`0x504204`), per-SM loop or selector field
appears in any of them. The trace therefore adds no evidence about the rate
selector; it does show the GSP hitting PRI refusals at PL2 during boot, which is
consistent with the boundary but not a new lever.

**Correction to Appendix A.10.** `0xBADF51` is a generic PRI client/privilege
error family, not fuse-specific. `0xBADF510C` at the fuse block and
`0xBADF5128` at `0x137200` are instances with different low bytes. `0xBADF4100`
belongs to the `0xBADF41` PRI-decode family.

---

## Appendix E — Tooling and artifact index

Paths are relative to `/home/shutty/code/nvidia-unlock` unless absolute.

| Path | Contents |
|---|---|
| `gsp-analysis/` | GSP-RM decompilation: `input/gsp_fwimage.bin`, `out/gsp_decompiled.c`, `out/modules_v2/` (69 modules), `out/strings.csv`, Ghidra project `project/gsp_full`, scripts (`DecompileAt.java`, `DisasmRange.java`, `Refs.java`, `Blocks.java`, `refscan.py`); E66 DEVINIT/UCODE authentication strings at file `0xEEF4C0`+ |
| `gsp-analysis/logdecode/` | GSP log decoder: `build_id_table.py` + `id_table.csv` (63,612 rows: 30,568 decompiled + 33,044 raw), `build_init_strings.py` + `init_strings.csv` (31 exact texts), `gsp_log_decode.py`, `selftest.py`, `README.md`, `CAPTURE.md` |
| `phase2b/gsp_log_capture.sh`, `phase2b/gsplog/` | Instrumented-driver ring capture (E59): 16 raw rings, `manifest.json`, decoded `decode_gpu*.{txt,jsonl}`, dmesg, logs |
| `regops/` | `GPU_EXEC_REG_OPS` client (`dump`, `rep`, `wrr`, `bar`, `barw`, `ememstream`, `ratev2`, `throttle`, and E70/E71: `plmpoll`, `race`, `gprobe`, `gprobe_route`, `gr`, `gw`); helper scripts `gsp_probe.sh`, `gsp_emem*.sh`, `fuse_probe.sh`, `riscv_dm_probe.sh` (E63); result logs |
| `regops/results/riscv_dm_*.txt`, `regops/log.txt` | E63: GSP-side 4 KB PRISCV sweep and the host BAR0 map of the same window |
| `phase2b/` | Instrumented-driver harness and FEAT samplers: `bf16_ctxdump.patch`, `bf16_boot_instr.patch`, `dump_ctx.sh`, `parse_ctxdump.py`, `parse_ctxfiles.py`, `analyze_crosscard.py`, `analyze_ptes.py`, `analyze_srdump*.py`, `featbank_writer_probe.sh` (cold/warm/FLR sampler with the early-boot systemd units), `feat_preboot_flr.sh` (FLR + attach brackets), oracle scripts (`fmc_oracle.sh`, `wpr_oracle.sh`, `sr_oracle.sh`, `sr_resume_test.sh`, `sr_dump_test.sh`, `wpr_verified_patch_test.sh`, `regkey_rate_sweep.sh`, `feat_preboot.sh`, `cotkey/`), and the run directories `ctxdump_*`, `sr_*`, `wpr_*`, `regkey_*`, `featpreflr_*`; cross-boot CSV in `/var/log/featbank/`; `key37_factoradic.c` / `key37_cuda.cu` (16! MD5-IV permutation searches; AES-NI CPU 0.73 G/s, one 5090 10.5 G/s; both self-test against FIPS-197) and `fmc_key_test.py` (FMC first-block tester, ECB/CBC/CTR; §11.6) |
| `phase2b/plm_window_race.sh`, `phase2b/plmrace_*` | E70: FLR/unbind/rebind window measurement (`measure`) and the PL2 write race (`benign`, `payload`); direct BAR0 poller with GSP ENGINE/PC columns; run dirs `plmrace_20261028_225311_measure` (missed), `..._225505_measure`, `..._225752_measure` |
| `phase2b/build_riscv_logp.py`, `phase2b/riscv_logp_q.bin` | E73: 16-bit parcel log-probability table trained on the GSP-RM code segment (65536 int8 entries, half-bit units) plus calibration (Stage-1/Stage-2 recall and random tails) |
| `phase2b/riscv_oracle_selftest.py`, `phase2b/fmc_riscv_verify.py` | E73: end-to-end rank-0 synthetic control for `--fmc-riscv`; full-code RV32/64 IMC validator for oracle hits (invalid fraction, longest run, out-of-image branch targets) |
| `fmc-analysis/scripts/run_fmc_riscv_2gpu.sh` | E73: two-GPU 16! RISC-V-oracle runner (8.5 G keys/s/GPU three-hypothesis; 5.5 sustained with all five; 8-block Stage 2), merge + verifier; run dirs `fmc-analysis/out/fmc_riscv_c09{,_modes}/`, `..._c11_modes/` |
| `phase2b/gprobe_with_ctx.sh`, `phase2b/cuda_ctx.c`, `phase2b/cuda_ctx`, `phase2b/gprobe_*` | E71: `gprobe`/`gprobe_route` under a live CUDA context (plain-C CUDA 13 driver API keep-alive); run dirs `gprobe_20261028_230324_probe`, `..._230521_route` |
| `phase2b/bootbuf_dump.sh`, `phase2b/bootbuf/`, `phase2b/bootdump_*` | E72: pre-COT and post-boot dumps of `pGspRmBootUcodeImage` and the entropy/SHA comparison; run dir `bootdump_20261028_230658` |
| `phase2b/fb_capture.sh`, `phase2b/fbread/`, `phase2b/fbread_*`, `phase2b/fbcapture_*` | E74: instrumented-load harness (`BF16_FBREAD` + `BF16_WPRLAYOUT`); BAR1-at-boot oops run `fbcapture_20261028_233108`; BAR0-window runs `fbread_20261028_234642`, `..._235114`, `..._235405`; dumps `fb_*_gpu{0,1}_*.bin` |
| `phase2b/fbread_analyze.py`, `phase2b/fbread_20261029_002110/`, `phase2b/fbread/fb_heap_*` | E75: non-WPR heap dump (3 MiB per card) and its miner — pointer census, strings, FEAT constants and the E58 handler runtime VAs; report `heap_report.txt` |
| `phase2b/icd_*` | E67 ICD tools: `icd_cmd.c` (single command), `icd_rdm.c` (memory read), `icd_dump.c` (8-byte dump), `icd_halt_probe.c` (`STOP` + register/memory read); wrapper scripts `icd_rstat_probe.sh`, `icd_probe2.sh`, `icd_rdm_probe.sh`, `icd_scan.sh`, `icd_map_probe.sh`. E68 adds `icd_trace_run.sh` (read-only PC/state tracer), `icd_trace_analyze.py`, `icd_halt_run.sh` (targeted boot-window halt), `icd_fsp_probe2.sh` (full PFSP sweep), `icd_bootimg_probe.c` (post-boot boot-image probe); traces in `phase2b/icd_trace/`, halt sidecars in `phase2b/icd_boot/` |
| `phase2b/boot_tamper_run.sh` | E69 bootloader-image ciphertext tamper harness (`BF16_BOOT_TAMPER`); WprMeta oracle fields 8–16 in `wpr_oracle.sh` |
| `phase2b/cotkey/` | Self-signed COT key/signature generator (`gen_cot_key.py`), the P-384 key pair, and `bf16_cot_key.h` (E61) |
| `phase2b/fmc_buffer_probe.sh`, `phase2b/artifacts/`, `phase2b/fmcprobe_*` | FMC container buffer dump and one-byte tamper harness (E62): three sample points, modes 1–3, stock COT hash |
| `analysis-tmp/` | `hw_probe.c` (direct BAR0 reads/streams), `run_step*.sh`, `fsp_emem_*/`, `hwprobe_*/` |
| `sm120-probe/` | sm_120 issue-rate probe: `.cu`, `build_ptx.py`, `tensor_modes_driver_runner.py`, `run_modifier_test.sh`, cubin, `results/` |
| `vbios-analysis/` | `scripts/vbios_probe`, `vbios_read`, `prom_read_raw`, `parse_flash.py`, `bit_tokens.py`, `devinit_scan.py` (E66); `input/flash_*.bin`, `prom_full_*.bin`; `out/devinit_scan_*.txt` |
| `fmc-analysis/` | Extracted FMC containers, keys, signatures, `fmc_image.bin`, `bootloader.bin`, `scripts/key37_search*.py` |
| `bootpath/` | `gsp_bootpath_tests.sh`, run logs |
| `/home/shutty/open-gpu-kernel-modules/` at 595.91.07 | The instrumented source tree (E14/E54 edits) and the driver audit; the project-relative `open-gpu-kernel-modules/` path no longer exists |
| `src/nvidia/arch/nvalloc/unix/src/osapi.c` | registry forwarding (`rm_parse_option_string`, E50) |
| `src/nvidia/inc/kernel/diagnostics/tracer.h` | `RMTRACE_*` compiled out on Linux (E55) |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | GSP log buffers, `.fwlogging` decode (E55) |
| `src/common/inc/swref/published/nvswitch/ls10/dev_falcon_v4.h` | Falcon v4 PLM fields (E53) |
| `gpu-unlock-ada/`, `gpu-unlock/`, `rtx-p2p/` | Prior-generation and adjacent research trees |

Local-only artifacts include patched firmware images and GPU register dumps. Do not
redistribute NVIDIA firmware; keep extracted images local and preserve notices.

---

## Appendix F — Reproduction recipes

### F.1 Scan the GSP-RM for a register constant

```bash
cd /home/shutty/code/nvidia-unlock/gsp-analysis
python3 - <<'EOF'
import struct
d = open('input/gsp_fwimage.bin','rb').read()
for t in (0x00823804,0x00823818,0x0082381c,0x00823820,0x008207d8,0x00504204):
    n = d.count(struct.pack('<I', t)) + d.count(struct.pack('<Q', t))
    print(f"{t:#010x} {n}")
EOF
```

### F.2 Decompile a specific address

```bash
JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64 GHIDRA_HEADLESS_MAXMEM=16G \
  /home/shutty/code/nvidia-unlock/ghidra-tools/ghidra_12.2_PUBLIC/support/analyzeHeadless \
  project gsp_full -process gsp_fwimage.bin -noanalysis \
  -scriptPath scripts -postScript DecompileAt.java /tmp/out.c 0x1acd340 0 300
```

### F.3 Register read/write through the GSP

```bash
sudo ./regops 1 0000:41:00.0 one                 # benign PMC_BOOT_0 read
sudo ./regops 1 0000:41:00.0 read                # FEAT/FUSE block
sudo ./regops 1 0000:41:00.0 dump 823800 50      # map (counts are hex)
sudo ./regops 1 0000:41:00.0 wr 82381c 0         # write + readback
sudo ./regops 1 0000:41:00.0 sc                  # PBUS positive control
sudo ./regops 1 0000:41:00.0 wrr 82074c 0 1      # write/read/restore/read
sudo ./regops 1 0000:41:00.0 barw 8207d8 0 3     # same through BAR0
```

`deviceId 0` = `c1:00.0`; `deviceId 1` = `41:00.0`.

### F.4 COT oracle

```bash
cd /home/shutty/code/nvidia-unlock
phase2b/fmc_oracle.sh <field> [value]
# field 1: frtsVidmemSize     3: gspBootArgsSysmemOffset
# field 2: frtsVidmemOffset   4: gspFmcSysmemOffset
# field 5: hash384[0] ^= value
```

The script rebuilds incrementally, loads the instrumented modules with the
dump-free harness, captures dmesg, and restores the stock driver in its trap.

### F.5 `WprMeta` oracle

```bash
phase2b/wpr_oracle.sh <field> [value]
# 1 magic  2 revision  3 verified  4 fbSize  5 frtsSize  6 gspFwHeapSize  7 nonWprHeapSize
phase2b/wpr_verified_patch_test.sh      # patched GSP-RM + preset verified
```

### F.6 SR oracle and state dump

```bash
phase2b/sr_resume_test.sh                # stock cycle, ~8 s, no reboot
phase2b/sr_oracle.sh <field> [value]     # 1 magic, 3 size, 4 radix3 pointer
phase2b/sr_dump_test.sh                  # dump SRMeta + radix3 + state
# trigger (inside the scripts):
echo devices > /sys/power/pm_test
echo mem > /sys/power/state
```

A bad SR field hangs the resume with no host log. Add netconsole or phase markers
before running variants.

### F.7 Context-buffer dump

```bash
phase2b/dump_ctx.sh
# Env: BDF=0000:41:00.0, EXITMAX=2, GLOBALMAX=6,
#      BF16_CTXDUMP_MAIN_OFFSET=0x4000, BF16_CTXDUMP_BYTES=8192,
#      BF16_CTXDUMP_CREATE=0, BF16_CTXDUMP_DMESG=0, BF16_CTXDUMP_GLOBAL=1
python3 -I phase2b/parse_ctxfiles.py <run-dir>
python3 -I phase2b/analyze_crosscard.py <run-dir>
```

### F.8 Issue-rate probe

```bash
cd sm120-probe
python3 build_ptx.py
/usr/local/cuda-13.0/bin/ptxas -arch=sm_120 -O3 \
    -o tensor_modes_issue_sm120.cubin tensor_modes_issue_sm120.ptx
CUDA_VISIBLE_DEVICES=<UUID> python3 tensor_modes_driver_runner.py \
    tensor_modes_issue_sm120.cubin --sha256 <hash> --expect-uuid <UUID> \
    --expect-power-limit 575 --iters 20000 --reps 3
# add --bdf 0000:41:00.0 --reg-offset 0x504204 --reg-value 0 for the modifier test
```

### F.9 vBIOS dump

```bash
cd /home/shutty/code/nvidia-unlock/vbios-analysis
sudo ./scripts/vbios_probe 0000:41:00.0 300000 100000
sudo ./scripts/vbios_read  0000:41:00.0 input/flash_41.bin
sudo ./scripts/prom_read_raw 0000:41:00.0 input/prom_full_41.bin
# usage: prom_read_raw <bdf> <outfile> [off_hex] [size_hex]
# defaults: off 0x300000 (aperture base), size 0x200000 (whole aperture)
python3 -I scripts/parse_flash.py input/flash_41.bin
```

Read the flash through the known-good window only; do not page-scan the aperture
while the driver owns the GPU.

### F.10 Verify an FMC signature

```bash
openssl pkey  -pubin -inform DER -in pub.der -out pub.pem
openssl dgst -sha384 -verify pub.pem -signature sig.der container.bin
```

### F.11 Registry-key rate sweep

```bash
phase2b/regkey_rate_sweep.sh --dry-run                  # plan only
sudo phase2b/regkey_rate_sweep.sh --only speed88         # one variant
sudo phase2b/regkey_rate_sweep.sh --only speedboth       # Ada payload pair
sudo phase2b/regkey_rate_sweep.sh --only speed0 --bdf 0000:c1:00.0
```

One stock-driver reload per variant; the probe measures both cards and the FEAT bank
is read before and after. Every variant ends with a stock restore.

### F.12 Pre-FMC FEAT sampling

```bash
sudo phase2b/feat_preboot.sh
```

Builds the instrumented modules with `BF16_FEAT_PREBOOT=1`, samples
`0x823800`–`0x823824` before the COT is sent and again after GSP-RM is up, prints both
lines to dmesg, restores the stock driver, and resets the define to 0.

### F.13 FMC container buffer dump and tamper

```bash
sudo phase2b/fmc_buffer_probe.sh dump               # read-only, three sample points
sudo phase2b/fmc_buffer_probe.sh tamper 1           # ciphertext bit at 0x1048
sudo phase2b/fmc_buffer_probe.sh tamper 1 0x30048   # same, different body offset
sudo phase2b/fmc_buffer_probe.sh tamper 2 0x46300   # body-size field
sudo phase2b/fmc_buffer_probe.sh tamper 3           # header magic bit
```

The script sets `BF16_FMCDUMP`/`BF16_FMCTAMPER`, rebuilds 595.91.07, loads the
instrumented modules with `dump_ctx.sh --no-trigger`, and restores stock in its
trap. Artifacts land in `phase2b/artifacts/` and the run directory. A refused
tamper leaves WPR2 armed; reboot before the next run.

### F.14 RISC-V PRISCV sweep (GSP and host views)

```bash
sudo regops/riscv_dm_probe.sh                  # 0x110000..0x113fff, GSP master
sudo regops/riscv_dm_probe.sh 0x111000 0x111800  # PRISCV block only
BDF=0000:c1:00.0 DEVID=0 sudo regops/riscv_dm_probe.sh   # second card
for o in 111000 111100 111200 111300 111400 111500 111600 111700; do
  sudo regops/regops 1 0000:41:00.0 bar $o 40  # host view, 64 dwords per call
done
```

The GSP sweep is read-only (`READ_32` through `GPU_EXEC_REG_OPS`); the host calls
mmap `resource0` read-only. Neither writes a register. The raw sweep lands in
`regops/results/riscv_dm_*.txt`.

### F.15 FEAT bank across cold boots, warm reboots, and FLR

```bash
sudo phase2b/featbank_writer_probe.sh selftest
sudo phase2b/featbank_writer_probe.sh boot-install
# then: cold = power off/on; warm = sudo reboot; label each boot:
sudo phase2b/featbank_writer_probe.sh label warm     # or cold
sudo phase2b/featbank_writer_probe.sh boot-collect
sudo phase2b/featbank_writer_probe.sh boot-uninstall
sudo phase2b/featbank_writer_probe.sh flr 0000:41:00.0
```

The boot units sample before `systemd-udev-trigger` (pre-FMC, no driver), at
multi-user, 60 s later, and at shutdown; the CSV is `/var/log/featbank/samples.csv`.
`flr` is the only mutating step (sysfs reset plus unbind/bind); the stock DKMS driver
is untouched. See E64.

### F.16 FLR + pre-FMC/attach bracket

```bash
sudo phase2b/feat_preboot_flr.sh 0000:41:00.0
```

Builds 595.91.07 with `BF16_FEAT_PREBOOT`/`BF16_FEAT_NVPROBE`/`BF16_FEAT_RMINIT`,
loads the instrumented modules, unbinds/FLRs/rebinds the target, and prints the PLM
timeline and flip interval. The harness restores the stock modules in its trap. See
E65.

---

## Appendix G — GSP-RM decompilation notes

Lessons from the static passes, complementing `DECOMPILE.md`. The worked example is
the decoder hunt in E13 and E17.

### G.1 Setup and commands

- Input: `/lib/firmware/nvidia/595.91.07/gsp_ga10x.bin`, ELF64 RISC-V, **no program
  headers**, sections `.fwimage` (72,830,976 B at file offset `0x40`) and the
  per-chip `.fwsignature_*` blocks. Working copy: `gsp-analysis/input/gsp_fwimage.bin`.
- Ghidra 12.2 headless at `ghidra-tools/ghidra_12.2_PUBLIC`; project
  `gsp-analysis/project/gsp_full`, program `gsp_fwimage.bin`, loaded at base
  `0x01000000`.
- Helper scripts: `DecompileAt.java` (create a function and decompile, optionally
  follow callees), `DisasmRange.java` (N instructions from an address), `Refs.java`,
  `Blocks.java`.
- `-noanalysis` does not prevent a script from calling `disassemble()` or
  `createFunction()`, and headless **saves** the program afterwards, so later runs
  see the instructions you added. That is how previously unanalyzed regions were
  opened.

### G.2 Address model

- Ghidra `ram:0x01xxxxxx` is the address of the **file** loaded at base
  `0x01000000`; **file offset = address − `0x01000000`**. This is not the runtime
  address: the `.fwimage` has a `0x18F000`-byte wrapper and the loaded ELF64
  starts at file `0x18F000`, linked at `0x01000000`, so
  `link VA = Ghidra VA − 0x18F000` and `file offset = link VA − 0x00E71000`
  (E67).
- The loaded ELF occupies core address `0x01000000` and runs at runtime VA
  `link + 0x92000000`; the ICD `RPC` reports the runtime VA (`0x93002ebc`), not
  the GSP-side `0x01404f66` (E67). Host FB PA `0x01000000` is empty, so the
  backing is in the WPR (E74).
- Confirm the base; do not assume it. Three independent checks: a known string
  (`LidCloseDisplayMask` at `0x01ef76e0` → file `0xef76e0`), a ctrl-table handler
  pointer (`0x1400740` → file `0x400740`), and the field-reported crash PC
  (`0x1368618`).
- A symbol that looks "unreferenced" may sit in a region the analyzer never
  disassembled. Before concluding dead code, disassemble from a known instruction
  boundary and run the raw byte scans (G.4).

### G.3 Ghidra's blind spots

- Auto-analysis did not create functions across large stretches (for example
  `0x1acd000`–`0x1ad25000` and `0x1c1c000`–`0x1c1e6xx`).
- Code reachable only through a function-pointer table has no inbound `jal`, so it
  is never discovered.
- The reference manager only knows references from code it has disassembled.
  **Zero references is not evidence of dead code** — that was the E13 error.
- In dump headers, `size` and `callers` are unreliable; use them for navigation only.
- `DecompileAt` will create a "function" mid-function and produce a plausible but
  wrong body. Find the prologue first: `c.addi16sp sp,-N` followed by `c.sdsp` saves
  (or `addi sp,sp,-N` / `sd ra,...` for non-compressed frames).

### G.4 Reference hunting belongs on raw bytes

- Scan every **2-byte** offset (RVC code can start at any 2-byte boundary) and test
  four encodings: `JAL`; `AUIPC+ADDI`; `AUIPC+JALR`; `LUI+ADDI`. Add u32/u64 literal
  and PC-/base-relative table forms.
- Decode the `auipc` U-immediate correctly: `imm = sign_extend_32(word & 0xfffff000)`.
  The E13 false negative came from treating `0xff9e3` as unsigned, so
  `auipc a4,0xff9e3; addi a4,a4,0x640` was never recognized as
  `pc − 0x61d000 + 0x640`.
- `lui` is used for absolute constants (`lui a4,0x4b2; addi a4,a4,-0x7fe`); a scan
  that only handles `auipc` misses them.
- Indirect calls through a struct-of-function-pointers slot usually compile as
  `c.lui r,1; c.add r,obj; ld f,-OFF(r); jalr f` — a **negative load from
  `obj+0x1000`**, not `ld f,0xC20(obj)`. Search that idiom when a slot call seems
  absent.
- An `auipc` scan over 72 MB yields ~630k candidates; filter by a plausible function
  start and by the follow-up (`sd` for a table store, `jalr` for a call). Random data
  produces many `auipc` opcodes but few coherent targets.

### G.5 RISC-V compressed instructions

- Instructions are 2-byte aligned. Walking in fixed 4-byte steps desynchronizes at
  the first `c.*` instruction; the symptom is a run of `.word 0x...` and invalid
  `c.*`.
- Walk by the low two bits: `(h & 3) != 3` → 16-bit, advance 2; otherwise 32-bit,
  advance 4.
- Useful encodings: `c.jalr rs1 = 0x9002 | rs1<<7`, `c.jr rs1 = 0x8002 | rs1<<7`
  (mask with `0xF07F` to clear `rs1`); `c.add` is quadrant 2, funct3=4, bit12=1 with
  `rs2 ≠ 0`; `c.lui` is quadrant 1, funct3=3 with `rd ≠ 0,2`.
- When resuming mid-stream, start from an address Ghidra already disassembled or
  from a prologue; alignment cannot be recovered from arbitrary bytes reliably.

### G.6 Reading NVIDIA's HAL tables

- Object constructors zero the object and install a table with a regular
  `auipc/addi/sd` sequence:

```c
memset(obj, 0, 0x3E40);
*(void **)(obj + 0xB78) = ...;
...
*(void **)(obj + 0xC20) = FUN_ram_015ffae8;   /* auipc + addi + sd */
```

- The initializer signature is `(obj, desc)`; `desc+0x10` packs family (`>> 5`) and
  variant (`& 0x1f`), and branch conditions are bitmask tests over variant IDs
  (`0x3e0 >> v & 1`, `0xbe08f400 >> v & 1`, `0x98000000 >> v & 1`).
- Slots can be bound to different implementations per chip; unimplemented entries
  are `ebreak` stubs. Do not read a stub as the real method.
- **Slot offsets are not class-unique.** Many unrelated objects have a method at
  `+0xC20`; identify the class by the initializer that writes the table and by its
  sibling slots, never by the offset alone.
- The ctrl method table is 32-byte records
  `{u32 ctrlId, u32 paramSize, u64 classPtr, u64 handlerPtr, u64 flags}`. Handler
  pointers frequently land 2 bytes before the first instruction, and decompiling
  them yields unreliable bodies.

### G.7 Strings versus message IDs

- `FUN_ram_01b9e86e(n, ...)` is the log/assert primitive, and `n` is the **operand
  count**, not a level (E57). It writes `N = n + 1` u64 entries — `[args...][meta]
  [time]`, with the meta word second-to-last — where the meta word packs the
  metadata VA (bits 47:0, relative to a per-task base), `N` (55:48) and the task ID
  (63:56). The last vararg is the metadata struct pointer, not a string. RM
  metadata IDs lie in `0x20300000`–`0x205217b8`, outside the image's load range;
  the level and format strings live only in the missing `gsp_log_ga10x.bin`. Do not
  read an unmapped constant as a corrupted string pointer.
- The early writer `FUN_ram_01179c62(n, ...)` is the same format with base
  `0x20178000`. Its sites sit next to a literal-printf fallback
  `FUN_ram_01179be4(format, file, line, ...)`, which lets the decoder recover exact
  text for 31 IDs. Its task assignment is unconfirmed: the captured task-1 buffer
  does not use these IDs.
- The INIT writer `FUN_ram_011849a6(n, ...)` uses base `0x20183000`; its long
  sequences of ring calls have no per-statement fallback. The captured task-1
  KERNEL buffer uses a fourth, unreferenced metadata section whose base is unknown
  (E59).
- Registry-key strings are in `out/strings.csv` with their image addresses; those
  can be xref'd normally.
- `0xBADFxxxx` values are not arbitrary magic. Bits `[31:8]` are the PRI-ringstation
  error code: `0xBADF11xx` decode failure, `0xBADF50xx` client error, `0xBADF57xx`
  refusal. Decode the code before recording a read as "unimplemented".

### G.8 Checklist

1. Extract `.fwimage`; keep the ELF for section offsets.
2. Confirm the base with a known string and a known handler pointer.
3. Scan raw bytes for references with correct sign extension and RVC handling.
4. Disassemble each hit from a known boundary, then decompile the enclosing function.
5. Cross-check with the ctrl table (IDs, parameter sizes) and host-side behavior.
6. Treat decompiled C as a hypothesis; the instruction bytes are the evidence.

---

## Appendix H — Revision history

Revision history: what each pass added, in order. The records in Appendix D carry
the same revision label.

| Rev | Date | Delta | Record |
|---:|---|---|---|
| 2 | 2026-10-25 | Static audit: registry keys dead; GSP-RM is PL2; only PL3 code can write FEAT | E01 |
| 2b | 2026-10-25 | PL3 component inventory: FMC is the only corpus worth attacking | E02 |
| 3 | 2026-10-25 | Availability study: FSP/BootROM unobtainable; vBIOS is the obtainable corpus | E03 |
| 4 | 2026-10-25 | vBIOS dumped at BAR0+`0x338000`; µcode encrypted; no FWSEC; no rate constants | E04 |
| 5 | 2026-10-25 | FMC container dissected; P-384 signatures verify; debug signing key ships | E05 |
| 6 | 2026-10-25 | GA100 test-key route ruled out for GB202 | E06 |
| 7 | 2026-10-25 | `GPU_EXEC_REG_OPS` first run invalidated by a pre-existing GSP crash | E07 |
| 8 | 2026-10-25 | `SS0` write accepted and silently dropped → PL2 boundary measured | E08 |
| 9 | 2026-10-25 | FEAT bank mapped; whole bank PLM-gated | E09 |
| 10 | 2026-10-25 | HS memory-read route closed; EMEM empty; self-access model | E10 |
| 11 | 2026-10-25 | Host→HS input surface live; GSPFMC bootstrap deadlocked; patched driver adopted | E11 |
| 12 | 2026-10-25 | FUSE shadow not writable; `SM_ISSUE_RATE_MODIFIER` inert | E12 |
| 13 | 2026-10-25 | Computed FEAT decoder found; control table has no hidden setter | E13 |
| 13b | 2026-10-25 | Host instrumentation: selectors arrive from the GSP | E14 |
| 13c | 2026-10-25 | Patched GSP-RM rejected (`0xaff`) | E15 |
| 14 | 2026-10-25 | Host driver is telemetry; GB202 HAL is vGPU-only | E16 |
| 15 | 2026-10-25 | Decoder is a table-installed HAL method; reference audit corrected | E17 |
| 16 | 2026-10-25 | Live FECS/FSP/SEC2 probes; `0x409800` doorbell writable | E18 |
| 17 | 2026-10-25 | FECS command protocol mapped | E19 |
| 18 | 2026-10-26 | FECS context path is a buffer loader; host builds descriptors | E20 |
| 19 | 2026-10-26 | FSP core EMEM is L3-gated | E21 |
| 20 | 2026-10-26 | First context dump; GPU1 WPR2-up | E22 |
| 21 | 2026-10-26 | Post-use patch buffer: 10 address values change | E23 |
| 22 | 2026-10-26 | Main window at `0x4000` is zero | E24 |
| 23 | 2026-10-26 | Global dump lost to the ring; switched to file dumps | E25 |
| 24 | 2026-10-26 | Full context image; `0x88888888` is a fill | E26 |
| 25 | 2026-10-26 | Consolidation (no new results) | — |
| 26 | 2026-10-26 | Cross-card context diff: 618/908,288 words; route closed | E27 |
| 27 | 2026-10-26 | Boot-input baseline; COT uses production FMC `c04` | E28 |
| 28 | 2026-10-26 | FRTS size refused (`0xd9`); event-lifetime driver bug | E29 |
| 29 | 2026-10-26 | Size control boots; larger size refused; exact 1 MB | E30 |
| 30 | 2026-10-26 | FRTS base movable | E31 |
| 31 | 2026-10-26 | Misaligned base refused (`0xd6`) | E32 |
| 32 | 2026-10-26 | Offset is from FB end; readback units corrected | E33 |
| 33 | 2026-10-26 | COT offset positions the whole GSP-RM WPR | E34 |
| 34 | 2026-10-26 | Placement window reaches 1 GiB | E35 |
| 35 | 2026-10-26 | `WprMeta.magic` enforced (`0x827`); `verified` accepted | E36 |
| 36 | 2026-10-26 | `WprMeta.frtsSize`/COT disagreement is inert | E37 |
| 37 | 2026-10-26 | `gspFwHeapSize` honoured downward | E38 |
| 38 | 2026-10-26 | 16 MiB heap wedges the boot | E39 |
| 39 | 2026-10-26 | `verified` does not bypass image verification | E40 |
| 40 | 2026-10-26 | COT hash authenticated (`0x377`); auth failure wedges | E41 |
| 41 | 2026-10-26 | SR-resume path live and host-driven | E42 |
| 42 | 2026-10-26 | Bad SRMeta magic hangs; no host log | E43 |
| 43 | 2026-10-26 | Critical reassessment; route ranking | E44 |
| 44 | 2026-10-26 | SR state image encrypted | E45 |
| 45 | 2026-10-26 | Radix3 plaintext; state per-boot, per-card | E46 |
| 46 | 2026-10-26 | Full vBIOS aperture: encrypted head, sentinel tail | E47 |
| 47 | 2026-10-26 | BAR1 FB read inconclusive and hazardous | E48 |
| 48 | 2026-10-26 | Two-card probe: `SS0`/`SS1` differences are not rate | E49 |
| 49 | 2026-10-26 | Registry speed-select keys are live code paths (retraction) | E50 |
| 50 | 2026-10-26 | Key sweep on both cards: no rate effect | E51 |
| 51 | 2026-10-26 | p2p SKU gate is display-only; no compute entry | E52 |
| 52 | 2026-10-26 | PLM field decode; the bit-10 mystery is resolved | E53 |
| 53 | 2026-10-26 | FEAT bank is final before the FMC; writer is pre-driver | E54 |
| 54 | 2026-10-26 | Tracing-facility audit; no per-launch firmware trace | E55 |
| 55 | 2026-10-26 | External cross-part corpus: `0x82380c` = ECC, FEAT block names, A100 full-rate reference | E56 |
| 56 | 2026-10-26 | GSP log writer semantics corrected; ID→call-site decode without `gsp_log_ga10x.bin` | E57 |
| 57 | 2026-10-26 | Static pass: `SS0`/`SS1` write method found but unproven; EA8 consumer resolved; no `0x504204` writer; FSP surface enumerated | E58 |
| 58 | 2026-10-26 | Follow-ups: GB202 variant resolved (`0x02` → `0x3818`); `SS0`/`SS1` method attempts MMIO but is unreachable/PLM-blocked | E58 |
| 59 | 2026-10-26 | GSP log decoder implemented; record layout corrected (meta is second-to-last); 31 exact early-writer texts recovered | E57 |
| 60 | 2026-10-26 | Live capture on both cards: layout confirmed; INIT base `0x20183000`; 173 identical records/card; raw fallback resolves 141/173; KERNEL section unresolved | E59 |
| 61 | 2026-10-26 | Sentinel records are PRI error telemetry, not rate probes; 17 raw log functions verified; A.10 `0xBADF51` correction | E60 |
| 62 | 2026-10-27 | COT key substitution refused (`0x1db`): key anchor enforced; GSP-RM image carries no host key; resume reuses the cold-boot image | E61 |
| 63 | 2026-10-27 | FMC container read back unchanged at three points; one-byte header/body tamper refused with `0x33`; image bound to the COT hash | E62 |
| 64 | 2026-10-27 | PRISCV block at `0x111000`; two-sided host/GSP map; host-facing ICD never commanded; no DM in `0x111800–0x113fff`; RPC is GSP-only | E63 |
| 65 | 2026-10-28 | FEAT bank across cold/warm boots and FLR: SS words are power-cycle-tied and enable-clear; FLR resets the PLM to `0x80842bcf` | E64 |
| 66 | 2026-10-28 | Attach brackets: the PLM is re-locked autonomously by GPU-side devinit before the first open; PMU devinit is the leading candidate; FMC/GSP-RM excluded | E65 |
| 67 | 2026-10-28 | vBIOS devinit-table scan: no FEAT address in any plaintext table/script; four real ucode images (`0x07`/`0x19`/`0x15`/`0x23`), two placeholders; PLM values only in app `0x23`/tgt `0x0E` data; DEVINIT tables/scripts HS-authenticated (AES-ECB); table route closed | E66 |
| 68 | 2026-10-28 | FSP/FMC crypto assessment: FMC encrypted, mode unknown (no ECB repeats/nonce, entropy 7.999); test key #37 route proven for GA100/GA102/AD102 booters (AES-128-ECB, MD5-IV permutation, public KAT, private key); 16! search feasible (~1–3 h on two 5090s); production `csecret(6)` is DFA-only; debug FMC is the target | §11.6 |
| 69 | 2026-10-28 | Full 16! MD5-IV permutation search (zero KAT) on two 5090s: 20,922,789,888,000 candidates, ~530 s per half, ~19.7 G keys/s each, **no match**; the key is not a plain IV permutation under the zero KAT. Next: FF KAT, index-37, round-key reversal, FMC first-block | §11.6 |
| 70 | 2026-10-28 | FF-KAT and last-round-key-transform 16! passes on two 5090s: **no match** (20.3 / 14.2 G keys/s per 5090; 515 s / 735 s per half). The debug key is not a plain MD5-IV permutation under zero or FF, nor the last round key of the IV schedule. Next: actual key source, FMC first-block oracle, index-37 | §11.6 |
| 71 | 2026-10-28 | Key-source check: gist has no comments/key; TOTORONG fixtures/assets/unlock source contain only a PCI config and SHA-256 hashes; the Ada key is private. The "published debug key" is not public as bytes. The three negative 16! derivations stand; further blind permutation searches are speculative | §11.6 |
| 72 | 2026-10-28 | Enumeration bug found and fixed: `unrank` decoded colexicographic digits while `next_perm` is lexicographic, so shards overlapped and the 16! passes (zero, FF, round-key, FMC oracle) were **not exhaustive**. Corrected to `idx = rank/(15−i)!` in both tools; revisions 69–71 are **invalid** pending a re-run. Added boundary + 20k random chain tests, 64-shard tiling, 4,096-thread partition-window digest, and hit-writer dedup/duplicate counting | §11.6 |
| 73 | 2026-10-28 | Inverse T-tables Td0–Td3 + equivalent inverse key schedule (U tables) in the FMC oracle: **4.66–4.72 G/s vs 2.47–2.50 G/s byte-wise, 1.89×**, hit sets identical; rolling backward schedule 3.28 G/s and launch-bounds 4.24 G/s were slower. Two-GPU 16! FMC pass now ~37 min. Selftests: FIPS inverse, byte/Td agreement, combined-routine cross-check | §11.6 |
| 74 | 2026-10-28 | Bank-replicated oracle (RF=16): T0/Td0 as `[256][16]`, lane reads its own column, T1–3/Td1–3 by rotates, loops unrolled, `__maxnreg__(128)`; **11.69 vs 10.35 G/s (+13%)**, hit sets identical over 5×10⁹. Microbench: sm_120 has 100 KB shared/SM, 48 KB static/block; random→RF32 LUT +21%, RF16 captures it; oracle and zero-KAT both at ~5.4×10¹² shared loads/s (LSU ceiling). Short `--bench S` mode added (GPU 0). Literature: bitslicing only 2.6–9% over best table-based; U-load removal via ALU is slower | §11.6 |
| 75 | 2026-10-28 | Corrected, exhaustive 16! FMC oracle pass on `c09` (both 5090s, disjoint halves, 1,031.1 s + 1,023.3 s, **10.15/10.22 G keys/s sustained**): 6,115 candidate hits (`3119+2996`), all unique, zero duplicates (proves the fixed enumeration covers 16! once); full-body validation `tested=9136 valid=0`. Under AES-128, MD5-IV-permutation keys, ECB/CBC-zero or CTR-zero first block, the debug FMC key is not in this family. Supersedes 69–71. Artifacts in `fmc-analysis/out/fmc_run_rf16_c09_2gpu/`; runner `fmc-analysis/scripts/run_fmc_rf16_c09_2gpu.sh`. Next: `c11` container, header-derived CBC IV, non-zero CTR counter, corrected booter KAT passes | §11.6 |
| 76 | 2026-10-28 | Corrected zero-KAT 16! on both GPUs (442.5 s / 440.2 s, 23.64/23.77 G keys/s): **no match** — key #37 is not a plain MD5-IV permutation under the zero control (first valid run of this test). Corrected c11 oracle 16! (both modes, RF=16): 6,145 unique hits, 0 duplicates, full-body `tested=9190 valid=0`. Neither debug FMC opens under ECB/CBC-zero/CTR-zero. Remaining: FF control, round-key transforms (last-round-key pass not validly re-run), FMC mode variants. Artifacts `fmc-analysis/out/kat_then_c11_2gpu/` | §11.6 |
| 77 | 2026-10-28 | Corrected FF-KAT 16! (443.2 s / 440.9 s, 23.60/23.73 G keys/s) and last-round-key transform 16! (555.4 s / 553.3 s, 18.84/18.91 G keys/s): **both no match**. With rev 76's zero-KAT, all three published variants of the MD5-IV-permutation family are validly exhausted and negative; the test-key #37 claim does not reproduce on GB202. Remaining options are speculative: round keys 1–9 (~1.9 h), FMC mode variants with guessed IV/counter (no nonce in either header), or the family does not apply. Artifacts `fmc-analysis/out/ff_then_rk_2gpu/` | §11.6 |
| 78 | 2026-10-28 | Consolidation: variant algebra — the IV pool is eight `{x, x^0x11}` pairs, so nibble swap, XOR `0x11`/`0x22`/`0x33`/`0xFF` and position rotations enumerate the same 16! set and need no passes; container header analysis — `c09`/`c11` headers are magic + size fields + 16 zero bytes, no IV/nonce field, leaving only the IV/counter-prefix and CTR counter=1 variants; ranked avenues and §11.7 verdict updated to the exhausted-family state; stale "re-run pending" text corrected; consolidated table of all five corrected 16! passes (zero, FF, round-key, c09, c11) | §11.6, §11.7 |
| 79 | 2026-10-28 | PRISCV ICD live: host-writable at PL0 (`ADDR0/1`/`CMD`), commands execute; `RREG`/`RCSR`/`RDM` rejected while running (`CMD[14]=1`, `0xbadfbadf`) and succeed after `STOP`; `RDM` reads the 14.4 MB halted RM code segment (`0x01000000`–`0x01DCD000`); driver's `kflcnCoreDumpDestructive_IMPL` uses the same interface (CSRs + unwind, Xid 154). Address model corrected: ELF at file `0x18F000`, link `0x01000000`, PA identity, runtime `+0x92000000`; host `0x1113ec` is the true PC (corrects E63) | E67 |
| 80 | 2026-10-28 | ICD boot-window measured: the read-only trace shows `CMD`/PC blocked (`0xbadf5620`) through the HS phase, unblocking at ~155 ms while the boot image (`0xefd0xxxx`, `0x47000` = `GspRmBoot`) executes; GSP-RM starts ~0.5 ms later. Targeted `STOP` at the unblock and at the LS transition halts the core (`CPUCTL=0x380`) and `RPC`/`RREG` work, but every `RDM` is refused, including the `0x01000000` control. The post-boot RDM aperture is the RM code segment only. The FSP has no ICD at either PRISCV placement (full 16 KB sweep), GSP-RM has no ICD-unlock write, and the GspRmBoot images have no prod/debug keystream reuse | E68 |
| 81 | 2026-10-28 | `WprMeta` bootloader/signature oracle: `sizeOfBootloader` checked (`0x82e`), `bootloaderManifestOffset` used (`0x885`), code/data offsets unused, `sizeOfSignature` ignored, `sizeOfRadix3Elf` bound into authentication (`0xaff`/`0xb`); a one-byte ciphertext flip in the GspRmBoot image is refused (`0xaff`/`0xb`) while the untampered card boots. Ten FMC/FSP codes now mapped | E69 |
| 82 | 2026-10-28 | Post-FLR L2 window measured: `0x80842bcf` for 1156–1323 ms, re-lock 1853 ms before the first GSP-RM PC (3176 ms); the open→GSP-RM path is ~2.1 s, so an early open cannot fit the window. The "boot the GSP early" variant is retracted | E70 |
| 83 | 2026-10-28 | `GR_CTX`/`GR_CTX_TPC`/`GR_CTX_SM`/`GR_CTX_QUAD` regtypes return `0x1f` with root, a live CUDA context and every `grRouteInfo` route; `FB` returns `0x56`. The per-context/SM space needs an RM channel owned by the caller; the cheap PL0 route is closed | E71 |
| 84 | 2026-10-28 | `GspRmBoot` host buffer is byte-identical pre-COT and post-boot (290,816 B, SHA-256 `f5f63a71…`, entropy 7.9835, both cards): the FMC does not decrypt in place | E72 |
| 85 | 2026-10-28 | FMC body layout measured: `[code][data][manifest 0xA00]`; data and manifest byte-identical to the GspRmBoot image's, code a prefix of its code, in both the prod and debug pairs — component-wise deterministic and code-first. The old magic-filter FMC oracle would discard a correct key. Built the RISC-V parcel-model oracle (`--fmc-riscv`; 64 KB table, Stage 1 one block at `t1=-256`, Stage 2 eight blocks at `t2=-2102`, modes ECB/CBC-zero/CTR-zero, **8.5 G keys/s/GPU**), end-to-end rank-0 synthetic controls in all three modes plus random rejection, a full-code RISC-V verifier (0.05% vs 8.8% invalid), and the two-GPU runner. Exact-DP staged false-positive rate `1.2e-14` per hypothesis. All 12,260 legacy c09/c11 hits re-score as random (medians -297 Q; 7 above `t1` by chance). Full 16! re-run pending | E73, §11.6 |
| 86 | 2026-10-28 | Host FB read measured and closed. BAR1 is bound to a VAS and the VAS does not exist during the GSP boot (`kbusInitBar1` runs in `gpuStateLoad`, after `kgspInitRm`); constructing a mapping at WprMeta-populate time oopses on a NULL PTE array. The BAR0 PRAMIN window (64 KiB at BAR0 `0x700000`) is the working host FB path: the non-WPR heap control reads 58,707 nonzero bytes, entropy 7.6408, identically on both cards. Through it, PA `0x01000000`, `0x5dd00000` and `0x181d0000` are zero, and `[frts − 0x50000, frts)` plus FRTS return the uniform access-denied fill `0xbad0ac00` (entropy exactly 2.0, nonzero exactly 3/4, both cards). The decrypted boot image is inside the WPR and host-inaccessible | E74 |
| 87 | 2026-10-29 | Non-WPR heap mining (E74's instrument): the 3 MiB GSP-RM non-WPR heap is byte-identical on both cards and holds a 64 KiB structured header, one 0x1910A2-byte high-entropy allocation (entropy 7.999), and zeros. No vtable pointer sets, no known handler VAs, no identifiers. The WPR sentinel starts exactly at `nonWprHeapOffset + 0x300000` = `0x7e75e0000`. The live RM objects are in the WPR heap; a host FB read cannot expose #10–#12 | E75 |
| 88 | 2026-10-29 | c09 16! RISC-V-oracle pass complete on both 5090s: 1375 s wall, 7.61 G keys/s per card, both rc 0, **0 hits** (expected chance records ~1.5; P(0)=0.22). Under ECB, per-component CBC-zero and CTR-zero the debug GB202 FMC is not decrypted by any MD5-IV permutation. First valid FMC negative (no magic filter). Artifacts in `fmc-analysis/out/fmc_riscv_c09/` | E73, §11.6 |
| 89 | 2026-10-29 | Mode-completeness extension and final FMC key result: five hypotheses (ECB, CBC-zero, CBC with the container-header IV, CTR start 0, CTR start 1) at 6.0 G keys/s/GPU bench (~5.50 sustained); CBC IV affects only block 0, so a true CBC key can hit both CBC modes as an expected pair, and CTR start 1 costs one extra encrypt. All five synthetic rank-0 controls pass. Combined c09→c11 five-hypothesis 16! runs: c09 1902 s, c11 1907 s, both rc 0, **both negative**; 3 chance records total (c09 mode 4; c11 mode 0 and mode 4), all verifier-rejected at 8.6–8.9% invalid. The IV-permutation avenue is exhausted for both debug FMCs under the tested modes | E73, §11.6 |

**Retracted claims, by revision:**

| Claim | Made in | Withdrawn / corrected by |
|---|---|---|
| `FUN_ram_015ffae8` is statically unreferenced | 13 (E13) | 15 (E17): negative `auipc` immediate mishandled |
| `0x9668` maps to absolute `0x409668` | 15 (E17) | 16 (E18): address unimplemented; translation unproven |
| The FMC is only on the confidential-compute path | 2b–14 | 27 (E28): ordinary path, production-signed |
| `frtsVidmemOffset` is an absolute FB address | 30–31 | 32 (E33): it is an offset from the FB end |
| `0x88888888` in the context image is the Ada payload | 24 (E26) | 24/26 (E26/E27): a static fill |
| The two cards' differing `SS0`/`SS1` may select different rates | 10 (E10) | 48 (E49): identical per clock |
| `RMOverrideSmSpeedSelect*` are dead and not forwarded | 2 (E01) | 49 (E50): forwarding is generic; both strings are referenced and parsed |
| PLM bits `[23:8]` are source enables; bit 10 names a removed source | 2/9 (E01/E09) | 52 (E53): the source-enable field is `[31:12]`, all set; bit 10 is `SOURCE_READ_CONTROL` |
| `SS0`/`SS1` are firmware writes | 2 (E01) | 53 (E54): already final before the FMC runs; the writer is pre-driver, and is a GPU-side devinit (E64/E65) |
| `0x82380c = 0x00888888` is a per-class speed override | 9 (E09) | 55 (E56): it is `FEAT_OVR_ECC`, the stock consumer ECC override |
| The FSP trusts the host-supplied COT hash without binding it to the image bytes | 57 (E58) | 63 (E62): a one-byte header or body change is refused with `0x33` |
| The GSP register block spans `0x110000`–`0x11172c` as one Falcon block | 10 (E10) | 64 (E63): Falcon ends at `0x110d4c`; PRISCV starts at `0x111004` and is partitioned per master |
| The PMU runs at LS/PL2, so the PL3-only PLM blocks its writes | 46 (E47/§11.1) | 66 (E65): the reset PLM is `0x80842bcf` (L2+L3); the PMU is the leading pre-lock writer |
| The Ada persistence model applies to GB202: the FEAT override stays open across FLR | §14.3 (assumption) | 65/66 (E64/E65): an FLR resets the PLM; GPU-side devinit re-locks it before the first open |
| The vBIOS ucode table has six populated entries | 4 (E04) | 67 (E66): four real (`0x07`, `0x19`, `0x15`, `0x23`); `0x18` and `0x24` point at `0xBADF1100` and are placeholders |
| The PMU devinit's FEAT writes might be table-driven and reachable by a custom vBIOS | 66 (E65) | 67 (E66): no plaintext table references the FEAT block; the DEVINIT tables/scripts are HS-authenticated; table route closed |
| The FMC's debug key "does not help" (the GA100 key37 route does not apply) | 6 (E06) | 68 (§11.6): key37 is proven for the SEC2 booter on GA102/AD102, not the GB202 FMC; the GB202 FMC's mode/key is unknown, and an FMC in CBC/CTR/XTS or compressed-then-ECB would not show the ECB KAT. The GA100 KAT still does not appear in the GB202 FMC. |
| The 16! permutation passes were exhaustive, and the zero/FF/round-key/FMC "no match" results are final | 69–71 (§11.6) | 72 (§11.6): `unrank` used colexicographic digits against a lexicographic `next_perm`, so shards overlapped and did not cover 16!; the results are invalid and must be re-run with the corrected enumeration |
| The host-facing ICD is present but has never been commanded, so it may be PLM-gated | 64 (E63) | 79 (E67): live and host-writable at PL0; commands execute; `STOP` + `RDM` reads the 14.4 MB RM code segment |
| The GSP master's `0x1113ec` is the core's live PC; the host's `0x1113ec` is not a PC | 64 (E63) | 79 (E67): the host's `0x1113ec`/ICD `RPC` is the halted PC (`0x93002ebc`); the GSP-side `0x01404f66` is a different register |
| `Ghidra ram:0x01xxxxxx` is a runtime address | Appendix G.2 | 79 (E67): it is the *file* address (base `0x01000000`). The loaded ELF starts at file `0x18F000` and is linked at `0x01000000`, so `link VA = Ghidra VA − 0x18F000` and runtime VA = link + `0x92000000`. The file-offset formula itself was correct. |
| The ICD can be halted during the FMC window and `RDM` can read the decrypted boot image | 79 (E67, §17.3) | 80 (E68): the ICD is blocked through HS; `RDM` is refused at the unblock and at the LS transition, and after boot its aperture is the RM code segment only |
| `RDM` is a general halted-core memory reader | 79 (E67) | 80 (E68): the post-boot aperture is the RM code segment; the data segment, boot image and WPR are refused |
| The host-filled `WprMeta` bootloader offsets and lengths reach a pre-authentication copy | hypothesis (§16.2 #4 shape) | 81 (E69): the size and manifest offset are checked, the code/data offsets are unused, and both boot images are authenticated |
| The host can boot the GSP-RM inside the post-FLR L2 window and write `SS0`/`SS1` from PL2 | E65 implication (§2.6) | 82 (E70): the window is 1.32 s and the first GSP-RM PC is at 3.18 s; the open→GSP path is ~2.1 s, so even a zero-delay open misses it |
| `GPU_EXEC_REG_OPS` reaches the per-context/per-SM register space via `GR_CTX` from PL0 | open question #5 (§16.2) | 83 (E71): every `GR_CTX` type returns `0x1f` with root, a live CUDA context and every route; a caller-owned RM channel is required |
| The FMC may decrypt the host-supplied `GspRmBoot` in place in unprotected sysmem | E69 hypothesis | 84 (E72): pre and post copies are byte-identical (SHA-256 `f5f63a71…`, entropy 7.9835) |
| The c09/c11 IV-permutation 16! passes close the test-key family for the FMC | 75–78 | 85/88/89 (E73): the body starts with code (`[code][data][manifest 0xA00]`), the oracle filtered for magics, and all 12,260 recorded hits re-score as random. The corrected code-first oracle is negative on c09 and c11 over 16! under five hypotheses (3 chance records, all verifier-rejected), so the family is exhausted for the FMC under the tested modes. |
| The decrypted boot image executes at PA `0x5dd00000` (runtime VA `0xefd00000` minus the `+0x92000000` GSP-RM offset) | §16.2 #16, §17.1 #13 | 86 (E74): that PA reads zero through a proven BAR0 window; the boot bin's WPR slot returns `0xbad0ac00` |
| The GSP-RM ELF is identity-mapped at host FB PA `0x01000000` | 79 (E67) | 86 (E74): host FB PA `0x01000000` is empty; `0x01000000` is a core-space address and the backing is in the WPR |
| BAR1 offsets are FB physical addresses (E48's test framing) | 47 (E48) | 86 (E74): BAR1 is a VAS; the VAS does not exist during the boot, and E48's zeros and fault are explained |

---

## Appendix I — References

**Prior work and documentation**

- [RTX 5090 Tensor Core Unlock: Why the 3090 and 4090 Trick Does Not Work on Blackwell](https://ai.rs/ai-developer/rtx-5090-tensor-core-unlock-blackwell)
- [gpu-unlock-ada issue #12 — GB202/RTX 5090 reconnaissance](https://github.com/JustAResearcher/gpu-unlock-ada/issues/12)
- [cmp170hx — fuses and OTP: FEAT block map across A100, 170HX and GA10x](https://github.com/Consensus-Protocol/cmp170hx/blob/879454d6cc221e06331708fba9540300c76b1d63/docs/hardware/fuses-and-otp.md)
- [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)
- [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)
- [Consensus-Protocol/cmp170hx — compute throttle, privilege-level masks](https://github.com/Consensus-Protocol/cmp170hx)
- [cmp170hx — how the unlock works (PL0/PL2/PL3, HS-gated PLM)](https://github.com/Consensus-Protocol/cmp170hx/blob/879454d6cc221e06331708fba9540300c76b1d63/docs/unlock/how-it-works.md)
- [cmp170hx — Falcon modes and SEC2 booter exfiltration](https://github.com/Consensus-Protocol/cmp170hx/blob/main/docs/unlock/falcon-and-booter.md)
- [cmp170hx — privilege-level masks: the SEC2 Booter raises the PLMs](https://github.com/Consensus-Protocol/cmp170hx/blob/main/docs/unlock/privilege-level-masks.md)
- [NVIDIA open-gpu-doc — Devinit opcode specification](https://download.nvidia.com/open-gpu-doc/Devinit/1/devinit.xml)
- [NVIDIA open-gpu-doc — BIOS Information Table specification](https://nvidia.github.io/open-gpu-doc/BIOS-Information-Table/BIOS-Information-Table.html)
- [FACEB13D — CMP 170HX: AES-ECB Falcon key recovery and SEC2 `booter_load` ROP to the PLMs](https://talks.mrmcd.net/2026/talk/ZDRJLV/)
- [gpu-unlock-ada — the BIT/uCode-table parser with the EFI-image correction](https://github.com/JustAResearcher/gpu-unlock-ada)
- [nvlight gist — GA100 VBIOS AES-128-ECB analysis and the key37 KAT](https://gist.github.com/nvlight/fc7479629b0ace094873e58ba7d75eb2)
- [TOTORONG/AD103_win_unlocker — decoded AD102 debug booter excerpts and four-PLM payload](https://huggingface.co/TOTORONG/AD103_win_unlocker)
- [WildFlash1st/cmp90hx-unlock — booter extraction and CMP90 exploit notes](https://github.com/WildFlash1st/cmp90hx-unlock)
- [CAmadeus/falcon-tools — Tegra TSEC csecret/keygen/secureboot tooling](https://github.com/CAmadeus/falcon-tools)
- [NVIDIA GPU Confidential Computing Demystified — FSP root of trust, COT/NVDM](https://arxiv.org/html/2507.02770v1)
- [rtx-p2p — GSP firmware registry keys](https://github.com/JustAResearcher/rtx-p2p) (local copy in `rtx-p2p/`; the `RMDisableFeatureDisablement` write-up in `docs/` is the method reference for E52)
- [Linux nova-core `falcon.rst` — PL3=HS, PL2=LS, PL0=NS](https://raw.githubusercontent.com/torvalds/linux/master/Documentation/gpu/nova/core/falcon.rst)
- [Linux nova-core `fsp.rst` — FSP boots from immutable ROM](https://dri.freedesktop.org/docs/drm/gpu/nova/core/fsp.html)
- [nova-core patch — corrected FSP secure-boot documentation, FSP → GSP BootROM → GSP-FMC → GSP-RM](https://patchew.org/linux/cover.1787754628.git.zhiw@nvidia.com/de054d8c5c1241fc600eb01aca34d6061429a174.1787754628.git.zhiw@nvidia.com/)
- [nova-core patch — FMC firmware image loaded via `request_firmware("fmc")`, `image` section only](https://lkml.iu.edu/hypermail/linux/kernel/2604.1/06010.html)
- [Linux nova-core `vbios.rst` — IFR/FwSec images, ROM at BAR0+0x300000](https://dri.freedesktop.org/docs/drm/gpu/nova/core/vbios.html)
- [gspwn knowledgebase — boot and firmware chain](https://indspl0it.github.io/gspwn/knowledgebase/boot-firmware/)
- [TechSpot — custom VBIOS without flashing](https://www.techspot.com/news/114257-mod-nvidia-geforce-owners-run-custom-vbios-without.html)
- [TechPowerUp — modified VBIOS tools for RTX 50/40/30](https://www.techpowerup.com/353849/new-tools-let-users-edit-and-load-modified-vbios-on-geforce-rtx-gpus-without-flashing)

**NVIDIA headers, sources, and whitepapers**

- [NVIDIA `ctrl2080gpu.h` — `NV2080_CTRL_CMD_GPU_EXEC_REG_OPS` and `NV2080_CTRL_GPU_REG_OP`](https://nv-tegra.nvidia.com/r/plugins/gitiles/tegra/kernel-src/nv-kernel-display-driver/+/8ef68d7c1ef5e19f5b301e8451a9bbe53c0b78ff/NVIDIA-kernel-module-source-TempVersion/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gpu.h)
- Local `open-gpu-kernel-modules/` at 595.91.07: `gpu_access.c`, `gpu_register_access_map.c`, `subdevice_ctrl_gpu_regops.c`, `kernel_graphics.c`, `kernel_graphics_context.c`, `g_subdevice_nvoc.c`, `kernel-open/nvidia/os-interface.c`, `arch/nvalloc/unix/src/osapi.c` (registry forwarding), `inc/kernel/diagnostics/tracer.h` (RMTRACE), `src/kernel/gpu/gsp/kernel_gsp.c` (GSP logs), `swref/published/nvswitch/ls10/dev_falcon_v4.h` (PLM fields), `ctrl2080gpu.h`, `ctrl2080gr.h`
- [NVIDIA RTX Blackwell PRO GPU Architecture whitepaper v1.1](https://www.nvidia.com/content/dam/en-zz/Solutions/design-visualization/quadro-product-literature/pdf/NVIDIA-RTX-Blackwell-PRO-GPU-Architecture-v1_1.pdf) — RTX PRO 6000 (same GB202 die): FP16-accumulate and BF16/FP32-accumulate both 503.8 TF/s
- [NVIDIA forums — RTX 5090 peak BF16 tensor TFLOPS](https://forums.developer.nvidia.com/t/rtx-5090-peak-bf16-tensor-tflops/350543/2) — BF16 exists only with FP32 accumulate in PTX

**Kernel and tooling**

- [cloudrift-ai/emmy — f16-accumulate MMA atoms](https://github.com/cloudrift-ai/emmy/commit/f7f35a38d762a6b78672f07d7d6f34c016c437b5)
- Ghidra 12.2 public build (local `ghidra-tools/ghidra_12.2_PUBLIC`)
- `envytools` (Falcon FUC5 disassembly) for any future µcode work

---

*This document is a research summary. It contains no working exploit, and no claim is
made that any open vector will succeed on retail GB202 silicon.*
