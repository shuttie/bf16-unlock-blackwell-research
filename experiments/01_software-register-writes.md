# Software register writes

Can the host or GSP-RM write the rate registers, and does a success status mean the
write landed? These seven experiments were run on 2026-10-25 to 2026-10-28. Each
record keeps the original hypothesis, method, and result; the observed data is
copied from the run output.

## Setup

Hardware: 2× RTX 5090 (GB202, `10de:2b85`), 575 W, Linux, CUDA 13, driver and
GSP-RM 595.91.07. `deviceId 1` is `41:00.0`; `deviceId 0` is `c1:00.0`.

Tools:

- [Register access](../tools/register-access/) — userspace RM client and shell probes.
- [Issue-rate probe](../tools/issue-rate-probe/) — register-resident tensor rate probe.
- [Driver harness](../tools/driver-harness/) — FLR/rebind window and CUDA-context probes.

Build `regops` once from the repo root:

```bash
gcc -O2 -Wall -o tools/register-access/regops tools/register-access/regops.c
```

Inputs: a live card with the 595.91.07 driver. The static checks read the installed
`nvidia.ko` (decompress the package's `.ko.zst`) and the GSP-RM `.fwimage` (extract
it from `/lib/firmware/nvidia/595.91.07/gsp_ga10x.bin`; the
[GSP-RM tools](../tools/gsp-rm-tools/) README has the extraction command). No
firmware is redistributed.

Boot state and cost: boot clean (`uptime` about a minute, no Xid, both GSPs at
595.91.07) and run as root. A wedged register test needs a forced reboot. Do not
page-scan BAR0 `0x300000`–`0x400000` while the driver owns the card.

Terms:

- **PL0 / PL2 / PL3** — host, GSP-RM, and boot-firmware privilege levels. See
  [privilege and rate control](../specs/02_privilege-and-rate-control.md).
- **PLM** — per-block read/write permission mask. Same spec.
- **FEAT bank / SS0 / SS1** — the rate override registers. See
  [register map](../specs/03_register-map.md).
- **FLR** — PCI function-level reset. See [boot chain](../specs/01_boot-chain.md).
- **BAR0** — the card's MMIO window. See
  [memory and host access](../specs/07_memory-and-host-access.md).
- **GSP-RM** — the main GPU firmware, runs at PL2. See
  [boot chain](../specs/01_boot-chain.md).

## E07 · `GPU_EXEC_REG_OPS` first attempt — invalidated

*2026-10-25 · status: INCONCLUSIVE (superseded by [E08](../experiments/01_software-register-writes.md))*

**Hypothesis.** A GSP-executed write can reach `FEAT_OVR_SM_SS0` and stick.

**Instrument.** `regops` from [register access](../tools/register-access/), a
userspace RM client on `/dev/nvidiactl`; target `deviceId 0` = `c1:00.0`, which was
already fatal. Baseline reads came from a direct BAR0 mmap on `41:00.0`.

**Method.** Allocate an RM client (`0x41`), device (`0x80` with `deviceId`), and
subdevice (`0x2080`), then issue `NV_ESC_RM_CONTROL 0x20800122`. `hRoot` must be the
client handle for child allocations; the device allocation needs
`NV_ESC_REGISTER_FD` on `/dev/nvidiaN` first. The control's `read` mode issues
eight `READ_32` ops; `rate` calls `0x20801230`; `name` calls `0x20800110`.

```bash
sudo tools/register-access/regops 1 0000:41:00.0 read
sudo tools/register-access/regops 1 0000:41:00.0 rate
```

**Observed data.** Baseline from the direct BAR0 read on `41:00.0`:

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
GET_NAME_STRING              -> 0x1F
```

`dmesg -T` showed both GSPs had crashed 36 minutes earlier:

```text
16:13:40  41:00.0  Xid 13 -> Xid 120 -> Xid 154
16:13:47  c1:00.0  same sequence, 7 s later
Xid 120: GSP task exception: load access page fault (cause:0xd) @ pc:0x1368618,
         partition:4#0, stval=0x250
