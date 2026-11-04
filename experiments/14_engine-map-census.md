# The engine-map census: BAR0 below 16 MiB is mapped

## Summary

**The idea.**

- The engine map was thread-followed, not censused: every closed surface was
  found by following a lead, and "no host window" was a statement about the
  tested bases only ([the falcon
  probe](11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).
- This group scans BAR0 read-only through the CUDA debugger class: the falcon
  `HWCFG2`/`CPUCTL`/`ENGINE_RESET` signature at every `0x1000`-aligned base
  below 16 MiB, a full register set at each candidate that flags, a
  `0x100`-stride value map, and a second dump of the per-card table at
  `0x1f2000`.
- Every batch re-reads `PMC_BOOT_0` as a canary and checks the RM control
  status, so a degraded read path aborts instead of printing zeros. That
  guard exists because the first run crashed the GSP, and the crash is
  recorded here too.

**What it found.**

- The engine map below 16 MiB is complete. Four secure cores answer with the
  `0x818xxxxx` RISC-V family: GSP, SEC2, FSP, and a new fourth block at
  `0x848000` ([the falcon-signature
  census](#141-the-falcon-signature-census-completes-the-engine-map)).
- Thirty-five engine-falcon bases answer in five families, led by twelve
  `0x10000`-strided instances of one family from `0x50f000` to `0x5af000`,
  the per-GPC shape; one block at `0x651000` carries `0xabcd1234` in its
  mailbox, a deliberate pattern ([the naming
  pass](#142-the-naming-pass-splits-the-candidates-into-three-classes)).
- BAR0 above `0x1000000` answers only sentinels at `0x10000` stride, so the
  64 MiB window holds nothing above the first 16 MiB ([the falcon-signature
  census](#141-the-falcon-signature-census-completes-the-engine-map)).
- Two read windows crash GSP-RM through the debugger path, both with the same
  page fault at `pc:0x1368618`: `0x42f900`–`0x431004` and the batch at
  `0x525200`–`0x532c00`. A read is code execution on the GSP, and this is a
  measured crash in its handler ([the read that crashes
  GSP-RM](#143-a-read-through-the-debugger-path-crashes-gsp-rm)).
- The per-card table at `0x1f2000` persists across a cold boot with partial
  mutation: 603 of 1,155 words identical, 552 changed in one to four bytes,
  and every record changed somewhere. Not per-boot randomness, not fused
  data ([the table across a cold
  boot](#144-the-per-card-table-persists-across-a-cold-boot)).
- The RM image carries an engine-aperture table, and it ties `0x8f4000` to
  the same engine as the legacy PMU base `0x10a000`: the PMU block on GB202
  is `0x8f4000`, a blocked secure core beside the FSP ([the image names the
  PMU block](#146-the-image-names-the-pmu-block)).

**What it did not find.**

- No engine name for the non-PMU families. The aperture table names only one
  block outright, through its legacy base: the PMU. The 8-instance families
  at `0x848000`+ and `0x9c0000`+, the `0x1c8000` quartet, and the rest carry
  opaque per-build tags no name hash decodes ([the image names the PMU
  block](#146-the-image-names-the-pmu-block)). Named later, without hashing,
  by [the tag decoder](15_tag-decoder.md#152-the-engine-type-table-names-the-rest-of-the-map).
- No confirmed sibling of the FECS command surface. The doorbell/echo
  candidates the map yields are small-value pairs, and none has the FECS
  command-id register shape ([the coarse map and the doorbell
  census](#145-the-coarse-map-and-the-doorbell-census)).
- No map for `0x42f804`–`0x500000` and `0x525200`–`0x1000000`: the first band
  contains a measured crash window and is skipped, and the second run of the
  map died at the second crash window ([the read that crashes
  GSP-RM](#143-a-read-through-the-debugger-path-crashes-gsp-rm)).
- No new host window into a secure core. The new blocks answer exactly like
  the documented ones: config visible, boot and vector registers blocked.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 14.1 | [The falcon-signature census completes the engine map](#141-the-falcon-signature-census-completes-the-engine-map) | 4 secure cores, 35 engine falcons |
| 14.2 | [The naming pass splits the candidates into three classes](#142-the-naming-pass-splits-the-candidates-into-three-classes) | no BROM id; one `0xabcd1234` mailbox |
| 14.3 | [A read through the debugger path crashes GSP-RM](#143-a-read-through-the-debugger-path-crashes-gsp-rm) | two windows, same fault |
| 14.4 | [The per-card table persists across a cold boot](#144-the-per-card-table-persists-across-a-cold-boot) | 603 words stable, 552 mutate |
| 14.5 | [The coarse map and the doorbell census](#145-the-coarse-map-and-the-doorbell-census) | no FECS sibling; one random window |
| 14.6 | [The image names the PMU block](#146-the-image-names-the-pmu-block) | PMU = `0x8f4000`, beside the FSP |

## 14.1 The falcon-signature census completes the engine map

**Question.** Which BAR0 bases below 16 MiB carry falcon register blocks
beyond the six documented ones?

**Why.**

- The map so far followed threads: the FECS mailbox, the ICD, the vBIOS table.
  No scan had ever asked every base the same question, so a block nobody
  probed could not appear as a lead (the surface-census hole the
  [ideas page](../IDEAS.md#the-surface-census-has-a-first-half) names).
- The PMU is the leading candidate for the power-on FEAT writer, and its
  documented base `0x10a000` is all
  [sentinel](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
  A census either finds the real base or closes the undocumented-base search.
- What it would give: a complete engine map, and if a new block is the PMU, a
  name for the power-on writer.

**Method.**

- Tool: the [debugger-class](../tools/debugger-class/README.md) hook in census
  mode. It rides the CUDA driver's own `0x83de` object and issues read-only
  `EXEC_REG_OPS` controls ([the class
  allocation](10_debugger-class-and-fecs-ucode.md#101-the-class-is-exposed-and-allocatable)).
- Target: `41:00.0`, stock driver, pinned by PCI order so the CUDA device
  cannot silently reorder between cards.
- Steps:
  - Read `+0xf4` (`HWCFG2`), `+0x100` (`CPUCTL`), and `+0x3c0`
    (`ENGINE_RESET`) at every `0x1000`-aligned base in `[0, 0x1000000)`,
    skipping the `0x300000`–`0x400000`
    [hazard](../specs/07_memory-and-host-access.md#fault-behavior-and-sentinels).
  - Prepend a `PMC_BOOT_0 = 0x1b2000a1` canary read to every batch and check
    the RM control status; any mismatch aborts the census.
  - Print the labeled signature at the six documented bases as calibration.
  - Probe `0x1000000`–`0x4000000` at `0x10000` stride for the top of the
    64 MiB BAR0 window.
- Args used:
```text
bases   step 0x1000, range 0..0x1000000, skip 0x300000..0x400000
regs    +0xf4 +0x100 +0x3c0
canary  PMC_BOOT_0 = 0x1b2000a1
top     step 0x10000, range 0x1000000..0x4000000
```

**Observed data.** Calibration first: GSP `0x110000`, SEC2 `0x840000`, and
FSP `0x8f0000` flag (`HWCFG2` `0x818787f7`, `0x818787f7`, `0x8182a721`;
`ENGINE_RESET` `0x200`); PMU `0x10a000`, FECS `0x409000`, and GPCCS
`0x41a000` return sentinels at all three offsets, matching [the falcon
probe](11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse).

One hundred bases flag. Grouped by the triple, the families are:

| `HWCFG2` | `CPUCTL` | Count | Bases |
|---|---|---|---|
| `0x02100c00` | `0x10` | 13 | `0x40c000`, `0x42f000`, `0x50f000`–`0x5af000` at `0x10000` stride |
| `0x00100c00` | `0x50` | 9 | `0x9a6000`, `0xa00000`–`0xa0e000` at `0x2000` stride |
| `0x02900c00` | `0x10` | 7 | `0x1cc000`, `0x1d0000`, `0x1d4000`, `0x844000`, `0x9a4000`, `0x9d8000`, `0x9dc000` |
| `0x03920c00` | blocked | 4 | `0xd40000`–`0xd4c000` at `0x4000` stride |
| `0x00100c00` | `0x10` | 1 | `0x651000` |
| `0x01100c00` | `0x10` | 1 | `0x8a8000` |
| `0x818787f7` | `0x10`/blocked | 2 | SEC2 `0x840000`, GSP `0x110000` |
| `0x8181a7f7` | blocked | 1 | `0x848000` |
| `0x8182a721` | blocked | 1 | FSP `0x8f0000` |
| `0x839387f7` | blocked | 1 | `0x8f4000` |
| `0x03908fec` | blocked | 1 | `0x854000` |

The remaining flags are false positives of the all-three-non-sentinel rule:
the zero window at `0x1ce000`/`0x1d2000`/`0x1d6000`, the `0xffffffff` pages at
`0x109000`, `0x1f4000`, and `0x884000`, a `0xa0000`–`0xbffff` window that
returns one constant at every offset (below), and the `0x423000`/`0x503000`
and `0x513000`–`0x5a3000` instance tables whose `+0xf4` word increments by
`0x99` per `0x10000` block: data, not falcon config.

The top probe answers with sentinels only: 3,072 reads at `0x10000` stride
above `0x1000000`, 768 non-zero, every one a `0xBADF____` value.

**Result.**

- **Answer:** the engine map below 16 MiB is complete, and nothing lives
  above it. Four secure cores answer in the `0x818xxxxx` RISC-V family (GSP,
  SEC2, FSP, and a new block at `0x848000`), plus two more secure-shaped
  blocks at `0x8f4000` and `0x854000` in their own families.
- **What we learned:**
  - Twelve instances of one falcon family at `0x10000` stride from `0x50f000`
    to `0x5af000` is the per-GPC shape on a 12-GPC die; `0x40c000` and
    `0x42f000` are two more of the same family in GR-adjacent space.
  - Every new block, secure or not, answers like the documented ones: config
    registers visible, boot and vector registers blocked or zero. The census
    adds engine windows, not access.
  - The `0x9a4000`/`0x9a6000`/`0x9d8000`/`0x9dc000`/`0xa00000` cluster is the
    densest unnamed falcon group on the die; the PMU question is now a
    choice among named candidates rather than an open base search.
- **Related:**
  - [The falcon probe](11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse).
  - [The PMU and CMS2 blocks](../specs/03_register-map.md#pmu-and-cms2).
  - [The sentinel families](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- **Open question:** what consumes the `0x848000` and `0x8f4000` cores;
  the PMU half is answered in [the image names the PMU
  block](#146-the-image-names-the-pmu-block).

## 14.2 The naming pass splits the candidates into three classes

**Question.** What does the full falcon register set say at each census
candidate, and does any of them expose a ucode id that matches the vBIOS
table?

**Why.**

- The signature census names families, not engines. The register set behind a
  signature is what separates a live core from a coincidental hit.
- The vBIOS ucode table names four targets (`0x06`, `0x01`, `0x0e`, `0x0f`),
  and target `0x01` is PMU in the only public mapping ([the ucode
  table](11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table)).
  A BROM ucode id that matched would name a block outright.
- What it would give: engine names for the new windows, or proof the id
  register cannot name them.

**Method.**

- Tool: the same hook in naming mode, one fresh CUDA client.
- Target: `41:00.0`, stock driver.
- Steps: read ten registers (`MAILBOX0` `+0x40`, `MAILBOX1` `+0x44`, `HWCFG`
  `+0xf0`, `HWCFG2` `+0xf4`, `CPUCTL` `+0x100`, `BOOTVEC` `+0x104`, `DMACTL`
  `+0x10c`, `UCODE_ID` `+0x198`, `ENGIDMASK` `+0x19c`, `ENGINE_RESET`
  `+0x3c0`) at 18 bases: the three live secure cores as calibration and 15
  census candidates.
- Args used:
```text
bases  GSP 00110000 FSP 008f0000 SEC2 00840000
       001cc000 001ce000 001d0000 001d2000 001d4000 001d6000
       0040c000 0042f000 0050f000 0055f000 005af000
       00651000 00844000 00848000 00854000
```

**Observed data.** Three classes:

- Secure cores (GSP, FSP, SEC2, `0x848000`): `HWCFG2` in the `0x818xxxxx`
  family, `MAILBOX` readable, every boot or vector register blocked
  (`0xbadf5610`/`0xbadf5620`/`0xbadf5723` by block). SEC2 alone reads
  `CPUCTL = 0x10`. SEC2's `MAILBOX0` read `0xd8693000` in the October probe
  and `0xe7073000` here: a per-boot value.
- Engine falcons (`0x02900c00` and `0x02100c00` families, `0x651000`,
  `0x8a8000`-shaped): `CPUCTL = 0x10`, `BOOTVEC = 0` readable, `DMACTL` `0`
  or `1`, `UCODE_ID = ENGIDMASK = 0xffffffff`. No BROM ucode id anywhere.
- The `0x1ce000`/`0x1d2000`/`0x1d6000` trio: every register zero except
  `+0x100 = 0x68`. Not a falcon; the census signature was the one live word.

Two singletons stand out: `0x651000` reads `MAILBOX0 = 1` and
`MAILBOX1 = 0xabcd1234`, a deliberate pattern left in the mailbox; and
`0x854000` reads `DMACTL = 0x81` with `UCODE_ID = 0xfff` while its `CPUCTL`
is blocked.

**Result.**

- **Answer:** the candidates split into secure cores, engine falcons, and one
  false-positive family; no block exposes a BROM ucode id, so the vBIOS
  targets cannot be matched through this register.
- **What we learned:**
  - The engine falcons are ACR-loaded, not BROM-loaded, which is consistent
    with the `sec2_acr` boot path the RM log shows ([the consumer
    record](11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
  - `0xabcd1234` in a mailbox is the first deliberately-planted value seen in
    an engine block; whatever wrote it passed a pattern, not state.
  - SEC2's mailbox joins the per-boot register class with `SS0`/`SS1`
    ([the bank across
    boots](05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
- **Related:**
  - [The ucode table](11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table).
  - [The GSP Falcon block](../specs/03_register-map.md#gsp-falcon).
- **Open question:** which engine leaves `0xabcd1234` in its mailbox. The
  PMU is neither cluster: the aperture table names it `0x8f4000` ([the
  image names the PMU block](#146-the-image-names-the-pmu-block)).

## 14.3 A read through the debugger path crashes GSP-RM

**Question.** What does a full-BAR0 read census do to the card?

**Why.**

- The census is read-only from the host, but a debugger regop executes on the
  GSP: the RM performs the BAR0 read. A register the handler does not expect
  can fault the handler itself.
- The project rule is that a mutating run budgets a reboot; this group
  planned for refusals, not for a crash, and the first run crashed twice
  before the guard existed.
- What it would give: the true hazard list for any future BAR0 scan, and a
  measured bug surface in the RM register-access path.

**Method.**

- Tool: the census hook, first without (v1), then with (v2) the
  `PMC_BOOT_0` canary and the RM-status check per batch.
- Target: `41:00.0`, stock driver, an active CUDA context.
- Steps:
  - v1: map `0x0`–`0x1000000` at `0x100` stride, reading `X`, `X+4`,
    `X+0x300`, `X+0x304` at every `0x100`-aligned `X`.
  - v2: repeat with one read per `X`, the canary, and the two crash bands
    skipped.
- Args used:
```text
v1  X/X+4/X+300/X+304, step 0x100, range 0..0x1000000
v2  X only, step 0x100, range 0x500000..0x1000000
    canary PMC_BOOT_0, rm-status check, abort on mismatch
```

**Observed data.** Both crashes are identical at the firmware level:

```text
Xid 120  GSP task exception: load access page fault (cause:0xd)
         @ pc:0x1368618, partition:4#0, task:3
Xid 13   Graphics FECS Exception: UCODE Error
Xid 154  GPU recovery action changed to 0x1 (GPU Reset Required)
```

- v1 died processing the batch covering `0x42f900`–`0x431004`. The last real
  value before the crash is `0x42f804 = 0x003f0000`.
- The v2 map, in a fresh client with the canary, died on the batch at
  `0x525200`–`0x532c00` after two clean regions; the card needed a reboot
  both times. With the GSP dead, `nvidia-smi` shows `ERR!` for fan, temp,
  and perf, and the fan controller failsafes to 100% until the reboot;
  on Blackwell the thermal path runs through the GSP.
- The v1 run also exposed an instrument bug that matters for any future
  probe: the batch helper ignored the RM control status, so once the path
  degraded, thousands of reads printed as silent zeros. The v1 log's
  `0x0`–`0x42f804` data is valid (its header values match the October probe
  word for word) and everything after is the crash, not the map.

**Result.**

- **Answer:** two read windows crash GSP-RM through the debugger path, both
  faulting the same task at the same PC, and a read-only census can wedge the
  card hard enough to require a reboot.
- **What we learned:**
  - A "read-only" host probe is code execution on the GSP. The register-
    access handler has a crashable surface, reproducible at two addresses
    with the same fault: an RM bug surface in the DoS class, and the first
    measured read-side hazard since the `0x300000`–`0x400000` page scan
    ([the hazard
    spec](../specs/07_memory-and-host-access.md#fault-behavior-and-sentinels)).
  - The canary pattern, one known-value register plus the control status in
    every batch, is what the [ideas page](../IDEAS.md#the-instrument-destroys-its-own-evidence)
    asks of every mutating run, and it should stay on every future scan.
  - The unscanned bands are now bounded by measurement, not caution:
    `0x42f804`–`0x500000` and `0x525200`–`0x1000000` carry at least one
    fatal read each or remain untested past the second window.
- **Related:**
  - [The FECS unknown-ID fatal](03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)
    for the Xid 13/154 pair.
  - [The hazards](../specs/07_memory-and-host-access.md#fault-behavior-and-sentinels).
- **Open question:** which register inside each window carries the faulting
  read; bisecting it costs one wedge per step.

## 14.4 The per-card table persists across a cold boot

**Question.** Does the per-card table at `0x1f2000` survive a cold boot, and
does it change?

**Why.**

- The table is the second per-card surface after the FEAT bank, and the
  October record left its nature open: static across a driver reload, so
  "fused or built at init; a reboot test would separate the two"
  ([the block](11_falcon-and-gr-window-probe.md#115-the-0x1f2000-block-is-a-per-card-table)).
- Its values are per-card and look random: across the two local cards the
  payload words share nothing, and within a card the entropy is 7.79
  bits/byte with all 256 byte values present.
- What it would give: the distinction between fused data, boot-built
  randomness, and retained mutable state: three different guesses about
  what the table is.

**Method.**

- Tool: the census hook's re-dump mode, one fresh CUDA client.
- Target: `41:00.0`, two cold boots after the October dump, same card.
- Steps: read `0x1f2000`–`0x1f3fff` at 4-byte stride, compare word for word
  with the October dump, and histogram the byte-level deltas.
- Args used:
```text
range  0x1f2000..0x1f3fff, step 4
ref    the October dump, same card, two cold boots earlier
```

**Observed data.** Both dumps carry 1,155 non-zero words with the same
layout, the same `0xBADF5040` holes, and `+0xfc = 3` in every record.

- 603 words are identical across the two cold boots.
- 552 words differ: 79 in one byte, 184 in two, 194 in three, and 95 in all
  four. 263 of the 552 share at least two of their four bytes with the
  October value.
- The 95 wholesale changes include the record-0 header fields
  (`0xf4278000`→`0xb682e002`, `0x8`→`0x4cf8f371`, `0xd88a1140`→`0xa4eef000`,
  `0x7`→`0xae2d4cf0`, `0x18390d`→`0x70005105`), the words the reload test
  already flagged as runtime-moving.
- Every one of the 32 records changed somewhere; no record body was
  rewritten wholesale.

**Result.**

- **Answer:** the table persists across a cold boot and mutates in place:
  most of each record survives, a minority of bytes change, and the header
  turns over completely.
- **What we learned:**
  - Not per-boot randomness: fresh entropy would rewrite the words, not
    flip bytes in them. Not fused data: fuses do not change across a boot.
    The body is retained per-card state with per-boot partial updates, the
    shape of training or calibration results, refreshed at power-on, not the
    shape of keys or fuse shadows.
  - The mutation also separates the table from `SS0`/`SS1`, which are
    rewritten whole at every cold boot ([the bank across
    boots](05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
  - The earlier exclusions stand: the per-card words are in neither vBIOS,
    nor the GSP image, and match no rate, PLM, or FEAT field.
- **Related:**
  - [The per-card table](../specs/03_register-map.md#the-per-card-table-at-0x1f2000).
  - [The bank across boots](05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr).
- **Open question:** which unit owns a 32-record, per-card, refresh-at-boot
  table; the memory-partition count is the closest structural fit, and
  nothing in the open stack names it.

## 14.5 The coarse map and the doorbell census

**Question.** What does a `0x100`-stride value map of the low BAR0 hold, and
is there a second doorbell/echo pair shaped like the FECS command surface?

**Why.**

- The FECS mailbox is the one measured host-command surface: writes to
  `0x409500`/`0x409504` execute a command and the echo lands at `0x409800`
  ([the host command
  record](03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).
  A census should ask whether a sibling exists, not wait for a thread to find
  one.
- The v1 map data (`0x0`–`0x42f804`) is complete and canary-free but
  header-verified; the v2 map adds `0x500000`–`0x525100`.
- What it would give: the surface census below `0x42f804` at `0x100`
  stride, and a bounded list of doorbell candidates.

**Method.**

- Tool: the census hook, v1 quadruple read and v2 single read, with the
  pairs derived offline from the map instead of reading `X+0x300` live
  after [the crash](#143-a-read-through-the-debugger-path-crashes-gsp-rm).
- Target: `41:00.0`, stock driver.
- Steps:
  - v1: `X`, `X+4`, `X+0x300`, `X+0x304` at every `0x100`-aligned `X` in
    `0x0`–`0x42f804` (valid part of the log).
  - v2: `X` at every `0x100`-aligned `X` in `0x500000`–`0x525100`.
  - Offline: flag a pair when `X+0x300` answers a small non-sentinel value
    and the `X` side is small, zero, or blocked; calibrate on `0x409500`.
- Args used:
```text
v1  0x0..0x42f804, quadruple, step 0x100
v2  0x500000..0x525100, single, step 0x100
pair echo(X+0x300) small non-sentinel; door(X) small/zero/sentinel
```

**Observed data.** The FECS calibration holds its geometry and moves its
state: `0x409500 = 0xffffffff` and `0x409800 = 4` at census time against the
`0`/`1` baseline, with the command id at `0x409504` still read-blocked
(`0xbadf5545`).

Candidate pairs below `0x40000`: `0x900`/`0xc00` (echo `0x10`),
`0x1100`/`0x1400` (echo `5`), `0x9200`/`0x9500` (echo `1`),
`0x9900`/`0x9c00` (echo `3`), and `0x37c00`/`0x37f00` (echo `0x12`). One
periodic family fills `0x40000`–`0x4cb00`: every `0x800`-strided slot reads
`0xffff` at `+0x300` with blocked doors: unwired slots, not mailboxes.

Two windows answer outside the pair test:

- `0xa0000`–`0xbffff` returns one constant at every offset: `0x19ff12cb` in
  the first boot, `0x596f32db` after the cold boot. A per-boot random
  constant across a 128 KiB window, with no per-offset structure.
- The `0x500000` block reads a sparse control header: `0x87fc029f`,
  `0x08000000`, `0x00010000` at the base, live words at `+0x160`,
  `+0x2c0`–`+0x2f0` (all `7`), a PLM-shaped `0x0884cb8f` at `+0x300`, and
  `0x2000c008` at `+0x320`, ending by `+0x3f0`. Not a falcon: the signature
  reads zero/blocked.
- The `0x1c0000` header is eight words: `0xffffff8f`, `0xffffffff`, `2`,
  `0xffffff00`, `1`, `0x100`, `0x80`, ending at `+0x4c` in
  `0xBADF5040`; the Ada FEAT constant at its base that the GR map already
  noted.

**Result.**

- **Answer:** no confirmed FECS sibling. The low-space candidates are
  small-value pairs without the blocked command-id register that makes the
  FECS shape, and the one periodic family is unwired slots.
- **What we learned:**
  - The host-command surface below `0x42f804` is the FECS mailbox alone; a
    second doorbell, if one exists, lives in the unscanned bands.
  - The per-boot random constant at `0xa0000`–`0xbffff` is a third
    per-boot register class after `SS0`/`SS1` and SEC2's `MAILBOX0`; a
    128 KiB window of one random value reads like an uninitialized or
    self-echoing aperture, and it is the cheapest per-boot randomness
    probe on the die.
  - The `0x500000` block carries a PLM-shaped word at `+0x300`, so it is a
    small protected control block, closing the "what is at `0x500000`"
    open question from the GR map with: not a falcon, not an engine window,
    a header plus PLM.
- **Related:**
  - [The space above the window](11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom).
  - [The FECS mailbox](../specs/03_register-map.md#fecs).
  - [The sentinel families](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- **Open question:** whether the `0x900`-class pairs answer a write at all;
  each is one probe away, and none is a rate surface on its face.

## 14.6 The image names the PMU block

**Question.** Which engine owns each census base?

**Why.**

- The census produced families, not engines, and the BROM ucode-id register
  is a dead end for naming ([the naming
  pass](#142-the-naming-pass-splits-the-candidates-into-three-classes)).
- The PMU is the leading candidate for the power-on FEAT writer, so its base
  is the one name that matters ([the load-bearing
  unknowns](../IDEAS.md#the-load-bearing-unknowns)).
- What it would give: the PMU's real block, and the grouping of every other
  family into instances of one engine.

**Method.**

- Tool: a literal sweep over the firmware image, then the decompiled corpus,
  then one live naming read.
- Target: the extracted GSP-RM image and its decompiled corpus; `41:00.0`
  for the live read.
- Steps:
  - Search the image for the 32-bit encodings of every census base and the
    documented ones.
  - Decode the cluster the hits land in, and scan its full extent.
  - Try to crack the engine tags as name hashes: nine hash families over
    every string in the image, 108 million combinations.
  - Follow the tags into the decompiled corpus: the engine-by-tag accessor
    and the subdevice construction loop.
  - Re-run the naming pass with `0x8f4000` and the unmapped candidates added.
- Args used:
```text
bases   00110000 00840000 008f0000 0010a000 00848000 008f4000 00854000
        009a4000 0050f000 0040c000 0042f000 00844000 008a8000 00d40000 001cc000
hashes  crc32 adler32 fnv djb2 jenkins elf sdbm x 9 multipliers x 4 seeds
naming  10 registers at 0x8f4000 0x9a4000 0x9c0000 0x9d8000 0xd40000 0x1c8000
```

**Observed data.** The hits land in an engine-aperture table at image
`0xd68120`–`0xd68370`: an array of `(BAR0 base, tag)` pairs where the tag is
`(engine id << 8) | instance`. The first copy (later corrected in [the
engine-type table names the rest of the
map](15_tag-decoder.md#152-the-engine-type-table-names-the-rest-of-the-map):
the copies are per-SKU window lists, and this card's measured blocks span
two of them):

| Tag | Instances | Bases |
|---|---|---|
| `0xf3d722` | 1 | **`0x10a000` and `0x8f4000`, the same engine** |
| `0xda3de4` | 1 | `0x110000` (GSP) |
| `0x28c408` | 1 | `0x840000` (SEC2) |
| `0x8f99e1` | 8 | `0x848000`–`0x864000` at `0x4000` stride |
| `0x2b3a54` | 8 | `0x9c0000`–`0x9f8000` at `0x8000` stride |
| `0xe97b6c` | 4 | `0x1c8000`–`0x1d4000` at `0x4000` stride |
| `0x174e21` | 1, four apertures | `0x100000`, `0x9a0000`, `0x140000`, `0x13b000` |
| `0x793ceb`, `0x95a6f5`, `0x6c1e56`, `0xd334df`, `0xcc4c31`, `0xed0b65`, `0xdd7bab` | 1–2 each | low-space apertures, `0x844000` under `0xdd7bab` |

Two more copies of the table at `0xd78758`+ carry different base sets for
the same tags (`0x830000`+ for the `0x8f99e1` family, `0x828000` for
`0x2b3a54`): the per-SKU engine maps of the cut-down GB20x parts sharing
this image.

The GSP and SEC2 bases carry their own tags, which anchors the semantics;
the FSP base appears nowhere in the table, consistent with an engine below
the RM's management. No name hash matches any tag over 108 million
combinations, and the image holds no `pmu` string, so the tags are opaque
per-build ids.

The decompiled corpus uses the tags as engine handles: an
engine-by-tag accessor, and a subdevice construction loop that instantiates
one `0xf3d722`, twenty `0x793ceb`, and eight `0xe97b6c` engines into fixed
slots.

The live read at `0x8f4000`: `HWCFG2 = 0x839387f7`, `CPUCTL` and `BOOTVEC`
blocked, and the mailbox pair `0xe7481000`/`0x74000007`: the same
`MAILBOX1` value SEC2 answers with and a per-boot `MAILBOX0` in the same
shape. The `0x9c0000` and `0x1c8000` instance-zero blocks read
`0xBADF1301` at every register: present in the table, blocked to this path.

**Result.**

- **Answer:** the PMU block on GB202 is `0x8f4000`. The aperture table ties
  it to the legacy `0x10a000` base under one engine tag, its census
  signature is a blocked secure core beside the FSP, and its mailbox
  answers in SEC2's shape.
- **What we learned:**
  - The census families split by core type, not by engine: the
    `HWCFG2 = 0x02900c00` core appears under three different engine tags.
    The aperture table is the authoritative grouping, and it merges the
    `0x1c8000` quartet into one engine and names two 8-instance families.
  - The RM manages the PMU as an ordinary engine with two apertures, a
    legacy stub and the real block. Every measured read path into
    `0x8f4000` is blocked, so naming the writer does not open it.
  - The table's per-SKU copies give the engine layout of every GB20x part
    in one image, which is the map any future cross-version diff starts
    from.
- **Related:**
  - [The falcon-signature census](#141-the-falcon-signature-census-completes-the-engine-map).
  - [The naming pass](#142-the-naming-pass-splits-the-candidates-into-three-classes).
  - [The PMU and CMS2 blocks](../specs/03_register-map.md#pmu-and-cms2).
- **Open question:** what the `0x8f99e1` and `0x2b3a54` 8-instance families
  are; their names live behind the opaque tags. Answered after the fact by
  [the engine-type table names the rest of the
  map](15_tag-decoder.md#152-the-engine-type-table-names-the-rest-of-the-map):
  NVDEC0-7 and NVJPEG0-7.
