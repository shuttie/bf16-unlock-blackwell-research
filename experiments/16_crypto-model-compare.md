# The crypto-model compare

## Summary

**The idea.**

- The key searches so far assumed a key worth finding: if the corpus is
  encrypted per device or per boot, no offline attack can work, and if it is
  encrypted per driver build, a recovered key dies with that build. Neither
  assumption was measured.
- I compared the same components across the two 5090s and across three driver
  versions (570.144, 595.91.07, and 615.78.08), all offline on dumps that
  already existed plus one new driver package.

**What it found.**

- **Not device-bound:** the encrypted [vBIOS](../specs/05_vbios-and-devinit.md#microcode-table)
  bodies are byte-identical between the two cards; every per-card byte sits in
  plaintext tails ([16.1](#161-the-encrypted-vbios-is-card-independent)).
- **Version-stable:** the encrypted [bindata](../specs/04_firmware-formats.md#secure-data-blobs)
  blobs that did not change between driver versions carry byte-identical
  ciphertext across all three versions, through a container-format change
  ([16.2](#162-the-bindata-key-is-version-stable)).
- **Per-copy seeds, not one ECB key:** the seven ucode images stored twice in
  one bindata share descriptors and then diverge exactly where a per-copy
  16-byte value sits ([16.3](#163-duplicated-ucode-diverge-at-a-per-copy-seed)).
- The FMC and GspRmBoot share ciphertext in every version, so the
  per-component reset holds across the corpus history
  ([16.4](#164-the-fmc-and-gsprmboot-share-ciphertext-in-every-version)).
- The thirteen driver containers belong to five chips plus three
  confidential-compute builds, each with its own signing keys, and the
  envelope's public-key record is 104 bytes, not 97 plus padding
  ([16.5](#165-the-container-census-names-the-chips-and-the-keys)).
- Driver 615.78.08 moves the engine ucode into a new `NVUCODES` container and
  signs the production FMC image as the debug FMC, byte-identical
  ([16.6](#166-the-615-corpus-splits-and-resigns-the-fmc)).
- **Every corpus encrypts alone:** within one driver version, no ciphertext
  block crosses a corpus boundary — not between chips that share signing
  keys, not between flavors, not between the module containers and the
  GSP-RM image ([16.7](#167-no-ciphertext-crosses-a-corpus-boundary)).
- **No shipped window is the FMC key:** every byte-offset 16-byte window of
  318 MB of shipped material — 336,307,381 candidates — fails to decrypt
  either GB202 FMC container under four mode paths, and the top 48
  candidates fail the full-code RISC-V walk
  ([16.8](#168-no-shipped-window-is-the-fmc-key)).

**What it did not find.**

- No key material in any header or envelope: container header tails are zero,
  and the envelope carries authentication only
  ([16.5](#165-the-container-census-names-the-chips-and-the-keys)).
- No cross-version ciphertext reuse in the FMC or GspRmBoot: every version
  rebuilds both, so their keys stay untestable by this method
  ([16.4](#164-the-fmc-and-gsprmboot-share-ciphertext-in-every-version)).
- No ECB-class repetition in any corpus and no seed structure in the FMC or
  vBIOS corpora: their key searches reduce to placements and build constants
  ([16.7](#167-no-ciphertext-crosses-a-corpus-boundary)).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 16.1 | [The encrypted vBIOS is card-independent](#161-the-encrypted-vbios-is-card-independent) | Zero device-bound ciphertext |
| 16.2 | [The bindata key is version-stable](#162-the-bindata-key-is-version-stable) | Identical ciphertext across versions |
| 16.3 | [Duplicated ucode diverge at a per-copy seed](#163-duplicated-ucode-diverge-at-a-per-copy-seed) | 16-byte seed at a fixed offset |
| 16.4 | [The FMC and GspRmBoot share ciphertext in every version](#164-the-fmc-and-gsprmboot-share-ciphertext-in-every-version) | Per-component reset, three times |
| 16.5 | [The container census names the chips and the keys](#165-the-container-census-names-the-chips-and-the-keys) | Five chips, per-chip keys |
| 16.6 | [The 615 corpus splits and resigns the FMC](#166-the-615-corpus-splits-and-resigns-the-fmc) | `NVUCODES` split, debug equals production |
| 16.7 | [No ciphertext crosses a corpus boundary](#167-no-ciphertext-crosses-a-corpus-boundary) | Disjoint corpora, no ECB anywhere |
| 16.8 | [No shipped window is the FMC key](#168-no-shipped-window-is-the-fmc-key) | 336 M windows, all null |

## 16.1 The encrypted vBIOS is card-independent

**Question.** Does the same vBIOS component encrypt identically on two cards
of the same board build?

**Why.**

- A device-bound key would end every offline key search: a key recovered from
  one card's dump would decrypt nothing on any other card.
- What it would give: the device-binding answer for the only per-card
  encrypted corpus, and the gate for [the vBIOS ucode key
  search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).

**Method.**

- Tools: [crypto compare](../tools/crypto-compare/) `diff`.
- Target: the two 1 MiB vBIOS dumps and the two 2 MiB PROM dumps from the two
  5090s; offline.
- Steps:
  - Diff the 1 MiB dumps byte by byte; merge differing bytes into ranges at
    8 B and classify each range against the image chain and the four
    [microcode bodies](../specs/05_vbios-and-devinit.md#microcode-table).
  - Diff the PROM head (`0x0`–`0x38000`) the same way and locate every range
    against the encrypted head blob.
- Args used:
```bash
python3 tools/crypto-compare/crypto-compare.py diff flash1m_41.bin flash1m_c1.bin \
  --region 0x6fdf0,0x8fff0,ucode_app07 \
  --region 0x90040,0xb1b40,ucode_app19 \
  --region 0xb1c80,0xb7780,ucode_app15 \
  --region 0xb780c,0xd5a0c,ucode_app23
python3 tools/crypto-compare/crypto-compare.py diff prom_full_41.bin prom_full_c1.bin
```

**Observed data.**

```text
flash 1 MiB: 1,713 differing bytes, 160 ranges
  ucode app07 (0x20200 B): 0 differing
  ucode app19 (0x21b00 B): 0 differing
  ucode app15 (0x5b00  B): 0 differing
  ucode app23: 118 differing, all inside the plaintext data tail
    header 0x7f4: 0; encrypted code 0x10000: 0; data 0xda0c: 118
    offsets 0x10cfa..0x1cfe5 relative to the body
  plaintext regions: PciAt 429 B, EFI image 203 B, third-image head 743 B,
    tail 220 B
PROM head 0x0..0x38000: 790 differing bytes, 46 ranges,
  all inside 0x36871..0x37fff; 0x0..0x1000 identical
```

**Result.**

- **Answer:** every encrypted body in the per-card corpus is byte-identical
  between the two cards; all per-card bytes sit in plaintext metadata and
  plaintext data tails.
- **What we learned:**
  - The vBIOS ucode keys are not device-bound. A key recovered from one card
    decrypts every card of the same board build.
  - The two PMU-family bodies ([the shared
    header](../experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies))
    share only the 8-byte family prefix; their size fields diverge at `+0x08`
    and their code differs from the first block, so they are two images, not
    two copies.
- **Related:**
  - [The version-stable bindata](#162-the-bindata-key-is-version-stable)
    answers the same question across builds.
  - The corpus key search lead in IDEAS is un-gated by this record.

## 16.2 The bindata key is version-stable

**Question.** Does the same encrypted bindata component carry byte-identical
ciphertext across driver versions?

**Why.**

- A per-build key would make a recovered key worthless after one driver
  update. A version-stable key makes the offline attack a one-time break.
- What it would give: the version-binding answer for the largest encrypted
  corpus, and mode constraints from where the matches fall.

**Method.**

- Tools: [crypto compare](../tools/crypto-compare/) `bindata`, `join`.
- Target: the 570.144 and 595.91.07 GSP-RM images and the 615.78.08 driver
  package; offline.
- Steps:
  - Extract `rm.bindata.bin` from both GSP-RM images through the libos
    manifest (570.144: `0x2c05000` B; 595.91.07: `0x33ad000` B).
  - Join the two bindatas on identical aligned 16-byte blocks, counting
    matches at any relative offset.
  - Join each bindata against the 615.78.08 `ucodes_ga10x.bin` container
    the same way.
- Args used:
```bash
python3 tools/crypto-compare/crypto-compare.py bindata gsp570_fwimage.bin \
  --out bindata_570.bin
python3 tools/crypto-compare/crypto-compare.py join bindata_570.bin bindata_595.bin
python3 tools/crypto-compare/crypto-compare.py join bindata_570.bin ucodes_ga10x.bin
```

**Observed data.**

```text
570 vs 595:
  same-offset identical blocks: 0 of 2,884,864
  any-offset: 235,561 blocks matched, 8.2% of the 570 bindata
  runs >= 0x4000 B: 16; longest 0xe2540 (927,040 B)
    at 570+0x78f000, counterpart at 595+0xae1810, a 0x10 shift
  matched-run entropy 7.99; runs bounded by plaintext blob headers
    (the 63 60 00 02 generic-header family)
570 vs 615 ucodes: 50,892 blocks (1.8%), longest run 0x54000 at 570+0x62cec0
595 vs 615 ucodes: 28,474 blocks (0.8%), longest run 0x54000 at 595+0x980130
  the 0x54000 run is the same content in all three files
```

**Result.**

- **Answer:** unchanged blobs carry byte-identical ciphertext across three
  driver branches and a container-format change. The 927 KB run did not
  survive to 615.78.08, but smaller unchanged blobs did.
- **What we learned:**
  - The bindata key is version-stable and the transform is deterministic and
    offset-independent: identical plaintext at different file offsets
    produces identical ciphertext.
  - Nothing here binds the key to a build, so a recovered key keeps working
    until the blob it opens is rebuilt.
  - The 615 in-image bindata extent shrinks to `0x69b000` B
    ([16.6](#166-the-615-corpus-splits-and-resigns-the-fmc)); the matches
    live in the new container.
- **Related:**
  - [The fwimage map](../experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)
    defined the bindata extent.
  - [The per-copy seed](#163-duplicated-ucode-diverge-at-a-per-copy-seed)
    explains what resets between components.

## 16.3 Duplicated ucode diverge at a per-copy seed

**Question.** Why do two copies of the same ucode image inside one bindata
carry different ciphertext?

**Why.**

- The [fwimage census](../experiments/13_fwimage-map-and-bindata.md#138-the-blob-census-five-families)
  found seven ucode images stored twice with identical descriptors. If their
  bodies were identical too, one ECB key would explain the corpus; if not,
  something per-copy changes.
- What it would give: the chaining model of the largest corpus, and the
  structure any key search must reproduce.

**Method.**

- Tools: [crypto compare](../tools/crypto-compare/) `selfjoin`; a byte scan
  for the falcon-descriptor signature.
- Target: both extracted bindatas; offline.
- Steps:
  - Self-join each bindata on identical aligned 16-byte blocks, skipping
    uniform blocks, and report runs at or above `0x1000` B.
  - Locate the fourteen descriptors by signature, group them by their two
    identity words, and diff each pair from the descriptor start.
- Args used:
```bash
python3 tools/crypto-compare/crypto-compare.py selfjoin bindata_595.bin
python3 tools/crypto-compare/crypto-compare.py selfjoin bindata_570.bin
```

**Observed data.**

```text
595 self-join: 12,679 duplicated blocks, 0 runs >= 0x1000 B
  14 descriptors in 7 identity pairs; all 7 pairs identical for 0x100 bytes,
  first divergence exactly at +0x100
  the 16 bytes at +0x100 differ per copy, e.g.
    copy1: 2f 0e 09 12 5f 02 84 49 41 24 ea 4f 77 62 39 9b
    copy2: 12 ec 03 70 72 4c 17 47 30 38 91 17 64 2f 45 3b
570 self-join: 27,505 duplicated blocks, 4 runs >= 0x1000 B
  0x1c330 B at 0x21bbea0 and 0x24c41c0 (identical twins)
  0x2210  B at 0x1bf65f0 and 0x1c00ef0 (identical twins)
  twin entropy 7.986
```

**Result.**

- **Answer:** each copy carries its own 16-byte value at a fixed offset after
  the descriptor, and the ciphertext after it differs. Copies that share the
  value, the two 570 pairs, encrypt identically.
- **What we learned:**
  - The corpus is not encrypted under one key in ECB mode: identical
    descriptors with different seeds produce different bodies, and identical
    seeds produce identical bodies.
  - The seed is stored in the image, so it is not secret; a key search must
    consume it as a per-blob IV or key-derivation input, not hunt for it.
  - The generic-header family shows the same shape: a 16-byte value at a
    fixed offset before the blob header
    ([the matched-run head](#162-the-bindata-key-is-version-stable)).
- **Related:**
  - [The version-stable bindata](#162-the-bindata-key-is-version-stable)
    shows identical seeds carry identical ciphertext across builds.
  - [The secure-data unit](../experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)
    named the decrypt path inside SEC2.

## 16.4 The FMC and GspRmBoot share ciphertext in every version

**Question.** Does the FMC and GspRmBoot shared-ciphertext structure hold in
driver versions other than 595.91.07?

**Why.**

- The [FMC key search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)
  established on 595.91.07 that the FMC body's data and manifest regions are
  byte-identical to the GspRmBoot image's regions at different absolute
  offsets: no cross-component chaining. One version is one sample.
- What it would give: the mode constraint either generalized or bounded to
  one build.

**Method.**

- Tools: the ELF image-section extractor and [crypto
  compare](../tools/crypto-compare/) `carray` for the generated arrays.
- Target: the 570.144 linux-firmware FMC and bootloader files, and the
  615.78.08 generated bindata arrays; offline.
- Steps:
  - Extract the 570.144 FMC container from the ELF `image` section and the
    GspRmBoot image from behind its 24-byte archive header and descriptor.
  - Convert the 615.78.08 FMC and GspRmBoot arrays from `NvU64` words.
  - Split every FMC body into code, data, and manifest by the header sizes
    and compare against the matching GspRmBoot regions.
- Args used:
```bash
python3 tools/crypto-compare/crypto-compare.py carray \
  g_bindata_kgspGetBinArchiveGspRmFmcGfwProdSigned_GB202.c --outdir fmc615
```

**Observed data.**

```text
570.144: FMC code 0x25800, data 0xa800, manifest 0xa00
  code == GspRmBoot[code_offset..]: identical
  data == GspRmBoot[0xa00..]: identical
  manifest == GspRmBoot[0..0xa00]: identical
615.78.08: FMC code 0x37000, data 0xe800, manifest 0xa00
  all three regions identical to the GspRmBoot image regions
cross-version (570 vs 595 vs 615, GB202 production):
  every region hash differs; GspRmBoot 595-vs-615 data
  identical blocks: 0 of 3,712
```

**Result.**

- **Answer:** the FMC body is the GspRmBoot image re-wrapped, with identical
  ciphertext at different offsets, in all three versions.
- **What we learned:**
  - The per-component reset (ECB or a zeroed IV per component) is a property
    of the format, not of one build.
  - Both components are rebuilt every version, so cross-version ciphertext
    reuse cannot test their key the way it tests the bindata's.
- **Related:**
  - [The FMC container](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature)
    defined the region split.
  - [The 615 corpus](#166-the-615-corpus-splits-and-resigns-the-fmc)
    changes what "production" and "debug" mean for this pair.
  - [16.7](#167-no-ciphertext-crosses-a-corpus-boundary) confirms the
    region identity inside the 595 module and locates the second copy.

## 16.5 The container census names the chips and the keys

**Question.** Which chips do the thirteen driver containers belong to, and
does any header or envelope field carry key material?

**Why.**

- The [container analysis](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature)
  left an undefined "inline key block" claim and counted two public keys. The
  census had never been mapped to the shipping symbols.
- What it would give: the chip inventory, the signing-key rotation, and a
  clean statement of what the envelope carries.

**Method.**

- Tools: the symbol table of the driver module; a SHA-384 verifier over each
  container and its envelope.
- Target: the thirteen extracted containers inside 595.91.07 `nvidia.ko`;
  offline.
- Steps:
  - Map each container's file offset to the generated-array symbol that
    contains it.
  - Split each envelope before a container and verify its hash field against
    a SHA-384 of the container.
  - Hexdump every container header tail and envelope field.

**Observed data.**

```text
symbol map:
  FmcGfw prod+debug: GB202, GB100, GB10B, GB20B, GH100 (10 containers)
  CcFmcGfw prod:     GB202, GB100, GH100 (3 containers)
  headers: flags 0x104 everywhere except GB10B 0x101; entry 0x2801 constant;
    header tails 0x24..0x47 all zero in all 13
  envelopes: hash field verifies for all 13
  public-key record: 104 bytes (0x68) in the 615 arrays;
    bytes 97..104 zero on GB202/GB100, non-zero on GB10B/GB20B/GH100,
    e.g. GB20B prod 97e03ce1bd640c
  GB202 prod pkey == GB100 prod pkey (048bf118..);
  GB202 debug pkey == GB100 debug pkey (04d30bd5..);
  every other chip's prod and debug keys distinct
```

**Result.**

- **Answer:** five chips ship ordinary prod-and-debug FMC pairs, three ship
  confidential-compute builds, every envelope verifies, and no header or
  envelope field carries key material.
- **What we learned:**
  - The envelope is `publickey[104] || signature[96] || hash[48]`; the
    7 bytes after offset 97 are the public-key record's tail, not padding.
    The earlier `publickey[97] || pad[7]` split is corrected here.
  - The "inline key block" phrase from
    [the container analysis](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature)
    described those 7 bytes; no key block exists.
  - GB202 and GB100 share signing keys; the other chips rotate their own.
    "Two public keys" held only for the containers that analysis tested.
- **Related:**
  - [The signature envelope](../specs/04_firmware-formats.md#signature-envelope)
    carries the corrected layout.
  - [The 615 corpus](#166-the-615-corpus-splits-and-resigns-the-fmc)
    re-signs one image under both keys.

## 16.6 The 615 corpus splits and resigns the FMC

**Question.** What changes in the shipped corpus in driver 615.78.08?

**Why.**

- Every static claim stood on 595.91.07. The newest branch restructures what
  ships, and any key search has to target the current layout.
- What it would give: the current corpus map, and the answer to whether a
  separate debug code path still exists to leak.

**Method.**

- Tools: [crypto compare](../tools/crypto-compare/) `carray`; a header scan
  over the new container.
- Target: the 615.78.08 driver package firmware files and generated arrays;
  offline.
- Steps:
  - Inventory the package firmware directory and compare against 595.91.07.
  - Parse the new `ucodes` container header and count the falcon-descriptor
    signatures inside.
  - Compare the production and debug FMC arrays byte for byte.

**Observed data.**

```text
package firmware:
  gsp_ga10x.bin: 72,830,976 -> 26,988,440 B (0x19ca898)
  in-image rm.bindata.bin extent: 0x33ad000 -> 0x69b000 B
  new: ucodes_ga10x.bin 0x3784e00 B, ucodes_tu10x.bin
  ucodes header: magic NVUCODES, version 1, count field 0x50d,
    8-byte field a6 03 b7 cd fe be 38 2d
  falcon-descriptor signatures: 14 (595 bindata) -> 18
FMC arrays (GB202):
  production image sha256 prefix 5b74fefd42fc
  debug image sha256 prefix    5b74fefd42fc  (byte-identical)
  signatures and public keys differ per variant
```

**Result.**

- **Answer:** the engine ucode moves out of the GSP-RM image into a
  `NVUCODES` container, and the debug FMC becomes the production image signed
  by the debug key.
- **What we learned:**
  - In 615.78.08 there is no distinct debug FMC code to leak: a debug-key
    break buys the same bytes the production image already publishes. The
    595-era pair differed in 99.6% of bytes
    ([the inventory](../experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package)).
  - The ucode corpus grows (18 descriptors against 14), and the
    unchanged-blob ciphertext survives the move
    ([16.2](#162-the-bindata-key-is-version-stable)).
- **Related:**
  - [The fwimage map](../experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)
    describes the 595 layout this supersedes.
  - The corpus key search lead in IDEAS inherits the un-gated status.

## 16.7 No ciphertext crosses a corpus boundary

**Question.** Do any two encrypted corpora in one driver version share
ciphertext, and does any corpus repeat itself at shifted offsets?

**Why.**

- The [corpus key search](../IDEAS.md#corpus-key-search) needed its mode
  question answered before any family sweep: shared blocks across chips
  would prove ECB and deliver known plaintext, and internal shifted
  repetition would mark ECB-class position independence.
- [The container census](#165-the-container-census-names-the-chips-and-the-keys)
  left GB202 and GB100 sharing both signing keys with no body-level
  comparison behind it — the sharing might have reached the body keys.
- What it would give: the mode set for the oracle design, the key-scope map
  across corpora, and the cheapest key-search shortcut either opened or
  closed.

**Method.**

- Tools: a magic-scan extractor with SHA-384 envelope verification;
  pairwise block joins with an offset-delta histogram; a shifted-segment
  test extending every duplicated block to its maximal same-delta run; a
  cross-corpus block census. Ad-hoc offline passes, standard library only.
- Target: driver 595.91.07 — the thirteen module containers, the GSP-RM
  image, and the four vBIOS bodies in the 1 MiB flash image; offline.
- Steps:
  - Extract the thirteen containers from the module by magic scan, verify
    every envelope hash, and identify them by size twins, key groups, and
    embedded content.
  - Join every same-flavor pair across chips, the same-chip flavor pair,
    and the confidential-compute builds; classify matches by offset delta
    and body component.
  - Run the shifted-segment test (runs at or above `0x80` B) over each FMC
    body and the whole 595 bindata.
  - Census every non-uniform 16-byte block across all eighteen corpora and
    count the values that appear in more than one.
  - Locate the four vBIOS bodies, map the two cards' differing bytes, and
    read the fields around each body.

**Observed data.**

```text
thirteen containers, all envelopes verify (offset, body, code, flags, pkey):
  gb202_prod 0x58f598 0x46200 0x37000 0x104 048bf118
  gb202_dbg  0x691480 0x46200 0x37000 0x104 04d30bd5   (the c09 container)
  gb100_prod 0x604450 0x30500 0x25400 0x104 048bf118
  gb100_dbg  0x706338 0x30500 0x25400 0x104 04d30bd5
  cc_a_prod 0x4c3c28 0x3ec00 0x33900 0x104 048bf118
  cc_b_prod 0x502968 0x2fc00 0x24900 0x104 048bf118
  gb10b pair 0x5d5b10/0x6d79f8 flags 0x101; four more single-key pairs
joins, matched non-uniform blocks out of ~18k per body:
  gb202_prod vs gb100_prod: 1;  gb202_dbg vs gb100_dbg: 1
  gb202_prod vs gb202_dbg:  0;  every other pair: 0 or 1
  the shared values are two flavor-tagged structured constants:
    prod 4200000055000000..  dbg 42000000aa000000..
cross-corpus census (bindata, 13 bodies, 4 vBIOS bodies):
  3,568,551 distinct non-uniform blocks; 2 values in more than one corpus
shifted segments >= 0x80 B at any delta:
  none inside gb202_prod, gb202_dbg, gb100_prod, cc_a_prod, gb10b_prod
  none anywhere in bindata_595
vBIOS bodies (flash1m): app07 0x6fe40+0x20200, app19 0x90040+0x21b00,
  app15 0xb1c80+0x5b00, app23 0xb780c+0x1e200
  1,713 bytes differ between the two cards: head metadata, app23's
  plaintext tail, and 18 bytes in app07's descriptor neighborhood
  (0x6fc51..0x6fc62); all four encrypted bodies byte-identical
  tgt01 bodies share exactly an 8-byte prefix; both headers are load-map
  records carrying the 0x6d ID-word family of the bindata generic headers
module vs GSP-RM image: gb202_prod body matches 0 blocks in the fwimage
boot image: the module carries GspRmBoot byte-exact twice — as its own
  array at 0x90afb0 (0x47000 B) and re-ordered inside the gb202_prod body;
  the container's code (0x37000) is a byte-exact prefix of the boot
  array's code (0x37e00), data and manifest identical
```

**Result.**

- **Answer:** no two corpora in the 595 package share ciphertext, and no
  corpus repeats itself at shifted offsets; every encrypted corpus in one
  driver version encrypts alone.
- **What we learned:**
  - Signing-key sharing does not reach body crypto: GB202 and GB100 share
    both signing keys and zero body blocks. The cross-chip shortcut in the
    corpus key search is closed — a key must be found per corpus.
  - ECB stands nowhere. [The per-copy seed](#163-duplicated-ucode-diverge-at-a-per-copy-seed)
    ruled out one ECB key for the bindata; the absence of any repeated
    segment inside any single copy now rules out ECB under per-copy
    derived keys as well. The bindata oracle must consume the seed: CBC
    with it as IV, CTR with it as nonce, XTS with it as tweak, or a
    derivation.
  - The FMC and vBIOS corpora carry no seed structure. The 28-byte
    high-entropy tail before each vBIOS body varies per card where the
    ciphertext does not (app07), so it is metadata or a MAC, not an
    encryption seed; vBIOS key material is card-independent, which
    [16.1](#161-the-encrypted-vbios-is-card-independent) already implied.
  - [16.4](#164-the-fmc-and-gsprmboot-share-ciphertext-in-every-version)
    is confirmed at module level for 595 and its mechanism is now
    physical: the module stores the boot image twice, and the container's
    regions are byte-identical to the boot array's at different offsets,
    so the per-region reset is real, not a packaging artifact. The boot
    array carries `0xe00` of code beyond the container's code component.
  - The module containers and the GSP-RM image are disjoint corpora; the
    fwimage's only encrypted payload is the bindata.
- **Related:**
  - [The corpus key search](../IDEAS.md#corpus-key-search) ran this as its
    Phase 1; the phase-2 window scan and the phase-3 families follow.
  - [The generic-header blob directory](../experiments/13_fwimage-map-and-bindata.md#135-the-generic-header-blob-directory)
    named the ID-word family the vBIOS headers share.
  - [The vBIOS ucode bodies](../experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)
    located the four bodies this record maps across cards.

## 16.8 No shipped window is the FMC key

**Question.** Does any 16-byte window of the shipped material decrypt an
FMC code component?

**Why.**

- The [corpus key search](../IDEAS.md#corpus-key-search) ordered its phases
  so the cheapest hypothesis runs first: if a body key ships verbatim in
  the package — in a header, an envelope, a seed, a table — a window scan
  finds it in minutes.
- [16.7](#167-no-ciphertext-crosses-a-corpus-boundary) closed key sharing
  across corpora but not a stored key; the bindata keys are derived inside
  SEC2 ([the secure-data
  unit](../experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)),
  while the FMC key's provenance is unknown.
- What it would give: the debug FMC decrypt, which feeds the
  [signature-section sweep](../IDEAS.md#fmc-signature-section-sweep), with
  no family design at all.

**Method.**

- Tools: the [FMC tools](../tools/fmc-tools/) window scanner and RISC-V
  verifier; the parcel log-probability table built from the GSP-RM code
  segment.
- Target: both GB202 FMC containers from 595.91.07, the debug container
  (`c09`) and the production container; offline.
- Steps:
  - Collect the shipped material: the module, the GSP-RM image, both
    extracted bindatas, the 570/595/615 container and boot corpus, both
    cards' 1 MiB and 2 MiB vBIOS images, two board ROMs, and three public
    reference ROMs — 318 MB.
  - Try every byte-offset 16-byte window as an AES-128 key against the
    first blocks of each code component under four scoring paths: ECB
    (blocks 0–4), CBC with unknown IV (blocks 1–4, IV-insensitive), and
    CTR with counter start 0 and 1.
  - Calibrate the scorer on real GSP code and on random bytes, then pass
    the top 24 candidates per target through the full-code RISC-V walk.
- Args used:
```bash
./window_scan riscv_logp_q.bin containers/c09.body <318 MB of package files>
python3 fmc_riscv_verify.py --hits hits.txt --container containers/c09.bin
```

**Observed data.**

```text
windows: 336,307,381 per target; code component 0x37000 per container
calibration (5-block scores): GSP code mean -659 (max -320),
  random bytes mean -1483 (max -1397)
gb202_dbg best scores: ecb -1326, cbc-anyIV -1038 (4-block), ctr0 -1313,
  ctr1 -1324
gb202_prod best scores: ecb -1314, cbc-anyIV -1037, ctr0 -1314, ctr1 -1329
full-code walk, top 24 per target: all 48 reject at 0.086-0.090 invalid
  instructions; compiled RISC-V walks at ~0.0003
```

**Result.**

- **Answer:** no 16-byte window of any shipped artifact decrypts either
  GB202 FMC container under ECB, CBC with any IV, or CTR with counter
  start 0 or 1. The key does not ship verbatim in the package.
- **What we learned:**
  - With [16.7](#167-no-ciphertext-crosses-a-corpus-boundary), the FMC key
    is now known to be neither a package literal nor shared with any other
    corpus. What remains for that target are the structured families: the
    csecret placements and the build constants.
  - The scan's scoring separates cleanly — the best of 336 million random
    keys stays 600 log-probability units below the real-code mean — so the
    same harness answers any future candidate list; Phase 3 families run
    through it by materializing candidates as a file.
  - The vBIOS and bindata corpora still need this pass, but their bodies
    are falcon code, not RISC-V, so the scan gates on a falcon-validity
    oracle first.
- **Related:**
  - [The negative key search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)
    exhausted the permutation family on the same containers.
  - [The corpus key search](../IDEAS.md#corpus-key-search) ran this as its
    Phase 2 at the FMC corpus.
