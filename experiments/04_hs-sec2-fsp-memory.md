# Reading secure memory through EMEM and the RISC-V debug block

## Summary

**The idea.**

- The first-stage mutable firmware (FMC) and the security processor (FSP) run in
  Heavy Secure (HS). The host and GSP-RM, the main GPU firmware, cannot read their
  memory directly ([boot chain](../specs/01_boot-chain.md),
  [privilege and rate control](../specs/02_privilege-and-rate-control.md)).
- I tested four host-reachable windows: the GSP external-memory (EMEM) port, the
  FSP core EMEM port, the GSP RISC-V (PRISCV) debug block, and the in-circuit
  debugger (ICD) during the boot window.
- What it would give: decrypted boot or FMC data, or proof the windows are empty
  or blocked.

**What it found.**

- GSP EMEM is real GSP-RM (PL2) storage but
  [held zeros at runtime](#041-gsp-emem-is-real-but-empty); FMC plaintext never
  appears there.
- The FSP EMEM port [drops pointer writes](#042-fsp-emem-pointer-writes-are-dropped);
  only the firmware-selected word is readable.
- The PRISCV block is [partitioned per master](#043-priscv-block-is-split-per-master),
  and the ICD is a [live host-facing debug port](#044-priscv-icd-is-a-live-debug-port)
  over halted RM code.
- During the boot window the ICD is
  [blocked through HS](#045-boot-window-icd-route-is-blocked); `RDM` (read
  memory) is refused and the FSP has no debug port.

**What it did not find.**

- No readable FMC plaintext in the [GSP EMEM](#041-gsp-emem-is-real-but-empty) or
  the [FSP EMEM](#042-fsp-emem-pointer-writes-are-dropped).
- No way to [move the FSP EMEM pointer](#042-fsp-emem-pointer-writes-are-dropped).
- No [ICD access through HS](#045-boot-window-icd-route-is-blocked), and no
  boot-image read.
- No [FSP debug port](#045-boot-window-icd-route-is-blocked).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 04.1 | [GSP EMEM is real but empty](#041-gsp-emem-is-real-but-empty) | No plaintext at runtime |
| 04.2 | [FSP EMEM pointer writes are dropped](#042-fsp-emem-pointer-writes-are-dropped) | Pointer fixed; one word readable |
| 04.3 | [PRISCV block is split per master](#043-priscv-block-is-split-per-master) | No debug module found |
| 04.4 | [PRISCV ICD is a live debug port](#044-priscv-icd-is-a-live-debug-port) | Halted RM code readable |
| 04.5 | [Boot-window ICD route is blocked](#045-boot-window-icd-route-is-blocked) | No boot-image read |

## 04.1 GSP EMEM is real but empty

**Question.** Can a GSP-RM read (PL2) through the GSP's EMEM port recover
decrypted FMC plaintext?

**Why.**

- The FMC runs in HS and is supplied encrypted; its plaintext is not
  host-readable.
- If the FMC stages plaintext in GSP EMEM, a PL2 read would expose boot secrets.
- What it would give: FMC plaintext, or proof that the runtime window is empty.

**Method.**

- Tool: `regops` through the GSP (`GPU_EXEC_REG_OPS`, `READ_32`) and the
  `gsp_probe.sh`, `gsp_emem_stream.sh`, and `gsp_emem_write.sh` wrappers from
  [register access](../tools/register-access/).
- Target: `deviceId 1` (`41:00.0`); I ran the wrappers as root.
- Source check: `kgspPrepareBootBinaryImage_IMPL` allocates sysmem with
  `MEMDESC_FLAGS_ALLOC_IN_UNPROTECTED_MEMORY` and copies the driver bindata
  verbatim; `_kgspBootstrapGspFmc_GH100` points the BootROM at that buffer with
  `BCR_DMAADDR_FMCCODE`. The host buffer is ciphertext.
- Stub check: `kflcnRiscvIcd{WaitForIdle,ReadMem,ReadReg,Rpc}` are
  `mov $0x56,%eax; ret` (`NV_ERR_NOT_SUPPORTED`).
- Steps: arm the EMEM control register (`EMEMC(0)`) with the auto-increment read
  flag (`AINCR`); stream 2,048 words; run the write/read discriminator with the
  auto-increment write flag (`AINCW`); check instruction/data memory (IMEM/DMEM).
- Args used:
```bash
gcc -O2 -Wall -o regops regops.c
objdump -d "$(modinfo -n nvidia)" --start-address=0x68340 --stop-address=0x683b0
sudo ./gsp_probe.sh
sudo ./gsp_emem_stream.sh
sudo ./gsp_emem_write.sh
```

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

**Result.**

- **Answer:** EMEM is real PL2-reachable storage, but it held zeros at the sample
  point. The FMC plaintext never appears there, and the RISC-V debug API is
  compiled out.
- **What we learned:**
  - The stream advances 4 B per read; all 2,048 words read zero.
  - The write discriminator passes 5/5: `0xdeadbeef` lands at `0x1ffc`, the
    neighbour is zero, re-arm is not stale, and restore returns zero.
  - No IMEM/DMEM ports exist; the eight EMEM ports at `0x110ac0`–`0x110afc` are
    present.
  - `0x00011ffc` silently disables `AINCW`.
  - The host boot-image buffer is ciphertext; the driver points the BootROM at it
    directly.
- **Related:**
  - The [boot-chain spec](../specs/01_boot-chain.md) covers the encrypted FMC and
    the host buffer.
  - The [FSP EMEM port](#042-fsp-emem-pointer-writes-are-dropped) is the other
    memory window tested.
- **Open question:** whether the FMC uses this EMEM during boot; no experiment
  samples it before runtime.

## 04.2 FSP EMEM pointer writes are dropped

**Question.** Does the FSP core's EMEM port expose readable HS data or accept a
host pointer write?

**Why.**

- The FSP runs first at PL3 (Heavy Secure); its EMEM might hold secure state.
- A writable pointer could redirect the port to host-chosen HS memory.
- What it would give: HS data or a host-controlled read/write window.

**Method.**

- Tool: `regops ... ememstream <ctrl> <data> <new> <orig> <count>` from
  [register access](../tools/register-access/); each write/read/restore is one
  non-transactional request.
- Target: `deviceId 1` (`41:00.0`), root.
- Steps: I read the maps on both cards, then ran two pointer
  write/read/restore/read batches on `41:00.0`.
- Args used: the two `ememstream` batches below; the wrapper takes the control,
  data, new, original, and count values.

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

The second variant (`new=0x55360001`) is also dropped. The likely gate is the
permission mask (PLM) at `0x8f0a90 = 0xffffff8f` (read all, write PL3 only). The
adjacent 16-byte constant is `e81dc861 98216d8b 803e5471 9e870bdf`.

**Result.**

- **Answer:** the port is real, but the pointer cannot be moved and only the
  firmware-selected word is readable.
- **What we learned:**
  - Host and GSP see the same channel values on both cards.
  - Pointer writes return `SUCCESS` and read back unchanged; both variants are
    dropped.
  - The likely gate is `0x8f0a90 = 0xffffff8f` (read all, write PL3 only), by
    proximity rather than a controlled gate test.
  - The 16-byte constant is not in the GSP-RM image, the driver module, the
    [vBIOS](../specs/05_vbios-and-devinit.md), or the FMC containers; it is not an
    MD5/SHA prefix, and it is not an AES-128 key for the FMC or bootloader in the
    tested ECB/CBC/CTR variants.
- **Related:**
  - The [register map](../specs/03_register-map.md) covers the FSP window and the
    `0x8f0a90` PLM.
  - The [privilege spec](../specs/02_privilege-and-rate-control.md) defines the
    PLM fields.
- **Open question:** what the 16-byte constant is; it remains unidentified.

## 04.3 PRISCV block is split per master

**Question.** Does the GSP's RISC-V core expose a debug module above the
`0x110000`–`0x11172c` window?

**Why.**

- The earlier [Falcon-window sweep](#041-gsp-emem-is-real-but-empty) covered
  `0x110000–0x11172c`; a debug module above it could give memory/register access.
- The block appears per-master; mapping it tells where the ICD lives.
- What it would give: a host/GSP debug path, or the layout to target.

**Method.**

- Tool: `riscv_dm_probe.sh` from [register access](../tools/register-access/)
  sweeps a half-open range in 128-dword chunks through `GPU_EXEC_REG_OPS`
  (`READ_32`; the GSP is the bus master). Host view: `regops ... bar <off> 40`
  (direct BAR0, the card's MMIO window;
  [memory and host access](../specs/07_memory-and-host-access.md)).
- Target: `deviceId 1` (`41:00.0`), root.
- Steps: I compared 4,096 GSP reads with 512 host reads over the same offsets,
  then mapped `CPUCTL 0x388`, `RPC 0x3ec`, `IRQMASK 0x528`, `IRQDEST 0x52c`, and
  `PRIV_ERR 0x420–0x430`; ICD `CMD 0x3d0`, `ADDR0/1 0x3d4/0x3d8`,
  `RDATA0/1 0x3e4/0x3e8`, with the STOP, read-register (RREG), read-memory (RDM),
  read-status (RSTAT), read-CSR (RCSR), and read-PC (RPC) opcodes.
- Args used:
```bash
sudo ./riscv_dm_probe.sh
sudo tools/register-access/regops 1 0000:41:00.0 bar 111000 40
```

**Observed data.** The GSP-side map at the PRISCV base:

```text
0x00111004 = 0x06003004
0x00111320 = 0xffffff8f   (PLM: read all, write PL3)
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

Across the 512 common offsets: 66 identical, 199 differing, 69
host-value/GSP-sentinel, 80 GSP-value/host-sentinel. The upper window has only 16
implemented dwords; the two 12-byte tables start:

```text
0x00111f00 = 0x00000f00
0x00111f08 = 0x11111111
0x00111f80 = 0x00000f00
0x00111f88 = 0000000000
```

**Result.**

- **Answer:** the PRISCV base is `0x111000`, not `0x110000`. The block is
  partitioned per master; `0x111800–0x113fff` contains no debug module.
- **What we learned:**
  - Across 512 common offsets: 66 identical, 199 differing, 69
    host-value/GSP-sentinel, 80 GSP-value/host-sentinel.
  - The upper window has 16 implemented dwords; the rest read `0xBADF5040`.
  - The Falcon block ends at `0x110d4c`; `0x110d50–0x110ffc` is unimplemented.
  - The PC is one-sided: `RPC` (read PC) is visible only to the GSP and reads a
    live code address (`0x01404f66`, which disassembles as GSP-RM code). The host's
    `0x1113ec` moved between two reads (`0x93002eb8` → `0x9300338a`, Δ`0x4d2`) and
    is not a PC.
  - The host ICD registers at `0x1113d0–0x1113dc` read zero and are not blocked,
    while the GSP gets `0xBADFFFFF`, so the ICD is host-facing but was not
    commanded here.
  - `TRACEPC_LO 0x11140c = 0x0100287c` does not decode at its stated address;
    trace association is unconfirmed.
- **Related:**
  - The [ICD command test](#044-priscv-icd-is-a-live-debug-port) resolves the host
    PC and commands the port.
  - The [GSP RISC-V and PRISCV
    spec](../specs/06_gsp-riscv-and-priscv.md) covers the block layout.
- **Open question:** why the block is partitioned per master; the counts are a
  map comparison, not a proof.

## 04.4 PRISCV ICD is a live debug port

**Question.** Is the PRISCV ICD a working debug command engine, and can `RDM` read
core memory?

**Why.**

- The [PRISCV map](#043-priscv-block-is-split-per-master) found host-readable
  but idle ICD registers; if live, the ICD is a PL0 debug port.
- The driver itself uses the ICD for core dumps, which suggests a command path.
- What it would give: host read access to halted-core memory and registers,
  possibly the boot image.

**Method.**

- Tools: direct BAR0 register access from the host (the card's MMIO window;
  [memory and host access](../specs/07_memory-and-host-access.md)); the ICD C
  tools (`icd_cmd.c`, `icd_rdm.c`, `icd_dump.c`, `icd_halt_probe.c`) and their
  wrappers in [driver harness](../tools/driver-harness/).
- Target: `41:00.0`, root. `STOP` halts GSP-RM.
- Steps: with GSP-RM up, I tested `ADDR0/1`, `CMD`, `RSTAT`, `RREG`, `RCSR`, and
  `RDM`; then `STOP`; read `RPC`, `RREG`, `RSTAT`, and `RDM`; dumped the code
  window; compared RDM bytes with the extracted image.
- Command encoding: `OPC[4:0]`, `SZ[7:6]`, `IDX[12:8]`, `ERROR[14]`, `BUSY[15]`,
  `PARM[31:16]`. Opcodes: STOP `0x0`, RREG (read register) `0x8`, RDM (read
  memory) `0xa`, RSTAT (read status) `0xe`, RCSR (read CSR) `0x10`, RPC (read PC)
  `0x12`.
- Args used:
```bash
gcc -O2 -o icd_cmd icd_cmd.c
```

and the same for the other probes.

**Observed data.** With GSP-RM up, `ADDR0`/`ADDR1` (`0x1113d4`/`0x1113d8`)
accepted `0xdeadbe00`, read it back, and restored to `0`; `CMD` retained
`0x0000000e`. A concurrent CUDA workload was unaffected. While the core ran,
`RSTAT` idx 0/3/4 completed (`ERROR=0`, `RDATA=0`), but `RREG x1/x2`, `RCSR misa`,
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
`0x01A0F3DA`. It is loaded at core address `0x01000000` (not host framebuffer
physical address, FB PA, `0x01000000`, which is empty; [the FB route is
shut](../experiments/05_fmc-fsp-boot-inputs.md)) and runs at runtime virtual
address (VA) `link + 0x92000000`. The translation from the halted PC to the
image:

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

**Result.**

- **Answer:** the ICD is a live, host-facing (PL0) debug port. It provides
  register access and a 14.4 MB read window over the halted core's RM code
  segment. It does not reach the write-protected region (WPR) or firmware runtime
  state (FRTS), and it does not change the FEAT/PL3 analysis.
- **What we learned:**
  - With GSP-RM up, `RREG`, `RCSR`, and `RDM` are refused with `CMD[14]=1` and
    `RDATA=0xbadfbadf`; `RSTAT` completes.
  - After `STOP`, `CPUCTL` moves `0x2a0`→`0x380`; `RPC`, `RREG`, and `RDM`
    succeed.
  - Reads succeed over `0x01000000–0x01DCD000`; `0x01000000` is ELF magic,
    `0x01400000` matches image file `0x58F000`; addresses outside the code
    segment refuse.
  - The halted PC maps to image offset `0x191EBC`; `RDM 0x01002ebc/4` returns
    `0x071300b7`, matching the extracted image.
  - The driver's core-dump path uses the same ICD; `STOP` raises Xid 154
    ([errors and logging](../specs/08_errors-and-logging.md)).
- **Related:**
  - The [PRISCV map](#043-priscv-block-is-split-per-master) explains the
    host/GSP split.
  - The [boot-window test](#045-boot-window-icd-route-is-blocked) asks whether the
    ICD works during HS.

## 04.5 Boot-window ICD route is blocked

**Question.** Can the ICD be commanded during the FMC/BootROM window and `RDM`
read the decrypted boot image?

**Why.**

- The [live ICD test](#044-priscv-icd-is-a-live-debug-port) showed the ICD can
  read halted RM code after boot; if it works during the boot window, it could
  read the boot image or FMC plaintext.
- The boot image at `0xefd00000` executes for about 0.5–0.6 ms; a targeted halt
  might catch it.
- What it would give: decrypted boot-image or FMC plaintext, or proof the ICD is
  blocked through HS.

**Method.**

- Tools: three instruments from [driver harness](../tools/driver-harness/) on
  `41:00.0`, plus an FSP sweep:
  - Read-only PC trace: I armed it immediately after the chain-of-trust (COT)
    response; it samples `CPUCTL 0x111388`, host PC mirror `0x1113ec`, `ICD_CMD 0x1113d0`,
    `ENGINE 0x1103c0`, and reset PLM `0x1103c4` every 100 µs for 1.5 s.
  - Targeted halt: polls the PC mirror every 10 µs; mode 0 stops on the first
    valid PC (boot image), mode 1 on the first PC inside the GSP-RM ranges (the
    Light Secure, LS, transition). Then `STOP`, RPC/RREG/RSTAT, boot-image
    probes, and a `0x48000`-byte dump at the first working address.
  - Post-boot halt: `icd_bootimg_probe.c` reproduces
    [the live ICD test](#044-priscv-icd-is-a-live-debug-port) and probes
    `0xEFD00000`, `0x5DD00000`, `0x181D00000`, the data segment, and its runtime
    VA.
- Target: `41:00.0`, root; the instrumented driver tree from
  [driver harness](../tools/driver-harness/). `STOP` halts GSP-RM.
- FSP sweep: the full FSP register window `0x8f0000`–`0x8f3fff` (4,096 dwords per
  view) through host BAR0 and through the GSP.
- Args used: the halt script in mode 0 (first valid PC) or mode 1 (first GSP-RM
  PC), then the FSP sweep; the harness README has the build hooks.

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
[the boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md).

**Result.**

- **Answer:** no. The ICD is blocked through the whole HS phase. `CMD` and the PC
  mirror read `0xbadf5620` from the COT response until about 155 ms, while Falcon
  `ENGINE` reads `0xbadf5720`. `STOP` works at unblock, but every `RDM` is
  refused.
- **What we learned:**
  - The first valid PCs on the two cards were
    `0xefd00174`/`0xefd00894`/`0xefd029b6` and
    `0xefd018c4`/`0xefd0073e`/`0xefd01c98`; GSP-RM followed 0.5–0.6 ms later.
  - The boot image is `0x47000` bytes; `WprMeta bootloader{size=290816}` and the
    `GspRmBoot` bindata is 290,816 bytes.
  - `STOP` leaves `CPUCTL=0x380` and returns the image's `pc`/`ra`/`sp`, but every
    `RDM` is refused, including `0x01000000`, `0xefd00000`, `0xefd00170`,
    `0xefd40000`, `0xefd46ff8`, `0x5dd00000`, and `0x181d00000`.
  - `RDM` is enabled later in GSP-RM init, not by the HS→LS transition; after boot
    the aperture is the RM code segment only. `0x04000000` (data) and
    `0x96000000` also refuse.
  - `CPUCTL` (`0x180`) and the reset PLM (`0x00000f00`) stay readable through the
    block.
  - The plaintext GSP-RM contains no ICD-enable write; its only PRISCV writes are
    `IRQDEST`/`0x111520` setup and `ICD_CMD=0` in fatal self-halt paths.
  - The FSP has no debug port: Falcon+`0x3d0` reads `0xbadf5620` (port present but
    blocked), and `+0x1000` reads `0xbadf5040` (not implemented). Implemented
    outliers are `0x8f1274/98/9c` and two 12-byte tables at
    `0x8f1f00`/`0x8f1f80`; the `0x8f3000` block carries `0xffffff8f` PLMs.
  - `GspRmBoot` is opaque: 290,816 bytes, entropy 7.999, no plaintext header; the
    prod/debug XOR has 1,167 zero bytes (0.401%, chance rate), so no shared
    keystream.
- **Related:**
  - The [live ICD test](#044-priscv-icd-is-a-live-debug-port) is the post-boot
    baseline.
  - [The boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md) cover
    `GspRmBoot` authentication.
- **Open question:** which GSP-RM init step enables `RDM` after boot; the
  plaintext image has no ICD-enable write, so the exact mechanism is not
  identified.
