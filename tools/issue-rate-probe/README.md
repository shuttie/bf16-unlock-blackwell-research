# Issue-rate probe

A register-resident tensor-core probe for `sm_120` (RTX 5090). It measures the
instruction issue rate of the FP32-accumulate path without memory traffic: every
input is exactly one, each warp keeps eight accumulator chains in flight, and
the kernel validates every output cell against the expected sum.

Modes:

| Mode | Instruction | Accumulator |
|---|---|---|
| `f16_f32` | `mma.sync.m16n8k16.f32.f16.f16.f32` | FP32 |
| `bf16_f32` | `mma.sync.m16n8k16.f32.bf16.bf16.f32` | FP32 |
| `tf32` | `mma.sync.m16n8k8.f32.tf32.tf32.f32` | FP32 |
| `u4_s32` | `mma.sync.m16n8k64.s32.u4.u4.s32` | S32 |

There is no FP16-accumulate mode here. The local cap ratio is therefore inferred
from the external full-rate number and the local FP32-accumulate baseline; see
[the privilege and rate-control spec](../../specs/02_privilege-and-rate-control.md).

## Layout

| File | Role |
|---|---|
| `tensor_modes_issue_sm120.cu` | Four device kernels, one per mode |
| `build_ptx.py` | Compiles the `.cu` to PTX through NVRTC |
| `tensor_modes_driver_runner.py` | Loads a hash-pinned cubin through the CUDA Driver API, runs each mode, validates cells, records telemetry |
| `run_modifier_test.sh` | Sets `SM_ISSUE_RATE_MODIFIER=0`, runs the probe, reads back, restores 5 |

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

Modifier test, as root:

```bash
sudo UUID=<uuid> BDF=0000:41:00.0 GPU=1 ./run_modifier_test.sh
```

The wrapper builds the register path from `../register-access/regops`, sets
`0x504204=0`, runs the probe with the register poked after `cuCtxCreate` and
before every launch, reads it back, and restores `5`. `HASH`, `BDF`, `GPU`, `REG`,
and `POWER_LIMIT` can be overridden through the environment.

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

The two-card run measured 226.6 / 229.6 TF/s on the FP32-accumulate path, with
all four modes agreeing within 0.23% per clock. The small differences above are
run-to-run clock variance. Each mode checks 270,336 cells and expects zero
mismatches; see [E12](../../experiments/01_software-register-writes.md) and
[E49](../../experiments/08_assessment-and-cross-checks.md).

## Access

Read/write. The plain runner reads telemetry and, with `--reg-offset`, writes a
BAR0 register; the wrapper writes `0x504204` and restores `5`. No known wedge in
normal use, but any blind register write on a live GPU can require a reboot.

## Related

- [Register-write experiments](../../experiments/01_software-register-writes.md) — E12, E49
- [Assessment and cross-checks](../../experiments/08_assessment-and-cross-checks.md) — E49
- [Privilege and rate control](../../specs/02_privilege-and-rate-control.md) — selector chain and cap
- [Register access](../register-access/) — the `regops` client used by the wrapper

## License

`tensor_modes_issue_sm120.cu` and `tensor_modes_driver_runner.py` carry
`SPDX-License-Identifier: GPL-2.0-only`; the build and wrapper scripts are part
of the same tool. Treat this directory as GPL-2.0-only.
