# GSP RISC-V and PRISCV

The GSP is the GPU's RISC-V coprocessor. Its register space has two parts: a
Falcon-style block and the PRISCV block. PRISCV contains a host-facing debug
engine, the ICD, which can halt the core and read its loaded code segment.

This spec is the register map, the host/GSP split, the ICD command encoding, the
RDM read aperture, and the boot-time gate. The measurements are from the two
local RTX 5090s; claims that come from public register definitions or are carried
over from Ampere are marked.

| Term | Meaning |
|---|---|
| GSP | The GPU's RISC-V coprocessor; runs the boot ROM and GSP-RM |
| PRISCV | The GSP's RISC-V register block |
| CPUCTL | PRISCV core-control register |
| ICD | In-circuit debugger; the host-facing command engine in PRISCV |
| RDM / RREG / RCSR / RSTAT / RPC | ICD commands: read memory / register / CSR / status / PC |
| PLM | Per-block read/write permission mask ([privilege and rate control](../specs/02_privilege-and-rate-control.md)) |
| GSP-RM | Main GPU firmware, running in Light Secure ([boot chain](../specs/01_boot-chain.md)) |
| HS / LS | Heavy Secure / Light Secure privilege levels ([privilege and rate control](../specs/02_privilege-and-rate-control.md)) |
| WPR / FRTS | Write-protected firmware region / runtime state inside it ([memory and host access](../specs/07_memory-and-host-access.md)) |

## 1. Two blocks, one base

The Falcon-style block ends at `0x110d4c`. The range `0x110d50`–`0x110ffc` is
unimplemented. The PRISCV block starts at `0x111004`; its header offsets are
relative to `0x111000`. [measured]

| Range | Block | Notes |
|---|---|---|
| `0x110000`–`0x110d4c` | Falcon-style GSP block | register file, EMEM ports, PLM |
| `0x110d50`–`0x110ffc` | unimplemented | reads return `0xBADF5040` |
| `0x111004`–`0x1117ff` | PRISCV | base `0x111000`; ICD lives here |
| `0x111800`–`0x113fff` | no debug module | 16 implemented dwords in two tables, rest `0xBADF5040` |

The base is confirmed four ways: `CPUCTL` at `0x111388`, `RPC` at `0x1113ec`,
`IRQMASK`/`IRQDEST` at `0x111528`/`0x11152c`, and `PRIV_ERR`/`HUB_ERR` at
`0x111420`–`0x111430`. The fault-containment register at `0x111700` is offset
`0x700`. [measured]

## 2. Falcon block

Selected registers, GSP view. Values are stock on GB202. [measured]

| Offset | Name | Value / note |
|---|---|---|
| `0x110008` | `IRQSTAT` | `0` |
| `0x1100f4` | `HWCFG2` | `0x818787f7`; bit 10 = RISC-V core |
| `0x110108` | `HWCFG` | `0x80420100` |
| `0x11012c` | `HWCFG1` | `0xc2101136`; bits 21:25 = 1 → 512-byte EMEM blocks |
| `0x110180`+ | `IMEMC/D` | `0xBADF5610` — no IMEM window |
| `0x1101c0`+ | `DMEMC/D` | `0xBADF5610` — no DMEM window |
| `0x1103c0` | `FALCON_ENGINE` | `0x00000200` deasserted; host-blocked while PRIV-locked |
| `0x1103c4` | `RESET_PRIV_LEVEL_MASK` | `0x00000f00`; level-0 enables clear |
| `0x110abc` | EMEM geometry | `0x20` → 32 × 256 B = 8 KB |
| `0x110ac0`–`0x110afc` | `EMEMC/D(0..7)` | 8 KB window; all zero at runtime |
| `0x110b84` | GSP PLM | `0xffffff8f` — read all / write L3 only |

The IMEM and DMEM ports do not exist on this RISC-V GSP, so there is no window
onto local instruction or data memory. The 8 KB EMEM window is real storage, but
it read zero at the sample point and held nothing. See
[E10](../experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty).
[measured]

## 3. PRISCV register map

