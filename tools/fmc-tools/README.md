# FMC tools

Offline tools for the GB202 FMC and GspRmBoot containers: extract them, verify
their P-384 signatures, and search the 16! permutation key space against the
public known-answer test and two container oracles.

No firmware is shipped here. The containers and the GSP-RM image are inputs you
extract from your own driver package.

## Layout

| File | Purpose |
|---|---|
| `key37_factoradic.c` | CPU AES-NI search over all 16! permutations, OpenMP across threads |
| `key37_cuda.cu` | CUDA search: KAT, first-block FMC oracle, RISC-V-validity oracle |
| `key37_search.py`, `key37_search2.py`, `key37_scan.py` | Structured CPU candidate searches derived from the MD5 IV |
| `build_riscv_logp.py` | Builds the 16-bit parcel log-probability table used by the RISC-V oracle |
| `fmc_key_test.py` | Tries one candidate key across ECB/CBC/CTR plus a header-IV variant |
| `fmc_hits_test.py` | Scores first-block oracle hits against FMC/container headers |
| `fmc_fullbody.py` | Decrypts the whole body for a hit and tests for a parseable image |
| `fmc_riscv_verify.py` | Walks every instruction of the whole code component as RV32/64 |
| `riscv_oracle_selftest.py` | End-to-end rank-0 synthetic controls for the RISC-V oracle |
| `run_*.sh` | Two-GPU runners for the KAT, first-block, and RISC-V passes |
| `containers/` | Place extracted containers here; empty in the repo |

## Extract the containers

The FMC container is a `0x48`-byte plaintext header followed by an encrypted
body. The header starts with the magic `03 04 48 00`; a container is
`0x48 + u32@+4` bytes long.

```python
import struct, sys
d = open(sys.argv[1], "rb").read()
for i in range(len(d) - 8):
    if d[i:i + 4] == b"\x03\x04\x48\x00":
        size = 0x48 + struct.unpack_from("<I", d, i + 4)[0]
        print(f"offset={i:#x} size={size:#x} header={d[i:i+0x48].hex()}")
```

Header fields used by the tools:

| Offset | Field |
|---:|---|
| `0x00` | magic `03 04 48 00` (header size `0x48`) |
| `0x04` | body size |
| `0x0C` | code size |
| `0x14` | data size |
| `0x18` | flags / version |
| `0x20` | constant `0x2801` |

The body is `[code][data][manifest 0xA00]`. The matching GspRmBoot image is a
raw `0x47000`-byte blob in the driver bindata: manifest at 0, data at `0xA00`,
code at `0xF200`.

A signed container is preceded by `0xF8` bytes:
`publickey[97] || pad[7] || signature[96] || hash[48]`. The key is an
uncompressed P-384 point, the signature is `r || s`, and the hash is SHA-384
over the whole container including its header.

```text
openssl pkey -pubin -inform DER -in pub.der -out pub.pem
openssl dgst -sha384 -verify pub.pem -signature sig.der container.bin
openssl pkeyutl -verify -pubin -inkey pub.pem -in hash.bin \
  -sigfile sig.der -pkeyopt digest:sha384
```

Override the container directory with `FMC_CONTAINERS`; the default is
`./containers`.

## Build

CPU search:

```text
gcc -O3 -march=native -maes -msse4.1 -fopenmp \
    -o key37_factoradic key37_factoradic.c
```

CUDA oracle (CUDA 13, RTX 5090 = `sm_120`). The `-U_GNU_SOURCE` avoids a
GCC 15/CUDA 13 `noexcept` conflict:

```text
$CUDA_HOME/bin/nvcc -O3 -arch=sm_120 -U_GNU_SOURCE \
    -o key37_cuda key37_cuda.cu
```

Python helpers need `cryptography`; the structured searches also need
`pycryptodome`.

The RISC-V table is built from the plaintext GSP-RM code segment:

```text
python3 build_riscv_logp.py --fw gsp_fwimage.bin --out riscv_logp_q.bin
```

