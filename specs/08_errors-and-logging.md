# Errors and logging

This spec is the reference for what secure firmware and the driver return when a
boot input, register access, or log read fails, and for the format of the GSP-RM
log rings. It covers the ten mapped boot codes, the NV status codes seen, the
`0xBADF` sentinel families, the log record layout, and the host tracing
facilities.

Most values here are `[measured]` on the two RTX 5090 cards; the log format is
`[source]` from the firmware writers and the host reader, and confirmed by a live
capture. The experiments behind each table are linked inline.

Related specs: [boot chain](../specs/01_boot-chain.md) for where these codes are raised,
[memory and host access](../specs/07_memory-and-host-access.md) for the WPR and FB paths,
and [register map](../specs/03_register-map.md) for the register offsets named below.

## 1. Boot error codes

Ten codes are mapped. The channel matters: `FSP response` codes come back in the
COT reply (Task `0x1`, command `0x14`); `Fatal GSP-FMC Error` codes come from the
FMC/ACR path and are printed by the driver.

| Code | Channel | Trigger | Recovery | Evidence |
|---|---|---|---|---|
| `0x83d` | FMC, partition 1 | vidmem FRTS withheld (`RmDisableCotCmd=0x4`) | clean | [E11](../experiments/02_registry-and-static-audit.md) |
| `0xd9` | FSP response | COT `frtsVidmemSize != 0x100000` | clean | [E29](../experiments/05_fmc-fsp-boot-inputs.md), [E30](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0xd6` | FSP response | COT FRTS offset not 128K-aligned | clean | [E32](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x827` | FMC/ACR, partition 1 | `WprMeta.magic` wrong | clean | [E36](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x82e` | FMC, partition 1 | `WprMeta.sizeOfBootloader` changed from `0x47000` | clean | [E69](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x885` | FMC, partition 1 | `WprMeta.bootloaderManifestOffset` outside the image | clean | [E69](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x377` | FSP response | COT hash authentication failure | **WPR2 left up** | [E41](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x1db` | FSP response | COT public key not accepted (self-signed pair) | **WPR2 left up** | [E61](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x33` | FSP response | FMC container byte changed while the COT hash is stock | **WPR2 left up** | [E62](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0xaff` | FMC, partition 1, info `0xb` | modified GSP-RM image or bootloader image | clean if firmware restored | [E15](../experiments/05_fmc-fsp-boot-inputs.md), [E40](../experiments/05_fmc-fsp-boot-inputs.md), [E69](../experiments/05_fmc-fsp-boot-inputs.md) |

The distinction that matters operationally is pre-auth versus auth. The size,
alignment, and magic checks reject without side effects. An authentication
failure (`0x377`, `0x1db`, `0x33`) leaves WPR2 armed, so every retry prints
`unexpected WPR2 already up` and the machine needs a reboot. The FSP arms WPR2
before it authenticates.

Raw lines, as printed:

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd6
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0x377
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x827, additional info=0x0
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
```

`0xaff` is the image-authentication failure for either boot image. `0x82e` and
`0x885` are separate pre-auth checks: the bootloader length and the manifest
offset are consumed, while the code/data offsets and the signature size are not.
See [boot chain](../specs/01_boot-chain.md) for the structures and
[E69](../experiments/05_fmc-fsp-boot-inputs.md) for the field matrix.

## 2. Failure taxonomy

Four failure modes have different costs:

| Mode | Example | Recovery | Evidence |
|---|---|---|---|
| Structured refusal, clean | `0xd9`, `0xd6`, `0x827`, `0x82e`, `0x885` | one module reload | [E29](../experiments/05_fmc-fsp-boot-inputs.md)–[E41](../experiments/05_fmc-fsp-boot-inputs.md) |
| Structured refusal, WPR2 up | `0x377`, `0x1db`, `0x33` | one reboot | [E41](../experiments/05_fmc-fsp-boot-inputs.md), [E61](../experiments/05_fmc-fsp-boot-inputs.md), [E62](../experiments/05_fmc-fsp-boot-inputs.md) |
| Hang, no host log | bad `SRMeta` magic | one reboot; no evidence without an out-of-band console | [SR-resume experiments](../experiments/06_sr-resume.md) |
| Hard wedge | heap below GSP-RM's minimum | one reboot, possibly a cold power cycle | [E39](../experiments/05_fmc-fsp-boot-inputs.md) |

The hang case is the expensive one for debugging. Journald freezes after
`Filesystem sync`, and post-freeze printk is only flushed on a successful resume.
A failed resume therefore leaves no host-visible log. Use a network console or
phase markers before running suspend/resume variants.

## 3. NV status codes

These are the RM status values seen in the experiments:

| Code | Name | Context | Evidence |
|---|---|---|---|
| `0x1f` | `NV_ERR_INVALID_ARGUMENT` | `GPU_EXEC_REG_OPS` with every `GR_CTX` regtype | [E71](../experiments/01_software-register-writes.md) |
| `0x56` | `NV_ERR_NOT_SUPPORTED` | RISC-V debug stubs; `GPU_EXEC_REG_OPS` `FB` regtype | [E71](../experiments/01_software-register-writes.md) |
| `0x62` | `NV_ERR_RESET_REQUIRED` | RPCs to a fatal GSP | [E07](../experiments/01_software-register-writes.md) |
| `0x65` | `NV_ERR_TIMEOUT` | GSP status queue after an undersized heap | [E39](../experiments/05_fmc-fsp-boot-inputs.md) |

`0x62` is not a statement about the requested operation: once the GSP is fatal,
`_kgspRpcSanityCheck` returns it for every RPC. The per-op status can still read
`SUCCESS`, which is why register claims need a readback.

## 4. Data sentinels and bad reads

Bad reads return `0xBADFxxxx`. Bits `[31:8]` are the PRI-ringstation error code
and the low byte is not decoded. Three classes are distinguishable: decode
errors, client/privilege errors, and refused/blocked reads.

| Value | Class / PRI code | Observed when |
|---|---|---|
| `0xBADF5040` | client error, `FECS_PRI_CLIENT_ERR` | offset not implemented |
| `0xBADF5610` | no such port | GSP IMEM/DMEM port absent |
| `0xBADF5620` | port present, inaccessible | FSP core IMEM/DMEM; HS-window ICD/PC |
| `0xBADF5720` | refused/blocked | present but blocked to the host |
| `0xBADF5723` | refused/blocked | present but blocked to the GSP |
| `0xBADF510C` | generic client/privilege | fuse-block instance; not fuse-specific |
| `0xBADF5128` | generic client/privilege | refused PL2 access at `0x137200` |
| `0xBADF4100` | decode/access error | refused GSP `HWCFG2` at `0x1100f4` |
| `0xBADF5545` | command-ID blocked | FECS command-ID register read |
| `0xBADF1100` | `FECS_PRI_DECODE` | address not decodable |
| `0xBADFFFFF` | not public | GSP-master read of the four PRISCV ICD registers |

The low byte also encodes the caller or engine for the blocked/port cases, which
is why `0xBADF5720` and `0xBADF5723` differ. `0xBADF51` is a family, not a fuse
marker: the low byte varies (`0x0c` at the fuse block, `0x28` at `0x137200`).
Evidence: [E18](../experiments/03_fecs-and-gr-context.md),
[E21](../experiments/04_hs-sec2-fsp-memory.md),
[E60](../experiments/08_assessment-and-cross-checks.md),
[E63](../experiments/04_hs-sec2-fsp-memory.md),
[E67](../experiments/04_hs-sec2-fsp-memory.md).

Other sentinels and data markers:

| Value | Meaning |
|---|---|
| `0xbad0ac00` | WPR access-denied fill; every dword in the protected range reads this (entropy exactly 2.0) |
| `0xdead5ed0` | dummy/unimplemented EMEM channel data |
| `0xaddeadde` | uninitialized context-buffer poison |
| `0xffffc04c` | `NV_PROM_DATA(0)` read on this board; PROM is not at the documented base |
| `0xbadfbadf` / `0xbadfbadfbadfbadf` | ICD command rejected (`ERROR[14]` set), 32-/64-bit form |
| `0x00c36180` | stock `FEAT_READOUT_1`; a known constant used as a search key, not a sentinel |

A read that returns `0xbad0ac00` is a protection response, not firmware data. The
WPR is host-unreadable and the fill is identical on both cards
([E74](../experiments/05_fmc-fsp-boot-inputs.md)). A read that returns
`0xbadfbadf` from the ICD means the command was rejected; `RREG`, `RCSR`, and
`RDM` require a halted hart ([E67](../experiments/04_hs-sec2-fsp-memory.md)).

## 5. GSP log ring format

GSP-RM writes per-task log rings into host-allocated, host-mapped sysmem. The
host can read them without firmware changes. The format below is `[source]` from
the three firmware writers and the host reader, and `[measured]` by a live
capture.

Ring header:

```text
word[0]      total u64 words ever written; monotonic, not a ring index
word[1..L]   ring data, L = buffer_size/8 - 1
```

The write index starts at 1, advances per word, and wraps to 1 at `L+1`. Data
word `k` (0 = first word ever written) is stored at `word[1 + (k % L)]`.
`word[0]` increments by `N` after a whole record lands, so it ends on a record
boundary.

Record, forward order:

```text
[ arg0 ][ arg1 ] ... [ arg(N-2) ][ meta ][ timestamp ]
```

The metadata word is second-to-last, immediately before the timestamp. An
earlier draft put it first; that misparses every record with more than two words.
The writer emits operands, then the metadata operand, then the timestamp; the
reader walks backwards from the timestamp.

Meta word:

```text
bits 47:0   metadata VA - per-task logging-section base
bits 55:48  N, total u64 entries in this record (2..22)
bits 63:56  libos task id
```

`N = argumentCount + 2`; `argumentCount = N - 2`. The writer
`FUN_ram_01b9e86e(n, ...)` takes an operand count, writes `N = n + 1` entries,
and packs the last vararg (the metadata struct pointer) into the meta word.

Task IDs and bases:

| ID | Task | Logging section | Base | Status |
|---:|---|---|---:|---|
| 1 | KERNEL | `.fwlogging_kernel_gb20x` | unknown | captured IDs `0x2017c3c0`–`0x2017ccf0` are not referenced |
| 2 | INIT | `.fwlogging_init` | `0x20183000` | confirmed; writer `FUN_ram_011849a6` |
| 3 | RM | `.fwlogging_rm` | `0x2018F000` | confirmed; writer `FUN_ram_01b9e86e` |
| 4 | INTR | `.fwlogging_rm` | `0x2018F000` | confirmed |
| 5 | VGPU | `.fwlogging_vgpu` | unknown | no capture |
| 6 | MNOC | `.fwlogging_mnoc` | unknown | buffer empty |
| 7 | DEBUG | `.fwlogging_debug` | unknown | buffer empty |
| 8 | ROOT | `.fwlogging_start` | unknown | IDs not referenced |
| 9 | RMON | `.fwlogging_rm` | `0x2018F000` | confirmed |

The early writer `FUN_ram_01179c62` uses base `0x20178000`. Its task assignment
is unconfirmed: its IDs do not appear in the captured KERNEL buffer. The decoder
labels it `EARLY` rather than KERNEL.

Capture order (registration order, not task ID) on GB202:

| idx | Task | Size |
|---:|---|---:|
| 0 | INIT | `0x10000` |
| 1 | INTR | `0x10000` |
| 2 | RM | `0x10000` |
| 3 | MNOC | `0x10000` |
| 4 | DEBUG | `0x10000` |
| 5 | ROOT | `0x1000` |
| 6 | RMON | `0x1000` |
| 7 | KERNEL | `0x10000` |

Sizes are registry-overridable with
`RmGspLogBufferSizeTask{Init,Intr,Rm,Mnoc}`. The host pointer is
`pKernelGsp->rmLibosLogMem[idx].pTaskLogBuffer`; the size is in
`pTaskLogDescriptor`. Capture tooling lives in
[driver harness](../tools/driver-harness/) and the decoder in
[GSP-RM tools](../tools/gsp-rm-tools/).

## 6. What the decoder recovers

The logging metadata ELF (`gsp_log_ga10x.bin`) is not shipped, so the message
text and severity are unavailable. The metadata IDs are compile-time constants at
most call sites, so an `{ID → emitting function, operand count}` table can be
built from the plaintext image and joined to a raw ring. That recovers a
function-level trace:

| Item | Value |
|---|---:|
| ID-table rows | 63,612 |
| Decompiled call sites | 30,568 |
| Raw-scan IDs | 33,044 |
| Distinct RM IDs | 58,736 |
| INIT IDs | 184 |
| Early-writer IDs | 75 |
| Live records per card | 173 |
| Resolved | 141 / 173 |

Per-buffer resolution in the live capture:

| Buffer | Records | Resolved | Base |
|---|---:|---:|---:|
| RM | 98 | 96 | `0x2018F000` |
| INIT | 42 | 41 | `0x20183000` |
| KERNEL | 26 | 0 | unknown |
| INTR | 2 | 2 | `0x2018F000` |
| ROOT | 3 | 0 | unknown |
| RMON | 2 | 2 | `0x2018F000` |

The trace gives task, timestamp, metadata ID, argument count, raw arguments, the
emitting function address and name, and the module. It does not give the format
string, source line, or severity for RM and INIT records. Thirty-one early-writer
IDs have an exact text fallback from a per-statement literal-printf path; INIT
has no such fallback.

Sample ring header and decoded record:

```text
# buffer 4: <ring> hint=RM      size=65536B capacity=8191 put=0x13f records=98
[    +2.263872 ms] t=2 INIT    id=0x201874d8 n_args=2  FUN_ram_01187426 [logging_debug]  args=[0xa00000, 0x9400000456490000]
```

The decoder selftest passes 27 checks (round-trip, wrap, bad boundary, resync,
auto-put, text join). A live capture produced the same `(task, ID, argc)`
sequence on both cards, and 70/70 raw-attributed records matched a real writer
call site. Evidence: [E57](../experiments/08_assessment-and-cross-checks.md),
[E59](../experiments/08_assessment-and-cross-checks.md),
[E60](../experiments/08_assessment-and-cross-checks.md).

## 7. Host tracing facilities

There is no per-launch firmware operation to trace. A CUDA launch is a pushbuffer
entry and a channel doorbell; the resource manager is not in that path. Its
rate-relevant work happens once, at engine/context initialization.

| Facility | State |
|---|---|
| `NVreg_RegistryDwords` | forwards every key to RM/GSP-RM; the instrument behind most oracles |
| `EnableGpuFirmwareLogs` | release build honours only `1`; the `2` default is DEBUG/DEVELOP only |
| `RmGspLogBufferSizeTask{Init,Intr,Rm,Mnoc}` | sizes the host-allocated GSP log buffers |
| `RmGspPreserveUnloadLogs`, `RmGspTraceCrashLogging*` | log retention and crash-trace masks |
| `RMNvLog`, `RMDumpNvLog` | host-RM NVLOG, dumped to dmesg on Xid/unload |
| `RMEnableEventTracer` | no-op on Linux; every `RMTRACE_*` macro is compiled out in `tracer.h` |
| `nvidia-debugdump` | external build lists devices and emits an opaque blob |
| PRISCV ICD | direct MMIO debug port; commands execute, and `STOP` + `RDM` reads the halted core’s RM code segment |

What can be added with modest instrumentation: a host control/RPC tracer (ctrl ID
and GSP RPC function ID plus parameter size) and a raw GSP log-buffer dump at a
chosen point. Neither reaches FSP, FMC, or Heavy Secure code. The pre/post FEAT
sampler is the worked example of instrumenting a boot stage. Evidence:
[E55](../experiments/08_assessment-and-cross-checks.md); the ICD itself is in
[GSP RISC-V and PRISCV](../specs/06_gsp-riscv-and-priscv.md).

## 8. Reading a failure

| Symptom | Meaning | Action |
|---|---|---|
| `0xd9` | COT FRTS size is not exactly 1 MB | fix the size; module reload |
| `0xd6` | COT FRTS offset is not 128K-aligned | align the offset; module reload |
| `0x827` | `WprMeta.magic` wrong | fix the magic; module reload |
| `0x82e` / `0x885` | bootloader length / manifest offset wrong | fix the field; module reload |
| `0x377` / `0x1db` / `0x33` | authentication or image binding failed | reboot; WPR2 is up |
| `0xaff` + info `0xb` | boot image failed authentication | restore the stock image |
| `0x83d` | FRTS region withheld from the FMC | restore the COT region |
| `0x65` + `msgqRxLink failed` | GSP-RM heap below minimum | reboot; bisect from above |
| `0xbad0ac00` | WPR access denied | the data is not readable from the host |
| `0xbadfbadf` | ICD command rejected | halt the core first; reads require `STOP` |
| `0xbadf5720` / `0xbadf5723` | register present but blocked to host / GSP | the caller is not admitted |
| `0xbadf5040` | offset not implemented | wrong address or block |
| `0x62` | GSP is fatal | one reboot; check the preceding Xid |

## 9. Limits

- Ten boot codes are mapped; the FSP/FMC error space is larger. `0xaff` carries
  only `additional info=0xb` on this build.
- The auth-failure ordering is measured for these fields; a TOCTOU between the
  FSP hash read and its decrypt read is not characterised.
- Message text and severity for RM and INIT log records need the missing
  metadata ELF. The KERNEL buffer base is unknown.
- Sentinel low bytes are only partly decoded; the `0xBADF51` family is generic,
  not fuse-specific.
- The PRISCV ICD is a diagnostic port, not a memory reader for the WPR, the boot
  image, or the data segment (see [GSP RISC-V and PRISCV](../specs/06_gsp-riscv-and-priscv.md)).

## 10. Evidence map

| Topic | Experiments |
|---|---|
| FMC/FSP boot codes | [E29–E41](../experiments/05_fmc-fsp-boot-inputs.md), [E61](../experiments/05_fmc-fsp-boot-inputs.md), [E62](../experiments/05_fmc-fsp-boot-inputs.md), [E69](../experiments/05_fmc-fsp-boot-inputs.md) |
| `0x83d`, registry boot keys | [E11](../experiments/02_registry-and-static-audit.md) |
| NV status codes | [E07](../experiments/01_software-register-writes.md), [E39](../experiments/05_fmc-fsp-boot-inputs.md), [E71](../experiments/01_software-register-writes.md) |
| Sentinels and PRI telemetry | [E18](../experiments/03_fecs-and-gr-context.md), [E21](../experiments/04_hs-sec2-fsp-memory.md), [E60](../experiments/08_assessment-and-cross-checks.md), [E63](../experiments/04_hs-sec2-fsp-memory.md), [E67](../experiments/04_hs-sec2-fsp-memory.md) |
| WPR fill `0xbad0ac00` | [E74](../experiments/05_fmc-fsp-boot-inputs.md) |
| GSP log format and decoder | [E57](../experiments/08_assessment-and-cross-checks.md), [E59](../experiments/08_assessment-and-cross-checks.md), [E60](../experiments/08_assessment-and-cross-checks.md) |
| Tracing facilities | [E55](../experiments/08_assessment-and-cross-checks.md) |
| ICD rejections | [E67](../experiments/04_hs-sec2-fsp-memory.md) |
