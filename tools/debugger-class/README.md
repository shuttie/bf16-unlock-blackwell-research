# Debugger class

## At a glance

- **What.** Two CUDA probes with `LD_PRELOAD` hooks for the `GT200_DEBUGGER`
  (`0x83de`) class. The command census rides the debugger object the CUDA
  driver already allocated and issues the non-register commands: SM error
  states, mappings, surface reads, memory reads, and the mode getters
  ([the command census](../../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)).
  The register census issues read-only `EXEC_REG_OPS` through the same
  object: the engine-map scan, the follow-up reads, and the per-card table
  dump ([the engine-map census](../../experiments/14_engine-map-census.md)).
- **Access.** Read-only by default. `C27_SUSPEND=1` suspends and resumes the
  CUDA context; a refused command can drop the context. The register census
  carries a `PMC_BOOT_0` canary and an RM-status check in every batch; two
  BAR0 read windows crash GSP-RM through this path and are skipped by
  design ([the read that crashes
  GSP-RM](../../experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm)).
- **Requirements.** A live card with the stock driver, CUDA 13, and the
  issue-rate cubin (or `C27_CUBIN` pointing at your own). No root and no driver
  tree.

**The short version.**

- The probe creates a CUDA context, allocates a buffer with a known pattern,
  launches one BF16 kernel so the GR context is resident, and calls the hook.
- The hook tracks `NV_ESC_RM_ALLOC`, captures the `0x83de` object, derives the
  debuggee channel from the compute object, and prints one line per command.
- `C27_DEVICE` picks the GPU. `C27_DUMP` prints the first readable object per
  class; `C27_SCAN` searches readable objects for the rate words; `C27_SUSPEND`
  adds the context suspend/resume pair.
- The memory reads are scoped to the CUDA client's handle database. The
  measured result and the command map are in
  [the census](../../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)
  and [the debugger-class spec](../../specs/10_debugger-class.md).

**In this file.**

