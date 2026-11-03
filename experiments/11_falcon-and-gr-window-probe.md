# The falcon blocks and the GR window: FECS is not host-readable

## Summary

**The idea.**

- The FECS route assumed the graphics front-end microcode could be reached
  from the host. Two things made that testable: the debugger class reads
  registers the host path rejects
  ([the debugger group](../experiments/10_debugger-class-and-fecs-ucode.md)),
  and the vBIOS table names the engines its images are for.
- This group covers the falcon register blocks on GB202, the GR window the
  GSP-RM admits, the space above it, and the correction to the ucode mapping.
  The last record follows the ucode table to its consumer.

**What it found.**

- GSP, SEC2, and FSP answer at their documented falcon bases. Their boot and
  vector registers return the "blocked" markers, not data
  ([the falcon blocks](#111-the-falcon-blocks-answer-or-refuse)).
- At the documented bases, the PMU, FECS, and GPCCS registers return decode or
  not-implemented markers. The FECS-adjacent registers at `0x409b00` still
  answer, and `0x409b7c` carries a PLM-shaped word
  ([the same record](#111-the-falcon-blocks-answer-or-refuse)).
- The GR window the GSP-RM admits (`0x140000`–`0x17ffff`) is empty except a
  `0x100`-byte header at its base
  ([the GR window](#112-the-admitted-gr-window-is-empty)).
- The vBIOS table is the PMU lookup table; target `0x01` is PMU in the only
  public mapping, so the two target-`0x01` images are not FECS/GPCCS. All four
  descriptors are version 6, `0x50` bytes
  ([the table](#113-the-ucode-table-is-the-pmu-lookup-table)).
- The space above the window is decode refusals plus the 2 MiB vBIOS PROM at
  `0x300000`–`0x4fffff`, byte for byte, and one per-card table at
  `0x1f2000`–`0x1f3fff`
  ([the space](#114-the-space-above-the-window-is-the-vbios-rom), [the
  table](#115-the-0x1f2000-block-is-a-per-card-table)).
- No component in the open stack reads the vBIOS ucode table on GB202. The
  host FWSEC path is short-circuited before it opens the image, and the RM
  boots GR through a single `sec2_acr` wait with no staging pointers
  ([the consumer](#116-no-stack-component-reads-the-ucode-table)).

**What it did not find.**

- No FECS or GPCCS falcon core, IMEM/DMEM port, or ucode id at the documented
  bases, and no code or state in the admitted GR window
  ([the falcon blocks](#111-the-falcon-blocks-answer-or-refuse), [the
  window](#112-the-admitted-gr-window-is-empty)).
- No app/target-to-FECS mapping. The earlier "target-`0x01` pair is
  FECS/GPCCS" claim is withdrawn
  ([the table](#113-the-ucode-table-is-the-pmu-lookup-table)).
- No FECS/GPCCS plaintext. The bodies stay encrypted past a `0x14`-byte tagged
  preamble.
- No GR ucode or writable block in the space above the window. The dense page
  that looked like memory is the vBIOS ROM
  ([the space](#114-the-space-above-the-window-is-the-vbios-rom)).
- No consumer of the vBIOS table, and no ucode-load record in the GSP-RM boot
  log ([the consumer](#116-no-stack-component-reads-the-ucode-table)).
- No engine name for the 32-record per-card table
  ([the table](#115-the-0x1f2000-block-is-a-per-card-table)).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 11.1 | [The falcon blocks answer or refuse](#111-the-falcon-blocks-answer-or-refuse) | GSP/SEC2/FSP live; FECS absent |
| 11.2 | [The admitted GR window is empty](#112-the-admitted-gr-window-is-empty) | no code or state at `0x140000` |
| 11.3 | [The ucode table is the PMU lookup table](#113-the-ucode-table-is-the-pmu-lookup-table) | target `0x01` is PMU; v6 descriptors |
| 11.4 | [The space above the window maps the ROM](#114-the-space-above-the-window-is-the-vbios-rom) | vBIOS ROM at `0x300000` |
| 11.5 | [The 0x1f2000 block is per-card](#115-the-0x1f2000-block-is-a-per-card-table) | 32 records, 567 words differ |
| 11.6 | [No stack component reads the table](#116-no-stack-component-reads-the-ucode-table) | table inert on GB202 |

## 11.1 The falcon blocks answer or refuse

**Question.** Which falcon register blocks exist on GB202, and which of their
registers can the host read?

**Why.**

- The FECS route needs the graphics front-end falcon. The debugger class reads
  the FEAT bank and the GR-context space, but 10.2 never probed a falcon block.
- The legacy FECS base is a documented address from Pascal through Volta, so
  reading it is the direct test.
- What it would give: the FECS core, its memory ports, and its ucode id, or
  proof the block is not there.

**Method.**

- Tool: the CUDA debugger hook, which issues
  [`NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS`](../experiments/10_debugger-class-and-fecs-ucode.md#101-the-class-is-exposed-and-allocatable)
  on the driver's `0x83de` object.
- Target: `41:00.0`, stock driver, an active CUDA context.
- Steps:
  - Read 12 standard FALCON offsets at the PMU, GSP, FSP, FECS, GPCCS, and
    SEC2 bases.
  - Read the FPF ucode-version fuse arrays.
  - Read the FECS `0x409b00` cluster.
- Args used:
```text
bases   PMU 0010a000  GSP 00110000  FSP 008f0000
        FECS 00409000 GPCCS 0041a000 SEC2 00840000
offsets 000 004 040 0f0 0f4 100 104 10c 198 19c 3c0 40c
fuses   00824100 00824140 008241c0, 16 words each
```

**Observed data.**

| Base | Standard block | Readable registers |
|---|---|---|
| PMU `0x10a000` | `0xbadf5040` ×12 | none |
| FECS `0x409000` | `0xbadf5040` ×11 | `0x40940c = 0x7ff` |
| GPCCS `0x41a000` | `0xbadf1100` ×12 | none |
| GSP `0x110000` | mixed | `+0xf0 = 0xf00`, `HWCFG2 = 0x818787f7`, `ENGINE_RESET = 0x200`; `CPUCTL`/`BOOTVEC`/`DMACTL`/`MAILBOX_TEST = 0xbadf5610`; `MAILBOX0 = 0` |
| FSP `0x8f0000` | mixed | `HWCFG2 = 0x8182a721`, `ENGINE_RESET = 0x200`, `MAILBOX0 = 0`; the rest `0xbadf5620` |
| SEC2 `0x840000` | mixed | `+0xf0 = 0xf00`, `HWCFG2 = 0x818787f7`, `CPUCTL = 0x10`, `MAILBOX0 = 0xd8693000`, `ENGINE_RESET = 0x200`; `BOOTVEC`/`DMACTL = 0xbadf5723` |

All 48 FPF ucode-version words read `0x2`.

The FECS-adjacent cluster:

| Offset | Value |
|---|---|
| `0x00409b00` / `0x00409b04` | `0x80000130` |
| `0x00409b74` | `0xe8` |
| `0x00409b7c` | `0xfffffbff` |

The [first FECS probe](../experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)
read `0x007e0f0a` at `0x409b00`/`04`; this run reads `0x80000130`. The register
is state-dependent or path-dependent, and neither reading changes the outcome.

**Result.**

- **Answer:** the security engines answer at their falcon bases; the PMU, FECS,
  and GPCCS blocks do not.
- **What we learned:**
  - `0x409000` is a sparse GR register and PLM block, not a Falcon core, which
    matches the [register-map note](../specs/03_register-map.md#fecs). The
    standard falcon offsets return the
    [offset-not-implemented](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)
    marker.
  - The GSP, SEC2, and FSP blocks answer, but every boot and vector register is
    behind a blocked-sentinel marker. The debugger does not widen the engine
    surface.
  - `0x409b7c = 0xfffffbff` is PLM-shaped, so the FECS-adjacent cluster is
    security-locked too.
  - The FPF fuse arrays read uniformly `0x2`; they do not distinguish engines.
- **Related:**
  - [The context and descriptor spaces](../experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read).
  - [The FECS register block](../specs/03_register-map.md#fecs).
  - [The sentinel families](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- **Open question:** which base, if any, carries the PMU or FECS falcon on
  GB202.

## 11.2 The admitted GR window is empty

**Question.** Does the `0x140000`–`0x17ffff` window that the GSP-RM admits hold
GR or FECS code or state?

**Why.**

- The GSP-RM `gr_fecs` register filter admits `0x409b00`, `0x409b78`, and that
  range. If a host-readable FECS window exists, it is the last candidate.
- The window is 256 KiB, large enough for a code or data image, and it sits
  just above the `0x137000` privilege block that already reads.
- What it would give: a code window to disassemble, or proof the window is a
  stub.

**Method.**

- Tool: the same debugger hook, with a strided sweep.
- Target: `41:00.0`, stock driver, an active CUDA context.
- Steps:
  - Sweep page starts across `0x140000`–`0x17ffff`.
  - Read two dense pages, at `0x140000` and `0x17f000`.
  - Read the `0x409b00` cluster.
- Args used:
```text
sweep  00140000 count 1024 step 000400
dense  00140000 count 64   step 4
dense  0017f000 count 1024 step 4
block  00409b00 count 32   step 4
```

**Observed data.** Page starts read `0x10` every `0x2000` from `0x140000` to
`0x15e000`, and again at `0x17e000`. Every other sampled offset is zero. The
dense page at `0x17f000` is entirely zero.

The first `0x100` bytes at `0x140000` carry a header-like block:

| Offset | Value |
|---|---|
| `0x00140000` | `0x10` |
| `0x00140028` / `2c` / `30` | `0x70` / `0xc840` / `0x44` |
| `0x00140038` / `3c` | `0x49a40a0a` / `0xff053977` |
| `0x00140048` / `4c` | `0x49a40a0a` / `0xff053977` |
| `0x00140064` / `68` | `0xffffffff` / `0x40000099` |
| `0x00140070`–`7c` | `0xffffffff`, `0xffffffff`, `0x40000099`, `0x40000099` |

The sweep's step arithmetic ran past the window and sampled
`0x180000`–`0x23fc00` as well:

| Offsets | Value |
|---|---|
| `0x001c0000` | `0xffffff8f` |
| `0x001c8000`–`0x001cbc00` | `0xbadf1301` ×16 |
| `0x001f2000`–`0x001f3c00` | per-card table; `0x8fc36009`, `0xecc36007`, `0xa0d29004` and others ([the block](#115-the-0x1f2000-block-is-a-per-card-table)) |
| `0x001f4000`–`0x001f5c00` | `0xffffffff` ×8 |
| `0x0022c000`–`0x0022f800` | `0xbadf202b` ×16 |

**Result.**

- **Answer:** the admitted window holds no ucode and no engine state.
- **What we learned:**
  - The range the GSP-RM filter names is a stub aperture: zero with a `0x10`
    page marker, and one small header at the base.
  - GR space above the window answers with its own decode markers
    (`0xbadf1301`, `0xbadf202b`), so those offsets decode but do not read.
  - The readable content above the window is one per-card table, one
    `0xffffffff` page, and the vBIOS ROM higher up
    ([the map](#114-the-space-above-the-window-is-the-vbios-rom)). Nothing
    resembles Falcon code.
  - `0x1c0000 = 0xffffff8f` matches the Ada FEAT constant that appears in the
    [vBIOS data tail](../specs/05_vbios-and-devinit.md#microcode-table), so the
    GR space carries FEAT-shaped constants.
- **Related:**
  - [The FECS register block](../specs/03_register-map.md#fecs).
  - [The GR privilege block](../specs/03_register-map.md#gr-privilege-block-at-0x137000).
  - [The sentinel families](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- **Open question:** what `0x1c0000 = 0xffffff8f` is and which engine owns the
  `0x1c8000` and `0x22c000` blocks.

## 11.3 The ucode table is the PMU lookup table

**Question.** Which engines do the four vBIOS images belong to, and what do
their descriptors say?

**Why.**

- 10.3 called the target-`0x01` pair the likely FECS/GPCCS images. That
  identification came from size and position, not from a published mapping.
- The Linux nova-core patches parse this table for FWSEC and label target
  `0x01` as PMU, which contradicts the pair claim.
- What it would give: a corrected engine map and the descriptor version the
  GSP-RM consumes.

**Method.**

- Tool: a table parser that walks the BIT, reads the falcon-data structure, and
  decodes each descriptor, applying the EFI correction.
- Target: both cards' 1 MiB dumps; the 2 MiB aperture was already shown not
  linear.
- Steps:
  - Read token `0x70`, the falcon-data word, and the table pointer.
  - Decode the table header and every entry.
  - Decode each descriptor's `vDesc`, stored size, and field block.
- Args used:
```text
BIT image offset     0xdf0
token 0x70 data      0x10c1 -> table pointer 0x4ce9d
EFI correction       0x18000 -> table image offset 0x64e9d
table                1 / 6 / 6 / 35
```

**Observed data.** Both cards carry the same table:

| App | Target | Descriptor | Stored size | vDesc |
|---|---|---|---|---|
| `0x07` | `0x06` | `0x06fda0` | `0x20200` | `0x0050061d` |
| `0x18` | `0x01` | `0x0d6104` | placeholder `0xbadf1100` | — |
| `0x19` | `0x01` | `0x08fff0` | `0x21b00` | `0x00500605` |
| `0x15` | `0x01` | `0x0b1c30` | `0x5b00` | `0x00500605` |
| `0x23` | `0x0e` | `0x0b77bc` | `0x1e200` | `0x0050061f` |
| `0x24` | `0x0f` | `0x0e3304` | placeholder `0xbadf1100` | — |

`vDesc` decodes as: bit 0 version available, bit 2 encrypted, bits 15:8
descriptor version, bits 31:16 descriptor size. All four real descriptors are
version 6, `0x50` bytes, encrypted, and their stored size equals the body
length exactly.

The fields after the stored size repeat one structure. For the two target-`0x01`
images, one pair sums to the stored size:

| Image | Field at `+0x08` | Field at `+0x0c` | Field at `+0x10` | Field at `+0x14` |
|---|---:|---:|---:|---:|
| app `0x19` | `0x9200` | `0x1c800` | `0x3700` | `0x5300` |
| app `0x15` | `0x9200` | `0x5200` | `0x3700` | `0x900` |

`0x1c800 + 0x5300 = 0x21b00` and `0x5200 + 0x900 = 0x5b00`, both equal to the
stored size. App `0x23` and app `0x07` add a `0x1000`/`0x1100` block and a
fixed `0xa00` above that sum.

The body preamble is tagged: app `0x19` and app `0x15` both start with a `0x35`
block, app `0x23` with a `0x1d` block, and app `0x07` starts encrypted at byte
zero. Apps `0x07`, `0x19`, and `0x15` are byte-identical on both cards; app
`0x23` differs in 118 bytes of its plaintext data tail, all outside the code.

**Result.**

- **Answer:** the table is the PMU lookup table, and target `0x01` is PMU in
  the only public mapping. The two target-`0x01` images are one PMU-family
  pair, not FECS/GPCCS.
- **What we learned:**
  - The FECS/GPCCS identification in [the earlier
    record](../experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)
    is withdrawn.
  - The descriptors are version 6 with a `0x50`-byte header, newer than the
    v2/v3 the open driver parses for FWSEC.
  - The values at `+0x08` (`0x9200`) and `+0x10` (`0x3700`) are identical
    across the two target-`0x01` images, and their `+0x0c`/`+0x14` pair sums to
    the stored size.
  - The plaintext part is a small tagged preamble. The app interface table and
    the code are inside the ciphertext.
- **Related:**
  - [The earlier body record](../experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies).
  - [The microcode table](../specs/05_vbios-and-devinit.md#microcode-table).
- **Open question:** which engine target `0x0e` is. Whether GB202 GR ucode is
  in the vBIOS at all is answered in [the consumer
  record](#116-no-stack-component-reads-the-ucode-table).

## 11.4 The space above the window is the vBIOS ROM

**Question.** What does the GR space above the admitted window hold?

**Why.**

- The earlier sweep overshot into `0x180000`–`0x23fc00` and found decode
  markers, one `0xffffff8f` word and a dense high-entropy page at `0x310000`
  ([the window](#112-the-admitted-gr-window-is-empty)).
- If that page were GR state or ucode, it was the only host-readable candidate
  left in the space.
- What it would give: a named block, or proof the space holds no state.

**Method.**

- Tool: the debugger hook's map scanner. It prints every non-zero value,
  sentinels included, so region boundaries are visible.
- Target: `41:00.0`, idle, stock driver.
- Steps:
  - Scan `0x180000`–`0x2fffff` at `0x1000`.
  - Read each answering block densely and refine its boundaries at `0x100`.
  - Compare dense 4 KiB reads with the 2 MiB PROM dump word for word.
  - Sweep to `0x400000` at `0x10000` for the end of the space.
- Args used:
```text
pages  00180000 0x1000 x192    00240000 0x1000 x192
dense  0030f000 00310000 00311000 004ff000  0x400 each
probe  002ff000 0x400          00500000 0x40
```

**Observed data.** The space splits into decode refusals, small blocks, and one
2 MiB ROM window:

| Range | Content |
|---|---|
| `0x180000`–`0x19d000` | `0xbadf1002`/`0xbadf1100` alternating in `0x2000` windows |
| `0x19e000`–`0x1bffff` | `0xbadf1100` |
| `0x1c0000`–`0x1c4fff` | `0x4c`-byte header, then `0xbadf5040` |
| `0x1c5000`–`0x1c7fff` | `0xbadf1100` |
| `0x1c8000`–`0x1cbcff` | `0xbadf1301` |
| `0x1cd000`–`0x1d6fff` | `0xbadf5040`, zero pages at `0x1d0000` and `0x1d4000`, and `0x804407` at `0x1ce000`, `0x1d2000`, `0x1d6000` |
| `0x1d7000`–`0x1e2000` | `0xbadf5040` |
| `0x1e3000`–`0x1ef000` | `0xbadf1100` |
| `0x1f2000`–`0x1f3fff` | 32-record per-card table |
| `0x1f4000`–`0x1f5fff` | `0xffffffff` |
| `0x1f6000`–`0x1ff000` | mixed markers; `0x7e59e2c` at `0x1f9000`, `0x80000000` at `0x1fe000` on card 0 |
| `0x200000`–`0x22bfff` | `0xbadf1002` |
| `0x22c000`–`0x22f9ff` | `0xbadf202b` |
| `0x230000`–`0x2fffff` | markers, with `0xffffffcc` words between `0x290000` and `0x2b5000` |
| `0x300000`–`0x4fffff` | the 2 MiB vBIOS PROM image, byte for byte |
| `0x500000` | `0x87fc029f`, `0x08000000`, `0x00010000`, then `0xbadf5040` |

The `0x300000`–`0x4fffff` window matches the PROM image exactly. `0x30f000`,
`0x310000`, `0x311000`, and `0x4ff000` return 1,024 words each with no
mismatch, and `0x301000` reads `0x5746564e`, `"NVFW"`, the ROM marker at
`+0x1000` ([where the flash sits](../specs/05_vbios-and-devinit.md#where-it-sits)).
`0x2ff000` returns `0xbadf1100` and `0x500000` opens a different block. Where
the two cards' images match, the window returns the same words.

**Result.**

- **Answer:** the space above the window is decode refusals plus the vBIOS ROM
  at `0x300000` and one per-card table at `0x1f2000`.
- **What we learned:**
  - The debugger's GLOBAL read is a BAR0 read. The ROM sits at
    BAR0 + `0x300000`, the same aperture the host dump uses. The direct-probe
    tool warns against raw mmap page scans of that range
    ([access and hazards](../tools/direct-probe/README.md#access-and-hazards));
    these reads went through the debugger's register-op path and the card
    stayed up.
  - The dense `0x310000` page that looked like memory is the ROM's encrypted
    ucode bodies. It is stable and identical on both cards because the image
    bytes are.
  - The map is complete to `0x500000`. The only unidentified data between the
    window and the ROM is the table at `0x1f2000`
    ([the table](#115-the-0x1f2000-block-is-a-per-card-table)).
- **Related:**
  - [The GR window](#112-the-admitted-gr-window-is-empty).
  - [The ucode table](#113-the-ucode-table-is-the-pmu-lookup-table).
  - [Where the flash sits](../specs/05_vbios-and-devinit.md#where-it-sits).
- **Open question:** what the block at `0x500000` is, and what the `0x804407`
  pages above `0x1cd000` are.

## 11.5 The 0x1f2000 block is a per-card table

**Question.** What is the structured block at `0x1f2000`–`0x1f3fff`, and is it
a second per-card config surface?

**Why.**

- It is the only block between the window and the ROM alias that is neither a
  decode marker nor all ones
  ([the space](#114-the-space-above-the-window-is-the-vbios-rom)).
- Its values differ between the two 5090s, so it follows the card, not the
  chip.
- What it would give: a named per-card surface, or proof it is scratch.

**Method.**

- Tool: the debugger hook with a dedicated range dump and a type sweep.
- Target: both cards; card 0 before and after a driver reload.
- Steps:
  - Dump `0x1f2000`–`0x1f3fff` densely on each card.
  - Repeat with `regType=GR_CTX`, and read three offsets with all five types.
  - Read the FEAT bank `0x823800`–`0x82387f` and the FPF arrays `0x824100`,
    `0x824140`, `0x8241c0`.
  - Search both vBIOS dumps, the GSP image, and the existing context and
    shadow-RAM dumps for the differing words.
- Args used:
```text
dense 001f2000 0x800 (type 0 and 1)
feat  00823800 0x80    fpf 00824100 00824140 008241c0
```

**Observed data.** The block is 32 records of `0x100` bytes with one layout.
Each record returns values at fixed word offsets and `0xbadf5040` at `+0x28`–
`0x38`, `+0x70`–`0x78`, `+0xa8`–`0xb8`, and `+0xf0`–`0xf8`; `+0xfc` is always
`0x3`.

Record 0 is header-like: `0x1000` at +0, `0x1000000` at +4 and +0x18,
`0xe000f096` at +0x10, `0xc0003600` at +0x24, `0xf4278000` at +0x3c, `0x8` at
+0x40, `0x7` at +0x48, `0x18390d` at +0x4c, `0x10005` at +0x6c. Records 1–31
carry the per-card values.

- 1,155 non-zero words; 567 differ between the two cards.
- The first word of each record has a low byte in `0x00`–`0x0f`, with per-card
  bits above it.
- Across a driver reload, records 1–31 return identical and three words in
  record 0 change (`0x1f2014`, `0x1f2044`, `0x1f205c`). The body is static; the
  header has runtime fields.
- The differing words I sampled do not appear in either vBIOS dump, the 72 MiB
  GSP image, or the existing context and shadow-RAM dumps. The FEAT bank shares
  only generic constants (`0xbadf5040`, `0x8`, `0x3`).
- GLOBAL and `GR_CTX` return the same words; `TPC`, `SM`, and `QUAD` return
  `regStatus 2`, so the block is global, not per-SM or per-TPC.

**Result.**

- **Answer:** a per-card, structured table, static across a driver reload,
  with a small runtime header.
- **What we learned:**
  - The block is a second per-card surface after the FEAT bank, and it is not
    derived from the vBIOS or the GSP image.
  - The static body points to fused or init-built data. A reboot test would
    separate the two; a reload does not.
  - The type sweep puts it in the global register space, not the typed SM or
    TPC space.
- **Related:**
  - [The space above the window](#114-the-space-above-the-window-is-the-vbios-rom).
  - [The sentinel families](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- **Open question:** what the 32 records index, and whether the body survives
  a reboot.

## 11.6 No stack component reads the ucode table

**Question.** Which component consumes the vBIOS falcon ucode table on GB202?

**Why.**

- [The table decode](#113-the-ucode-table-is-the-pmu-lookup-table) named the
  images but not a consumer.
- The apps (`0x07`, `0x19`, `0x15`, `0x23`) and targets (`0x06`, `0x01`,
  `0x0e`, `0x0f`) have no public mapping beyond target `0x01` = PMU.
- What it would give: a consumer to follow into the code, or proof the table
  is inert on this card.

**Method.**

- Static: the open module's VBIOS and FWSEC path, and a constant scan of the
  GSP-RM decompiled corpus.
- Dynamic: capture the GSP-RM log rings at a driver load with 1 MiB INIT and
  RM rings, decode them, and search for table, app, target and ucode records.
- Args used:
```text
rings  init 0x100000  intr 0x40000  rm 0x100000  mnoc 0x10000
```

**Observed data.**

- The only parser in the tree is the host FWSEC loader. It accepts
  applications `0x05`, `0x45`, `0x85` and descriptor versions 2 and 3. This
  table has none of those applications and only version 6.
- The Blackwell chip binding maps the VBIOS extraction to a stub that returns
  `NV_ERR_NOT_SUPPORTED`, and the init path treats that status as success. The
  image is never parsed on this card.
- The GSP-RM corpus has no `0xB8FF` BIT ID and no `"BIT\0"` signature constant
  in 23,016 functions.
- The boot capture returns 197 records: INIT 64, RM 99, KERNEL 27, INTR 2,
  ROOT 3, RMON 2. The GR path is `gr_fecs` at +20, +226, and +387 ms,
  `sec2_acr` at +387 and +408 ms — the args are a 4-second timeout pair,
  not pointers ([the decode](13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)) —
  and the known `0x137200` refusal at +505 ms.
- I found no record that references a table offset, one of the four app/target
  pairs, or a ucode load. The `0xe` and `0x3` arguments in the timeout sweep are
  slot indices, not engine IDs.

**Result.**

- **Answer:** no component in the open stack reads the table on GB202, so the
  four bodies are not GR ucode here.
- **What we learned:**
  - The host FWSEC path is gated by chip and never runs on GB20x.
  - The RM waits on a `sec2_acr` completion for the GR boot — one wait pair
    per boot, ~20 ms wide — and publishes no staging pointers
    ([the decode](13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)).
  - What consumes apps `0x07`, `0x19`, `0x15`, and `0x23` is outside this
    stack.
- **Related:**
  - [The table](#113-the-ucode-table-is-the-pmu-lookup-table).
  - [The microcode table](../specs/05_vbios-and-devinit.md#microcode-table).
  - [The sentinel families](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- **Open question:** what the Windows driver or the device firmware does with
  the other apps, and what target `0x0e` is.