```

**Result.** The control returned `0x62` on every invocation, with no per-op status.
A parameterless getter on the same client returned `NV_OK`. The GSP was already
fatal, so the write question was not tested.

**Reproduce.**
1. Boot the machine and run the two commands above.
2. A clean machine returns `NV_OK` and the register values; a fatal GSP returns
   `0x62` and Xid 120/154 in `dmesg -T`.
3. Retry on `deviceId 1` (`41:00.0`) after a reboot. A clean run is
   [E08](../experiments/01_software-register-writes.md).

**Limits.** This run is invalid as a write test. It shows the failure mode of an
RPC to a fatal GSP, not whether a GSP-executed write can land. The link to the BAR0
page scan is circumstantial. Recovery needed a forced reboot
(`systemctl reboot -f`, or SysRq-B); `nvidia-smi -r` is not supported on GeForce,
and writing the PCI `remove` node can spin.

## E08 · `GPU_EXEC_REG_OPS` second attempt — the write is dropped

*2026-10-25 · status: CLOSED-MEASURED*

**Hypothesis.** A GSP-executed write to `FEAT_OVR_SM_SS0` can stick when the GSP is
healthy.

**Instrument.** `regops` from [register access](../tools/register-access/); target
`deviceId 1` = `41:00.0`, root.

**Method.** After a clean reboot, run four modes: `one` (benign `PMC_BOOT_0`),
`read` (eight `READ_32`), `wr 82381c 0` (`WRITE_32` with `regAndNMask = ~value`,
then `READ_32`), and `sc` (scratch dump plus a positive control).

```bash
sudo tools/register-access/regops 1 0000:41:00.0 one
sudo tools/register-access/regops 1 0000:41:00.0 read
sudo tools/register-access/regops 1 0000:41:00.0 wr 82381c 0
sudo tools/register-access/regops 1 0000:41:00.0 sc
```

**Observed data.** Captured console output, reformatted from the run notes:

```text
one                SUCCESS   PMC_BOOT_0=0x1b2000a1 (matches BAR0)
read               8/8 SUCCESS; GSP values == host BAR0; SS0=0x21240001
wr 82381c 0        SUCCESS; readback=0x21240001; host BAR0=0x21240001
sc  SCRATCH[15]    0x143c: 0x5A5AA5A5 -> 0x5A5AA5A5; 0 -> 0
```

**Result.** The path works and the FEAT write is silently dropped by
`FEAT_OVR_PLM`. Success status cannot distinguish applied from dropped. This is the
negative/positive control pair reused by every later register claim.

**Reproduce.**
1. Boot clean (`uptime` about a minute, no Xid, both GSPs at 595.91.07).
2. Build: `gcc -O2 -Wall -o tools/register-access/regops tools/register-access/regops.c`.
3. Run the four commands in order from the repo root.
4. Expect the FEAT write to report `SUCCESS` while `0x82381c` reads back
   `0x21240001`; the scratch control must change and restore.

**Limits.** Success status does not mean the write landed; the readback is the
evidence. This shows the FEAT bank drops a PL2 write. The gate is decoded in
[E53](../experiments/01_software-register-writes.md).

## E09 · The FEAT bank map and its write gate

*2026-10-25 · status: CLOSED-MEASURED*

**Hypothesis.** Some register in the wider FEAT bank may have a different write
gate; `0x82380c = 0x00888888` was the candidate because it reads as an active
override.

**Instrument.** `regops dump` (non-transactional `READ_32`) and `regops wr`
(`WRITE_32` with `regAndNMask = ~value`, then `READ_32`); target `deviceId 1` =
`41:00.0`, root.

**Method.** Dump 50 dwords from `0x823800`, then write `0x88888888` to `0x82380c`
and read it back.

```bash
sudo tools/register-access/regops 1 0000:41:00.0 dump 823800 50
sudo tools/register-access/regops 1 0000:41:00.0 wr 82380c 88888888
```

**Observed data.** Targeted window, captured map output:

```text
0x00823814 = 0x00000233  status=0 SUCCESS
0x00823818 = 0x00c36180  status=0 SUCCESS
0x0082381c = 0x21240001  status=0 SUCCESS
0x00823820 = 0x00000002  status=0 SUCCESS
```

Wider bank values from the same map:

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

Static scan of the installed 595.91.07 driver (disassembly excerpt, reformatted
from the scan notes):

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
`imm` in `0x3000`–`0x3fff` finds only `0x820c04`, `0x82074c`, `0x823814`, and a
run of unrelated `0x8230xx` registers.

**Result.** All 50 map ops returned `SUCCESS`; unimplemented offsets appear as
`0xBADF5040`, not errors. The `0x88888888` write returned `SUCCESS` and the
readback stayed `0x00888888`. The bank map is in
[the register map](../specs/03_register-map.md).

**Reproduce.**
1. Run the dump and write commands above.
2. Expect `SUCCESS` on every op, `0xBADF5040` at unimplemented offsets, and
   `0x00888888` after the write.
3. For the static scan, decompress the installed `nvidia.ko` and search for the
   two instruction forms; the [register access](../tools/register-access/) README
   has the build and scan notes.

**Limits.** The whole bank is gated; no register in `0x823800`–`0x8238b0` has a
different gate. `0x82380c` is the stock ECC override (`FEAT_OVR_ECC`), not a speed
word ([E56](../experiments/07_plaintext-corpus.md)). This run does not test the
selector words themselves; [E08](../experiments/01_software-register-writes.md)
does.

## E12 · The FUSE/OTP gate and `SM_ISSUE_RATE_MODIFIER`

*2026-10-25 · status: CLOSED-MEASURED (both)*

**Hypothesis.** The FUSE shadow and the GR rate register are either write-gated or
inert.

**Instrument.** `regops wrr` (GSP, one RPC), `regops barw` (host, `resource0`
mmap), `fuse_probe.sh`, and the [issue-rate probe](../tools/issue-rate-probe/)'s
`run_modifier_test.sh`; target `41:00.0`, root.

**Method.** Four FUSE dump batches over `0x820000`–`0x8207ff`, then write, read,
and restore `0x82074c` and `0x8207d8` from both privilege levels. Then write
`0x504204` to 0 from both levels and run the hash-pinned tensor probe with the
register held at 0 after `cuCtxCreate`.

```bash
sudo tools/register-access/regops 1 0000:41:00.0 wrr 82074c 0 1
sudo tools/register-access/regops 1 0000:41:00.0 barw 82074c 0 1
sudo tools/register-access/regops 1 0000:41:00.0 wrr 8207d8 0 3
sudo tools/register-access/regops 1 0000:41:00.0 barw 8207d8 0 3
sudo tools/register-access/regops 1 0000:41:00.0 barw 504204 0 5
sudo tools/register-access/regops 1 0000:41:00.0 wrr 504204 0 5
```

Probe build and wrapper:

```bash
cd tools/issue-rate-probe
python3 build_ptx.py
/usr/local/cuda-13.0/bin/ptxas -arch=sm_120 -O3 \
    -o tensor_modes_issue_sm120.cubin tensor_modes_issue_sm120.ptx