All values are the GSP (PL2) view unless marked host. "Host-blocked" means the
host reads `0xBADF5720`. The GSP is refused at the ICD with `0xBADFFFFF`.
[measured]

| Offset | Name | Value / note |
|---|---|---|
| `0x111004`–`0x111094` | core state | GSP-only; host-blocked |
| `0x11106c` | core-state block | `d0f6abf9 1f1b665b 9fc84de6 64658a97`, then `0x00010001` |
| `0x111128` | PLM-shaped | `0x00000f00` |
| `0x1111a8`–`0x1111e4` | host-only table | 16 × `0x00000002` |
| `0x111320` | PLM | `0xffffff8f` — read all / write L3 only |
| `0x111324` | PLM | `0xffffff0f` — read all / write none |
| `0x111328` | PLM | `0xffffffff` — read/write all |
| `0x111388` | `CPUCTL` | `0x00000180`; halt `[4]=0`, active `[7]=1` |
| `0x1113d0`–`0x1113dc` | `ICD_CMD`/`ADDR0`/`ADDR1` | host `0`; GSP `0xBADFFFFF` |
| `0x1113e0`–`0x1113e8` | ICD data / reserved | `0` to both |
| `0x1113ec` | `RPC` | host `0x9300xxxx` (the true PC); GSP `0x01404f66` |
| `0x111400` | host-only control | host `0x51100000`; GSP `0xBADF5610` |
| `0x111404`–`0x111410` | trace registers | GSP-only; host-blocked |
| `0x111420`–`0x111430` | `PRIV_ERR`/`HUB_ERR` | `0`; `PRIV_ERR_INFO` is `0xBADF5040` |
| `0x111514`/`0x11151c`/`0x111550` | PLMs | `0xffffff0f` / `0xffffffff` / `0xffffffff` |
| `0x111528`/`0x11152c` | `IRQMASK`/`IRQDEST` | `0x810490d2` / `0x010800d0` |
| `0x111534` | `IRQDELEG` | `0xBADF5610` — no port |
| `0x111700` | fault containment | `0` |
| `0x111f00`–`0x111f2c` | table | 4 × {`0x00000f00`, `0`, `0x11111111`} |
| `0x111f80`–`0x111fac` | table | 4 × {`0x00000f00`, `0x04000000`, `0`} |
| `0x111610`+ | host-only pattern | `0x83bbbbbb`, `0x8bb9bbbb`, `0xbbbbbbbb`, `0x01000330` |

The two 12-byte-stride tables at `0x111f00` and `0x111f80` are the only
implemented dwords in the upper window. `0x111fb0` onward is `0xBADF5040`.
[measured]

## 4. Host/GSP partition

Over the 512 offsets both masters can address, the block is partitioned, not a
single register file seen twice. [measured]

| Class | Count | Examples |
|---|---:|---|
| Same value to host and GSP | 66 | `CPUCTL 0x111388 = 0x180`; PLMs `0x111300`–`0x111328`; IRQ `0x111528`/`0x11152c` |
| Differ | 199 | core state `0x111004`–`0x111094`: GSP reads values, host gets `0xBADF5720` |
| Host-only | 69 | `0x1111a8`–`0x1111e4`; `0x111610`+; ICD `0x1113d0`+ |
| GSP-only | 80 | GSP `0x1113ec = 0x01404f66`; trace `0x111404`–`0x111410` |