`--fw` defaults to `$FWIMAGE` or `gsp_fwimage.bin`; `--out` defaults to
`$LOGP` or `riscv_logp_q.bin`. Without `--starts`, calibration is skipped.

## Run

Self-tests:

```text
./key37_factoradic --selftest
./key37_cuda --selftest --device 0
```

KAT search over the whole space, one process per GPU with complementary
`--start`/`--count` halves:

```text
./key37_cuda --device 0 --start 0 --count 10461394944000 --chunks 128
./key37_cuda --device 1 --start 10461394944000 --count 10461394944000 --chunks 128
```

First-block FMC oracle on the debug container:

```text
./run_fmc_rf16_c09_2gpu.sh
```

The KAT-then-c11 and FF/last-round-key runners split the same 16! space and
validate any hits:

```text
./run_kat_then_c11_2gpu.sh
./run_ff_then_rk_2gpu.sh
```

RISC-V-validity oracle on either debug container:

```text
./run_fmc_riscv_2gpu.sh containers/c09_00691480_046200.bin out/riscv_c09
```

Verify a hit file against the whole code component:

```text
python3 fmc_riscv_verify.py --hits out/riscv_c09/fmc_hits.txt \
    --container containers/c09_00691480_046200.bin
```

The runners default to `key37_cuda` and `containers/` beside the script; set
`BIN`, `CONTAINERS`, or `OUT` to override. Outputs go to `out/` by default.

## Expected results

The public control is:

```text
AES-128-ECB(K, 00 * 16) = 717d1494eaca317ff106195258b38377
```

The corrected 16! passes are all negative:

| Pass | Result |
|---|---|
| zero-block KAT | no match |
| FF-block KAT | no match |
| last-round-key transform | no match |
| c09 first-block oracle | 6,115 unique hits, full-body `valid=0` |
| c11 first-block oracle | 6,145 unique hits, full-body `valid=0` |
| c09 code-first RISC-V oracle | 0 hits |
| c09/c11 five-mode RISC-V | 3 chance records, all rejected by the full-code walk |

The debug FMCs are not decrypted by any MD5-IV permutation under ECB,
per-component CBC with a zero or header IV, or CTR with counter start 0 or 1.
No key was recovered.

Reference rates on two 5090s: about 23.6 G keys/s per card for the zero/FF KAT,
10.2 G/s for the first-block oracle, 8.5 G/s for the three-hypothesis RISC-V
oracle, and 5.5 G/s sustained for the five-mode RISC-V oracle.

## Inputs and outputs

- Containers: from your own driver package; place them in `containers/` or set
  `FMC_CONTAINERS`.
- GSP-RM code segment: the `.fwimage` section of `gsp_ga10x.bin`, 72,830,976
  bytes at file offset `0x40`; set `FWIMAGE`.
- Outputs: `out/` by default; `FMC_OUT` overrides the decryption directory.
- Nothing here writes to a GPU register. The CUDA paths need a GPU, but only
  for compute; the CPU path needs no device.

## Access

Offline. The CUDA paths use the GPU for compute only; nothing writes to a GPU
register or needs root.

## Limits

The key/mode question is not solved: the IV-permutation family is exhausted
under the tested modes, and the key source is unknown. The first-block magic
filter used in the early passes was the wrong oracle for a code-first body; use
`fmc_riscv_verify.py` for any new hit. No containers, firmware, or recovered
keys are included.

## Related

- [Experiment 07: FMC body layout and key oracle](../../experiments/07_plaintext-corpus.md)
- [Boot chain](../../specs/01_boot-chain.md)
- [Firmware formats](../../specs/04_firmware-formats.md)
- [GSP-RM tools](../gsp-rm-tools/)
- [Driver harness](../driver-harness/)

## License

The source files carry their original `SPDX-License-Identifier: GPL-2.0-only`
headers. Reconcile that with the repository-level tool license before
publishing.