sudo ./run_modifier_test.sh
```

`run_modifier_test.sh` uses:

```text
REGOPS=tools/register-access/regops
DIR=tools/issue-rate-probe
UUID=<your card UUID from nvidia-smi -L>
HASH=099aecf487705caacb24500ef36d41175bdfb650e00bafd57db6caaa17c1cde8
BDF=0000:41:00.0
GPU=1
REG=504204
```

and runs:

```bash
CUDA_VISIBLE_DEVICES="$UUID" timeout 180 python3 tensor_modes_driver_runner.py \
    tensor_modes_issue_sm120.cubin --sha256 "$HASH" --expect-uuid "$UUID" \
    --expect-power-limit 575 --iters 20000 --reps 3 \
    --bdf "$BDF" --reg-offset "0x$REG" --reg-value 0
```

The runner checks the power cap, validates all 270,336 cells per mode, records
clocks and power, then reads back and restores 5.

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

Rate results, reformatted from the probe JSON (best TF/s or TOPS over three reps;
20,000 iterations; 270,336 cells per mode):

```text
baseline (modifier 5):  f16_f32=227.14  bf16_f32=227.10  tf32=113.56  u4_s32=596.46
held at 0:              f16_f32=227.09  bf16_f32=225.88  tf32=112.99  u4_s32=591.10
```

The register log reads 0 at all 17 stages; the cubin is pinned to the hash above.

**Result.** The FUSE writes are dropped from both levels. `SM_ISSUE_RATE_MODIFIER`
is writable, reasserted at CUDA context creation, and inert: the rate does not
move. The page-0 FUSE mask reads write-all but is not the effective gate.

**Reproduce.**
1. Read the FUSE map: `sudo tools/register-access/fuse_probe.sh 1 0000:41:00.0`.
2. Run the four `wrr`/`barw` FUSE commands; expect the values to stay 1 and 3.
3. Build the probe as above, set `UUID` to your card, and run
   `sudo tools/issue-rate-probe/run_modifier_test.sh`; expect the modifier to read
   0 during the probe, be 5 on readback, and the rates to match the baseline
   within run-to-run variance.

**Limits.** The FUSE page-0 mask reads write-all but the shadow is not writable,
so the effective gate is below the PLM. The rate register is writable but
reasserted and inert; this does not make it a selector. The probe has no
FP16-accumulate mode, so it cannot measure the cap ratio locally.

## E53 · The PLM field decode

*2026-10-26 · status: CLOSED-STATIC (corrected)*

**Hypothesis.** The "cleared bit 10 names a removed source" reading of
`FEAT_OVR_PLM = 0xfffffb8f` is wrong; the field layout should be the Falcon v4 PLM
used by the other IP blocks.

**Instrument.** Static decode; no hardware access.

**Method.** Apply the Falcon v4 field layout quoted below to the measured value,
and compare with Ada's `0xffffff8f` and the low-byte semantics already established.
The layout is described in
[privilege and rate control](../specs/02_privilege-and-rate-control.md).

**Observed data.** Measured on `41:00.0`:

```text
FEAT_OVR_PLM (0x00823804) = 0xfffffb8f
Ada comparison            = 0xffffff8f
```

The field macros used for the decode:

```c
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_READ_PROTECTION   3:0
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_WRITE_PROTECTION  7:4
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_READ_PROTECTION_ALL_LEVELS_ENABLED 0x0000000f
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_WRITE_PROTECTION_ONLY_LEVEL3_ENABLED 0x00000008
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_READ_VIOLATION 8:8
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_WRITE_VIOLATION 9:9
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_SOURCE_READ_CONTROL 10:10
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_SOURCE_READ_CONTROL_BLOCKED 0x00000001
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_SOURCE_READ_CONTROL_LOWERED 0x00000000
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_SOURCE_WRITE_CONTROL 11:11
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_SOURCE_ENABLE 31:12
#define NV_PFALCON_FALCON_EXE_PRIV_LEVEL_MASK_SOURCE_ENABLE_ALL_SOURCES_ENABLED 0x000fffff
```

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

There is no removed source and no hidden `[23:8]` source-enable field: the
source-enable field is `[31:12]` and is fully populated. The only gate is the write
mask, `[7:4] = 8`, i.e. PL3. The bit-10 difference from Ada is
`SOURCE_READ_CONTROL`, a read-side control, not a writer.

**Reproduce.**
1. Read `0x00823804` with `tools/register-access/regops 1 0000:41:00.0 read`.
2. Decode the value with the field macros above; expect read mask `0xf` and write
   mask `0x8`.

**Limits.** The FEAT block is not described in the public headers. The low byte
matches the Falcon layout exactly; the fields above it are applied by analogy. The
decode says which writes the mask admits, not what the hardware does with a write
that passes.

## E70 · The post-FLR L2 window: 1.32 s, and no PL2 master inside it

*2026-10-28 · status: CLOSED-MEASURED (early-GSP-boot variant retracted)*

**Hypothesis.** The L2-writable PLM window [E65](../experiments/05_fmc-fsp-boot-inputs.md)
found after an FLR is reachable if the host opens the device immediately after the
bind and boots the GSP-RM inside it: a PL2 `GPU_EXEC_REG_OPS` write to `SS0`/`SS1`
issued then would land.

**Instrument.** `tools/driver-harness/plm_window_race.sh measure` and
`tools/register-access/regops plmpoll`; target `41:00.0`, root.

**Method.** After an unbind and an FLR, a direct BAR0 poller
(`tools/register-access/regops 1 0000:41:00.0 plmpoll 5 6000`, which re-maps
`resource0` on every sample so it survives the bind) starts
before the bind and samples the FEAT bank plus GSP `ENGINE` (`0x1103c0`), the reset
PLM (`0x1103c4`), and the host PC mirror (`0x1113ec`). The bind probe runs across
the window; `nvidia-smi -L` triggers the first open.

```bash
sudo tools/driver-harness/plm_window_race.sh measure 0000:41:00.0
```

**Observed data.** Two runs, labeled A and B for this record. Run A:

```text
samples=1042 first=0x80842bcf last=0xfffffb8f
window opens at t=0 ms (plm=0x80842bcf)
re-lock at t=1156 ms (+1156 ms after open)
```

Run B:

```text
samples=1067 first=0x80842bcf last=0xfffffb8f
boot image PC (0xefd00000-0xefd47000) never seen
GSP-RM first PC (0x93007b16) at t=3176 ms
window opens at t=0 ms (plm=0x80842bcf)
re-lock at t=1323 ms (+1323 ms after open)
```

The first lines of the poll show the pre-bind state:

```text
# t_ms wall_ms plm ss0 ss1 readout1 fusefmla32 engine resetplm pc
0 1793228276872 0x80842bcf 0x21265043 0x00000006 0x00c36180 0x00000003 0xbadf4100 0xbadf4100 0xbadf4100
5 1793228276877 0x80842bcf 0x21265043 0x00000006 0x00c36180 0x00000003 0xbadf4100 0xbadf4100 0xbadf4100
```

After the rebind:

```text
  BAR0 0x00823804 = 0xfffffb8f
  BAR0 0x0082381c = 0x21265043
  BAR0 0x00823820 = 0x00000006
