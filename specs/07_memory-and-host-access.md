# Memory and host access: BAR windows, WPR, and EMEM

## At a glance

- **Scope.** How the host reaches GPU memory on GB202: the BAR0 (register) and
  BAR1 (virtual address space, VAS) windows, the PRAMIN framebuffer (FB) window,
  the WPR (write-protected VRAM region) and FRTS (firmware runtime state region)
  layout, the unprotected heaps, and the small EMEM (external memory) windows on
  the GSP (the GPU's RISC-V coprocessor), FSP (the security processor), and SEC2
  (the security coprocessor). It also records the read hazards and the sentinels
  that mark refusals.
- **Bench.** Stock RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  two cards, unless the sentence says otherwise.
- **Evidence.** Measured claims link to the experiment that established them.
  Source-derived claims name the header or driver function; claims carried over
  from Ada/Ampere say so in the sentence.

**The short version.**

- BAR0 memory-mapped I/O (MMIO) is the register window. The PRAMIN window at
  `0x700000` is the working host path to framebuffer physical addresses.
- BAR1 is a VAS window, not a physical-address window. It has no VAS during the
  boot, so FB reads return zeros.
- The WPR is write-protected. Host reads inside it return the `0xbad0ac00`
  access-denied fill.
- The non-WPR heap is readable, but the live resource-manager (RM) objects are
  in the WPR heap.
- The GSP, FSP, and SEC2 EMEM windows are small and mostly empty or blocked.
  None exposed Heavy Secure (HS) data in the steady-state samples.
- Two reads can wedge the GPU: a BAR0 page scan of `0x300000`–`0x400000`, and
  BAR1 framebuffer reads.

**In this spec.**

- [BAR0 and BAR1](#bar0-and-bar1): the register window, the PRAMIN path, and the
  BAR1 VAS problem.
- [WPR and FRTS layout](#wpr-and-frts-layout): the placement model and the
  heap-size lever.
- [Host FB reads and the WPR](#host-fb-reads-and-the-wpr): what is readable and
  what returns `0xbad0ac00`.
- [The non-WPR heap](#the-non-wpr-heap): the 3 MiB unprotected heap and why it
  has no RM objects.
- [EMEM windows](#emem-windows): GSP, FSP core, and SEC2.
- [Fault behavior and sentinels](#fault-behavior-and-sentinels): the bad-read
  values and the wedge cases.
- [What remains open](#what-remains-open): the unresolved memory surfaces.
- [Evidence map](#evidence-map): which record supports each fact.

**Related specs.** The boot chain that creates these regions is in [the boot-chain
spec](01_boot-chain.md); raw register offsets are in [the register
map](03_register-map.md); the PRISCV debug engine is in [the GSP RISC-V
spec](06_gsp-riscv-and-priscv.md).

## BAR0 and BAR1

**BAR0.** The card's memory-mapped register window. Host code reads the FEAT,
FUSE, FECS, GSP, and FSP blocks through it. For framebuffer access, the working
mechanism is the PRAMIN window: 64 KiB at BAR0 `0x700000`. The base is moved with
`kbusSetBAR0WindowVidOffset` and restored after the read. The window writes and
reads back its base; a read at the non-WPR heap returns real data.

**BAR1.** BAR1 is not a one-to-one window onto framebuffer physical addresses. It
is bound to a BAR1 VAS, and its offsets are VAS offsets. During the GSP boot the
VAS does not exist yet: `kbusInitBar1` runs in `kbusStatePostLoad` inside
`gpuStateLoad`, after `kgspInitRm`. Creating a mapping before that point faults
on a NULL PTE array.

The [BAR1 probe](../experiments/08_assessment-and-cross-checks.md#082-direct-bar1-framebuffer-read-probe)
mapped four FB offsets read-only. All four returned zeros:

| Offset | What it stands for | Result |
|---|---|---|
| `0x1000000` | control offset | 0/4096 nonzero |
| `0x7e72e0000` | non-WPR heap | 0/4096 nonzero |
| `0x7f0000000` | mid-WPR | 0/4096 nonzero |
| `0x7f42c0000` | FRTS | 0/4096 nonzero |

The same boot's context dump recorded a positive control at physical
`0x7dd580000` as `nonzero=15063`, so the zeros were not a bad mapping. The probe
left both GPUs in `GPU requires reset`. The reason is in [the FB-route
test](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut): BAR1 offsets
are VAS offsets, and the VAS is absent during the boot. The BAR0 PRAMIN window is
the correct host FB path.

| Mechanism | What it addresses | Measured result |
|---|---|---|
| BAR0 MMIO | registers | reads and writes the documented blocks |
| BAR0 PRAMIN, 64 KiB at `0x700000` | framebuffer physical addresses | reads the non-WPR heap correctly |
| BAR1 | BAR1 VAS offsets, not PA | zeros during boot; no boot-time VAS |

**Hazards.** A read-only page scan of BAR0 `0x300000`–`0x400000` on a live GSP
coincides with Xid 13 → Xid 120 → Xid 154 on both cards. Causation is not proven,
but the working rule is: do not scan that aperture while the driver owns the GPU;
read the flash through the single known-good window at `0x338000`. BAR1 FB reads
also end in `GPU requires reset`. Budget a forced reboot for either.

## WPR and FRTS layout

The firmware lives in a write-protected region (WPR) in framebuffer. The host
chooses the COT offset; the FSP and FMC place the whole GSP-RM footprint relative
to the end of FB. The model is:

```text
GSP_frts_abs = FB_end - COT_offset - 0xA200000
span         = 0xCFE0000 + (gspFwHeapSize - 0x8700000)
nonWprHeap   = GSP_frts_abs - span
```

`frts` is the firmware runtime-state region; `nonWprHeap` is the unprotected heap
that sits below the WPR. `span` is the distance from the non-WPR heap start to
FRTS. The stock values are `nonWprHeap = 0x7e72e0000`, `frts = 0x7f42c0000`, and
`span = 0xCFE0000`.

The model predicts the measured layout across the tested window:

| Run | COT offset | `nonWprHeap` | `frts` | Δ vs stock |
|---|---:|---:|---:|---:|
| stock | `0x1b40000` | `0x7e72e0000` | `0x7f42c0000` | n/a |
| moved | `0x10500000` | `0x7d8920000` | `0x7e5900000` | `0xE9C0000` |
| 1 GiB | `0x40000000` | `0x7a8e20000` | `0x7b5e00000` | n/a |
| heap 256 MiB | `0x1b40000` | `0x7df9e0000` | `0x7f42c0000` | `0x7900000` |
| non-WPR heap 256 MiB | `0x1b40000` | `0x7d75e0000` | `0x7f42c0000` | `0xFD00000` |

The COT offset moves the whole WPR; the heap-size request grows it downward while
the top stays anchored to the COT base. The COT size must be exactly `0x100000`
and the offset must be 128K-aligned; a different size draws `0xd9` and a
misaligned offset draws `0xd6`. The size checks are in [the FRTS-size
rejection](../experiments/05_fmc-fsp-boot-inputs.md#054-frts-size-rejected-by-the-fsp)
and [the control boot](../experiments/05_fmc-fsp-boot-inputs.md#055-frts-size-control-boots-larger-refused).
The placement tests are in [the relocated
base](../experiments/05_fmc-fsp-boot-inputs.md#056-relocated-frts-base-boots),
[the misaligned-base
test](../experiments/05_fmc-fsp-boot-inputs.md#057-misaligned-frts-base-draws-0xd6),
[the second base](../experiments/05_fmc-fsp-boot-inputs.md#058-second-accepted-base-and-units-correction),
[the layout model](../experiments/05_fmc-fsp-boot-inputs.md#059-cot-offset-positions-the-whole-layout),
[the 1 GiB window](../experiments/05_fmc-fsp-boot-inputs.md#0510-placement-window-reaches-1-gib),
and [the heap-size test](../experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward).

`nonWprHeapSize` is the other heap lever. A 256 MiB request moves the
unprotected heap start down by exactly the increase over the 3 MiB stock value,
while the heap end stays at the stock WPR base and FRTS stays anchored
([the non-WPR heap
test](../experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever)).
A 4 GiB request wedges the boot with WPR2 armed.

## Host FB reads and the WPR

Once the BAR0 PRAMIN window is proven with the non-WPR heap control, the host can
read unprotected FB. The results from [the FB-route
test](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut):

| Address | Size | Nonzero | Entropy | Head |
|---|---:|---:|---:|---|
| non-WPR heap `0x7e72e0000` | `0x10000` | 58,707 | 7.6408 | `0200020020000000…` |
| PA `0x01000000` | `0x10000` | 0 | n/a | zeros |
| PA `0x5dd00000` | `0x48000` | 0 | n/a | zeros |
| PA `0x181d0000` | `0x48000` | 0 | n/a | zeros |
| FRTS `0x7f42c0000` | `0x10000` | 49,152 | 2.0000 | `00acd0ba00acd0ba…` |
| `[frts − 0x50000, frts)` | `0x50000` | 245,760 | 2.0000 | `00acd0ba00acd0ba…` |

The WPR range returns the repeating dword `0xbad0ac00`, an access-denied fill:
three nonzero bytes per dword, exactly 3/4 of the window, entropy exactly 2.0,
identical on both cards. It is not firmware. The boot image's slot is
`frts − sizeOfBootloader` = `0x7f4279000`; it falls inside this poisoned range.
The decrypted boot image is inside the WPR, and the host has no readable copy.

The earlier `VA 0xefd00000 → PA 0x5dd00000` inference is retracted: those PAs are
empty. The PRISCV ICD (the GSP's RISC-V in-circuit debugger) uses `0x01000000` in
the core's address space, not as a host FB PA; see [the GSP RISC-V
spec](06_gsp-riscv-and-priscv.md).

## The non-WPR heap

The 3 MiB heap at `nonWprHeapOffset` is readable but is not where the live
resource-manager (RM) objects live. See [the non-WPR heap
test](../experiments/05_fmc-fsp-boot-inputs.md#0526-non-wpr-heap-holds-no-rm-objects).

| Range | Content |
|---|---|
| `+0x000000`–`+0x010000` | 64 KiB structured header, 90% nonzero, entropy 7.64 |
| `+0x010000`–`+0x1A10A2` | `0x1910A2` bytes of uniform random, entropy 7.999–8.000; one 8,288-byte zero hole |
| `+0x1A10A2`–`+0x300000` | zero |

The whole 3 MiB is byte-identical on both cards (SHA-256
`dacca64feb98a6adf61836ff71ed2860b02bb4513e21b7807638f875de142c52`). There is no
object structure: 3,324 code-range dwords are all distinct, the 16-byte histogram
has 102,149 distinct values in 102,666 blocks, and none of the eight known handler
runtime VAs appears. The RM objects are in the protected WPR heap
(`gspFwHeapOffset`, 135 MiB).

The WPR sentinel starts at `0x7e75e0000`, exactly `nonWprHeapOffset + 0x300000`.
The published non-WPR heap size is the whole heap, and the WPR base is
`0x7e75e0000`. The 64 KiB window below the published start still holds data
(6,766 nonzero bytes), so the start is an allocation boundary, not the edge of FB.

## EMEM windows

The GSP, FSP, and SEC2 each expose small local-memory ports. None of them exposes
Heavy Secure data at PL2.

### GSP EMEM

The GSP's legacy IMEM/DMEM ports are absent: `0x110180`+ and `0x1101c0`+ return
`0xBADF5610`. The eight EMEM ports at `0x110ac0`–`0x110afc` are present and
measure 8 KiB. Streaming with `AINCR` advances the pointer 4 bytes per read
(`0x02000000 → 0x02002000` over 2,048 reads); every word read zero. See [the GSP
EMEM test](../experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty).
A write/read discriminator passed 5/5, so the window is real read/write storage,
not a loopback:

```text
AINCW arm readback: 0x01001ffc
word at 0x1ffc:     0xdeadbeef
word at 0x1ff8:     0x00000000   (neighbour: not loopback)
word at 0x1ffc (2): 0xdeadbeef   (after re-arm: not stale)
word at 0x1ffc after restore: 0
```

Only arm-then-read is trustworthy; an immediate readback of `EMEMD` returned
`0xdead5ed0`. The RISC-V debug entry points in the shipped driver are inert stubs
(`mov $0x56,%eax; ret`), so the API is not a hardware gate.

### FSP core EMEM

The FSP has two different EMEM blocks. `0x8f2ac0` is the host-driven RM/MCTP
transport (`NV_PFSP_EMEMC(0)`); `0x8f0ac0` is the FSP core's Falcon EMEM port
block, with four live channels. See [the FSP EMEM
test](../experiments/04_hs-sec2-fsp-memory.md#042-fsp-emem-pointer-writes-are-dropped).

| Offset | Value | Meaning |
|---|---|---|
| `0x8f0a90` | `0xffffff8f` | PLM: read all, write PL3 only |
| `0x8f0ac0/c4` | `0x5536c785` / `0x6fd593dc` | ch0 control/data |
| `0x8f0ac8/cc` | `0xc79705f3` / `0x8f7a6cc2` | ch1 |
| `0x8f0ad0/d4` | `0x5792ea26` / `0xf7cd4b7b` | ch2 |
| `0x8f0ad8/dc` | `0xc1c4c375` / `0x21fa03ab` | ch3 |
| `0x8f0ae0/ec` | `0` | ch4–5 |
| `0x8f0af0/fc` | `0xbadf5620` | ch6–7 |

Pointer write/read/restore batches returned success and read back unchanged, while
the same path writes `0x409800` and PBUS scratch. Only the firmware-selected word
per channel is readable. The PLM at `0x8f0a90` is the likely gate by proximity, not
by a controlled gate test.

The adjacent 16-byte constant is `e81dc861 98216d8b 803e5471 9e870bdf`. It is not
in the GSP-RM image, the installed driver module, the vBIOS, or the FMC containers;
it is not an MD5/SHA prefix; and it is not an AES-128 key for the FMC or bootloader
in ECB, CBC, or CTR with the tested key/IV variants. It remains unidentified.

PFSP EMEM is master-dependent: the host sees ch4–7 `0xBADF5720` and ch1–3
zero/`0xdead5ed0`; the GSP sees ch1/2/4/6/7 `0xBADF5723` and ch3/5
zero/`0xdead5ed0`.

### SEC2

`0x8401c0/c4` is a real host-controlled DMEM port; `AINCR` advances it, but the
first 8 KiB is zero. `0x840180/184` (IMEM) is blocked: `0xbadf5720` from the host,
`0xbadf5723` from the GSP. `0x840ac0/c4` (EMEM) reads `0x02000040` / `0`; empty.
The PLM at `0x8403c4` reads `0x00000b0f` (read all, write none). See [the live SEC2
probes](../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes).

## Fault behavior and sentinels

| Value | Meaning | Seen at |
|---|---|---|
| `0xbad0ac00` | access-denied fill | WPR/FRTS through the BAR0 window |
| `0xBADF5610` | no such Falcon port | GSP IMEM/DMEM |
| `0xBADF5620` | port present but inaccessible | FSP core ports, PRISCV during HS |
| `0xBADF5720` | present but blocked to the host | host reads of GSP/FSP blocks |
| `0xBADF5723` | present but blocked to the GSP | GSP reads of some FSP/SEC2 channels |
| `0xBADF5040` | unimplemented offset | register maps |

The sentinel families and the PRI error codes are in [the errors and logging
spec](08_errors-and-logging.md). Reads inside the WPR return `0xbad0ac00` and do
not wedge the GPU; BAR0 page scans and BAR1 FB reads can wedge it. Recovery is a
forced reboot, and a cold power cycle if WPR2 survives.

## What remains open

- The WPR contents are not readable from the host. The boot image is in the WPR;
  the RM objects are in the WPR heap. A runtime view needs GSP-RM cooperation (an
  RPC that reads or copies its heap) or a PL3 primitive.
- The high-entropy 1.6 MiB allocation in the non-WPR heap is unidentified.
- The exact gate on the FSP core EMEM pointer is likely `0x8f0a90`, but it was not
  proven by a controlled gate test.
- The PRISCV ICD reads the RM code segment after a halt, not the WPR. Its limits
  are in [the GSP RISC-V spec](06_gsp-riscv-and-priscv.md).

## Evidence map

| Experiment | What it establishes |
|---|---|
| [04.1 GSP EMEM](../experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty) | GSP EMEM is 8 KiB, empty, read/write; IMEM/DMEM absent; debug API compiled out |
| [04.2 FSP EMEM](../experiments/04_hs-sec2-fsp-memory.md#042-fsp-emem-pointer-writes-are-dropped) | FSP core EMEM channels, PLM, dropped pointer moves, 16-byte constant |
| [05.4 FRTS size](../experiments/05_fmc-fsp-boot-inputs.md#054-frts-size-rejected-by-the-fsp), [05.5 control boot](../experiments/05_fmc-fsp-boot-inputs.md#055-frts-size-control-boots-larger-refused), [05.7 misaligned base](../experiments/05_fmc-fsp-boot-inputs.md#057-misaligned-frts-base-draws-0xd6) | FRTS size and alignment checks |
| [05.6 relocated base](../experiments/05_fmc-fsp-boot-inputs.md#056-relocated-frts-base-boots), [05.8 second base](../experiments/05_fmc-fsp-boot-inputs.md#058-second-accepted-base-and-units-correction), [05.9 layout model](../experiments/05_fmc-fsp-boot-inputs.md#059-cot-offset-positions-the-whole-layout), [05.10 1 GiB window](../experiments/05_fmc-fsp-boot-inputs.md#0510-placement-window-reaches-1-gib) | COT offset placement model and tested window |
| [05.13 heap-size lever](../experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward) | Heap-size layout lever |
| [08.2 BAR1 probe](../experiments/08_assessment-and-cross-checks.md#082-direct-bar1-framebuffer-read-probe) | BAR1 offsets are not FB PAs; the probe wedges the GPU |
| [05.25 FB route](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut) | BAR1 is a VAS; BAR0 PRAMIN works; WPR returns `0xbad0ac00` |
| [05.26 non-WPR heap](../experiments/05_fmc-fsp-boot-inputs.md#0526-non-wpr-heap-holds-no-rm-objects) | Non-WPR heap contents; WPR base `0x7e75e0000`; no live RM objects |
| [03.1 live SEC2 probes](../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes) | SEC2 memory windows and the PLM |

Tools: [Direct probe](../tools/direct-probe/) for the read-only BAR1 probe,
[Register access](../tools/register-access/) for the GSP EMEM streams, and
[Driver harness](../tools/driver-harness/) for the FB-capture and WPR-layout
experiments.
