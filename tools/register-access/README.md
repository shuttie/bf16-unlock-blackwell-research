# Register access

## At a glance

- **What.** `regops` is a userspace client for `NV2080_CTRL_CMD_GPU_EXEC_REG_OPS`
  ([the PL2 write test](../../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)).
  It opens `/dev/nvidiactl`, allocates an RM client, device, and subdevice, and
  issues 32/64-bit register reads and writes through the driver. GSP-RM
  ([PL2](../../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm))
  is the bus master, so a write through this path is a PL2 write, not a host
  BAR0 write.
- **Access.** Read/write.
- **Requirements.** A live card with the stock driver, root, `/dev/nvidiactl`,
  and the matching `/dev/nvidiaN`. No firmware images or dumps are needed.

**The short version.**

- The client covers the FEAT and FUSE banks, the GSP Falcon block, the GSP EMEM
  port, and the PRISCV/ICD window
  ([the FECS/SEC2 probe](../../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)).
- `read` and the probe wrappers are read-only; `wr`, `wrr`, `barw`,
  `ememstream`, and `race` write.
- `SUCCESS` is not proof that a write landed; read the register back. The FEAT
  bank drops PL2 writes silently
  ([the write test](../../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)).
- The wrappers write timestamped logs under `$OUTDIR`.

**In this file.**