rate getter status = 0 (0)
  imla0=0 fmla16=0 dp=0 fmla32=3 ffma=0 imla1=3 imla2=3 imla3=0 imla4=3
```

**Result.** The first run started the poller after the bind and missed the window
(`first=0xfffffb8f`). The next two measured a window of 1156 ms and 1323 ms. The
boot-image PC was not sampled; by [E68](../experiments/04_hs-sec2-fsp-memory.md) it
can only be the ~0.5–0.6 ms immediately before the first GSP-RM PC. The bind
consumes ~1.0 s of the 1.32 s window; the open→GSP-RM path is ~2.1 s (open inferred
at ~1.05 s → GSP-RM at 3.18 s), which cannot fit the window even with a zero-delay
open. The re-lock is 1853 ms before the first GSP-RM PC.

The window closes before the only PL2 master exists, and the re-lock is a pre-boot
GPU-side devinit (FSP/PMU/hardware), not the FMC and not the GSP-RM. [E65](../experiments/05_fmc-fsp-boot-inputs.md)'s
"the PL2 window is real but not reachable" is confirmed with timing, and the "boot
the GSP early" variant is retracted: the GSP boot path is longer than the window.
`benign`/`payload` were not run because they cannot win; they would only cost an
FLR.

**Reproduce.**
1. With the stock driver loaded, run
   `sudo tools/driver-harness/plm_window_race.sh measure 0000:41:00.0`.
2. Expect `first=0x80842bcf` and a re-lock around 1.1–1.3 s. One run also logged
   the first GSP-RM PC at 3.18 s.
3. If the FLR wedges, reboot. `benign` and `payload` were not run because the
   window closes before GSP-RM exists.

**Limits.** This measures the window and the re-lock time. It does not name the
writer; [E65](../experiments/05_fmc-fsp-boot-inputs.md) brackets that to GPU-side
devinit, and [E64](../experiments/05_fmc-fsp-boot-inputs.md) covers the per-boot SS
state.

## E71 · `GR_CTX`/`GR_CTX_SM`/`FB`: not reachable from PL0 without an RM channel

*2026-10-28 · status: CLOSED-MEASURED (caller-limited)*

**Hypothesis.** `NV2080_CTRL_CMD_GPU_EXEC_REG_OPS` reaches per-context/per-SM
registers through `regType = GR_CTX`, `GR_CTX_TPC`, `GR_CTX_SM`, or `GR_CTX_QUAD`,
giving the per-SM selector path described in
[privilege and rate control](../specs/02_privilege-and-rate-control.md). Every
earlier register pass ([E08](../experiments/01_software-register-writes.md),
[E09](../experiments/01_software-register-writes.md),
[E12](../experiments/01_software-register-writes.md)) used `GLOBAL` only.

**Instrument.** `regops gprobe` and `gprobe_route` from
[register access](../tools/register-access/), and `gprobe_with_ctx.sh` from
[driver harness](../tools/driver-harness/); target `41:00.0`, root.

**Method.** `gprobe` reads `0x504204`, `SS0`, `SS1`, and `PLM` under `GLOBAL`,
`GR_CTX`, `GR_CTX_TPC`, `GR_CTX_SM`, `GR_CTX_QUAD`, and `FB`. `gprobe_route`
repeats the `GR_CTX` read with `grRouteInfo.flags` 0–3
(`TYPE_NONE`/`ENGID`/`CHANNEL`/both). `gprobe_with_ctx.sh` holds a CUDA context on
`41:00.0` from plain C (`cuda_ctx.c`, driver API) while the probe runs, to test
whether a live channel is the missing argument.

```bash
sudo tools/register-access/regops 1 0000:41:00.0 gprobe
sudo tools/driver-harness/gprobe_with_ctx.sh route
```

**Observed data.** From the probe output:

```text
gprobe GLOBAL       status=0
  0x00504204 = 0x00000005 status=0 SUCCESS
  0x0082381c = 0x21265043 status=0 SUCCESS
  0x00823820 = 0x00000006 status=0 SUCCESS
  0x00823804 = 0xfffffb8f status=0 SUCCESS
