# Writing the speed registers from software

## Summary

**The idea.**

- The [4090](https://github.com/JustAResearcher/gpu-unlock-ada) and
  [3090](https://github.com/Zagitta/gpu-unlock) unlocks write two override words
  in the GPU's rate-control bank, then reset the card.
- I tried the same writes on the 5090 without the reset, from the host CPU at
  [PL0](../specs/02_privilege-and-rate-control.md) and from
  [GSP-RM](../specs/01_boot-chain.md), the GPU's main firmware, at
  [PL2](../specs/02_privilege-and-rate-control.md).

**What it found.**

- Every register in the [FEAT bank](../specs/03_register-map.md#feat-bank) has the
  [same write gate](#013-the-whole-feat-bank-shares-one-gate).
- FEAT writes through the control
  [return success and read back unchanged](#012-speed-register-write-from-gsp-is-dropped).
- The [permission mask](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
  [admits writes from PL3 only](#015-the-permission-mask-admits-pl3-writes-only);
  the [PL2 drop is silent](#012-speed-register-write-from-gsp-is-dropped).
- The [mask field layout](#015-the-permission-mask-admits-pl3-writes-only) matches
  NVIDIA's public Falcon v4 header, including the level-3-only write constant.
- The FUSE shadow and the rate modifier
  [do not accept a useful write](#014-the-fuse-shadow-and-the-inert-modifier).
- The [CUDA debugger class](#018-the-debugger-class-reads-the-bank-but-cannot-write-it)
  reads the bank and its FEAT write drops too.
- The [post-reset window closes too early](#016-the-post-reset-window-closes-before-gsp-rm),
  and the [per-context types are rejected](#017-per-context-registers-need-a-caller-owned-channel).

**What it did not find.**

- No software path
  [writes the selector](#012-speed-register-write-from-gsp-is-dropped).
- No debugger-class write path. The debug op reads the bank and the write is
  [dropped](#018-the-debugger-class-reads-the-bank-but-cannot-write-it).
- The old route reaches [`SS0`/`SS1`](../specs/03_register-map.md#ss0-and-ss1) from a boot image at PL3, and
  [that is still the only route](#015-the-permission-mask-admits-pl3-writes-only).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 01.1 | [First register write hits a crashed GSP](#011-first-register-write-hits-a-crashed-gsp) | Write untested; GSP already fatal |
| 01.2 | [Speed-register write from GSP is dropped](#012-speed-register-write-from-gsp-is-dropped) | Success returned; value unchanged |
| 01.3 | [The whole FEAT bank shares one gate](#013-the-whole-feat-bank-shares-one-gate) | No ungated register in bank |
| 01.4 | [The fuse shadow and the inert modifier](#014-the-fuse-shadow-and-the-inert-modifier) | Fuse locked; rate modifier inert |
| 01.5 | [The permission mask admits PL3 writes only](#015-the-permission-mask-admits-pl3-writes-only) | Write gate is PL3-only |
| 01.6 | [The post-reset window closes before GSP-RM](#016-the-post-reset-window-closes-before-gsp-rm) | Window ends before GSP-RM exists |
| 01.7 | [Per-context registers need a caller-owned channel](#017-per-context-registers-need-a-caller-owned-channel) | Context route closed at PL0 |
| 01.8 | [The debugger class reads but cannot write](#018-the-debugger-class-reads-the-bank-but-cannot-write-it) | Read matches; write drops |

## 01.1 First register write hits a crashed GSP

**Question.** Can a GSP-RM write through `NV2080_CTRL_CMD_GPU_EXEC_REG_OPS` reach
[`FEAT_OVR_SM_SS0`](../specs/03_register-map.md#ss0-and-ss1) and stick?

**Why.**

- The [4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) writes the
  same word from a PL3 boot image.
- If PL2 could do it from userspace, the selector would be writable without a PL3
  exploit.
- What it would give: a software write path to the BF16 rate, or a clear no.

**Method.**

- Tool: `regops` from [register access](../tools/register-access/), a userspace
  client for the register-op control.
- Target: first `deviceId 0` (`c1:00.0`), which was already fatal; then
  `deviceId 1` (`41:00.0`).
- Control: allocate an RM client, device, and subdevice, then issue
  `NV_ESC_RM_CONTROL 0x20800122`; the tool README has the details.
- Modes: `read` sends eight `READ_32` ops; `rate` calls the issue-rate getter
  ([`0x20801230`](../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)); `name` calls `0x20800110`.
- Baseline: direct [BAR0](../specs/07_memory-and-host-access.md#bar0-and-bar1) read on `41:00.0`.
- Args used:
```bash
sudo tools/register-access/regops 1 0000:41:00.0 read
sudo tools/register-access/regops 1 0000:41:00.0 rate
```

**Observed data.** Baseline from the direct BAR0 read on `41:00.0`
([register map](../specs/03_register-map.md) has the field names):

```text
PLM             0xfffffb8f
READOUT_1       0x00c36180
SS0             0x21240001
SS1             0x00000002
FMLA32          3
SM_ISSUE_RATE   5
OPTVRDIS        0
```

The control result:

```text
NV_ESC_RM_CONTROL 0x20800122 -> 0x62 (NV_ERR_RESET_REQUIRED)
parameterless getter         -> NV_OK
GET_NAME_STRING              -> 0x1F (NV_ERR_INVALID_ARGUMENT)
```

`dmesg -T` showed both GSPs had crashed 36 minutes earlier:

| Time | GPU | Sequence |
|---|---|---|
| 16:13:40 | `41:00.0` | Xid 13 -> [Xid 120](../specs/07_memory-and-host-access.md#bar0-and-bar1) -> Xid 154 |
| 16:13:47 | `c1:00.0` | same sequence, 7 s later |

```text
Xid 120: GSP task exception: load access page fault (cause:0xd) @ pc:0x1368618,
         partition:4#0, stval=0x250
```

**Result.**

- **Answer:** no measurement. The control returned [`0x62`](../specs/08_errors-and-logging.md#nv-status-codes) on every invocation, so
  the write was never tested.
- **What we learned:**
  - `0x62` is `NV_ERR_RESET_REQUIRED`; `_kgspRpcSanityCheck` returns it for every
    RPC once the GSP is fatal, so it says nothing about the requested write
    ([errors and logging](../specs/08_errors-and-logging.md)).
  - The parameterless getter still returned `NV_OK` because the host driver caches
    the nine selectors at GR init
    ([privilege and rate control](../specs/02_privilege-and-rate-control.md)).
  - `GET_NAME_STRING` returned [`0x1F`](../specs/08_errors-and-logging.md#nv-status-codes) (`NV_ERR_INVALID_ARGUMENT`), a normal
    argument error rather than a reset error, so the RM still answered host-side
    controls.
- **Related:**
  - The [clean rerun](#012-speed-register-write-from-gsp-is-dropped) supplies the
    actual write test.
- **Open question:** the BAR0 page scan [`0x300000`–`0x400000`](../specs/07_memory-and-host-access.md#bar0-and-bar1) ran in the same
  window, but the crash cause is not established; `c1:00.0` faulted 7 s later at
  the same PC. The aperture is a hazard regardless
  ([memory and host access](../specs/07_memory-and-host-access.md) has the recovery
  note).

## 01.2 Speed-register write from GSP is dropped

**Question.** Can a GSP-RM write to [`FEAT_OVR_SM_SS0`](../specs/03_register-map.md#ss0-and-ss1) stick when the GSP is
healthy?

**Why.**

- The [4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) uses
  `SS0 = 0x88888888`.
- A success here would be a PL2 write path to the selector.
- A drop would explain why every later register claim needs a readback.

**Method.**

- Tool: `regops` from [register access](../tools/register-access/), as root
  against `deviceId 1` (`41:00.0`) on a clean boot.
- Modes:
  - `one` reads [`PMC_BOOT_0`](../specs/03_register-map.md#chip-wpr-and-boot-targets) as a connectivity
    check.
  - `read` sends eight `READ_32` ops over the FEAT and FUSE windows.
  - `wr 82381c 0` writes `FEAT_OVR_SM_SS0` (offset [`0x82381c`](../specs/03_register-map.md#ss0-and-ss1)) with `WRITE_32` and
    `regAndNMask = ~value`, then reads it back.
  - `sc` writes a PBUS scratch register that the host also writes at PL0, reads
    it back, and restores it in the same RPC batch.
- Register-op write: `new = (read32(bar0 + offset) & ~regAndNMaskLo) | regValueLo`.
  To force `V`, set `regValue = V` and `regAndNMask = ~V`.
- Args used:
```bash
sudo tools/register-access/regops 1 0000:41:00.0 one
sudo tools/register-access/regops 1 0000:41:00.0 read
sudo tools/register-access/regops 1 0000:41:00.0 wr 82381c 0
sudo tools/register-access/regops 1 0000:41:00.0 sc
```

**Observed data.** Captured console output:

```text
one                SUCCESS   PMC_BOOT_0=0x1b2000a1 (matches BAR0)
read               8/8 SUCCESS; GSP values == host BAR0; SS0=0x21240001
wr 82381c 0        SUCCESS; readback=0x21240001; host BAR0=0x21240001
sc  SCRATCH[15]    0x143c: 0x5A5AA5A5 -> 0x5A5AA5A5; 0 -> 0
```

The scratch line means the register accepted `0x5A5AA5A5` and read back
`0x5A5AA5A5`, then accepted `0` and read back `0`. The FEAT write returned success
and the register did not move.

**Result.**

- **Answer:** the path works; the FEAT write is dropped.
- **What we learned:**
  - The scratch write changes and restores, the GSP reads match the host BAR0
    reads, and both writes return success.
  - The FEAT register reads back `0x21240001`, unchanged.
  - The drop is silent: [`regStatus = SUCCESS`](../specs/08_errors-and-logging.md#nv-status-codes)
    cannot distinguish applied from dropped; only the readback can.
  - The public [`GPU_EXEC_REG_OPS` header](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gpu.h)
    defines a per-op `regStatus` and a `NOACCESS` bit, and the
    [register-op implementation](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/nvidia/src/kernel/gpu/subdevice/subdevice_ctrl_gpu_regops.c)
    validates the offset before execution. A `SUCCESS` status with an unchanged
    readback places the drop below the ioctl, in the register path.
  - The negative/positive control pair and the readback rule are the method later
    register claims use.
  - The test wrote 0, not the [`0x88888888`](../specs/02_privilege-and-rate-control.md#selector-encoding) payload. `SS0 = 0` clears every enable
    bit, so it exercises the gate, not a rate change.
- **Related:**
  - The [rest of the bank](#013-the-whole-feat-bank-shares-one-gate) is the next
    test.
  - The [mask decode](#015-the-permission-mask-admits-pl3-writes-only) explains
    the drop.

## 01.3 The whole FEAT bank shares one gate

**Question.** Does any register in the wider FEAT bank have a write gate that
admits PL0 or PL2 writes?

**Why.**

- `SS0` was [dropped](#012-speed-register-write-from-gsp-is-dropped); a different
  register in the same bank might have a looser gate.
- [`0x82380c`](../specs/03_register-map.md#other-feat-words) = `0x00888888` looked like an active override; the 4090 payload uses
  `0x88888888`.
- What it would give: an ungated register in the same bank, or proof that the
  whole bank is closed.

**Method.**

- Tool: `regops dump` (non-transactional `READ_32`) and `regops wr` (`WRITE_32`
  with `regAndNMask = ~value`, then `READ_32`).
- Target: `deviceId 1` (`41:00.0`), root.
- Steps: dump 50 dwords from [`0x823800`](../specs/03_register-map.md#feat-bank); write `0x88888888` to `0x82380c`; read
  back.
- Args used:
```bash
sudo tools/register-access/regops 1 0000:41:00.0 dump 823800 50
sudo tools/register-access/regops 1 0000:41:00.0 wr 82380c 88888888
```

**Observed data.** The targeted registers in the dump:

```text
0x00823814 = 0x00000233  status=0 SUCCESS
0x00823818 = 0x00c36180  status=0 SUCCESS
0x0082381c = 0x21240001  status=0 SUCCESS
0x00823820 = 0x00000002  status=0 SUCCESS
```

The wider bank:

```text
0x00823800 = 0xfffffb8f   0x00823804 = 0xfffffb8f
0x00823808 = 0x01000280   0x0082380c = 0x00888888
0x00823810 = 0x002a2aaa   0x00823814 = 0x00000233
0x00823818 = 0x00c36180   0x0082381c = 0x21240001
0x00823820 = 0x00000002   0x00823824 = 0x00000003
0x00823828 = 0x00000001   0x0082382c = 0x0000000a
0x008238b0 = 0x12800541
unimplemented offsets -> 0xBADF5040
```

The write:

```text
WRITE 0x82380c = 0x88888888  status=SUCCESS
READBACK                   = 0x00888888   (unchanged)
```

The 4-byte scan found `0x00823814` once in `.text`, inside the ECC enablement
check. The two instruction forms are:

```text
file 0x2b5cb0, inside kmemsysCheckReadoutEccEnablement_GA100:
  mov ecx, 0x823814
  call <register read>
  shr eax, 16
  and eax, 1
  ret

file 0x2b3000, GB100 variant:
  lea ecx, [rax+0x3814]   (rax = 0x820000)
```

A targeted scan for `b9 imm32` in `0x820000`–`0x830000` and `8d 88 imm32` with
`imm` in `0x3000`–`0x3fff` found only `0x820c04`, `0x82074c`, `0x823814`, and
unrelated `0x8230xx` registers.

**Result.**

- **Answer:** no. All 50 map ops returned `SUCCESS`; the `0x88888888` write
  returned `SUCCESS` and the readback stayed `0x00888888`.
- **What we learned:**
  - Unimplemented offsets read [`0xBADF5040`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)
    ([errors and logging](../specs/08_errors-and-logging.md)).
  - No register in `0x823800`–`0x8238b0` has a different gate.
  - The driver only references [`0x823814`](../specs/03_register-map.md#readout-decode) in the ECC check; the targeted scan
    found no speed-register writer.
  - The bank map is in [the register map](../specs/03_register-map.md).
    `0x82380c` is [`FEAT_OVR_ECC`](../specs/03_register-map.md#other-feat-words), the stock ECC override, not a speed word
    ([the plaintext corpus](../experiments/07_plaintext-corpus.md)).
  - This tests the bank, not the selector.
- **Related:**
  - The [SS0 write test](#012-speed-register-write-from-gsp-is-dropped) is the
    selector test.
  - The [gate decode](#015-the-permission-mask-admits-pl3-writes-only) explains
    the drop.

## 01.4 The fuse shadow and the inert modifier

**Question.** Are the FUSE shadow or [`SM_ISSUE_RATE_MODIFIER`](../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)
a usable write path to the rate?

**Why.**

- The [FUSE page-0 permission mask](../specs/03_register-map.md#fuse-and-otp) appears to allow writes from every level, so
  the shadow looked writable.
- The rate modifier is the one rate-related register that might move the issue
  rate.
- What it would give: a rate change without the FEAT bank, or proof both are
  inert.

**Method.**

- Tools: `regops wrr` (GSP, one RPC), `regops barw` (host, `resource0` mmap),
  `fuse_probe.sh` (FUSE map), [issue-rate probe](../tools/issue-rate-probe/)
  (tensor rate).
- Target: `41:00.0`, root.
- Steps:
  - Dump the FUSE window in four non-transactional batches over
    [`0x820000`–`0x8207ff`](../specs/03_register-map.md#fuse-and-otp).
  - Write, read back, and restore `0x82074c` and `0x8207d8` from both levels.
  - Write [`0x504204`](../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view) to 0 from both levels.
  - Run the hash-pinned tensor probe with the register held at 0 after
    `cuCtxCreate`.
- Probe: the runner checks the power cap, validates all 270,336 output cells per
  mode, records clocks and power, and restores 5. Cubin SHA-256
  `099aecf487705caacb24500ef36d41175bdfb650e00bafd57db6caaa17c1cde8`.
- Args used:
```bash
sudo tools/register-access/fuse_probe.sh 1 0000:41:00.0
sudo tools/register-access/regops 1 0000:41:00.0 wrr 82074c 0 1
sudo tools/register-access/regops 1 0000:41:00.0 barw 82074c 0 1
sudo tools/register-access/regops 1 0000:41:00.0 wrr 8207d8 0 3
sudo tools/register-access/regops 1 0000:41:00.0 barw 8207d8 0 3
sudo tools/register-access/regops 1 0000:41:00.0 barw 504204 0 5
sudo tools/register-access/regops 1 0000:41:00.0 wrr 504204 0 5
```

**Observed data.** FUSE values:

```text
0x008200fc FUSE_SS_PLM              = 0xfffffbff
0x0082074c OPT_SECURE_GSP_DEBUG_DIS = 1
0x008207d8 FUSE_SS_FMLA32           = 3
0x008207d4 FUSE_SS_FMLA16           = 0
0x008207dc/07e0/07e4/07e8/07ec      = 0 / 3 / 3 / 0 / 3
```

Write tests:

```text
0x0082074c: host 1 -> 1   GSP 1 -> 1
0x008207d8: host 3 -> 3   GSP 3 -> 3
0x00504204: host 5 -> 0 -> 5   GSP 5 -> 0 -> 5
```

Rate results (best TF/s or TOPS over three reps; 20,000 iterations; 270,336 cells
per mode):

```text
baseline (modifier 5):  f16_f32=227.14  bf16_f32=227.10  tf32=113.56  u4_s32=596.46
held at 0:              f16_f32=227.09  bf16_f32=225.88  tf32=112.99  u4_s32=591.10
```

The register log read 0 at all 17 stages.

**Result.**

- **Answer:** both are dead ends. The FUSE writes are dropped from both levels;
  the rate modifier is writable but reasserted and inert.
- **What we learned:**
  - The FUSE page-0 mask appears to allow writes from every level, but the
    shadow is not writable; the effective gate is below the PLM.
  - [`SM_ISSUE_RATE_MODIFIER`](../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view) is writable and reasserted to 5 at CUDA context
    creation. Holding it at 0 does not move the measured rate.
  - The hash-pinned probe with the register held at 0 is the method for testing a
    register's effect on the measured rate.
  - [The probe](../tools/issue-rate-probe/) now has an FP16-accumulate mode, but
    this run and the 5090 baseline do not use it; the 5090 has no local
    FP16-accumulate measurement.
- **Related:**
  - The rate modifier is documented in
    [privilege and rate control](../specs/02_privilege-and-rate-control.md).
- **Open question:** where the FUSE shadow's effective gate sits below the [PLM](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) is
  not located.

## 01.5 The permission mask admits PL3 writes only

**Question.** What does [`FEAT_OVR_PLM`](../specs/03_register-map.md#write-gate) = `0xfffffb8f` mean, and which writes does it
admit?

**Why.**

- Bit 10 is clear here and set in Ada's [`0xffffff8f`](../specs/03_register-map.md#write-gate); an earlier reading took
  that as a removed source.
- If the layout is the standard Falcon v4 mask, the write field is the gate.
- What it would give: the exact privilege level a write must come from.

**Method.**

- Static decode, no hardware.
- Apply the Falcon v4 field layout in
  [privilege and rate control](../specs/02_privilege-and-rate-control.md) to the
  measured value.
- Compare with Ada's `0xffffff8f`
  ([the 4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada)).
- Read the measured value with
  `sudo tools/register-access/regops 1 0000:41:00.0 read` if repeating.

**Observed data.** Measured on `41:00.0`:

```text
FEAT_OVR_PLM (0x00823804) = 0xfffffb8f
Ada comparison            = 0xffffff8f
```

**Result.**

- **Answer:** the mask is a Falcon v4 privilege mask. The write field
  `[7:4] = 8` admits [PL3](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) writes only.
- **What we learned:**

| Bits | Field | `0xfffffb8f` | Ada `0xffffff8f` |
|---|---|---|---|
| `3:0` | `READ_PROTECTION` | `0xf` (all levels) | same |
| `7:4` | [`WRITE_PROTECTION`](../specs/03_register-map.md#write-gate) | `0x8` (**PL3 only**) | same |
| `8` | `READ_VIOLATION` | report error | same |
| `9` | `WRITE_VIOLATION` | report error | same |
| `10` | `SOURCE_READ_CONTROL` | 0 = lowered | 1 = blocked |
| `11` | `SOURCE_WRITE_CONTROL` | 1 = blocked | same |
| `31:12` | `SOURCE_ENABLE` | `0xfffff` (**all 20 sources**) | same |

- No removed source and no hidden `[23:8]` source-enable field. The source-enable
  field is `[31:12]` and is fully populated.
- Bit 10 is `SOURCE_READ_CONTROL`, a read-side control, not a writer.
- The field layout matches NVIDIA's public Falcon v4 register header, including
  `WRITE_PROTECTION_ONLY_LEVEL3_ENABLED 0x00000008` and
  `SOURCE_ENABLE_ALL_SOURCES_ENABLED 0x000fffff`
  ([dev_falcon_v4.h](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/common/inc/swref/published/nvswitch/ls10/dev_falcon_v4.h)).
  The same header defines `RESET_PRIV_LEVEL_MASK` at Falcon `0x3c4` with the same
  layout, which is the `0x00000f00` read in
  [the post-reset window](#016-the-post-reset-window-closes-before-gsp-rm).
- The header match does not prove the FEAT bank is a Falcon PLM, because the
  block is not a Falcon register file. It does remove the field-name guess.
- **Related:**
  - The [PL2 write test](#012-speed-register-write-from-gsp-is-dropped) sees this
    drop.
  - The [post-reset window](#016-the-post-reset-window-closes-before-gsp-rm)
    measures the post-FLR value, which admits PL2 and PL3.
- **Open question:** what the hardware does with a write that passes the mask; no
  experiment exercises a passing write.

## 01.6 The post-reset window closes before GSP-RM

**Question.** Can a GSP-RM write use the PL2-writable window that opens after a
PCI function-level reset ([FLR](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm))?

**Why.**

- [The boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md) found the
  window; this tests whether it can be reached before the re-lock.
- The [4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) relies on
  an FLR leaving its override in place.
- What it would give: a [PL2](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) write path without a PL3 exploit, or a timing bound
  that closes it.

**Method.**

- Tools: `plm_window_race.sh measure` from
  [driver harness](../tools/driver-harness/) (unbind + FLR), `regops plmpoll`
  from [register access](../tools/register-access/) (BAR0 poller).
- Target: `41:00.0`, root.
- Steps:
  - Start the poller before the bind; it re-maps `resource0` on every sample so
    it survives the bind.
  - Sample the FEAT bank plus GSP `ENGINE` ([`0x1103c0`](../specs/03_register-map.md#gsp-falcon)), reset PLM ([`0x1103c4`](../specs/03_register-map.md#gsp-falcon)),
    and host PC mirror ([`0x1113ec`](../specs/03_register-map.md#priscv)).
  - `nvidia-smi -L` triggers the first open.
- Args used:
```bash
sudo tools/driver-harness/plm_window_race.sh measure 0000:41:00.0
```

**Observed data.** Two runs measured a window; an earlier run missed it:

| Run | First sample | Re-lock | First GSP-RM PC |
|---|---:|---:|---:|
| missed | [`0xfffffb8f`](../specs/03_register-map.md#write-gate) | not measured | not logged |
| A | [`0x80842bcf`](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) | 1156 ms | not logged |
| B | `0x80842bcf` | 1323 ms | 3176 ms |

In both measured runs the window opened at t=0 with `plm=0x80842bcf`. The first
sample shows the pre-bind state:

```text
plm=0x80842bcf  ss0=0x21265043  ss1=0x00000006  engine=0xbadf4100  resetplm=0xbadf4100  pc=0xbadf4100
```

After the rebind:

```text
BAR0 0x00823804 = 0xfffffb8f
BAR0 0x0082381c = 0x21265043
BAR0 0x00823820 = 0x00000006
rate getter status = 0
```

The boot-image PC (`0xefd00000`–`0xefd47000`) was not sampled in either run.

**Result.**

- **Answer:** no. The window is 1156–1323 ms; it closes 1853 ms before GSP-RM
  starts.
- **What we learned:**
  - The bind consumes about 1.0 s of the window; the open→GSP-RM path is about
    2.1 s, longer than the window even with a zero-delay open.
  - The re-lock is a pre-boot GPU-side devinit (FSP/PMU/hardware), not the FMC or
    GSP-RM
    ([the boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md)
    bracket it).
  - The "boot the GSP early" variant is retracted; `benign` and `payload` were not
    run because they cannot win and would only cost an FLR.
  - The re-mapping BAR0 poller and race harness time the window without touching
    the driver.
- **Related:**
  - The [cold-boot experiment](../experiments/05_fmc-fsp-boot-inputs.md) covers
    the per-boot SS state.
  - The [boot-window experiment](../experiments/04_hs-sec2-fsp-memory.md) covers
    the boot-image PC.
- **Open question:** the exact devinit that performs the re-lock is not named.

## 01.7 Per-context registers need a caller-owned channel

**Question.** Can the register-op control reach per-context or per-SM registers
through `GR_CTX` and the other typed regtypes?

**Why.**

- Earlier passes used `GLOBAL` only. The
  [SS0 write test](#012-speed-register-write-from-gsp-is-dropped), the
  [bank map](#013-the-whole-feat-bank-shares-one-gate), and the
  [FUSE and rate probe](#014-the-fuse-shadow-and-the-inert-modifier) all used a
  plain offset; a per-SM route might have a different gate.
- The per-SM selector path is described in
  [privilege and rate control](../specs/02_privilege-and-rate-control.md).
- What it would give: a per-SM write path, or proof the cheap PL0 route is
  closed.

**Method.**

- Tools: `regops gprobe` and `gprobe_route` from
  [register access](../tools/register-access/); `gprobe_with_ctx.sh` from
  [driver harness](../tools/driver-harness/).
- Target: `41:00.0`, root.
- Steps:
  - `gprobe` reads [`0x504204`](../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view), [`SS0`](../specs/03_register-map.md#ss0-and-ss1), `SS1`, and [`PLM`](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) under `GLOBAL`, `GR_CTX`,
    `GR_CTX_TPC`, `GR_CTX_SM`, `GR_CTX_QUAD`, and `FB`.
  - `gprobe_route` repeats `GR_CTX` with `grRouteInfo.flags` 0–3
    (`TYPE_NONE`/`ENGID`/`CHANNEL`/both).
  - `gprobe_with_ctx.sh` holds a CUDA context on `41:00.0` from plain C
    (`cuda_ctx.c`, driver API).
- Args used:
```bash
sudo tools/register-access/regops 1 0000:41:00.0 gprobe
sudo tools/driver-harness/gprobe_with_ctx.sh route
```

**Observed data.**

| `regType` | Control status | Per-op values |
|---|---|---|
| `GLOBAL` | 0 | `0x504204=5`, `SS0=0x21265043`, `SS1=0x6`, `PLM=0xfffffb8f` |
| `GR_CTX` | [`0x1f`](../specs/08_errors-and-logging.md#nv-status-codes) | all 0 |
| `GR_CTX_TPC` | `0x1f` | all 0 |
| `GR_CTX_SM` | `0x1f` | all 0 |
| `GR_CTX_QUAD` | `0x1f` | all 0 |
| `FB` | [`0x56`](../specs/08_errors-and-logging.md#nv-status-codes) | all 0 |

The route run repeated `GR_CTX` with flags 0–3:

```text
gprobe_route flags=0 route=0 status=0x1f
gprobe_route flags=1 route=0 status=0x1f
gprobe_route flags=2 route=0 status=0x1f
gprobe_route flags=3 route=0 status=0x1f
```

The ctrl-table entry for `0x20800122` (from the installed GSP-RM image):

```text
file 0xd16a68  ctrlId=0x20800122  paramSize=0x30
classPtr=0x01b92748  handlerPtr=0x01400740  flags=0x00000109
```

At the handler target (`0x1400740`), the first bytes are:

```text
11 00 97 47 ef 02 83 b7 67 45
```

The `11 00` is a 2-byte RVC hint/nop; the first real instruction starts at
`0x400742` (`97 47 ef 02` = `auipc a5, 0x2ef4`). The handler pointer is two bytes
before the first instruction, so the table entry does not decode as a function
start.

**Result.**

- **Answer:** the type is recognized but the batch is rejected before execution;
  `FB` is unsupported.
- **What we learned:**
  - `GR_CTX` variants return `0x1f`; `FB` returns `0x56`; a CUDA context and every
    route flag give the same result
    ([errors and logging](../specs/08_errors-and-logging.md)).
  - The ctrl-table handler pointer does not resolve to a function start.
  - `gprobe`/`gprobe_route` and the CUDA-context harness are the typed-regtype
    probe method.
  - A CUDA channel is not addressable: RM handles are client-scoped, the CUDA
    client's handle is not exposed, and the `hClientTarget=0` expansion is not
    implemented for context ops on this build.
- **Related:**
  - The [`SS0` write test](#012-speed-register-write-from-gsp-is-dropped) is the
    direct selector test.
  - The [bank map](#013-the-whole-feat-bank-shares-one-gate) covers the wider
    FEAT window.
  - The [FUSE and rate probe](#014-the-fuse-shadow-and-the-inert-modifier) covers
    the other rate registers.
- **Open question:** would a channel owned by the calling client succeed? Testing
  it needs a mini RM client (VA space, GPFIFO, UserD, bind/schedule) or a kernel
  hook; the GSP may still reject it.

## 01.8 The debugger class reads the bank but cannot write it

**Question.** Can the CUDA debugger class (`GT200_DEBUGGER`, `0x83de`) write a
FEAT-bank word from the host?

**Why.**

- The register-op control and the GSP both drop the write. The debugger class is
  the last host-facing object with a register-op command, and the CUDA driver
  creates one under the device at context creation.
- A debug class that bypassed the FEAT PLM would be a PL0 write path without an
  exploit.
- What it would give: a host write path, or proof the PLM gates the bank below
  the debug class.

**Method.**

- Tool: an `LD_PRELOAD` hook inside a CUDA process, issuing
  `NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS` (`0x83de031d`) to the debugger object the
  driver creates at `cuCtxCreate`.
- Target: `41:00.0` (device 0), idle, stock driver.
- Steps:
  - Confirm `GT200_DEBUGGER` is in the GB202 class list (117 classes). The
    driver's debugger object has `hAppClient` = the CUDA client,
    `hClass3dObject` = a `BLACKWELL_COMPUTE_B` (`0xcec0`) handle, and the device
    as parent.
  - Read `PMC_BOOT_0`, `FEAT_OVR_PLM`, `READOUT_0`, `READOUT_1`, `SS0`, `SS1`,
    `FUSE_SS_FMLA32`, and `FUSE_SS_PLM` through the debug op.
  - Write `FEAT_OVR_QUADRO` (`0x823808`) with bit 0 flipped, then read it back.
  - Sweep `0x504000`–`0x5042ff` and the `0x137000` block read-only through the
    same path.

Args used:

```text
NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS  0x83de031d
read   00000000 00823804 00823814 00823818 0082381c 00823820 008207d8 008200fc
write  00823808  bit 0
sweep  00504000..005042ff  00137000..00137fff
```

**Observed data.** The read path matches the BAR0 and GSP values:

```text
PMC_BOOT_0       0x1b2000a1
FEAT_OVR_PLM     0xfffffb8f
READOUT_0        0x00000233
READOUT_1        0x00c36180
SS0              0x21265043
SS1              0x00000006
FUSE_SS_FMLA32   3
FUSE_SS_PLM      0xfffffbff
```

The write returned the success path and the readback stayed `0x01000280`:

```text
WRITE   0x00823808 bit 0   RM status=0  regStatus=0   (intended 0x01000281)
READBACK 0x00823808        = 0x01000280   (unchanged)
```

The GR-context sweep found no FEAT-selector mirror. `0x504204` is the inert
rate register at `5`; `0x504100` is a PLM `0xffffffcf`; `0x504180`–`0x5041fc`
return `0xbadf1002`. The `0x137000` block reads as a `0x30`-stride table, with
`0x137200 = 0xc120048a`. The FECS log record `0x20471930` shows a refused PL2
attempt at `0x137200` with `0xbadf5128`
([the sentinel analysis](../experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis)).

**Result.**

- **Answer:** the debugger class reads the bank and the write is dropped. It is
  a read-only observability path; the FEAT write does not land.
- **What we learned:**
  - The debug class resolves the same bank and returns the stock values, so it
    is a fourth read path alongside BAR0, the GSP, and the driver's cached getter.
  - A benign FEAT write returns the success path and the PLM drops it, exactly
    like [the host and GSP writes](#012-speed-register-write-from-gsp-is-dropped).
    The gate sits below the debug class.
  - The write targeted `FEAT_OVR_QUADRO`; the result applies to the bank rather
    than the selector alone.
  - `0x137200` is a privilege-protected FECS/GR register, not a FEAT word. That
    closes the free lead the FECS log record raised.
- **Related:**
  - The [GSP write drop](#012-speed-register-write-from-gsp-is-dropped) is the
    same behavior through a different master.
  - The [bank-wide gate](#013-the-whole-feat-bank-shares-one-gate) explains why
    the benign word drops.
  - The [PLM decode](#015-the-permission-mask-admits-pl3-writes-only) is the gate.
  - The [debugger
    group](../experiments/10_debugger-class-and-fecs-ucode.md) covers the class
    exposure, the context and descriptor spaces, and the FECS bodies.
- **Open question:** the op is still useful for read-only observation. Whether
  it exposes other engine blocks, or a write through a different debug
  subcommand, is untested.