The practical split: the host can reach the ICD and the host-side tables; the GSP
can reach the core state and the trace registers. The PC register is per-master.
The host's `0x1113ec` matches the ICD `RPC` when the block is accessible; the
GSP-side `0x01404f66` is a different register, not the current PC.
[measured; see [E63](../experiments/04_hs-sec2-fsp-memory.md#043-priscv-block-is-split-per-master)]

## 5. ICD command engine

The four registers `0x1113d0`–`0x1113dc` are host-writable at PL0. `ADDR0` and
`ADDR1` retain a written value, `CMD` retains the command, and the engine
executes. The GSP is refused at these registers with `0xBADFFFFF`. [measured]

### Command word

The field layout is carried over from the Ampere ICD definitions [source][analogy].
The behavior below is measured on GB202 [measured].

| Bits | Field | Meaning |
|---|---|---|
| `4:0` | `OPC` | opcode |
| `7:6` | `SZ` | access size |
| `12:8` | `IDX` | CSR / register index |
| `14` | `ERROR` | command rejected |
| `15` | `BUSY` | command in flight |
| `31:16` | `PARM` | opcode parameter |

| Opcode | Name | Role |
|---|---|---|
| `0x0` | `STOP` | halt the core |
| `0x8` | `RREG` | read a GPR |
| `0xa` | `RDM` | read memory |
| `0xe` | `RSTAT` | read status |
| `0x10` | `RCSR` | read a CSR |
| `0x12` | `RPC` | read the PC |

Reads must be aligned to the access size.

### Running core

`RSTAT` indices 0, 3, and 4 complete with `ERROR=0`. `RREG`, `RCSR`, and `RDM`
are rejected with `CMD[14]=1` and `RDATA=0xbadfbadf`; 8-byte reads return
`0xbadfbadfbadfbadf`. That is the halted-hart requirement, not a dead latch.
[measured]

### After STOP

`CMD=0` halts the core. `CPUCTL` moves from `0x2a0` to `0x380`, but
`CPUCTL[4]` stays clear, so the GA102 `HALTED` bit is not the indicator on
GB202. With the core halted, the register and memory reads succeed. [measured]

| Read | Value |
|---|---|
| `RPC` | `0xffffffff93002ebc` |
| `RREG x1` (ra) | `0xffffffff93002ea6` |
| `RREG x2` (sp) | `0xffffffffa3003ed0` |
| `RSTAT` 0/3 | `0` |
| `RDM 0x01400000`/8 | `0x96be52c70693b9e7` |
| `RDM 0x01404f64`/4 | `0x4208962a` |
| `RDM 0x01404f66`/2 | `0x4208` |

The host `0x1113ec` reads `0x93002ebc`, matching `RPC`; the GSP master's
`0x1113ec` reads `0x01404f66`. The driver's own core-dump path uses the same
ICD: after `STOP` it reads CSRs, attempts an `RDM` stack unwind, and raises
Xid 154. The Linux ICD wrappers are an API layer, not the hardware gate.
[measured; see [E67](../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)]

## 6. RDM aperture and address model

With the core halted, `RDM` reads the loaded GSP-RM code segment at
`0x01000000`–`0x01DCD000` (tested through `0x01B40000`). Reads outside that
range return `ERROR`. [measured]

| Address | Result |
|---|---|
| `0x01000000` | ELF magic `7f454c4602010100` |
| `0x01400000` | image bytes at file offset `0x58F000` |
| `0x01800000` | readable |
| `0x02000000` | `ERROR` |
| `0x04000000` | `ERROR` — data segment |
| `0xEFD00000` | `ERROR` — boot image |
| `0x5DD00000`, `0x181D00000` | `ERROR` |
| `0x96000000` | `ERROR` — data runtime VA |
| WPR / FRTS | `ERROR` |

The image layout explains the aperture:

| Item | Value |
|---|---|
| `.fwimage` wrapper | `0x18F000` bytes |
| ELF code | `p_vaddr 0x01000000`, `filesz 0xDCD000`, RX |
| ELF data | `p_vaddr 0x04000000`, `filesz 0x1A1000`, RW |
| entry | `0x01A0F3DA` |
| runtime VA | link VA + `0x92000000` |
| file offset | link VA − `0x00E71000` |

The halted PC and `ra` translate as follows; both `RDM` reads match the extracted
image. [measured]

| Register | Link VA | RDM read | Image file offset |
|---|---|---|---|
| `RPC 0x93002ebc` | `0x01002ebc` | `0x071300b7` | `0x191EBC` |
| `ra 0x93002ea6` | `0x01002ea6` | `0xe11c` | `0x191EA6` |

The `0x01000000` address is in the core's space, not a host framebuffer physical
address. The host physical address `0x01000000` reads zero; the backing is inside
the WPR. See [E74](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut).
[measured]

## 7. Boot-window gate

A read-only trace armed after the COT response samples `CPUCTL`, the host PC
mirror, `ICD_CMD`, the Falcon `ENGINE`, and the reset PLM every 100 µs. [measured]

| Time | `CPUCTL` | PC mirror | `ICD_CMD` | `ENGINE` | Reset PLM |
|---|---|---|---|---|---|
| 0–1.6 ms | `0xbadf4100` | `0xbadf4100` | `0xbadf4100` | `0xbadf4100` | `0xbadf4100` |
| 1.6–155 ms | `0x180` | `0xbadf5620` | `0xbadf5620` | `0xbadf5720` | `0x00000f00` |
| ~155 ms | `0x180` | `0xefd0xxxx` | `0` | `0xbadf5720` | `0x00000f00` |
| ~158 ms | `0x180` | `0x9300xxxx` | `0` | `0xbadf5720` | `0x00000f00` |

At the unblock, the first valid PCs are the boot image at `0xefd00000`, which is
`0x47000` bytes — the host-supplied `GspRmBoot` image. GSP-RM starts 0.5–0.6 ms
later. `STOP` works in that window and `RPC`/`RREG` return the image's
`pc`/`ra`/`sp`, but every `RDM` is refused, including the `0x01000000` control.
The same holds at the Light Secure transition. [measured]

After full boot the aperture is the RM code segment only: `0xEFD00000`,
`0x5DD00000`, `0x181D00000`, `0x04000000`, and `0x96000000` all refuse. The
plaintext GSP-RM contains no ICD-enable write; its only PRISCV writes are
`IRQDEST`/`0x111520` setup and `ICD_CMD=0` in fatal self-halt paths. The refusal
is a hardware/firmware privilege gate. See
[E68](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked).
[measured]

## 8. The FSP has no ICD

A full 16 KB sweep of the FSP window `0x8f0000`–`0x8f3fff` from both the host
and the GSP finds no PRISCV core interface at either placement. [measured]

| Placement | Offsets | Value | Meaning |
|---|---|---|---|
| Falcon+`0x3d0` | `0x8f0388`/`0x8f03d0` | `0xbadf5620` | port present, blocked |
| GSP-like `+0x1000` | `0x8f1388`/`0x8f13d0` | `0xbadf5040` | not implemented |

Implemented outliers are `0x8f1274`, `0x8f1298`, and `0x8f129c`, plus two
12-byte-stride tables at `0x8f1f00` and `0x8f1f80`. The `0x8f3000` block carries
`0xffffff8f` PLMs. None of it is a command engine, so the FSP is not a
debug-port target. [measured; see [E68](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked)]

## 9. Evidence map

| Claim | Experiment | Status |
|---|---|---|
| Two blocks; base `0x111000`; partition counts | [E63](../experiments/04_hs-sec2-fsp-memory.md#043-priscv-block-is-split-per-master) | measured |
| ICD is live at PL0; command behavior; 14.4 MB code window | [E67](../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port) | measured |
| Boot-window block; RDM refusal; FSP has no ICD | [E68](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked) | measured |
| Host PA `0x01000000` is empty; backing is in the WPR | [E74](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut) | measured |
| GSP EMEM is empty at runtime | [E10](../experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty) | measured |
| Register offsets and PLM encoding | [register map](../specs/03_register-map.md), [privilege and rate control](../specs/02_privilege-and-rate-control.md) | measured/source |

Tools: [Register access](../tools/register-access/) for the GSP and host register
sweeps, and [Driver harness](../tools/driver-harness/) for the ICD tools and the
instrumented-driver trace.

## 10. Limits and open questions

- The reason for the per-master split — a decoupler mapping versus two register
  files — is not proven.
- The host-only table at `0x1111a8`–`0x1111e4` and the `0x111610`+ pattern are
  unidentified.
- `TRACEPC_LO 0x11140c = 0x0100287c` does not decode at its stated address, so
  the trace-register association is unconfirmed.
- Why `RDM` is refused in the HS window and early GSP-RM, and what enables it
  during GSP-RM init, is unresolved.
- There is no memory-mapped debug module in `0x111800`–`0x113fff`.
- The ICD is not a route to Heavy Secure firmware. It reads the RM code segment
  only after boot, and the boot image and WPR are outside the aperture.
