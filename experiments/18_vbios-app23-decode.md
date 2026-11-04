# The vBIOS app 0x23 decode

## Summary

**The idea.**

- The app `0x23` / target `0x0E` image is the only vBIOS artifact carrying
  the exact FEAT PLM values, in low-entropy sentinel-structured data. The lead
  was to decode that data as a register array against the live block maps, and
  to map the four ucode app/target IDs to their loaders.
- I decoded the whole plaintext DEVINIT area of the 1 MiB vBIOS image on both
  cards: boundaries, structure, per-card calibration, every PLM-shaped dword,
  and every live FEAT value.

**What it found.**

- The plaintext data is bigger than app `0x23`: it spans the in-body tail
  `0xC8000`–`0xD5A0C` and a second region `0xE8010`–`0xF7B18` that lies beyond
  the last PCI image. Three of the four FEAT-PLM anchors sit outside every
  ucode body, so the earlier "app `0x23` data tail" ownership was
  under-scoped ([18.1](#181-the-devinit-data-area-and-its-bounds)).
- The area is a sparse register-default map: about 95% poison/sentinel fill,
  eight per-instance 4 KiB pages, 0x200-stride records, twin config blocks,
  and 155 per-card calibration dwords
  ([18.2](#182-a-sparse-register-default-map)).
- The PLM entries decode one-to-one against the live locked map: the FEAT pair
  value, the `FUSE_SS_PLM` value, and the `0x500300` sparse-block family are
  all table data in flash
  ([18.3](#183-the-plm-defaults-match-the-live-locked-map)).
- No selector content exists anywhere in the area, on either card, at any
  alignment: no readout value, no `SS0`/`SS1` base, no FEAT address, and no
  loader for the table in any stack component
  ([18.4](#184-no-selector-content-and-no-loader)).

**What it did not find.**

- No rate lever. The table writes nothing the parser leads can reach, and the
  tables are authenticated in Heavy Secure
  ([devinit authentication](../specs/05_vbios-and-devinit.md#devinit-authentication)).
- No public identity for app `0x23` / target `0x0E`; its descriptor carries an
  ASCII field the other three images do not have, but no name resolves.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 18.1 | [The DEVINIT data area and its bounds](#181-the-devinit-data-area-and-its-bounds) | Two regions, one beyond the PCI chain |
| 18.2 | [A sparse register-default map](#182-a-sparse-register-default-map) | 95% fill, per-instance copies |
| 18.3 | [The PLM defaults match the live locked map](#183-the-plm-defaults-match-the-live-locked-map) | Re-lock values are table data |
| 18.4 | [No selector content and no loader](#184-no-selector-content-and-no-loader) | Zero live-value hits |

## 18.1 The DEVINIT data area and its bounds

**Question.** Where does the plaintext data behind app `0x23` actually start
and end?

**Why.**

- The [devinit scan](05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)
  attributed the PLM anchors to "app `0x23` data" by body-range check. The
  anchor offsets it printed reach past the body end `0xD5A0C`, so the
  attribution needed a boundary pass.
- What it would give: the true extent of the data the GPU-side devinit reads,
  and the correct owner for each table.

**Method.**

- Tool: [vBIOS tools](../tools/vbios-tools/) `app23_decode.py` window pass,
  over both 1 MiB dumps; offline.
- Steps:
  - Classify every `0x400`-byte window from `0xC8000` to the image end by
    entropy and fill class, then list every run of non-fill dwords (fill =
    `0xBADF1100` and `0xBADF5040`).
  - Place the runs against the ucode bodies and the PCI image chain.

**Observed data.**

```text
plaintext data runs:      0xC8080..0xD4B18   (inside the app 0x23 body and
                                            the last FwSec image, end 0xD5C00)
                          0xE8010..0xF7B18   (beyond the last PCI image)
0xD5C00..0xE8010          pure fill
0xF7B18..0x100000         pure fill; the image ends in 0xBADF1100 rows
in-body tail census:      13,955 dwords, 325 distinct values
fill inside the tail:     6,723 0xBADF1100 + 5,931 0xBADF5040 + 603 zeros
                          (~95% of the dwords)
new sentinels in the fill vocabulary: 0xBADF5720 (54), 0xBADF510C, 0xBADF5546
FEAT-PLM anchor 0xfffffb8f at 0xd40e8, 0xe832c, 0xe942c, 0xf70e8:
  only 0xd40e8 is inside the app 0x23 body
```

**Result.**

- **Answer:** the plaintext DEVINIT area is two regions, and the larger one
  belongs to no ucode body and no PCI image; it is board data past the end of
  the chain.
- **What we learned:**
  - The earlier ownership claim is corrected: the tail tables at `0xE8300` and
    `0xE9400` and the `0xF70E8` anchor are outside app `0x23`, and "app `0x23`
    data tail" under-described a shared DEVINIT area.
  - The fill vocabulary is three sentinels wider than the scan recorded.
- **Related:**
  - [The vBIOS spec](../specs/05_vbios-and-devinit.md#microcode-table) carries
    the corrected extent.

## 18.2 A sparse register-default map

**Question.** What is the structure of the DEVINIT data area?

**Why.**

- The lead's decode step: read the data as a 4-byte-stride array and name the
  record shapes, or close the tail as an opaque block.
- What it would give: the record grammar any future edit or dump must match,
  and the per-card component.

**Method.**

- Tool: [vBIOS tools](../tools/vbios-tools/) `app23_decode.py` census, stride,
  cluster, and per-card passes; offline.
- Steps:
  - Hash candidate periodic structures, diff supposed twins, and list every
    dword that differs between the two cards from `0xC8000` to the image end.

**Observed data.**

```text
stride autocorrelation: no strong period; the data is records in fill, not
  a uniform array
0x1000-periodic pages: 8 pages at 0xEC000..0xF3FFF, identical cluster layout,
  no two pages byte-identical (per-instance values at fixed slots)
0x200-stride records: 6 at 0xEB0E8 onward, 0xC4 bytes each, two identical pairs
twin config blocks: 0xD4000 vs 0xF7000 (2,844 B, 37 differ);
  0xD1800 vs 0xEA800 (592 B, 39 differ)
per-card calibration: 155 differing dwords, both regions, e.g.
  0x0cc630: 18e1ca91 / 18e1ca92        serial-shaped
  0x0cc140: 06a37f74 / 06a37f7c        one bit, 7 occurrences
  0x0d42c8: 00000957 / 0000063b        timing-shaped pairs
  0x0cc718: 28040800 / 38040800        0x280/0x380 split (see 18.4)
```

**Result.**

- **Answer:** the area is a sparse register-default and trim map: poison or
  sentinel in unimplemented slots, real values in per-instance copies with a
  per-card calibration component.
- **What we learned:**
  - The per-instance copies (8 pages, 6 records, twins) match the DEVINIT
    model: per-unit default values, refreshed per card.
  - The per-card component is serial-, timing-, and single-bit-shaped. Nothing
    in it is selector-shaped, which [18.4](#184-no-selector-content-and-no-loader)
    measures directly.
- **Related:**
  - The per-card BAR0 table at `0x1f2000` shows the same
    training-shaped per-card pattern
    ([the table across a cold boot](14_engine-map-census.md#144-the-per-card-table-persists-across-a-cold-boot)).

## 18.3 The PLM defaults match the live locked map

**Question.** Do the PLM values in the DEVINIT area decode against live
registers?

**Why.**

- The anchors are the exact stock PLM values of the FEAT bank. If they are
  default-table entries, the table names what the GPU-side devinit locks at
  power-on, which is the [autonomous re-lock](05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)
  actor's data source.
- What it would give: the decode the lead asked for, and an attribution gain
  for the open question of who writes and re-locks the bank.

**Method.**

- Tool: [vBIOS tools](../tools/vbios-tools/) `app23_decode.py` anchor census;
  the live values come from the [register map](../specs/03_register-map.md).
- Steps: count every aligned occurrence of each PLM family member across the
  whole image, and dump the record context around each cluster.

**Observed data.**

```text
value            live owner                         hits   sites
0xfffffb8f       FEAT PLM pair, locked                4    0xd40e8 0xe832c
                                                          0xe942c 0xf70e8
0xfffffbff       FUSE_SS_PLM (0x8200fc), locked       7    0xd1624 0xd1b7c
                                                          0xe8308 0xe8374
                                                          0xe9408 0xe9474
                                                          0xea624
0x0884cb8f       sparse block 0x500300 PLM            2    0xe8300 0xe9400
0x0884cbcf       same family                          2    0xe8328 0xe9428
0x0085cb8f       same family                          2    0xe8358 0xe9458
0xffffff8f       Ada FEAT locked                      9    aligned: 0xcf044
                                                          0xcf058 0xd2278
                                                          0xd4190 0xe9060
                                                          0xf7190 0xf7a90
0xffffff0f       Ada FBPA locked                      7    aligned: 0xd41e0
                                                          0xd4914 0xf71e0
                                                          0xf7914
0x80842bcf       FLR reset value                      0    none
record around each 0xfffffb8f site (identical at both out-of-body sites):
  40000000  000e003f  badf5720  00000000  fffffb8f  badf5040 ...
  02100c00  00000000  badf5040  00000010  00000000  <per-instance>
the 0xE8300 and 0xE9400 records are the same 0x28-byte shape, and the two
sites are 0x1100 apart
```

**Result.**

- **Answer:** the PLM entries are default-table rows for real registers: the
  FEAT pair's locked value, `FUSE_SS_PLM`'s locked value, and the
  `0x500300`-family PLMs all sit in the table, each in a fixed record shape.
- **What we learned:**
  - The re-lock values the autonomous devinit writes are plaintext table data
    on the flash. The writer still runs in Heavy Secure and the table is
    authenticated, so this names the data source, not an edit path.
  - Ada-family values in a GB202 table mean the table is generic across
    families, not a GB202-specific write list.
  - The FLR reset value `0x80842bcf` is absent, consistent with the reset
    value coming from the reset domain, not from this table.
- **Related:**
  - [The re-lock record](01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)
    established which registers the devinit re-locks.

## 18.4 No selector content and no loader

**Question.** Does the DEVINIT area carry the FEAT selector values or their
per-card base, and does anything load the four ucode images?

**Why.**

- The bank's `SS0`/`SS1` words are rewritten at every power-on from a fixed
  per-card base plus a small variable component
  ([the bank across boots](05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
  The DEVINIT area is per-card, so it was the candidate source.
- What it would give: the selector's data source, or the tail closed as a
  rate lever.

**Method.**

- Tools: [vBIOS tools](../tools/vbios-tools/) `app23_decode.py` value scans; a
  source grep of the 615 open kernel modules; the [corpus
  diff](../tools/corpus-diff/) manifest split for the driver images; offline.
- Steps:
  - Scan both cards' images for every measured live FEAT value, their
    per-card AND/OR masks, and the `SS0` halfword shapes, at dword alignment
    and any byte alignment, in both endiannesses.
  - Grep the 615 open kernel modules for a vBIOS ucode-table parser, and check
    the bindata falcon descriptors for an identity join with the v6 vBIOS
    descriptors.

**Observed data.**

```text
live values vs the plaintext area (both cards, 0xC8000..0x100000):
  FEAT_READOUT_1 0x00c36180, READOUT_0 0x233, OVR_ECC 0x00888888,
  OVR_ECC_1 0x002a2aaa, QUADRO 0x01000280 / 0x01000380, ID 0x12800541,
  every measured SS0 and SS1 sample, both cards' SS0 AND and OR masks,
  the FLR reset PLM: zero occurrences, any alignment, either endianness
  (small integers 1 and 2 match by chance and are not evidence)
SS0 halfword shapes 2124/2024/2126/5422/6005/4005: zero occurrences in the
  plaintext area on either card; matches exist only inside encrypted regions
  at unaligned offsets
per-card 0x280/0x380 dword pairs at 0xcc6c0/0xcc718/0xcc754 correlate with
  the QUADRO register's per-card split, but no live QUADRO value appears
loader mapping:
  target 0x01 is PMU in the only public mapping (nova-core FWSEC parser);
    apps 0x19/0x15 are that PMU pair
  no stack component reads the table on GB202
    ([the consumer record](11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table))
  the 615 open kernel modules contain no FWSEC or ucode-table parser at all
  the bindata falcon load descriptors are a different family
    (signature ed300700 ee703000 ce300300), so no identity join exists
  app 0x23's descriptor: +0x04 stored size equals the body length, +0x28 is
    the constant 0x01012801 in all four images, and +0x2c/+0x30 carry ASCII
    ("OO", 0x42554842) where the PMU pair carries small integers (4/5,
    0x11/0x12); no public name resolves the field
```

**Result.**

- **Answer:** the DEVINIT area carries no selector value, no `SS0`/`SS1` base,
  and no FEAT address, and nothing in any stack loads the four images on
  GB202.
- **What we learned:**
  - The selector's per-card base is not on the readable flash. Silicon fuses
    remain the natural fixed-per-card source, which sharpens the
    writer-identity question: the devinit reads per-card state that plaintext
    does not carry.
  - The `0x280/0x380` calibration pairs show the table does hold some
    per-card classification-shaped data; the absence of the live values is
    therefore a measured negative, not a scope gap.
  - The lead's decision lands on the closed side: a configuration and default
    table, with the PLM decode as the one structural gain. It is not a rate
    lever, and the parser leads gain nothing from it.
- **Related:**
  - [The devinit scan](05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)
    closed the plaintext write route; this record closes the data reading.
