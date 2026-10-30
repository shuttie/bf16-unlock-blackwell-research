# HS / SEC2 / FSP memory

Recorded 2026-10-25 to 2026-10-28 on the local RTX 5090 pair. Evidence is quoted
inline; no firmware image, dump, or private key is included.

## Reproducing this group

**Hardware.** 2× RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07, Linux,
CUDA 13. `deviceId 1` is `41:00.0`; `deviceId 0` is `c1:00.0`.

**Tools.** [Register access](../tools/register-access/) for the GSP/RM register
paths and [Driver harness](../tools/driver-harness/) for the ICD tools and
instrumented-driver traces. Root is required for MMIO and RM.

**Inputs.** The register maps and ICD probes need no firmware. E67 and E68 compare
the halted PC and RDM bytes against the GSP-RM image, so extract it once:

1. Copy `gsp_ga10x.bin` from the 595.91.07 driver package (or
   `/lib/firmware/nvidia/595.91.07/`).
2. The `.fwimage` section starts at file offset `0x40` and is 72,830,976 bytes; use
   it as `gsp_fwimage.bin`.
3. The extraction and analysis helpers are in
   [GSP-RM tools](../tools/gsp-rm-tools/README.md); the boot image and FMC
   containers are in [FMC tools](../tools/fmc-tools/README.md).

The E68 trace and halt need the instrumented 595.91.07 tree: apply the harness
patches from [Driver harness](../tools/driver-harness/README.md), build, and load
it. The stock driver cannot produce those traces.

**Boot state and cost.** Start from a clean boot with the stock driver loaded and
no Xid. Register reads take seconds. An ICD `STOP` halts GSP-RM, raises Xid 154,
and needs a reboot; a wedged FLR or a trace that leaves the card in reset also
needs a reboot. Pass `0000:c1:00.0` and `deviceId 0` for the second card; the tools
default to `0000:41:00.0` and `deviceId 1`.

**Terms.**

| Term | Meaning |
|---|---|
| EMEM / EMEMC / EMEMD | Falcon external-memory port and its control/data registers |
| AINCR / AINCW | auto-increment read/write flags for the EMEM pointer |
| PLM | per-block read/write permission mask ([privilege and rate control](../specs/02_privilege-and-rate-control.md)) |
| HS / LS / PL2 / PL3 | Heavy Secure / Light Secure / GSP-RM / boot-firmware privilege levels ([privilege and rate control](../specs/02_privilege-and-rate-control.md)) |
| FSP / SEC2 | security processor that runs first / GPU security coprocessor ([boot chain](../specs/01_boot-chain.md)) |
| GSP / GSP-RM | the GPU's RISC-V coprocessor / the main GPU firmware it runs, in Light Secure ([boot chain](../specs/01_boot-chain.md)) |
| FMC | first-stage mutable GPU firmware, runs in Heavy Secure ([boot chain](../specs/01_boot-chain.md)) |
| Falcon / BootROM | NVIDIA's microcontroller block / the immutable ROM that starts the next stage ([boot chain](../specs/01_boot-chain.md)) |
| PFSP | the FSP's register and EMEM window ([boot chain](../specs/01_boot-chain.md)) |
| WprMeta | host-filled boot descriptor the FMC consumes ([boot chain](../specs/01_boot-chain.md)) |
| Xid | NVIDIA driver/kernel error code; Xid 154 means GPU reset required ([errors and logging](../specs/08_errors-and-logging.md)) |
| FB / PA / VA | framebuffer memory / physical address / virtual address ([memory and host access](../specs/07_memory-and-host-access.md)) |
| vBIOS | board firmware and option ROM ([vBIOS and devinit](../specs/05_vbios-and-devinit.md)) |
| PRISCV / ICD | GSP RISC-V register block / its in-circuit debugger ([GSP RISC-V and PRISCV](../specs/06_gsp-riscv-and-priscv.md)) |
| RDM / RREG / RCSR / RSTAT / RPC | ICD commands: read memory / read register / read CSR / read status / read PC |
| WPR / FRTS | write-protected firmware region / firmware runtime state inside it ([memory and host access](../specs/07_memory-and-host-access.md)) |
| COT / GspRmBoot | chain-of-trust message from host to FSP / boot image the FMC authenticates ([boot chain](../specs/01_boot-chain.md), [firmware formats](../specs/04_firmware-formats.md)) |