- [What it does](#what-it-does)
- [Layout](#layout)
- [Build](#build)
- [Run](#run)
- [Environment](#environment)
- [Inputs and outputs](#inputs-and-outputs)
- [Access](#access)
- [Example](#example)
- [Related](#related)
- [License](#license)

## What it does

`c27_probe` is a small CUDA driver-API program. It creates a context, allocates
a 64 KiB device buffer filled with a `0xC2 0x7C` pattern, loads the issue-rate
cubin, launches `bench_bf16_f32` once, and calls `c27_run()`. The kernel launch
is what makes the GR context resident, so the SM-state commands have a target.

`c27_hook.so` interposes `ioctl`. It records the CUDA driver's
`NV_ESC_RM_ALLOC` requests, captures the `GT200_DEBUGGER` allocation and its
`hAppClient` and `hClass3dObject`, and resolves the debuggee channel from the
compute object's parent. `c27_run()` then issues the commands on that object
with the CUDA client and prints the status and any returned data
([the allocation model](../../specs/10_debugger-class.md#the-class-and-its-allocation-model)).

The census covers:

- `GET_HANDLES`, the MMU and ERRbar mode getters;
- single and all-SM error states, the single-SM debugger status, and MMU fault
  info;
- `GET_MAPPINGS` over the low VAS, the buffer's range, and a high range;
- `READ_SURFACE` at the buffer and at candidate RM/engine VAs;
- `READ_MEMORY` and `READ_BATCH_MEMORY` against the buffer and non-Memory
  controls;
- optional `SUSPEND_CONTEXT` and `RESUME_CONTEXT`.

## Layout

| File | Purpose |
|---|---|
| `c27_hook.c` | The `LD_PRELOAD` hook: allocation tracker, debugger capture, command census |
| `c27_probe.c` | The CUDA driver-API probe: context, buffer, kernel launch, `c27_run()` |
| `run_c27.sh` | Builds both, runs one census, writes a timestamped log |
| `rm_debug_hook.c` | The register-census hook: canary batches, falcon-signature scan, naming pass, coarse map, table dump |
| `cuda_ctx_probe.c` | The register-census probe: context create, nothing else |
| `run_census_probe.sh` | Builds the register census, runs it pinned to one card |

## Build

```bash
gcc -O2 -Wall -shared -fPIC -o c27_hook.so c27_hook.c -ldl
gcc -O2 -Wall -o c27_probe c27_probe.c \
    -I/usr/local/cuda/include -L/usr/local/cuda/lib64 -lcuda
```

`run_c27.sh` does both steps.

## Run

```bash
./run_c27.sh
```

The script builds, runs the probe with `LD_PRELOAD`, and writes
`runs/c27_<timestamp>/probe.out` and `census.log`. It does not need root.

## Environment

| Variable | Meaning |
|---|---|
| `C27_DEVICE` | CUDA device index; default `0` |
| `C27_CUBIN` | Cubin for the resident-kernel launch; default `../issue-rate-probe/tensor_modes_issue_sm120.cubin` |
| `C27_DUMP` | `1` prints the first readable object of each class and probes its size |
| `C27_SCAN` | `1` scans the first 256 KiB of every readable object for the FEAT, PLM, and selector words |
| `C27_SUSPEND` | `1` adds `SUSPEND_CONTEXT` and `RESUME_CONTEXT` at the end |

## Inputs and outputs

Inputs are the CUDA device and the cubin. Outputs are the two log files under
`runs/`. Raw logs stay local; the published result is the experiment record.

## Access

The default run is read-only apart from creating a CUDA context and a kernel
launch. `C27_SUSPEND=1` changes context state. A command the GSP path refuses
can drop the CUDA context; the probe process exits, and the card does not need a
reboot.

## Example

```text
C27 GET_HANDLES                                status=0x56
C27 READ_ALL_SM_ERROR_STATES sm0..99           status=0
C27   all-sm0: SMs=100 nonzero_words=0 pattern_hits=0 ...
C27 GET_MAPPINGS 0x0-0x10000000000             status=0
C27   mappings count=0 hasMore=0
C27 READ_SURFACE                               status=0x1f
C27 READ_MEMORY h=0x5c00008c cls=0x40          status=0
C27   PATTERN at h=0x5c00008c off=0
```

## Related

- Experiment: [the command census](../../experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path).
- Spec: [the debugger class](../../specs/10_debugger-class.md).
- Sibling tool: [issue-rate probe](../issue-rate-probe/) for the cubin.
- Register path: [register access](../register-access/) for the same FEAT bank
  without CUDA.

## License

MIT.

## Register census mode

```bash
gcc -O2 -Wall -shared -fPIC -o rm_debug_hook.so rm_debug_hook.c -ldl
CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=0 RM_DEBUG_CENSUS=1 LD_LIBRARY_PATH=/usr/local/cuda/lib64 LD_PRELOAD=./rm_debug_hook.so     ./cuda_ctx_probe 2> census.log
```

`RM_DEBUG_CENSUS=1` runs the full census: the dense follow-ups, the
falcon-signature scan over every `0x1000`-aligned base below `0x1000000`,
the BAR0-top probe, the per-card `0x1f2000` dump, and the `0x100`-stride
map from `0x500000` up. `RM_DEBUG_CENSUS_NAME`, `RM_DEBUG_CENSUS_1F2`, and
`RM_DEBUG_CENSUS_B` (with `CENSUS_B_START`/`CENSUS_B_END`) run one part in
a fresh client. Every batch re-reads `PMC_BOOT_0` as a canary and checks
the RM control status; a mismatch prints `CENSUS ABORT` and stops the run
instead of returning silent zeros. The older `RM_DEBUG_FALCON`, `GRWIN`,
`GRBLK`, and `GRMAP` modes reproduce the experiment-11 probes.

Read-only, no root. The scan skips `0x300000`–`0x400000` and the
`0x42f804`–`0x500000` band; two measured read windows in that band crash
GSP-RM (Xid 120), so do not widen the ranges without a sacrificial card.