gprobe GR_CTX       status=0x1f
  0x00504204 = 0000000000 status=0 SUCCESS
  0x0082381c = 0000000000 status=0 SUCCESS
  0x00823820 = 0000000000 status=0 SUCCESS
  0x00823804 = 0000000000 status=0 SUCCESS
gprobe GR_CTX_TPC   status=0x1f
  0x00504204 = 0000000000 status=0 SUCCESS
  0x0082381c = 0000000000 status=0 SUCCESS
  0x00823820 = 0000000000 status=0 SUCCESS
  0x00823804 = 0000000000 status=0 SUCCESS
gprobe GR_CTX_SM    status=0x1f
  0x00504204 = 0000000000 status=0 SUCCESS
  0x0082381c = 0000000000 status=0 SUCCESS
  0x00823820 = 0000000000 status=0 SUCCESS
  0x00823804 = 0000000000 status=0 SUCCESS
gprobe GR_CTX_QUAD  status=0x1f
  0x00504204 = 0000000000 status=0 SUCCESS
  0x0082381c = 0000000000 status=0 SUCCESS
  0x00823820 = 0000000000 status=0 SUCCESS
  0x00823804 = 0000000000 status=0 SUCCESS
gprobe FB           status=0x56
  0x00504204 = 0000000000 status=0 SUCCESS
  0x0082381c = 0000000000 status=0 SUCCESS
  0x00823820 = 0000000000 status=0 SUCCESS
  0x00823804 = 0000000000 status=0 SUCCESS