## E10 · The HS memory-read route

*2026-10-25 · status: CLOSED-MEASURED*

**Hypothesis.** A PL2 primitive can read decrypted FMC plaintext out of HS memory.

**Instrument.** `regops` through the GSP (`GPU_EXEC_REG_OPS`, `READ_32`) plus the
`gsp_probe.sh`, `gsp_emem_stream.sh`, and `gsp_emem_write.sh` wrappers in
[Register access](../tools/register-access/). Target `deviceId 1` = `41:00.0`;
root.

**Method.** The source basis is the driver's boot-image path:

- `kgspPrepareBootBinaryImage_IMPL` allocates sysmem with
  `MEMDESC_FLAGS_ALLOC_IN_UNPROTECTED_MEMORY` and copies the driver bindata
  verbatim.
- `_kgspBootstrapGspFmc_GH100` points the BootROM at that buffer with
  `BCR_DMAADDR_FMCCODE`.
- The host buffer is therefore ciphertext, not plaintext.

The RISC-V debug entry points in the installed 595.91.07 driver are inert stubs:

```bash
objdump -d "$(modinfo -n nvidia)" --start-address=0x68340 --stop-address=0x683b0
# kflcnRiscvIcd{WaitForIdle,ReadMem,ReadReg,Rpc}: mov $0x56,%eax ; ret
```

`0x56` is `NV_ERR_NOT_SUPPORTED`. The live test then arms the GSP EMEM port and
streams it.

**Observed data.** Arming `EMEMC(0)` with `AINCR` and streaming 2,048 words:

```text
== arming EMEMC(0) = 0x02000000  (AINCR | offset 0)
  WRITE         off=0x00110ac0 status=0   SUCCESS        value=0x02000000
  READBACK      off=0x00110ac0 status=0   SUCCESS        value=0x02000000
...
  [ 63] 0000000000  status=0 SUCCESS
```

The stream advanced `0x02000000 -> 0x02002000` (4 B per read), and all 2,048 words
read zero. The write/read discriminator passed 5/5:

```text
PASS  AINCW arm readback: 0x01001ffc
PASS  word at 0x1ffc: 0xdeadbeef
PASS  word at 0x1ff8: 0x00000000   (neighbour: not loopback)
PASS  word at 0x1ffc (2nd): 0xdeadbeef   (after re-arm: not stale)
PASS  word at 0x1ffc after restore: 0x00000000
== RESULT: 5 passed, 0 failed
```

No IMEM/DMEM ports exist:

```text
0x00110180 = 0xbadf5610  status=0 SUCCESS
0x00110184 = 0xbadf5610  status=0 SUCCESS
0x001101c0 = 0xbadf5610  status=0 SUCCESS
0x001101c4 = 0xbadf5610  status=0 SUCCESS
```

The eight EMEM ports at `0x110ac0`–`0x110afc` are present.

**Result.** EMEM is real PL2-reachable storage, and it held zeros at the sample
point. The FMC plaintext never appears there, and the RISC-V debug API is compiled
out.

**Reproduce.**

1. Build `regops` from [Register access](../tools/register-access/):
   `gcc -O2 -Wall -o regops regops.c`.
2. Run `sudo ./gsp_probe.sh` and `sudo ./gsp_emem_stream.sh`.
3. Run `sudo ./gsp_emem_write.sh` for the 5/5 discriminator.
4. Expect `AINCR` to advance 4 B per read, all streamed words zero, and the write
   test to pass. The stream arm is `0x02000000`; the write discriminator's arm is
   `0x01001ffc`. `0x00011ffc` silently disables `AINCW`.

**Limits.** The EMEM is empty at the sample point. This does not prove the FMC
never uses it; it proves nothing readable remained at runtime.

## E21 · The FSP core EMEM port

*2026-10-26 · status: CLOSED-MEASURED*

**Hypothesis.** The FSP core's EMEM port may expose readable HS data or accept a
host pointer write.

