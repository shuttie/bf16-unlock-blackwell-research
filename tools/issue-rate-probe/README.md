# Issue-rate probe

## At a glance

- **What it measures.** The tensor-core issue rate of the FP32-accumulate path
  on `sm_120` (RTX 5090), with no memory traffic. Every input is exactly one
  except the FP16-accumulate mode, which uses 1/16; each warp keeps eight
  accumulator chains in flight, and every output cell is validated against the
  expected sum.
- **Access.** Read/write. The plain runner reads telemetry; with `--reg-offset`
  it writes a BAR0 register. The modifier wrapper writes `0x504204` and
  restores 5.
- **Requirements.** A live RTX 5090 (`sm_120`) and CUDA 13. No firmware, dumps,
  or proprietary images.

**The short version.**

- Four default modes: FP16→FP32, BF16→FP32, TF32→FP32, and U4→S32. `--f16-f16`
  adds the FP16-accumulate control.
- It measures issue rate, not GEMM throughput. The two-card run is [the
  same-boot issue-rate
  probe](../../experiments/08_assessment-and-cross-checks.md#083-same-boot-two-card-issue-rate-probe).
- The FP16-accumulate control is what makes the cap visible: on a PRO 6000 it
  matches FP16→FP32, while the 5090's external FP16→FP16 number is about twice
  its FP16→FP32 rate; see [the cap
  section](../../specs/02_privilege-and-rate-control.md#the-cap-is-product-segmentation).
- `SM_ISSUE_RATE_MODIFIER` (`0x504204`) is writable but reasserted and inert.
  Holding it at 0 does not move the measured rate; see [the modifier
  test](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier).

**In this file.**

- [Modes](#modes)
- [Layout](#layout)
- [Build](#build)
- [Run](#run)
- [Inputs](#inputs)
- [Output](#output)
- [Access](#access)
- [Related](#related)
- [License](#license)

## Modes

| Mode | Instruction | Accumulator |
|---|---|---|
| `f16_f32` | `mma.sync.m16n8k16.f32.f16.f16.f32` | FP32 |
| `f16_f16` | `mma.sync.m16n8k16.f16.f16.f16.f16` | FP16 |
| `bf16_f32` | `mma.sync.m16n8k16.f32.bf16.bf16.f32` | FP32 |
| `tf32` | `mma.sync.m16n8k8.f32.tf32.tf32.f32` | FP32 |
| `u4_s32` | `mma.sync.m16n8k64.s32.u4.u4.s32` | S32 |

The FP16-accumulate mode is opt-in. It uses 1/16 inputs so the half accumulator
stays exact; it grows by 1/16 per MMA and stalls at 128 once the increment falls
below half an ulp. Validate it at 2000 iterations with `--f16-f16`; a
20000-iteration run is for timing only and will not match the expected cell.

## Layout

| File | Role |
|---|---|
| `tensor_modes_issue_sm120.cu` | Five device kernels, one per mode |
| `build_ptx.py` | Compiles the `.cu` to PTX through NVRTC |
| `tensor_modes_driver_runner.py` | Loads a hash-pinned cubin through the CUDA Driver API, runs each mode, validates cells, records telemetry |
| `run_modifier_test.sh` | Sets [`SM_ISSUE_RATE_MODIFIER`](../../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)=0, runs the probe, reads back, restores 5 |

## Build

CUDA 13 is required. If it is not in `/usr/local/cuda`, set `CUDA_HOME`.

```bash
export CUDA_HOME=/usr/local/cuda
python3 build_ptx.py
"$CUDA_HOME/bin/ptxas" -arch=sm_120 -O3 \
    -o tensor_modes_issue_sm120.cubin tensor_modes_issue_sm120.ptx
sha256sum tensor_modes_issue_sm120.cubin
```

`build_ptx.py` uses NVRTC because `nvcc` 13 rejects GCC 15's `noexcept` math
declarations. The PTX and cubin are build products and are not committed.

## Run

Manual, read-only:

```bash
CUDA_VISIBLE_DEVICES=<uuid> python3 tensor_modes_driver_runner.py \
    tensor_modes_issue_sm120.cubin --sha256 <hash> --expect-uuid <uuid> \
    --expect-power-limit 575 --iters 20000 --reps 3
```

The runner requires the exact GPU UUID and power limit, checks the cubin SHA-256,
and prints one JSON object. Use your card's power cap for `--expect-power-limit`.

The FP16-accumulate control needs the shorter validated run:

```bash
CUDA_VISIBLE_DEVICES=<uuid> python3 tensor_modes_driver_runner.py \
    tensor_modes_issue_sm120.cubin --sha256 <hash> --expect-uuid <uuid> \
    --expect-power-limit <power-limit> --f16-f16 --iters 2000 --reps 5
```

Modifier test, as root:

```bash
sudo UUID=<uuid> BDF=0000:41:00.0 GPU=1 ./run_modifier_test.sh
```

The wrapper builds the register path from `../register-access/regops`, sets
[`0x504204`](../../specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)=0,
runs the probe with the register poked after `cuCtxCreate` and before every
launch, reads it back, and restores `5`. `HASH`, `BDF`, `GPU`, `REG`, and
`POWER_LIMIT` can be overridden through the environment.

## Inputs

- A live RTX 5090 (`sm_120`) with CUDA 13.
- The target GPU UUID (`nvidia-smi --query-gpu=uuid`).
- The card's power limit.
- No firmware, dumps, or proprietary images.

## Output

The runner prints JSON with per-mode timings, rates, cells checked, mismatches,
telemetry, and the register log. A trimmed example:

```json
{
  "gpu": "NVIDIA GeForce RTX 5090, ..., 595.91.07, 575.00",
  "cubin_sha256": "<hash>",
  "iters": 20000,
  "reps": 3,
  "blocks": 1056,
  "threads": 256,
  "chains": 8,
  "f16_f16": false,
  "modes": {
    "f16_f32":  {"best_Top_per_s": 227.14, "cells_checked": 270336, "mismatches": 0},
    "bf16_f32": {"best_Top_per_s": 227.10, "cells_checked": 270336, "mismatches": 0},
    "tf32":     {"best_Top_per_s": 113.56, "cells_checked": 270336, "mismatches": 0},
    "u4_s32":   {"best_Top_per_s": 596.46, "cells_checked": 270336, "mismatches": 0}
  },
  "reg": {"offset": "0x504204", "value": 0, "log": []}
}
```

Expected ranges at stock clocks, from the experiments:

| Mode | Baseline | Held at `0x504204=0` |
|---|---:|---:|
| FP16 → FP32 | 227.1 TF/s | 227.1 TF/s |
| BF16 → FP32 | 227.1 TF/s | 225.9 TF/s |
| TF32 → FP32 | 113.6 TF/s | 113.0 TF/s |
| U4 → S32 | 596.5 TOPS | 591.1 TOPS |
| FP16 → FP16 | 441.4 TF/s (5090, external) | not tested |

The two-card run measured 226.6 / 229.6 TF/s on the FP32-accumulate path, with
the four default modes agreeing within 0.23% per clock. The small differences
above are run-to-run clock variance. Each mode checks 270,336 cells and expects
zero mismatches; see [the two-card issue-rate
run](../../experiments/08_assessment-and-cross-checks.md#083-same-boot-two-card-issue-rate-probe)
and [the modifier
test](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier).

On a PRO 6000 the same probe measured 518.0 TF/s BF16 → FP32, 520.7 TF/s
FP16 → FP32, and 515.0 TF/s FP16 → FP16, so the FP32-accumulate path is not
capped there; see [the PRO 6000 reference
dump](../../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump).

## Access

Read/write. The plain runner reads telemetry and, with `--reg-offset`, writes a
BAR0 register; the wrapper writes `0x504204` and restores `5`. No known wedge in
normal use, but any blind register write on a live GPU can require a reboot.

## Related

- [The modifier test](../../experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)
- [The two-card issue-rate run](../../experiments/08_assessment-and-cross-checks.md#083-same-boot-two-card-issue-rate-probe)
- [The PRO 6000 reference dump](../../experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)
- [The cap and selector chain](../../specs/02_privilege-and-rate-control.md#the-cap-is-product-segmentation)
- [Register access](../register-access/): the `regops` client used by the wrapper

## License

`tensor_modes_issue_sm120.cu` and `tensor_modes_driver_runner.py` carry
`SPDX-License-Identifier: GPL-2.0-only`; the build and wrapper scripts are part
of the same tool. Treat this directory as GPL-2.0-only.
