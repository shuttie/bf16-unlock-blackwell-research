# Writing the speed registers from software

The [4090](https://github.com/JustAResearcher/gpu-unlock-ada) and
[3090](https://github.com/Zagitta/gpu-unlock) unlocks write two override words in
the GPU's rate-control bank, then reset the card. I tried the same writes on the
5090 without the reset, from the host CPU at
[PL0](../specs/02_privilege-and-rate-control.md) and from
[GSP-RM](../specs/01_boot-chain.md), the GPU's main firmware, at
[PL2](../specs/02_privilege-and-rate-control.md). The register-op control accepted
the write and returned success on a healthy GSP. The registers did not change. The
bank's [permission mask](../specs/02_privilege-and-rate-control.md) admits writes
from [PL3](../specs/02_privilege-and-rate-control.md) only, the level where
NVIDIA's boot firmware runs.

The old route reaches [`SS0`/`SS1`](../specs/03_register-map.md) from a boot image
at PL3. This group asks whether anything already running at PL0 or PL2 can do the
same.

## Summary

These seven experiments asked whether the host (`PL0`) or GSP-RM (`PL2`) can
write the rate-control registers, and whether success status means the write
landed. They ran on the [two-card test rig](../README.md).

The instrument was [`NV2080_CTRL_CMD_GPU_EXEC_REG_OPS`](../tools/register-access/)
(`0x20800122`), NVIDIA's exported register-op control. A root client names a
[BAR0](../specs/07_memory-and-host-access.md) offset, and GSP-RM performs the
access at PL2.

The transport works. Every register in the
[FEAT bank](../specs/03_register-map.md) has the same write gate, and accepted
FEAT writes read back unchanged. The FUSE shadow and the rate modifier do not
accept a useful write, the post-reset window closes too early, and the
per-context register types are rejected.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| [01.1](#011-first-register-write-hits-a-crashed-gsp) | First register write hits a crashed GSP | Write untested; GSP already fatal |
| [01.2](#012-speed-register-write-from-gsp-is-dropped) | Speed-register write from GSP is dropped | Success returned; value unchanged |
| [01.3](#013-the-whole-feat-bank-shares-one-gate) | The whole FEAT bank shares one gate | No ungated register in bank |
| [01.4](#014-the-fuse-shadow-and-the-inert-modifier) | The fuse shadow and the inert modifier | Fuse locked; rate modifier inert |
| [01.5](#015-the-permission-mask-admits-pl3-writes-only) | The permission mask admits PL3 writes only | Write gate is PL3-only |
| [01.6](#016-the-post-reset-window-closes-before-gsp-rm) | The post-reset window closes before GSP-RM | Window ends before GSP-RM exists |
| [01.7](#017-per-context-registers-need-a-caller-owned-channel) | Per-context registers need a caller-owned channel | Context route closed at PL0 |

## 01.1 First register write hits a crashed GSP

**Hypothesis.** A write issued by GSP-RM through
[`NV2080_CTRL_CMD_GPU_EXEC_REG_OPS`](../tools/register-access/) can reach
[`FEAT_OVR_SM_SS0`](../specs/03_register-map.md) and stick. The
[4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) writes the same
word from a PL3 boot image; this run asked whether PL2 firmware could do it from
userspace.

**Method.** `regops` from [register access](../tools/register-access/) is a
userspace client for the register-op control. I ran it as root, first against
`deviceId 0` (`c1:00.0`), which was already fatal, then against `deviceId 1`
(`41:00.0`). The client allocates an RM client, device, and subdevice, then issues
`NV_ESC_RM_CONTROL 0x20800122`; the tool README has the details. The `read` mode
sends eight `READ_32` ops, `rate` calls the issue-rate getter (`0x20801230`), and
`name` calls `0x20800110`. I ran the same modes on `deviceId 1` with:

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
| 16:13:40 | `41:00.0` | Xid 13 -> Xid 120 -> Xid 154 |
| 16:13:47 | `c1:00.0` | same sequence, 7 s later |

```text
Xid 120: GSP task exception: load access page fault (cause:0xd) @ pc:0x1368618,
         partition:4#0, stval=0x250
```

**Result.** The control returned `0x62` on every invocation and no per-op status.
`0x62` is `NV_ERR_RESET_REQUIRED`, which `_kgspRpcSanityCheck` returns for every
RPC once the GSP is fatal, so it says nothing about the requested write
([errors and logging](../specs/08_errors-and-logging.md)). The parameterless
getter still returned `NV_OK` because the host driver caches the nine selectors
at GR init and serves the getter from that cache
([privilege and rate control](../specs/02_privilege-and-rate-control.md)).
`GET_NAME_STRING` returned `0x1F` (`NV_ERR_INVALID_ARGUMENT`), a normal argument
error rather than a reset error, so the RM still answered host-side controls.

The GSP was already fatal, so this run did not test whether a GSP-executed write
can land.

**Reproduce.**
1. Build `regops` from the repo root:
   `gcc -O2 -Wall -o tools/register-access/regops tools/register-access/regops.c`.
2. On a boot with a fatal GSP (`Xid 120` in `dmesg -T`), run the two commands
   above.
3. Expect `0x62` from the register-op control and `NV_OK` from the parameterless
   getter.
4. On a clean boot the same commands return the register values; that run is
   [01.2](#012-speed-register-write-from-gsp-is-dropped).

**Limits.** This run is invalid as a write test. It shows the failure mode of an
RPC to a fatal GSP, not whether a GSP-executed write can land. The BAR0 page scan
`0x300000`–`0x400000` ran in the same window; causation with the crash is not
established, because `c1:00.0` faulted 7 s later at the same PC. Treat the
aperture as a hazard anyway
([memory and host access](../specs/07_memory-and-host-access.md)), which also has
the recovery note. The clean rerun
[01.2](#012-speed-register-write-from-gsp-is-dropped) supplies the
negative/positive control pair this run lacks.

## 01.2 Speed-register write from GSP is dropped

**Hypothesis.** A GSP-RM write to [`FEAT_OVR_SM_SS0`](../specs/03_register-map.md)
can stick when the GSP is healthy. The
[4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) writes
`SS0 = 0x88888888`; this test wrote 0, which is enough to see whether the write
lands.

**Method.** `regops` from [register access](../tools/register-access/), run as root
against `deviceId 1` (`41:00.0`) on a clean boot. Four modes ran in order:

- `one` reads [`PMC_BOOT_0`](../specs/03_register-map.md) as a connectivity check.
- `read` sends eight `READ_32` ops over the FEAT and FUSE windows.
- `wr 82381c 0` writes `FEAT_OVR_SM_SS0` (offset `0x82381c`) with `WRITE_32` and
  `regAndNMask = ~value`, then reads it back.
- `sc` writes a PBUS scratch register that the host also writes at PL0, reads it
  back, and restores it in the same RPC batch.

The register-op write is a read-modify-write:
`new = (read32(bar0 + offset) & ~regAndNMaskLo) | regValueLo`. To force an exact
value `V`, set `regValue = V` and `regAndNMask = ~V`.

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

**Result.** The path works. The scratch register changes and restores, the GSP's
reads match the host's BAR0 reads, and both writes return success. The FEAT write
is dropped by [`FEAT_OVR_PLM`](../specs/02_privilege-and-rate-control.md), and the
drop is silent. [01.5](#015-the-permission-mask-admits-pl3-writes-only) decodes
the mask. [`regStatus = SUCCESS`](../specs/08_errors-and-logging.md) cannot
distinguish "applied" from "dropped"; only the readback can.

This is the negative/positive control pair every later register claim uses. A
dropped FEAT write sits next to a scratch write that lands.

**Reproduce.**
1. Boot clean.
2. Build from the repo root:
   `gcc -O2 -Wall -o tools/register-access/regops tools/register-access/regops.c`.
3. Run the four commands in order.
4. Expect `SUCCESS` from the FEAT write while `0x82381c` reads back `0x21240001`,
   and the scratch register to change and restore.

**Limits.** Success status does not mean the write landed; the readback is the
evidence. The value written was 0, not the `0x88888888` payload the 4090 unlock
writes, and `SS0 = 0` leaves every enable bit clear, so this run does not show what
a non-zero value would do. It does show that the write did not change the
register. The bank's gate is decoded in
[01.5](#015-the-permission-mask-admits-pl3-writes-only); the rest of the bank is
[01.3](#013-the-whole-feat-bank-shares-one-gate).

## 01.3 The whole FEAT bank shares one gate

**Hypothesis.** A register in the wider [FEAT bank](../specs/03_register-map.md)
might have a different write gate. The candidate was `0x82380c = 0x00888888`,
which reads like an active override; `0x88888888` is also the value the
[4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) writes to `SS0`.

**Method.** `regops` from [register access](../tools/register-access/) dumps 50
dwords from `0x823800` with non-transactional `READ_32` ops, then writes
`0x88888888` to `0x82380c` and reads it back. I ran it as root against
`deviceId 1` (`41:00.0`).

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

**Result.** All 50 map ops returned `SUCCESS`; unimplemented offsets read
`0xBADF5040`, not an error ([errors and logging](../specs/08_errors-and-logging.md)).
The `0x88888888` write returned `SUCCESS` and the readback stayed `0x00888888`.
No register in `0x823800`–`0x8238b0` has a different gate. The bank map is in
[the register map](../specs/03_register-map.md).

**Reproduce.**
1. Run the dump and write commands above.
2. Expect `SUCCESS` on every op, `0xBADF5040` at unimplemented offsets, and
   `0x00888888` after the write.
3. For the static scan, decompress the installed `nvidia.ko` and search for the
   two instruction forms; the [register access](../tools/register-access/) README
   has the scan notes.

**Limits.** `0x82380c` is the stock ECC override (`FEAT_OVR_ECC`), not a speed
word ([the plaintext corpus](../experiments/07_plaintext-corpus.md)). This run
tests the bank's write gate, not the selector words;
[01.2](#012-speed-register-write-from-gsp-is-dropped) tests `SS0`.

## 01.4 The fuse shadow and the inert modifier

**Hypothesis.** The [FUSE shadow](../specs/03_register-map.md) and the
[`SM_ISSUE_RATE_MODIFIER`](../specs/02_privilege-and-rate-control.md) could be
write-gated or inert. The FUSE page-0 permission mask appears to allow writes
from every level, which makes the shadow look writable; the rate modifier is the
one rate-related register that might move the issue rate.

**Method.** `regops` from [register access](../tools/register-access/) writes
through GSP-RM (`wrr`) or through a `resource0` mmap (`barw`). `fuse_probe.sh`
maps the FUSE window. The [issue-rate probe](../tools/issue-rate-probe/) measures
the tensor rate with the register held at 0.

I dumped the FUSE window in four non-transactional batches over
`0x820000`–`0x8207ff`, then wrote, read back, and restored `0x82074c` and
`0x8207d8` from both privilege levels. Next I wrote `0x504204` to 0 from both
levels and ran the hash-pinned tensor probe with the register held at 0 after
`cuCtxCreate`.

```bash
sudo tools/register-access/fuse_probe.sh 1 0000:41:00.0
sudo tools/register-access/regops 1 0000:41:00.0 wrr 82074c 0 1
sudo tools/register-access/regops 1 0000:41:00.0 barw 82074c 0 1
sudo tools/register-access/regops 1 0000:41:00.0 wrr 8207d8 0 3
sudo tools/register-access/regops 1 0000:41:00.0 barw 8207d8 0 3
sudo tools/register-access/regops 1 0000:41:00.0 barw 504204 0 5
sudo tools/register-access/regops 1 0000:41:00.0 wrr 504204 0 5
```

The probe runner checks the power cap, validates all 270,336 output cells per
mode, records clocks and power, and reads back and restores 5. The cubin is pinned
to SHA-256
`099aecf487705caacb24500ef36d41175bdfb650e00bafd57db6caaa17c1cde8`.

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

**Result.** The FUSE writes are dropped from both levels. `SM_ISSUE_RATE_MODIFIER`
is writable, reasserted to 5 at CUDA context creation, and inert: the measured
rate does not move. See
[privilege and rate control](../specs/02_privilege-and-rate-control.md). The page-0
FUSE mask appears to allow writes from every level but is not the effective gate.

**Reproduce.**
1. Read the FUSE map with `sudo tools/register-access/fuse_probe.sh 1 0000:41:00.0`.
2. Run the four `wrr`/`barw` FUSE commands; expect the values to stay 1 and 3.
3. Build the probe as described in the
   [issue-rate probe](../tools/issue-rate-probe/) README; pin the cubin to the
   recorded SHA-256.
4. Set `UUID` to your card and run `sudo ./run_modifier_test.sh`; expect the
   modifier to read 0 during the probe, 5 on readback, and the rates to match the
   baseline within run-to-run variance.

**Limits.** The FUSE page-0 mask appears to allow writes from every level, but the
shadow is not writable, so the effective gate is below the PLM. The rate register is writable but
reasserted and inert; this does not make it a selector. The probe has no
FP16-accumulate mode, so it cannot measure the cap ratio locally.

## 01.5 The permission mask admits PL3 writes only

**Hypothesis.** Bit 10 is clear in
[`FEAT_OVR_PLM = 0xfffffb8f`](../specs/03_register-map.md) and set in Ada's
`0xffffff8f`. An earlier reading took the cleared bit to mean a removed source.
The value should instead decode as the Falcon v4 privilege mask used by the other
IP blocks, where bit 10 is a read-side control.

**Method.** Static decode, no hardware. I applied the Falcon v4 field layout in
[privilege and rate control](../specs/02_privilege-and-rate-control.md) to the
measured value and compared it with Ada's `0xffffff8f`
([the 4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada)).

**Observed data.** Measured on `41:00.0`:

```text
FEAT_OVR_PLM (0x00823804) = 0xfffffb8f
Ada comparison            = 0xffffff8f
```

**Result.**

| Bits | Field | `0xfffffb8f` | Ada `0xffffff8f` |
|---|---|---|---|
| `3:0` | `READ_PROTECTION` | `0xf` (all levels) | same |
| `7:4` | `WRITE_PROTECTION` | `0x8` (**PL3 only**) | same |
| `8` | `READ_VIOLATION` | report error | same |
| `9` | `WRITE_VIOLATION` | report error | same |
| `10` | `SOURCE_READ_CONTROL` | 0 = lowered | 1 = blocked |
| `11` | `SOURCE_WRITE_CONTROL` | 1 = blocked | same |
| `31:12` | `SOURCE_ENABLE` | `0xfffff` (**all 20 sources**) | same |

There is no removed source and no hidden `[23:8]` source-enable field. The
source-enable field is `[31:12]` and is fully populated. The only gate is the
write mask, `[7:4] = 8`, which is PL3. The bit-10 difference from Ada is
`SOURCE_READ_CONTROL`, a read-side control, not a writer. The write test in
[01.2](#012-speed-register-write-from-gsp-is-dropped) sees this mask drop the PL2
write.

**Reproduce.**
1. Read `0x00823804` with
   `sudo tools/register-access/regops 1 0000:41:00.0 read`.
2. Decode the value with the field layout in
   [privilege and rate control](../specs/02_privilege-and-rate-control.md); expect
   read mask `0xf` and write mask `0x8`.

**Limits.** The FEAT block is not described in the public headers. The low byte
matches the Falcon v4 layout exactly; the fields above it are applied by analogy.
The decode says which writes the mask admits, not what the hardware does with a
write that passes.

## 01.6 The post-reset window closes before GSP-RM

**Hypothesis.** A PCI function-level reset (FLR) opens a window where the
[PLM](../specs/02_privilege-and-rate-control.md) admits PL2 writes
([the boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md) found it).
If the host opens the device immediately after the bind and boots GSP-RM inside
that window, a PL2 `GPU_EXEC_REG_OPS` write to `SS0`/`SS1` would land. The
[4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) relies on an FLR
leaving its override in place; this experiment asked whether the window could be
used to write the bank.

**Method.** `plm_window_race.sh measure` from
[driver harness](../tools/driver-harness/) performs the unbind and FLR.
`regops plmpoll` from [register access](../tools/register-access/) polls BAR0; it
re-maps `resource0` on every sample so it survives the bind. The poller starts
before the bind and samples the FEAT bank plus GSP `ENGINE` (`0x1103c0`), the reset
PLM (`0x1103c4`), and the host PC mirror (`0x1113ec`). `nvidia-smi -L` triggers
the first open.

```bash
sudo tools/driver-harness/plm_window_race.sh measure 0000:41:00.0
```

**Observed data.** Two runs measured a window; an earlier run missed it:

| Run | First sample | Re-lock | First GSP-RM PC |
|---|---:|---:|---:|
| missed | `0xfffffb8f` | not measured | not logged |
| A | `0x80842bcf` | 1156 ms | not logged |
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

**Result.** The window is 1156 ms in run A and 1323 ms in run B. By
[the boot-window experiment](../experiments/04_hs-sec2-fsp-memory.md), the
boot-image PC can only occupy the ~0.5–0.6 ms before the first GSP-RM PC. The
bind consumes about 1.0 s of the 1.2–1.3 s window; the open→GSP-RM path is about
2.1 s (open inferred at ~1.05 s, GSP-RM at 3.18 s), which cannot fit the window
even with a zero-delay open. The re-lock is 1853 ms before the first GSP-RM PC.

The window closes before the only PL2 master exists. The re-lock is a pre-boot
GPU-side devinit (FSP/PMU/hardware), not the FMC and not GSP-RM;
[the boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md) bracket it.
The "boot the GSP early" variant is retracted because the GSP boot path is longer
than the window. `benign` and `payload` were not run because they cannot win and
would only cost an FLR.

**Reproduce.**
1. With the stock driver loaded, run
   `sudo tools/driver-harness/plm_window_race.sh measure 0000:41:00.0`.
2. Expect `first=0x80842bcf` and a re-lock around 1.1–1.3 s. One run also logged
   the first GSP-RM PC at 3.18 s.

**Limits.** This measures the window and the re-lock time. It does not name the
writer; [the boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md)
bracket that to GPU-side devinit, and
[the cold-boot experiment](../experiments/05_fmc-fsp-boot-inputs.md) covers the
per-boot SS state. The FLR can wedge the card; the
[driver harness](../tools/driver-harness/) README has the recovery note.

## 01.7 Per-context registers need a caller-owned channel

**Hypothesis.** The register-op control accepts more than `GLOBAL`: `GR_CTX`,
`GR_CTX_TPC`, `GR_CTX_SM`, and `GR_CTX_QUAD`. If one of those reached the per-SM
registers, it would give the per-SM selector path described in
[privilege and rate control](../specs/02_privilege-and-rate-control.md). The
earlier passes in [01.2](#012-speed-register-write-from-gsp-is-dropped),
[01.3](#013-the-whole-feat-bank-shares-one-gate), and
[01.4](#014-the-fuse-shadow-and-the-inert-modifier) used `GLOBAL` only.

**Method.** `regops gprobe` and `gprobe_route` from
[register access](../tools/register-access/), plus `gprobe_with_ctx.sh` from
[driver harness](../tools/driver-harness/). I ran as root against `41:00.0`.
`gprobe` reads `0x504204`, `SS0`, `SS1`, and `PLM` under `GLOBAL`, `GR_CTX`,
`GR_CTX_TPC`, `GR_CTX_SM`, `GR_CTX_QUAD`, and `FB`. `gprobe_route` repeats the
`GR_CTX` read with `grRouteInfo.flags` 0–3 (`TYPE_NONE`/`ENGID`/`CHANNEL`/both).
`gprobe_with_ctx.sh` holds a CUDA context on `41:00.0` from plain C (`cuda_ctx.c`,
driver API) while the probe runs, to test whether a live channel is the missing
argument.

```bash
sudo tools/register-access/regops 1 0000:41:00.0 gprobe
sudo tools/driver-harness/gprobe_with_ctx.sh route
```

**Observed data.**

| `regType` | Control status | Per-op values |
|---|---|---|
| `GLOBAL` | 0 | `0x504204=5`, `SS0=0x21265043`, `SS1=0x6`, `PLM=0xfffffb8f` |
| `GR_CTX` | `0x1f` | all 0 |
| `GR_CTX_TPC` | `0x1f` | all 0 |
| `GR_CTX_SM` | `0x1f` | all 0 |
| `GR_CTX_QUAD` | `0x1f` | all 0 |
| `FB` | `0x56` | all 0 |

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

**Result.** The type is recognized (not `INVALID_TYPE`) but the batch is rejected
before execution. `FB` is not supported at all. The leading explanation is that
the GSP needs a channel owned by the calling RM client. A CUDA channel is not
addressable: RM handles are client-scoped, the CUDA client's handle is not
exposed, and the `hClientTarget=0` "all current and future channels" expansion is
not implemented for context ops on this GSP build. The only way to test the
explanation is a channel owned by the calling client (VA space, GPFIFO, UserD,
bind/schedule, a mini RM client) or a kernel hook that issues the op with a
channel handle; the GSP may still reject it. The cheap
[PL0](../specs/02_privilege-and-rate-control.md) route is closed; whether a
caller-owned channel would succeed is open.

**Reproduce.**
1. Run `sudo tools/register-access/regops 1 0000:41:00.0 gprobe`; expect `GLOBAL`
   status 0 with the FEAT values, every `GR_CTX` variant `0x1f`, and `FB` `0x56`.
2. Run `sudo tools/driver-harness/gprobe_with_ctx.sh route`; it holds a CUDA
   context with `cuda_ctx.c` and repeats the probe. Expect the same `0x1f`.
3. For the table decode, extract the GSP-RM `.fwimage` and read the 32-byte
   record at file `0xd16a68`; the handler pointer is the third 8-byte field.

**Limits.** The type is recognized but rejected before execution. The leading
explanation is a caller-owned RM channel; a CUDA context is not addressable. This
closes the cheap PL0 route, not the question of whether a caller-owned channel
would succeed. The status codes are in
[errors and logging](../specs/08_errors-and-logging.md).
