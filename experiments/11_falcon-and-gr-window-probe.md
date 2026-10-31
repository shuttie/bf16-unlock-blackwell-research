# The falcon blocks and the GR window: FECS is not host-readable

## Summary

**The idea.**

- The FECS route assumed the graphics front-end microcode could be reached
  from the host. Two things made that testable: the debugger class reads
  registers the host path rejects
  ([the debugger group](../experiments/10_debugger-class-and-fecs-ucode.md)),
  and the vBIOS table names the engines its images are for.
- This group covers the falcon register blocks on GB202, the GR window the
  GSP-RM admits, and the correction to the ucode mapping.

**What it found.**

- GSP, SEC2, and FSP answer at their documented falcon bases. Their boot and
  vector registers return the "blocked" markers, not data
  ([the falcon blocks](#111-the-falcon-blocks-answer-or-refuse)).
- The PMU, FECS, and GPCCS bases return decode or not-implemented markers. The
  FECS-adjacent registers at `0x409b00` still answer, and `0x409b7c` carries a
  PLM-shaped word
  ([the same record](#111-the-falcon-blocks-answer-or-refuse)).
- The GR window the GSP-RM admits (`0x140000`–`0x17ffff`) is empty except a
  `0x100`-byte header at its base
  ([the GR window](#112-the-admitted-gr-window-is-empty)).
- The vBIOS table is the PMU lookup table; target `0x01` is PMU in the only
  public mapping, so the two target-`0x01` images are not FECS/GPCCS. All four
  descriptors are version 6, `0x50` bytes
  ([the table](#113-the-ucode-table-is-the-pmu-lookup-table)).

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

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 11.1 | [The falcon blocks answer or refuse](#111-the-falcon-blocks-answer-or-refuse) | GSP/SEC2/FSP live; FECS absent |
| 11.2 | [The admitted GR window is empty](#112-the-admitted-gr-window-is-empty) | no code or state at `0x140000` |
| 11.3 | [The ucode table is the PMU lookup table](#113-the-ucode-table-is-the-pmu-lookup-table) | target `0x01` is PMU; v6 descriptors |

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
| `0x001f2000`–`0x001f3c00` | `0x8fc36009`, `0xecc36007`, `0xa0d29004`, `0x5ef0700b`, `0xb33ca004`, `0x96dda006`, `0xf758200d` |
| `0x001f4000`–`0x001f5c00` | `0xffffffff` ×8 |
| `0x0022c000`–`0x0022f800` | `0xbadf202b` ×16 |

**Result.**

- **Answer:** the admitted window holds no ucode and no engine state.
- **What we learned:**
  - The range the GSP-RM filter names is a stub aperture: zero with a `0x10`
    page marker, and one small header at the base.
  - GR space above the window answers with its own decode markers
    (`0xbadf1301`, `0xbadf202b`), so those offsets decode but do not read.
  - The readable content above the window is constants and one
    `0xffffffff` page. Nothing resembles code.
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
- **Open question:** which engine target `0x0e` is, and whether the GB202 GR
  ucode is in the vBIOS at all.
