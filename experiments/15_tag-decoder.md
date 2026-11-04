# The tag decoder: engine names from the power code

## Summary

**The idea.**

- The aperture table pairs every engine window with a 24-bit tag, and no
  name hash cracks the tags ([the image names the PMU
  block](14_engine-map-census.md#146-the-image-names-the-pmu-block)). But the
  RM code that consumes a tag has to translate it into the RM's own
  engine-type enum, and that translation is in the image in plaintext.
- Two decoders, run in order. First the power code: it reads per-engine
  clock-gating thresholds from the registry, and the registry-key strings
  carry engine names. Then a static 57-row table that maps every tag
  instance to an RM engine type, matched against the enum the open driver
  publishes in
  [`gpu_engine_type.h`](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/src/nvidia/inc/kernel/gpu/gpu_engine_type.h).

**What it found.**

- Thirteen engine tags are named, by two decoders that agree everywhere they
  overlap: GR, CE, NVDEC, NVENC, TSEC, SW, SEC2, HOST, DPU, PMU, FBFLCN,
  NVJPG, OFA ([the engine-type table names the rest of the
  map](#152-the-engine-type-table-names-the-rest-of-the-map)).
- The GR engine's window is `0x400000`, so the FECS-shaped doorbell pairs at
  `0x409500`/`0x409800` from the doorbell census are the GR engine's own
  registers ([the coarse map and the doorbell
  census](14_engine-map-census.md#145-the-coarse-map-and-the-doorbell-census)).
- The big census families resolve: `0x848000`+ is NVDEC, the `0x1c8000`
  quartet is NVENC, `0x844000` is OFA0, `0x9c0000`+ is NVJPG, `0x104000` is
  the first copy engine.
- Four windows in the aperture table are not engines at all, and their class
  descriptors point into the encrypted bindata, so their names stay
  encoded ([four windows are not
  engines](#153-four-windows-are-not-engines-and-their-names-are-encrypted)).

**What it did not find.**

- No names for the four non-engine windows (`0x100000`/`0x9a0000`/`0x140000`/
  `0x13b000` under one tag, `0x1000`, `0x260000`, `0x20000`): the class-info
  pointers land in the AES region ([the fwimage
  map](13_fwimage-map-and-bindata.md)).
- No SKU-to-copy assignment for the aperture table. The table repeats per
  SKU with different window sets, and the measured facts of this card span
  two of the copies, so I read the copies as per-SKU window lists, not one
  map for this card. This corrects the "copy matching this card" read in
  [the image names the PMU
  block](14_engine-map-census.md#146-the-image-names-the-pmu-block).
- No live records of the threshold code: the boot log ring wraps before the
  retained window, so the decode is static-only.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 15.1 | [The clock-gating keys name six families](#151-the-clock-gating-keys-name-six-families) | six tags named by strings |
| 15.2 | [The engine-type table names the rest of the map](#152-the-engine-type-table-names-the-rest-of-the-map) | 13 tags, two decoders agree |
| 15.3 | [Four windows are not engines and their names are encrypted](#153-four-windows-are-not-engines-and-their-names-are-encrypted) | class info inside bindata |

## 15.1 The clock-gating keys name six families

**Question.** Do any plaintext strings in the RM image name the engine tags?

**Why.**

- Context: 108 million name-hash combinations over every string in the image
  produced no tag match, so the tags are per-build ids, not hashes
  ([the image names the PMU
  block](14_engine-map-census.md#146-the-image-names-the-pmu-block)).
- The RM reads engine-specific registry overrides at boot. If a tag keys that
  lookup, the registry-key string names the tag for free.
- A positive result here also calibrates the log-corpus join: the log
  id table attributes ids to functions, so a named tag's handler functions
  tell me which modules to trust for the unnamed ones.

**Method.**

- Tool: literal search over the decompiled corpus, then the log id table.
- Target: the GSP-RM decompile and its id table.
- Steps:
  - Collect every corpus function that compares against one of the 15 known
    tags, and join each function to its module in the id table.
  - Read the dispatch hubs: the engine-by-tag accessor callers and the
    engine construction loop.
  - Where a hub reads the registry, follow the key string.

```text
tags    d334df 793ceb 8f99e1 2b3a54 e97b6c 174e21 95a6f5 6c1e56
        cc4c31 ed0b65 dd7bab f3d722 28c408 da3de4 1cc271
sites   106 lines, 60 functions
join    id_table.csv: 63k rows, module per function
```

**Observed data.** The power code at `FUN_ram_01861d40` installs
engine-level clock-gating thresholds. It maps the tag to a registry key and
reads a threshold:

```c
if (uVar12 == 0xffffffffd334df00)
    FUN_ram_011cfb2c(p, s_RMLpwrGrElcgThreshold_ram_01f49e48, &out);
else if (uVar12 == 0x793ceb00)
    FUN_ram_011cfb2c(p, s_RMLpwrCeElcgThreshold_ram_01f49e60, &out);
else if (uVar12 == 0xffffffff8f99e100)
    FUN_ram_011cfb2c(p, s_RMLpwrNvdecElcgThreshold_ram_01f49e78, &out);
else if (uVar12 == 0x2b3a5400)
    FUN_ram_011cfb2c(p, s_RMLpwrNvjpgElcgThreshold_ram_01f49eb8, &out);
else if (uVar12 == 0xffffffffe97b6c00)
    FUN_ram_011cfb2c(p, s_RMLpwrNvencElcgThreshold_ram_01f49e98, &out);
else if (uVar12 == 0xffffffffdd7bab00)
    FUN_ram_011cfb2c(p, s_RMLpwrOfaElcgThreshold_ram_01f49ed8, &out);
```

Six keys exist in the image, no seventh. The same function then indexes a
per-engine array by a compact id it gets from `FUN_ram_01861c84`, a
`tag -> small integer` mapper (`0xd334df` to 0, `0x8f99e1` to 1-8,
`0xe97b6c` to 9-12, `0x2b3a54` to 13-20, `0xdd7bab` to 21-22, `0x793ceb` to
24-44).

The log-id join calibrates on the named tags before I trust it: the
`0xd334df` handler functions carry 103 log ids, and 84 of them also appear
inside `gr_fecs` call sites, so GR handlers live in graphics code, as they
should. The join also places tag `0x1cc271` in `display` module functions
(38 shared ids), a class compared against an engine-object tag field
alongside NVDEC in the corpus.

**Result.**

- **Answer:** six families named outright: `0xd334df` GR, `0x793ceb` CE,
  `0x8f99e1` NVDEC, `0x2b3a54` NVJPG, `0xe97b6c` NVENC, `0xdd7bab` OFA.
- **What we learned:**
  - The threshold strings are engine names, and the power code covers
    exactly the six engine classes that take a software-managed gating
    threshold on this part.
  - Engine objects carry their full tag in a field at `+0x4ac`, so any
    corpus code that switches on that field is an engine dispatch, a
    reusable naming surface.
  - The compact id in `FUN_ram_01861c84` groups engines with instance
    counts 8, 4, 8, 2, 21: the first census-independent instance counts.
- **Related:**
  - [The engine-type table names the rest of the
    map](#152-the-engine-type-table-names-the-rest-of-the-map).
  - [The image names the PMU
    block](14_engine-map-census.md#146-the-image-names-the-pmu-block).
- **Open question:** what the compact id space is; it is not the exported
  `NV2080_ENGINE_TYPE` order.

## 15.2 The engine-type table names the rest of the map

**Question.** What are all the tags, including the ones the power code never
touches?

**Why.**

- Context: the threshold keys cover six families. SEC2, GSP and the PMU were
  already named by the aperture table, but TSEC, HOST, DPU, FBFLCN and the
  display class were not, and instance counts per engine were unknown.
- A total mapping would name every window in the census, correct the SKU
  read of the aperture table, and give the cross-version diff a fixed
  alignment.
- The RM must convert engine objects into its own engine-type enum for
  channel and runlist code, so a full table should exist in the image.

**Method.**

- Tool: image table dumps, aligned to the open driver's enum.
- Target: the firmware image and the decompiled corpus.
- Steps:
  - Follow `FUN_ram_01cd1be8`, a translator that reads an engine object's
    tag at `+0x184` and returns its engine type. It walks a static table.
  - Dump the table from the image and align the value column against
    `RM_ENGINE_TYPE` from the open driver's `gpu_engine_type.h`.
  - Re-dump the aperture table and the per-SKU class registry around it in
    full.

```text
table   image 0xd5ad80, 57 rows x 16 B: (engine type, tag id, instance)
enum    RM_ENGINE_TYPE: GR 1-8, COPY 9-0x1c, NVDEC 0x1d-0x24, NVENC
        0x25-0x28, SW 0x2d, TSEC 0x2e, SEC2 0x31, HOST 0x32, DPU 0x33,
        PMU 0x34, FBFLCN 0x35, NVJPEG 0x36-0x3d, OFA 0x3e-0x3f
```

**Observed data.** The 57-row table, value column against the enum:

| Tag | Instances | Engine type ids | Name |
|---|---|---|---|
| `0xd334df` | 8 | 1-8 | GR0-GR7 |
| `0x793ceb` | 20 | 9-`0x1c` | COPY0-COPY19 |
| `0x8f99e1` | 8 | `0x1d`-`0x24` | NVDEC0-NVDEC7 |
| `0xe97b6c` | 4 | `0x25`-`0x28` | NVENC0-NVENC3 |
| `0x95a6f5` | 1 | `0x2d` | SW |
| `0x8dd911` | 1 | `0x2e` | TSEC |
| `0x28c408` | 1 | `0x31` | SEC2 |
| `0xf3e155` | 1 | `0x32` | HOST |
| `0x23486d` | 1 | `0x33` | DPU |
| `0xf3d722` | 1 | `0x34` | PMU |
| `0x8a20bf` | 1 | `0x35` | FBFLCN |
| `0x2b3a54` | 8 | `0x36`-`0x3d` | NVJPEG0-NVJPEG7 |
| `0xdd7bab` | 2 | `0x3e`-`0x3f` | OFA0-OFA1 |

Nine anchors hold the alignment: the seven families named by the threshold
keys land exactly in their enum ranges, and the two tags the aperture table
already knew (SEC2 at `0x840000`, PMU) map to their own enum values. The
row for `0x95a6f5` carries the SW engine, whose window in this SKU's
aperture copy is `0x120000`, the only engine window the SW class owns.

The aperture table, all three copies: copy 1 carries eight NVDEC windows at
`0x848000`-`0x864000`, eight NVJPG at `0x9c0000`-`0x9f8000`, OFA0 at
`0x844000`, and no NVENC; copies 2 and 3 carry four NVDEC at
`0x848000`-`0x854000`, four NVENC at `0x1c8000`-`0x1d4000`, the PMU at
`0x8f4000`, and differ from each other only in where the fourth non-engine
class sits (`0xad0000` versus `0x2280000`). The measured facts of this card
span the copies: the PMU at `0x8f4000` is from copies 2-3, the live OFA
falcon at `0x844000` is from copy 1, so the copies are per-SKU window lists
and this card is not one clean copy.

The class registry behind the aperture table (image `0xd65630`-`0xd68120`)
holds ten per-SKU engine-count configs, one row per tag with an instance
count: GR 1-8, CE 2-20, NVDEC 1-8, NVENC 0-4, NVJPG 0-8, OFA 0-2 across the
ten. The largest config (8 GR, 20 CE, 8 NVDEC, 8 NVJPG, 2 OFA, no NVENC)
matches aperture copy 1; the configs with 4 NVDEC and 4 NVENC match copies
2-3.

**Result.**

- **Answer:** every engine tag in the aperture table is named except the
  four non-engine classes; the full table is above and the named map is in
  [the register map](../specs/03_register-map.md#engine-names).
- **What we learned:**
  - The GR engine's window is `0x400000`. The FECS doorbell pairs at
    `0x409500`/`0x409800` are GR registers, and the twelve `0x10000`-strided
    falcons from `0x50f000` to `0x5af000` are the per-GPC blocks under it.
  - The engine-type enum in the 595 GSP is the open driver's `RM_ENGINE_TYPE`
    with the gaps closed; the exported `NV2080_ENGINE_TYPE` keeps the sparse
    legacy order, so cross-referencing client headers to firmware tables
    needs this table, not the client enum.
  - Twenty copy-engine slots exist and `0x104000` is the first one's window;
    the ten SKU configs give any later cross-version diff a fixed
    per-SKU alignment that does not depend on tag values at all.
- **Related:**
  - [The clock-gating keys name six
    families](#151-the-clock-gating-keys-name-six-families).
  - [The falcon-signature census completes the engine
    map](14_engine-map-census.md#141-the-falcon-signature-census-completes-the-engine-map).
- **Open question:** which of the ten SKU configs is this exact card; the
  count blocks are not fused data and several configs share the measured
  engine set.

## 15.3 Four windows are not engines and their names are encrypted

**Question.** What are the four aperture-table tags that the engine-type
table does not carry?

**Why.**

- Context: `0x174e21` owns four windows (`0x100000`, `0x9a0000`, `0x140000`,
  `0x13b000`), `0xcc4c31` owns `0x1000`, `0xed0b65` owns `0x260000`, and
  `0x6c1e56` owns `0x20000` (`0xad0000`/`0x2280000` in other copies). Real
  windows, but no engine type.
- If any of them is a command surface rather than bookkeeping, it matters
  for the surface census; if they are bookkeeping, the census can close them.

**Method.**

- Tool: slot-usage counts and the class-registry dump.
- Target: the subdevice construction loop and the registry rows.
- Steps:
  - Count slot reads in the construction hub for each of the four objects.
  - Scan the image for registry rows keyed by tag, and dump the class-info
    structures the rows point at.

```text
slots   0x1db8 = 0x174e21, 0x1e70 = 0xcc4c31, 0x1f48 = 0xed0b65,
        0x1f58 = 0x6c1e56
reads   0 / 0 / 285 / 54 slot dereferences
```

**Observed data.** The registry rows exist for all four tags, one instance
each in every SKU config, and each row points at a class-info structure.
The four pointers land in the same image region: `0x1bcb220` for
`0x174e21`, `0x1be83b8` for `0xcc4c31`, `0x1be7f08` for `0xed0b65`,
`0x1be7e40` for `0x6c1e56`. The words there are high-entropy, the same
class of data as the encrypted bindata ([the fwimage
map](13_fwimage-map-and-bindata.md)), not readable vtable pointers.

Usage splits them in two: `0xcc4c31` is constructed and then never read
through its slot in the whole corpus, while `0xed0b65`'s object is read 285
times and `0x6c1e56`'s 54, spread across every RM module, the shape of core
plumbing rather than an engine. The `0x174e21` accessors go through the
engine-by-tag accessor instead of the slot and consult the `0xed0b65`
object's flags.

The hub-client roster in the image (`HUBCLIENT_NVDEC7`, `HUBCLIENT_FSP`,
`FBFLCN`, `GR_HOST0`-`7`, `HSCE0`-`15`, `ESC0`-`10`) is a separate,
already-named id space: a switch in `FUN_ram_014fc824` maps hub-client
numbers to those strings, and it does not intersect the tag space.

**Result.**

- **Answer:** the four windows belong to non-engine classes, and their names
  sit behind the bindata encryption; no decoder in the plaintext image
  reaches them.
- **What we learned:**
  - The aperture table mixes engine falcons and other register-owning
    classes, so a window in the table is not evidence of an engine.
  - Two of the four (`0xed0b65`, `0x6c1e56`) are core objects used
    everywhere in RM, one (`0x174e21`) interacts with `0xed0b65`'s flags,
    and one (`0xcc4c31`) is dead weight beyond construction. None shows a
    command-surface shape.
  - The display class `0x1cc271` from the module join is also absent from
    the engine-type table: display code runs on classes, not on the engine
    enum, which is why the census never saw a DPU falcon window.
- **Related:**
  - [The engine-type table names the rest of the
    map](#152-the-engine-type-table-names-the-rest-of-the-map).
  - [bindata is encrypted, not
    compressed](13_fwimage-map-and-bindata.md#133-bindata-is-encrypted-not-compressed).
- **Open question:** whether any cross-version image ships these four
    class-info regions unencrypted, which would name them for free.