```

The route run repeats `GR_CTX` with flags 0–3:

```text
gprobe_route flags=0 route=0 status=0x1f
gprobe_route flags=1 route=0 status=0x1f
gprobe_route flags=2 route=0 status=0x1f
gprobe_route flags=3 route=0 status=0x1f
```

The ctrl-table entry for `0x20800122` (captured from the installed GSP-RM image):

```text
file 0xd16a68, VA 0x01d16a68:
22 01 80 20 30 00 00 00 48 27 b9 01 00 00 00 00 40 07 40 01 00 00 00 00 09 01 00 00 00 00 00 00
ctrlId=0x20800122  paramSize=0x30  classPtr=0x01b92748
handlerPtr=0x01400740  flags=0x00000109
```

At the handler target (Ghidra VA `0x1400740`, file `0x400740`):

```text
11 00 97 47 ef 02 83 b7 67 45   (first 10 bytes)
^ 2-byte RVC HINT/nop; the first real instruction starts at 0x400742:
97 47 ef 02  = auipc a5, 0x2ef4
```

The handler pointer is therefore two bytes before the first instruction, which is
why the table entry does not decode as a function start.

**Result.** The type is recognized (not `INVALID_TYPE`) but the batch is rejected
before execution; `FB` is not supported at all. The leading explanation is that
the GSP needs a channel owned by the calling RM client. A CUDA channel is not
addressable: RM handles are client-scoped, the CUDA client's handle is not exposed,
and the `hClientTarget=0` "all current and future channels" expansion is not
implemented for context ops on this GSP build. The only way to test the explanation
is a channel owned by our client (VA space + GPFIFO + UserD + bind/schedule, a mini
RM client) or a kernel hook that issues the op with a channel handle; the GSP may
still reject it. The cheap PL0 route is closed; whether a caller-owned channel
would succeed is open.

**Reproduce.**
1. `sudo tools/register-access/regops 1 0000:41:00.0 gprobe`; expect `GLOBAL`
   status 0 with the FEAT values, all `GR_CTX` variants `0x1f`, and `FB` `0x56`.
2. `sudo tools/driver-harness/gprobe_with_ctx.sh route`; it holds a CUDA context
   with `cuda_ctx.c` and repeats the probe. Expect the same `0x1f`.
3. For the table decode, extract the GSP-RM `.fwimage` and read the 32-byte record
   at file `0xd16a68`; the handler pointer is the third 8-byte field.

**Limits.** The type is recognized but rejected before execution. The leading
explanation is a caller-owned RM channel; a CUDA context is not addressable. This
closes the cheap PL0 route, not the question of whether a caller-owned channel
would succeed.