**Instrument.** `regops ... ememstream <ctrl> <data> <new> <orig> <count>` in
[Register access](../tools/register-access/); each write/read/restore is one
non-transactional RPC. Target `deviceId 1` = `41:00.0`; root.

**Method.** Read-only maps on both cards, then two pointer write/read/restore/read
batches on `41:00.0`.

**Observed data.** The port is present, and host and GSP see the same channel
values:

```text
0x008f0ac0 = 0x5536c785  status=0 SUCCESS   (ch0 ctrl)
0x008f0ac4 = 0x6fd593dc  status=0 SUCCESS   (ch0 data)
0x008f0ac8 = 0xc79705f3  status=0 SUCCESS   (ch1 ctrl)
0x008f0acc = 0x8f7a6cc2  status=0 SUCCESS   (ch1 data)
0x008f0ad0 = 0x5792ea26  status=0 SUCCESS   (ch2 ctrl)
0x008f0ad4 = 0xf7cd4b7b  status=0 SUCCESS   (ch2 data)
0x008f0ad8 = 0xc1c4c375  status=0 SUCCESS   (ch3 ctrl)
0x008f0adc = 0x21fa03ab  status=0 SUCCESS   (ch3 data)
```

The pointer writes are accepted and dropped:

```text
CTRL WRITE   new=0x5736c785 status=0 SUCCESS
CTRL READ    after new = 0x5536c785 status=0 SUCCESS  -> DROPPED
DATA[  0]    = 0x6fd593dc status=0 SUCCESS
CTRL WRITE   restore=0x5536c785 status=0 SUCCESS
CTRL READ    after restore = 0x5536c785 status=0 SUCCESS  -> RESTORED
```

The second variant (`new=0x55360001`) is also dropped. The likely gate is
`0x8f0a90 = 0xffffff8f` (read all, write L3 only). The adjacent 16-byte constant is
`e81dc861 98216d8b 803e5471 9e870bdf`.

**Result.** The port is real, but the pointer cannot be moved and only the
firmware-selected word is readable. The constant is not in the GSP-RM image, the
installed driver module, the vBIOS, or the FMC containers; it is not an MD5/SHA
prefix; and it is not an AES-128 key for the FMC or bootloader in ECB, CBC, or CTR
with the tested key/IV variants. It remains unidentified.

**Reproduce.**

1. Build `regops` from [Register access](../tools/register-access/).
2. Run the two `ememstream` commands in the record.
3. Expect `CTRL WRITE ... SUCCESS`, then `CTRL READ after new` equal to the old
   value (`DROPPED`), with the data word unchanged.
4. Read `0x8f0a90` and `0x8f0ab0` to confirm the PLM and the constant.

**Limits.** The PLM at `0x8f0a90` is the likely gate by proximity, not by a
controlled gate test. The constant stays unidentified.

## E63 · The RISC-V PRISCV block and its two-sided host/GSP map

*2026-10-27 · status: OPEN (map measured; ICD command path not tested)*

**Hypothesis.** The GSP's RISC-V core may expose a debug module (RISC-V DM or
Falcon ICD) above the `0x110000–0x11172c` window that
[E10](../experiments/04_hs-sec2-fsp-memory.md) swept.

**Instrument.** `riscv_dm_probe.sh` in [Register access](../tools/register-access/)
sweeps a half-open range in 128-dword chunks through `GPU_EXEC_REG_OPS` (`READ_32`;
the GSP is the bus master). The host view is `regops ... bar <off> 40` (direct
BAR0). Target `deviceId 1` = `41:00.0`; root.

**Method.** The GB202 PRISCV offsets are `CPUCTL 0x388`, `RPC 0x3ec`,
`IRQMASK 0x528`, `IRQDEST 0x52c`, and `PRIV_ERR 0x420–0x430`; the ICD layout is
`CMD 0x3d0`, `ADDR0/1 0x3d4/0x3d8`, `RDATA0/1 0x3e4/0x3e8`, with
STOP/RREG/RDM/RSTAT/RCSR/RPC opcodes. The probe compares 4,096 GSP reads with 512
host reads over the same offsets.

**Observed data.** The GSP-side map at the PRISCV base:

```text
0x00111004 = 0x06003004
0x00111320 = 0xffffff8f   (PLM: read all, write L3)
0x00111328 = 0xffffffff   (PLM: read/write all)
0x00111388 = 0x00000180   (CPUCTL)
0x001113d0 = 0xbadfffff   (ICD_CMD, GSP refused)
0x001113d4 = 0xbadfffff
0x001113d8 = 0xbadfffff
0x001113dc = 0xbadfffff
0x001113ec = 0x01404f66   (GSP-side register, not the host PC)
0x00111528 = 0x810490d2   (IRQMASK)
0x0011152c = 0x010800d0   (IRQDEST)
```

The host-side map for the same offsets:

```text
BAR0 0x00111004 = 0xbadf5720
BAR0 0x00111388 = 0x00000180
BAR0 0x001113d0 = 0000000000
BAR0 0x001113d4 = 0000000000
BAR0 0x001113d8 = 0000000000
BAR0 0x001113dc = 0000000000
BAR0 0x001113ec = 0x9300338a
```

Across the 512 common offsets: 66 identical, 199 differing, 69 host-value/GSP-
sentinel, 80 GSP-value/host-sentinel. The upper window has only 16 implemented
dwords; the two 12-byte tables start:

```text
0x00111f00 = 0x00000f00
0x00111f08 = 0x11111111
0x00111f80 = 0x00000f00
0x00111f88 = 0000000000
```

**Result.** The PRISCV base is `0x111000`, not `0x110000`. The block is partitioned
per master, not a single register file seen twice. The Falcon block ends at
`0x110d4c`, and `0x110d50–0x110ffc` is unimplemented. `0x111800–0x113fff` contains
no debug module: 16 implemented dwords in the two tables, the rest `0xBADF5040`.

The PC is one-sided at this stage: `RPC` is visible only to the GSP and reads a live
code address (`0x01404f66`, which disassembles as GSP-RM code). The host's
`0x1113ec` changed between two reads (`0x93002eb8` → `0x9300338a`, Δ`0x4d2`) and is
not a PC. The host's ICD registers at `0x1113d0–0x1113dc` read zero and are not
blocked, while the GSP gets `0xBADFFFFF`, so the ICD is host-facing but was never
commanded in this experiment. `TRACEPC_LO 0x11140c = 0x0100287c` does not decode at
its stated address, so the trace association is unconfirmed.

**Reproduce.**

1. Build `regops` from [Register access](../tools/register-access/).
2. Run `sudo riscv_dm_probe.sh` for the GSP view over `0x110000..0x113fff`.
3. For the host view, run `regops ... bar <off> 40` at `0x111000`, `0x111100`,
   … `0x111700`.
4. Expect the base at `0x111000`, host-blocked core state, the host-only ICD at
   `0x1113d0`, and GSP-only core and trace registers. The ICD command path is not
   tested here; [E67](../experiments/04_hs-sec2-fsp-memory.md) does that.

**Limits.** The partition counts are a map comparison, not a proof of why the split
exists. The `0x1113ec` question is resolved by
[E67](../experiments/04_hs-sec2-fsp-memory.md): the host register is the true PC when the ICD is
accessible; the GSP-side `0x01404f66` is a different register.

## E67 · The PRISCV ICD is live: host command execution and a 14.4 MB halted-core read window

*2026-10-28 · status: CLOSED-MEASURED (ICD live; RDM window measured)*

**Hypothesis.** The PRISCV ICD at `0x1113d0`–`0x1113e8`, which
[E63](../experiments/04_hs-sec2-fsp-memory.md) found host-readable but idle and refused to the
GSP, may be a working debug command engine, and `RDM` may give a host read path
into the core's memory.

**Instrument.** Direct BAR0 MMIO from the host, with no RM/GSP involvement: the ICD
C tools (`icd_cmd.c`, `icd_rdm.c`, `icd_dump.c`, `icd_halt_probe.c`) and their
wrappers in [Driver harness](../tools/driver-harness/). Target `41:00.0`; root.
`STOP` halts GSP-RM and costs a reboot.

