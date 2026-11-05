# FWSEC-LIC handler resolution

## Summary

**The idea.**

- The HULK lead's offline half was one question: can the certificate
  handlers be read in the 595 plaintext? The named stages — the `BCRT2X_VDPA`
  reader, the `3AES`-versus-fuse verify, and the SEC2 opcode interpreter — were
  string-mapped but never located as code
  ([the cluster](20_hulk-cert-machinery.md#201-the-certificate-cluster-in-the-rm-plaintext)).
- I resolved every code reference to the certificate vocabulary, mapped the
  FWSEC-LIC unit that carries it, and swept the whole readable quarter for the
  constants a certificate parser or register-writing interpreter cannot avoid.

**What it found.**

- All 127 certificate-vocabulary references land in one place: a field of
  `0x22`-byte log thunks in `0x0134cfa0`–`0x0134e994`, each of which logs one
  error name and tail-jumps into the RM-task log writer
  ([26.1](#261-the-cluster-resolves-to-a-log-thunk-field)).
- The FWSEC-LIC plaintext unit is three parts: an error-decode and helper head,
  a loader middle of about 200 functions, and the shared log-thunk tail, with
  153 call entries from the surrounding RM
  ([26.2](#262-the-fwseclic-unit-in-three-parts)).
- No certificate parser exists in the readable quarter. No `BCRT2X`/`CERT20`/
  `CERT21`/HULK signature, no FEAT-bank register constant in any form, no DEVID
  match list. The scan is validated against constants that do exist
  ([26.3](#263-no-certificate-parser-in-the-readable-quarter)).
- What the readable layer carries is the sourcing and loading: stride-descriptor
  walkers, a `0x930`-byte loader object, and DMA/loader calls
  ([26.4](#264-the-readable-layer-is-the-loader)).

**What it did not find.**

- No certificate bytes, no opcode table, no verify routine — the stages the
  error strings name are not in this image's plaintext, so the `3AES` admission
  wall cannot be audited for a parser bug from 595.91.07.
- Which encrypted container holds them is narrowed but not named: the boot-time
  FMC body or the SEC2 applets behind the bindata keys
  ([the blob census](13_fwimage-map-and-bindata.md#138-the-blob-census-five-families)).
- The control-table census, the other half of the merged pass, is unrun; this
  session mapped the logging layer and the register-constant absence only.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 26.1 | [The cluster resolves to a log-thunk field](#261-the-cluster-resolves-to-a-log-thunk-field) | 127 refs, one field, one writer |
| 26.2 | [The FWSEC-LIC unit in three parts](#262-the-fwseclic-unit-in-three-parts) | Head, loader middle, thunk tail |
| 26.3 | [No certificate parser in the readable quarter](#263-no-certificate-parser-in-the-readable-quarter) | Signatures, registers, DEVID all absent |
| 26.4 | [The readable layer is the loader](#264-the-readable-layer-is-the-loader) | Stride walkers and a loader object |

## 26.1 The cluster resolves to a log-thunk field

**Question.** Which code references the 127 certificate-vocabulary error
strings, and does any of it parse certificates?

**Why.**

- The HULK lead named its next run as resolving the certificate handlers in the
  readable quarter. The strings exist; their referencing code is the handler
  location.
- A reference scan that handles RISC-V `auipc`/`lui` pairs and raw literals is
  the instrument; the readable-quarter map depends on not missing
  non-literal forms ([the reference
  scanner](../tools/gsp-rm-tools/)).

**Method.**

- Extracted every string matching the FWSEC-LIC vocabulary (`HULK`, `BCRT`,
  `CERT2`, `UL_GLOB`, `FWSECLIC`, `UGPU`, `3AES`, mutex families) from the 595
  fwimage with virtual addresses: 136 strings, of which the 63-string
  certificate cluster of [20.1](20_hulk-cert-machinery.md#201-the-certificate-cluster-in-the-rm-plaintext)
  is the subset.
- Scanned the image for every reference form to each string address.
- Disassembled the referencing region and hand-decoded the veneer instructions
  at the reference sites.

Args used: `refscan.py <fwimage> <string VAs>`; `DisasmRange.java` over
`0x0134cfa0` and neighbours. Working scripts in `analysis-tmp/c30_c36/work/`.

**Observed data.**

```text
136 vocabulary strings (exp 20's 63-string cert cluster plus mutex/UDE/loader families)
127 code references, every one auipc+addi, zero pointer tables, zero literals
reference span: 0x0134cfe6-0x0134e994
unit shape (34 bytes, repeating):  auipc a3,<log metadata>
                                   auipc a2,<error string>
                                   li   a1,<log id>          ids 0x265-0x43a
                                   li   a0,3
                                   addi sp,0x10 ; auipc t1,0x852 ; jr imm12(t1)
every jr target: 0x01b9e86e, the RM-task log writer
```

- Two false positives (`LTS_CCUPROF`, `TPC_CCUPROF`, the substring `UPR`)
  sit in profiler code at `0x016956xx` and are unrelated.
- The field around the FWSEC-LIC units holds more thunks of the same shape
  pointing at registry and display strings: the tail region is a shared RM
  log-thunk pool, and the FWSEC-LIC unit owns 127 of its units.

**Result.**

- **Answer:** no referencing code parses anything. Each reference is one
  log-report thunk that names an error and jumps into the logging task's
  writer; the units contain no comparisons, no loops, and no data access
  beyond the log arguments.
- **What we learned:** the error strings are the readable quarter's *naming*
  of the certificate pipeline, not its code. Any handler audit has to find the
  code somewhere else, which [26.3](#263-no-certificate-parser-in-the-readable-quarter)
  closes for this image.
- **Related:** [the certificate cluster](20_hulk-cert-machinery.md#201-the-certificate-cluster-in-the-rm-plaintext),
  [the log writer task table](../specs/08_errors-and-logging.md).

## 26.2 The FWSEC-LIC unit in three parts

**Question.** What does the plaintext code around the thunk field actually do?

**Why.**

- The unit that owns the vocabulary had no function map: the decompiled dump
  stopped at its edges, and [the module map](../specs/04_firmware-formats.md#module-map)
  grouped it into one oversized community.
- The structure decides where a parser could hide and what the RM-side
  interface into the unit is.

**Method.**

- Created and decompiled every function reachable by direct call into the two
  uncovered spans: 93 functions in the head `0x0130cb0b`–`0x0130f78c` (the 92
  call targets plus one), on top of the about-200 functions the main dump
  already held in the middle `0x0130f78c`–`0x0134bc74`.
- Dumped the full instruction stream of the tail `0x0134b000`–`0x01351000`
  (7,786 instructions, one two-byte gap at `0x0134dda6`) and measured its
  control flow:
  439 transfers in 7,786 instructions, no transfers into the thunk units from
  outside, no jump tables into them.
- Enumerated every direct call entry into the whole unit from outside it.

Args used: `HulkDecompile.java <out.c> <lo> <hi> <candidates>`;
`RegionDump.java <out.tsv> <lo> <hi>`; raw `jal`-target scans. Both scripts
join [the GSP-RM tools](../tools/gsp-rm-tools/).

**Observed data.**

```text
head   0x0130ca64-0x0130f78c   93 functions, none larger than 0xe6 bytes
                                 error-decode helpers; the decode entry at
                                 0x0130cb16 has 73 callers and an indirect
                                 jump through a relative-offset table
middle 0x0130f78c-0x0134bc74   ~200 functions, the largest 0x20f2 bytes
                                 loader logic; stride-descriptor walkers (26.4)
tail   0x0134bc74-0x01351000   shared RM log-thunk pool; 127 FWSEC-LIC units
153 direct-call entries from the surrounding RM into the unit
```

- The head's decode entry returns error codes and jumps through a table of
  32-bit relative offsets — the compiler's switch over the FWSEC-LIC error
  enum, whose arms are the thunk units.

**Result.**

- **Answer:** the unit is a loader-and-reporting layer. The head decodes and
  logs errors, the middle loads and stages, the tail reports. The certificate
  pipeline's decision logic is not one of the three parts.
- **What we learned:** the RM interface into the unit is wide (153 entries),
  not a single command door, so an RM-control census of this unit would have
  to map each entry separately; none of the entries is a certificate parser.
- **Related:** [the module map](../specs/04_firmware-formats.md#module-map),
  [the readable quarter](../specs/04_firmware-formats.md#module-map).

## 26.3 No certificate parser in the readable quarter

**Question.** Does any plaintext code carry the constants a certificate
parser or a register-writing interpreter cannot avoid?

**Why.**

- A BCRT2X-style reader must test its container's signatures and version
  gates; a HULK interpreter must materialize its register-write targets — on
  GA100 that was `FUSE_FEATURE_OVERRIDE` (`0x823800`), the FEAT bank's address
  family; a device matcher must carry a DEVID list, and the bench die is
  `0x2b85`.
- The static audit's literal pass covered six rate registers
  ([the static audit](02_registry-and-static-audit.md#021-static-scan-finds-no-rate-register-reference));
  this sweep extends it to every literal and `lui+addi` form of the whole
  FEAT/PLM register family across the full 18.5 MB readable quarter
  ([the plaintext boundary](13_fwimage-map-and-bindata.md#132-the-plaintext-boundary)).

**Method.**

- Searched the readable quarter for `0x823800`, `0x823804`, `0x82381c`,
  `0x823820`, `0x8207d8`, `0x2b85`, and `0x88888888` as 32-bit literals, and
  for `lui+addi` pairs materializing any value in `0x820000`–`0x824000`.
- Validated the scan on constants that do exist: the PMU block `0x8f4000` and
  the legacy stub `0x10a000` appear as aperture-table literals
  ([the image names the PMU block](14_engine-map-census.md#146-the-image-names-the-pmu-block)).
- Searched the loader middle for the PCI-ROM and container signatures
  (`PCIR`, `0xaa55`, `BCRT`, `HULK`, `CERT` as ASCII values) and inspected the
  two `HLK` byte hits inside the encrypted bindata.

Args used: raw 32-bit pattern scans over the fwimage; `lui+addi` decoder at
2-byte stride. Working scripts in `analysis-tmp/c30_c36/work/`.

**Observed data.**

```text
literal32 hits in the readable quarter (18.5 MB):
  0x823800 0 | 0x823804 0 | 0x82381c 0 | 0x823820 0 | 0x8207d8 0
  0x2b85 0  | 0x88888888 1  (a sentinel-palette dword at 0x01ea4da8:
                             90/88/46/ee fills in a row)
lui+addi materializations of 0x820000-0x824000: 0
scan validation: 0x8f4000 -> 18 hits, 0x10a000 -> 16 hits (aperture tables);
  FECS 0x4096d0 and the SEC2 DMEM port 0x8401c0 -> 0 (register access is
  table-driven in the RM, so zero immediates is the expected shape)
container signatures in the loader middle: 0
HLK inside the encrypted bindata: 2 hits, ciphertext coincidence ("IHLK",
  "HLK;6" surrounded by high-entropy bytes)
```

**Result.**

- **Answer:** the readable quarter carries no certificate parser and no
  register-writing interpreter. The FEAT register family appears in no form
  the scan can express, and the one `0x88888888` is a poison fill.
- **What we learned:**
  - The no-writer claim of the static audit now rests on both literal and
    computed immediate forms, not literals alone.
  - The certificate pipeline the error strings name — reader, `3AES` verify,
    SEC2 opcode execution — lives in encrypted code: the boot-time FMC body or
    the SEC2 applets behind the per-blob keys
    ([the secure-data unit](13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)).
    The strings in the RM plaintext are the RM's names for results that come
    back from that code.
  - A parser-bug audit of the HULK admission path therefore requires a decrypt
    first — the same wall as [the FMC key
    search](07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).
    The offline route from 595 plaintext is closed.
- **Related:** [the static audit](02_registry-and-static-audit.md#021-static-scan-finds-no-rate-register-reference),
  [the two override paths](../specs/02_privilege-and-rate-control.md#the-two-override-paths),
  [the FMC key search](07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).

## 26.4 The readable layer is the loader

**Question.** What do the loader-middle functions parse, if not certificates?

**Why.**

- The middle holds the only real parsing logic in the unit; naming what it
  parses separates the certificate machinery from the generic loader it shares
  a unit with.

**Method.**

- Located every reference to the formatter mini-language strings
  (`4b2d2b`, `2b`, `1b`, and variants) at `0x01eef000`–`0x01eef490` and read
  the referencing functions in the decompiled dump.

Args used: `refscan.py` over the formatter-string addresses; the decompiled
functions `FUN_ram_01340138`, `FUN_ram_01340a70`, `FUN_ram_01341060`, and
neighbours.

**Observed data.**

```text
descriptor-selected entry layouts: "4b2d2b", "4b2d2b1d", "4b2d2b1d1b",
  selected by a version field (0x12/0x13/0x0e gates)
FUN_ram_01340138: rejects a size != 0x40, walks entries at base + stride*i
  with the descriptor stride, builds a 0x930-byte object, fills fixed
  offsets, hands it to a loader call, and returns 0x6d on one refusal path
FUN_ram_01341060 and neighbours: same walker with other descriptors
```

- The stride grammar (`<n><b|w|d>` repeats) is the same family as the
  `CERT21_FMT_*` formatter errors name, so the walker class is shared; these
  instances consume ucode-descriptor layouts, not certificate containers.

**Result.**

- **Answer:** the middle is a descriptor-driven loader: version-gated stride
  tables, a staging object, and a loader handoff. It is the same machinery the
  FMC uses for its descriptor tables
  ([the parser spec](../specs/09_fmc-parsers.md)), instantiated for ucode.
- **What we learned:** the readable FWSEC-LIC unit is the sourcing, staging,
  and error-naming layer of the certificate pipeline. Its inputs are the
  InfoROM objects ([the base state](21_inforom-base-state.md#211-the-object-battery))
  and its outputs are load requests and log lines; the admission decision is
  made elsewhere, in encrypted code.
- **Related:** [the InfoROM base state](21_inforom-base-state.md#211-the-object-battery),
  [the nvflash read matrix](24_nvflash-read.md#241-the-read-matrix),
  [the FMC parsers](../specs/09_fmc-parsers.md).