- [What it does](#what-it-does)
- [Layout](#layout)
- [Build](#build)
- [Target mapping](#target-mapping)
- [Modes](#modes)
- [Run](#run)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Access](#access)
- [Examples](#examples)
- [Limits](#limits)
- [Related](#related)

## What it does

`regops` is a small userspace client for `NV2080_CTRL_CMD_GPU_EXEC_REG_OPS`. It
opens `/dev/nvidiactl`, allocates an RM client, device, and subdevice, and issues
32/64-bit register reads and writes through the driver. The GSP-RM firmware is the
bus master, so a write through this path is a PL2 write, not a host BAR0 write.
The shell wrappers cover the GSP Falcon block, the FUSE bank, the GSP EMEM port,
and the RISC-V debug block.

The same client is used in:

- [the FEAT-bank map](../../experiments/01_software-register-writes.md#013-the-whole-feat-bank-shares-one-gate),
- [the FUSE and rate-modifier tests](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier),
- [the FECS/SEC2 probe](../../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes),
- [the FSP EMEM test](../../experiments/04_hs-sec2-fsp-memory.md#042-fsp-emem-pointer-writes-are-dropped),
- [the PRISCV split map](../../experiments/04_hs-sec2-fsp-memory.md#043-priscv-block-is-split-per-master),
- [the live ICD](../../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port),
- and [the GR_CTX probe](../../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel).

## Layout

| File | Purpose |
|---|---|
| `regops.c` | The client: RM allocation, register-op batches, BAR0 helpers, probes |
| `gsp_probe.sh` | Read-only dump of the GSP Falcon/PRISCV register window |
| `fuse_probe.sh` | Read-only map of the FUSE/OTP window, with a `PMC_BOOT_0` sanity check |
| `gsp_emem.sh` | Arm the GSP EMEM port and read 256 bytes; stops if the arm is dropped |
| `gsp_emem_stream.sh` | Stream the 8 KB GSP EMEM window |
| `gsp_emem_write.sh` | Write/read discriminator: write, read back, neighbour control, restore |
| `riscv_dm_probe.sh` | Read-only PRISCV/ICD sweep with a collapsed map and known-offset check |

## Build

```bash
gcc -O2 -Wall -o regops regops.c
```

There are no dependencies beyond libc and the installed NVIDIA driver ABI. Build
in this directory; the wrappers default to `./regops`.

## Target mapping

| `deviceId` | BDF | Notes |
|---:|---|---|
| `1` | `0000:41:00.0` | The primary card in the register-write experiments |
| `0` | `0000:c1:00.0` | The second card |

`regops <deviceId> <bdf> <mode>`. The wrappers take `[gpu_index] [bdf]` and also
read `GPU` and `BDF` from the environment. `REGOPS` overrides the binary path;
`OUTDIR` overrides where the wrappers write their logs.

Script defaults differ: `gsp_probe.sh` and the `gsp_emem*` wrappers use deviceId
`0` / `c1:00.0`; `fuse_probe.sh` uses `1` / `41:00.0`; `riscv_dm_probe.sh` uses
`DEVID` (default `1`). Pass the arguments or set `GPU`/`BDF`/`DEVID` to override.

## Modes

| Mode | What it does |
|---|---|
| `one` | Read [`PMC_BOOT_0`](../../specs/03_register-map.md#chip-wpr-and-boot-targets) as a benign connectivity check |
| `read` | Eight `READ_32` ops over the [FEAT](../../specs/03_register-map.md#feat-bank)/[FUSE](../../specs/03_register-map.md#fuse-and-otp) window |
| `write` | Explicit single-write test; set `regAndNMask = ~value` |
| `rate`, `ratev2`, `throttle`, `name` | RM getters for the [issue-rate selector](../../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view) and clock throttle |
| `sc` | Dump a PBUS scratch register, then write/read/restore a control value |
| `dump <base> <count>` | Non-transactional `READ_32` sweep; counts are hex |
| `rep <off> <count>` | Read the same offset `count` times; used after arming an EMEM port |
| `wr <off> <val>` | `WRITE_32` then `READ_32`; both arguments are hex |
| `wrr <off> <new> <orig>` | Write/new, read, restore/orig, read, in one RPC |
| `bar <off> [count]` | Direct [BAR0](../../specs/07_memory-and-host-access.md#bar0-and-bar1) read through `resource0` |
| `barw <off> <new> <orig>` | Direct BAR0 write and restore through `resource0` |
| `ememstream <ctrl> <data> <new> <orig> <count>` | Arm an EMEM channel and stream it |
| `gprobe`, `gprobe_route` | Probe `GLOBAL`, `GR_CTX`, `GR_CTX_TPC`, `GR_CTX_SM`, `GR_CTX_QUAD`, `FB` |
| `gr <type> <off> <count>`, `gw <type> <off> <new> <orig>` | Typed GR register read/write |
| `plmpoll <interval_ms> <count>` | Direct BAR0 [PLM](../../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) poller; read-only |
| `race <new0> <orig0> <new1> <orig1>` | Two-write race helper used by [the reset-window experiment](../../experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm) |

The `gprobe`/`gr` `regType` values are `0=GLOBAL`, `1=GR_CTX`, `2=GR_CTX_TPC`,
`4=GR_CTX_SM`, `0x20=FB`, `0x40=GR_CTX_QUAD`, `0x80=DEVICE`. The per-context
types are rejected without a caller-owned RM channel
([the GR_CTX probe](../../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).

## Run

```bash
# connectivity, then the FEAT/FUSE window
sudo ./regops 1 0000:41:00.0 one
sudo ./regops 1 0000:41:00.0 read

# GSP-side write/readback of SS0
sudo ./regops 1 0000:41:00.0 wr 82381c 0

# positive control: scratch write and restore
sudo ./regops 1 0000:41:00.0 sc

# the wrappers
sudo ./gsp_probe.sh 1 0000:41:00.0
sudo ./fuse_probe.sh 1 0000:41:00.0
sudo ./gsp_emem.sh 0 0000:c1:00.0
sudo ./gsp_emem_stream.sh 0 0000:c1:00.0 0 2048
sudo ./gsp_emem_write.sh 0 0000:c1:00.0
sudo ./riscv_dm_probe.sh
```

The wrappers write timestamped logs under `$OUTDIR` (default `./runs`) and print
the path at the end. `riscv_dm_probe.sh` also prints a collapsed map and a
known-offset check to stdout.

## Inputs

A live card with the stock driver loaded, root, and `/dev/nvidiactl` plus the
matching `/dev/nvidiaN`. No firmware images or dumps are needed. Run on a clean
boot; a fatal GSP returns
[`NV_ERR_RESET_REQUIRED` (`0x62`)](../../specs/08_errors-and-logging.md#nv-status-codes)
for every RPC.

## Outputs

Register offsets, values, control status, and per-op status on stdout. The
wrappers add a raw log in `$OUTDIR`. Unimplemented blocks read as
[`0xBADF5040`](../../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads);
the [register map](../../specs/03_register-map.md) has the full list.

## Access

Read/write. `wr`, `wrr`, `barw`, `ememstream`, and `race` write; `one`, `read`,
`dump`, `rep`, `bar`, `gsp_probe.sh`, `fuse_probe.sh`, and `riscv_dm_probe.sh`
only read. A blind write can wedge the card; `wrr`/`barw` restore the original
value, but a wrong target does not. Expect one reboot if a write or scan wedges
the GSP. The [BAR0 hazards](../../specs/07_memory-and-host-access.md#bar0-and-bar1)
are the same ones the direct probes hit.

## Examples

A PL2 write that reports success and is dropped
([the write test](../../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)):

```text
one                SUCCESS   PMC_BOOT_0=0x1b2000a1 (matches BAR0)
read               8/8 SUCCESS; GSP values == host BAR0; SS0=0x21240001
wr 82381c 0        SUCCESS; readback=0x21240001; host BAR0=0x21240001
sc  SCRATCH[15]    0x143c: 0x5A5AA5A5 -> 0x5A5AA5A5; 0 -> 0
```

The [`SS0`](../../specs/03_register-map.md#ss0-and-ss1) value in that trace is
the same `FEAT_OVR_SM_SS0` shown in [the write
example](../../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped).

The FUSE shadow and the GR rate register
([the FUSE/rate test](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)):

```text
0x008200fc FUSE_SS_PLM              = 0xfffffbff
0x0082074c OPT_SECURE_GSP_DEBUG_DIS = 1
0x008207d8 FUSE_SS_FMLA32           = 3

0x0082074c: host 1 -> 1   GSP 1 -> 1
0x008207d8: host 3 -> 3   GSP 3 -> 3
0x00504204: host 5 -> 0 -> 5   GSP 5 -> 0 -> 5

baseline (modifier 5):  f16_f32=227.14  bf16_f32=227.10  tf32=113.56  u4_s32=596.46
held at 0:              f16_f32=227.09  bf16_f32=225.88  tf32=112.99  u4_s32=591.10
```

The FUSE page-0 mask is `FUSE_SS_PLM`
([FUSE block](../../specs/03_register-map.md#fuse-and-otp)); the rate register is
`SM_ISSUE_RATE_MODIFIER` (`0x504204`)
([RM getter](../../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)).

`GR_CTX` and `FB` are rejected
([the GR_CTX probe](../../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)):

```text
gprobe GLOBAL       status=0
  0x00504204 = 0x00000005 status=0 SUCCESS
  0x0082381c = 0x21265043 status=0 SUCCESS
  0x00823820 = 0x00000006 status=0 SUCCESS
  0x00823804 = 0xfffffb8f status=0 SUCCESS
gprobe GR_CTX       status=0x1f
gprobe GR_CTX_TPC   status=0x1f
gprobe GR_CTX_SM    status=0x1f
gprobe GR_CTX_QUAD  status=0x1f
gprobe FB           status=0x56
```

The `0x1f` and `0x56` codes are in [the NV status-code
table](../../specs/08_errors-and-logging.md#nv-status-codes).

## Limits

`SUCCESS` does not mean a write landed; the readback is the evidence. The
per-context/per-SM register space is not reachable without a channel owned by the
calling RM client
([the GR_CTX probe](../../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).
The GR rate register is writable but reasserted at context creation and inert
([the FUSE/rate test](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
This tool reads and writes registers; it does not flash firmware.

## Related

- [Register writes](../../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped),
  [FEAT bank](../../experiments/01_software-register-writes.md#013-the-whole-feat-bank-shares-one-gate),
  [FUSE and rate modifier](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier),
  [GR_CTX](../../experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)
- [FECS/SEC2 probe](../../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes),
  [FSP EMEM](../../experiments/04_hs-sec2-fsp-memory.md#042-fsp-emem-pointer-writes-are-dropped),
  [PRISCV split](../../experiments/04_hs-sec2-fsp-memory.md#043-priscv-block-is-split-per-master),
  [live ICD](../../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)
- [Privilege and rate control](../../specs/02_privilege-and-rate-control.md): PL0/PL2/PL3, PLM, selectors
- [Register map](../../specs/03_register-map.md): offsets and stock values
- [GSP RISC-V and PRISCV](../../specs/06_gsp-riscv-and-priscv.md): ICD registers
- [Direct probe](../direct-probe/): the same blocks without the driver
- [Driver harness](../driver-harness/): the oracles that use this client