**Method.** The command word uses the Ampere encoding: `OPC[4:0]`, `SZ[7:6]`,
`IDX[12:8]`, `ERROR[14]`, `BUSY[15]`, `PARM[31:16]`; opcodes STOP `0x0`, RREG
`0x8`, RDM `0xa`, RSTAT `0xe`, RCSR `0x10`, RPC `0x12`. Reads must be aligned to
the access size. No `STOP` was issued until the deliberate halt run.

**Observed data.** With GSP-RM up, `ADDR0`/`ADDR1` (`0x1113d4`/`0x1113d8`)
accepted `0xdeadbe00`, read it back, and restored to `0`; `CMD` retained
`0x0000000e`. A concurrent CUDA workload was unaffected. While the core ran,
`RSTAT` idx 0/3/4 completed (`ERROR=0`, `RDATA=0`), but `RREG x1/x2`, `RCSR misa`
and `RDM` returned `CMD[14]=1` and `RDATA=0xbadfbadf`
(`0xbadfbadfbadfbadf` for 8-byte reads). The rejection is the halted-hart
requirement, not a dead latch.

After `STOP` (`CMD=0`), `CPUCTL` moved `0x2a0` → `0x380`, and the reads succeeded:

| Read | Value |
|---|---|
| `RPC` | `0xffffffff93002ebc` |
| `RREG x1` (ra) | `0xffffffff93002ea6` |
| `RREG x2` (sp) | `0xffffffffa3003ed0` |
| `RSTAT` 0/3 | 0 |
| `RDM 0x01400000`/8 | `0x96be52c70693b9e7` |
| `RDM 0x01404f64`/4 | `0x4208962a` |
| `RDM 0x01404f66`/2 | `0x4208` |

The host-side `0x1113ec` read `0x93002ebc`, matching the ICD `RPC`; the GSP
master's `0x1113ec` read `0x01404f66`. After the `STOP` the GSP heartbeat timed
out and the driver's core-dump path ran: it read `csr[0x897]=5`, `0x899=1`,
`0x89a=0`, `0x8b4=0`, `0x8b5=0`, `csr[0xc00]=0x48bc3341d37e`,
`0xc01=0x292d5e5f1480`, `0xc02=0x23`, attempted a stack unwind with `RDM`, got 0,
and raised Xid 154.

With the core halted, reads succeed over the RM code segment
`0x01000000`–`0x01DCD000` (tested at and between `0x01000000` and `0x01B40000`)
and fail outside it: `0x01000000` = `7f454c4602010100` (ELF magic), `0x01400000`
= the image bytes at file `0x58F000`, `0x01800000` OK, `0x02000000` ERROR;
`0x04000000` (data segment), `0x13ec00000`, `0x7dd580000`, `0x7e72e0000`,
`0x7f0000000`, `0x7f42c0000` all ERROR.

The address model: the `.fwimage` has a `0x18F000`-byte wrapper; at file
`0x18F000` is an ELF64 RISC-V image with `p_vaddr 0x01000000` (code,
`filesz 0xDCD000`, RX), `p_vaddr 0x04000000` (data, `filesz 0x1A1000`, RW), entry
`0x01A0F3DA`. It is loaded at core address `0x01000000` (not host FB PA
`0x01000000`, which is empty — [E74](../experiments/05_fmc-fsp-boot-inputs.md)) and runs at
runtime VA `link + 0x92000000`. The translation from the halted PC to the image:

```text
file offset = link VA - 0x00E71000 = PA - 0x00E71000
runtime VA  = link VA + 0x92000000 = PA + 0x92000000
```

| Register | Link VA | RDM read | Image file offset |
|---|---|---|---|
| `RPC 0x93002ebc` | `0x01002ebc` | `0x071300b7` | `0x191EBC` |
| `ra 0x93002ea6` | `0x01002ea6` | `0xe11c` | `0x191EA6` |

Both RDM bytes match the extracted image at the listed offsets. That is the
independent check that `0x93002ebc` is the true halted PC and `0x01404f66` is a
different, per-master register.

**Result.** The PRISCV ICD is a live, host-facing PL0 debug port. It provides
register access and a 14.4 MB read window over the halted core's RM code segment,
and the driver itself uses it for core dumps. It does not reach the WPR/FRTS and
does not change the FEAT/PL3 analysis. The obvious follow-up — halt the core
during the FMC window and read the image — is tested in
[E68](../experiments/04_hs-sec2-fsp-memory.md) and fails: the ICD is blocked through HS, `RDM`
is refused there, and the post-boot aperture is the RM code segment only.

**Reproduce.**

1. Build the ICD tools from [Driver harness](../tools/driver-harness/):
   `gcc -O2 -o icd_cmd icd_cmd.c` (and the same for the other probes).
2. Run the command and RDM probes, then `STOP`, then the register and RDM reads.
3. Expect the running-core rejection (`CMD[14]=1`, `0xbadfbadf`), then success
   after `STOP`; expect Xid 154 and a reboot when GSP-RM is halted.
4. Compare `RDM 0x01002ebc/4` with file offset `0x191EBC` in your own
   `gsp_fwimage.bin`; expect `0x071300b7`.

**Limits.** The halted PC and the 14.4 MB code window are measured. The data
segment, the boot image, and the WPR/FRTS are outside the window;
[E68](../experiments/04_hs-sec2-fsp-memory.md) tests them and closes the boot-image route. The
`0x01000000` FB address is a core-space address, not a host physical address
([E74](../experiments/05_fmc-fsp-boot-inputs.md)).

## E68 · The boot window: ICD blocked through HS, RDM gated, the boot image at `0xefd00000`

*2026-10-28 · status: CLOSED-MEASURED (ICD memory path; FSP has no ICD)*

**Hypothesis.** The ICD can be commanded during the FMC/BootROM window and `RDM`
can read the decrypted boot image, either by a delay sweep or by halting when the
image executes.

**Instrument.** Three instruments on `41:00.0`, all from
[Driver harness](../tools/driver-harness/):

1. **Read-only PC trace.** Armed immediately after the COT response; samples
   `CPUCTL 0x111388`, the host PC mirror `0x1113ec`, `ICD_CMD 0x1113d0`,
   `ENGINE 0x1103c0`, and the reset PLM `0x1103c4` every 100 µs for 1.5 s.
2. **Targeted halt.** Polls the PC mirror every 10 µs; mode 0 stops on the first
   valid PC (boot image), mode 1 on the first PC inside the GSP-RM ranges (LS
   transition). Then `STOP`, RPC/RREG/RSTAT, probes of the boot-image hypotheses,
   and a `0x48000`-byte dump at the first working address.
3. **Post-boot halt.** `icd_bootimg_probe.c` reproduces the
   [E67](../experiments/04_hs-sec2-fsp-memory.md) halt on a healthy system and probes
   `0xEFD00000`, `0x5DD00000`, `0x181D00000`, the data segment, and its runtime VA.

The FSP was swept separately: the full PFSP window `0x8f0000`–`0x8f3fff` (4,096
dwords per view) through host BAR0 and through the GSP.

**Method.** The trace is armed immediately after the COT response; the targeted
halt and the FSP sweep follow the same boot. The trace and halt hooks are the
instrumented-driver patches in [Driver harness](../tools/driver-harness/); the
boot-chain terms are in [the boot-chain spec](../specs/01_boot-chain.md).

**Observed data.** The PC trace shows the block opening at about 155 ms:

```text
# t_us,cpuctl,pc,cmd,engine,rplm
0,badf4100,badf4100,badf4100,badf4100,badf4100
800,180,badf5620,badf5620,badf5720,f00
154800,180,badf5620,badf5620,badf5720,f00
155300,180,efd018c4,0,badf5720,f00
155800,180,930054b6,0,badf5720,f00
```

The first valid PCs on the two cards were `0xefd00174`/`0xefd00894`/`0xefd029b6`
and `0xefd018c4`/`0xefd0073e`/`0xefd01c98`; GSP-RM followed 0.5–0.6 ms later. The
boot image is `0x47000` bytes: the boot log records
`WprMeta bootloader{addr=… size=290816}` and the `GspRmBoot` bindata is 290,816
bytes; one run sampled `0xefd47000`, base+`0x47000`.

The halt leaves `CPUCTL=0x380` and returns the image's `pc`/`ra`/`sp`, but every
`RDM` is refused:

```text
trigger: yes t=114.940 ms pc=0x930014bc
stop: cmd=0x00000000 cmdBusy=0 cpuctl=0x00000380 hostpc=0x93001628
rpc=0xffffffff93001628 ra=0xffffffff930015a0 sp=0xffffffffa3007ed0
probe 0x1000000 err=1 val=0xbadfbadfbadfbadf
probe 0xefd00000 err=1 val=0xbadfbadfbadfbadf
probe 0xefd00170 err=1 val=0xbadfbadfbadfbadf
probe 0xefd40000 err=1 val=0xbadfbadfbadfbadf
probe 0xefd46ff8 err=1 val=0xbadfbadfbadfbadf
probe 0x5dd00000 err=1 val=0xbadfbadfbadfbadf
probe 0x181d00000 err=1 val=0xbadfbadfbadfbadf
dump: no working boot-image candidate
```

The FSP sweep finds no PRISCV core interface at either placement:

```text
BAR0 0x008f1388 = 0xbadf5040   (+0x1000 placement, not implemented)
BAR0 0x008f13d0 = 0xbadf5040
BAR0 0x008f0388 = 0xbadf5620   (Falcon+0x3d0 placement, port present but blocked)
BAR0 0x008f03d0 = 0xbadf5620
```

`GspRmBoot` is opaque: 290,816 bytes, entropy 7.999, no plaintext header, and a
prod/debug XOR with 1,167 zero bytes in 290,816 (0.401%, chance rate), so no shared
keystream. Its authentication is covered in
[E69](../experiments/05_fmc-fsp-boot-inputs.md).

**Result.** The block is closed through the whole HS phase: `CMD` and the PC
mirror read `0xbadf5620` from the COT response until about 155 ms, while the Falcon
`ENGINE` reads `0xbadf5720`; `CPUCTL` (`0x180`) and the reset PLM (`0x00000f00`)
stay readable. At the unblock the boot image (`0xefd0xxxx`, `0x47000` bytes) is
executing, and GSP-RM starts 0.5–0.6 ms later. `STOP` works in that window but
every `RDM` is refused, including the `0x01000000` control; `RDM` is enabled later
in GSP-RM init, not by the HS→LS transition. After boot the aperture is the RM code
segment only: `0xEFD00000`, `0x5DD00000`, `0x181D00000`, `0x04000000`, and
`0x96000000` all refuse. The plaintext GSP-RM contains no ICD-enable write; its
only PRISCV writes are `IRQDEST`/`0x111520` setup and `ICD_CMD=0` in fatal
self-halt paths, so the refusal is a hardware/firmware privilege gate.

The FSP has no debug port. The Falcon+`0x3d0` placement reads `0xbadf5620` (port
present but blocked), and the GSP-analogous `+0x1000` placement reads
`0xbadf5040` (not implemented). Implemented outliers are `0x8f1274/98/9c` and two
12-byte tables at `0x8f1f00`/`0x8f1f80`; the `0x8f3000` block carries
`0xffffff8f` PLMs. Either way, there is no core interface, and the FSP ICD route is
closed.

**Reproduce.**

1. Build and load the instrumented 595.91.07 tree from
   [Driver harness](../tools/driver-harness/) with the trace and halt hooks.
2. Arm the trace immediately after the COT response; expect the first rows to read
   `0xbadf4100`, then `0xbadf5620` through the HS window, then a valid
   `0xefd0xxxx` PC at about 155 ms.
3. For the halt, run the halt script in mode 0 (first valid PC) or mode 1 (first
   GSP-RM PC); expect `CPUCTL=0x380`, the image's `pc`/`ra`/`sp`, and every `RDM`
   refused. The halt requires a reboot.
4. For the FSP, sweep the full `0x8f0000–0x8f3fff` window through host BAR0 and
   through the GSP; expect `0xbadf5620` at Falcon+`0x3d0` and `0xbadf5040` at
   `+0x1000`, with no core interface.

**Limits.** The trace shows when the block opens and that the boot image is
executing; it does not read the image. `RDM` is refused in the halt window, and
after boot its aperture is the RM code segment only. The FSP is not a debug-port
target.
