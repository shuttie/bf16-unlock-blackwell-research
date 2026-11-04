# The cross-version corpus diff

## Summary

**The idea.**

- Every static claim stood on one driver and one GSP-RM version, 595.91.07,
  plus the two PRO reference versions. A check that appears only in a later
  branch names both the security-relevant parser and the older image where it
  is absent, and a header that never changes across versions closes itself as
  a key source.
- I split the GSP-RM images of 570.144, 595.91.07, and 615.78.08 into their
  libos manifest modules, diffed the modules and their strings, and censused
  the FMC and GspRmBoot headers across the corpus.

**What it found.**

- The three packages ship three RM lineages: `r570_00`, `r596_84`, and
  `r617_07` ([17.1](#171-the-module-map-spans-three-rm-lineages)). The module
  set grows per branch; the plaintext `rm.elf` grows from 14.1 MB to 15.5 MB.
- The FMC header is frozen: magic, flags, the `0x2801` constant, zero tails,
  and the `body = code + data + 0xA00` law hold in all fifteen containers
  across all three versions ([17.2](#172-the-fmc-and-gsprmboot-headers-are-stable)).
  The 570 package's GB202 production container is byte-identical to the public
  linux-firmware sample.
- The secure-boot string families are identical in 570 and 595 and vanish from
  the 615 image: `NV_FWSECLIC_ERR` 126 to 0, `NV_UDE_ERR` 103 to 0, and every
  bare `DEVINIT`, `FWSEC`, and `UDE` substring is gone
  ([17.3](#173-the-secure-boot-strings-vanish-in-615)).
- The 595 RM added a `GSP-FMC` error family over 570, and the 615 RM added a
  handful of new checks with strings ([17.4](#174-what-each-branch-added)).

**What it did not find.**

- No version-to-version vBIOS: the vBIOS ships with the board, not the driver,
  and the local corpus is one board build. That leg needs a second board
  source, which is the PRO rental plan in the payload lead.
- No key-shaped header field in any branch; the header closure in
  [the container census](16_crypto-model-compare.md#165-the-container-census-names-the-chips-and-the-keys)
  now rests on three branches instead of two.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 17.1 | [The module map spans three RM lineages](#171-the-module-map-spans-three-rm-lineages) | `r570`, `r596`, `r617`; set grows |
| 17.2 | [The FMC and GspRmBoot headers are stable](#172-the-fmc-and-gsprmboot-headers-are-stable) | Frozen header, no key field |
| 17.3 | [The secure-boot strings vanish in 615](#173-the-secure-boot-strings-vanish-in-615) | 126/14/103 to zero |
| 17.4 | [What each branch added](#174-what-each-branch-added) | GSP-FMC checks; SRAM-slot checks |

## 17.1 The module map spans three RM lineages

**Question.** What does the libos manifest contain in each driver branch, and
which modules changed?

**Why.**

- The [fwimage map](13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)
  defined the manifest for 595.91.07 only. A cross-version diff needs the same
  split on every branch, and a restructured manifest would hide whole modules
  from every static claim.
- What it would give: the module inventory per branch, and the dating of every
  later arrival.

**Method.**

- Tool: [corpus diff](../tools/corpus-diff/) `split`.
- Target: the 570.144 and 615.78.08 GSP-RM images staged next to the running
  595.91.07 image; offline.
- Steps:
  - Parse the libos manifest of each image. Each module is a NUL-terminated
    name padded to 8 bytes followed by `flags, reserved, align, offset, size`
    as u64 words; short names such as `rm.elf` shift the fields by 8 against a
    16-byte name slot, so the fields are read from the padded name end.
  - Hash each module extent and read the build-lineage string.
- Args used:
```bash
python3 -I tools/corpus-diff/corpus_diff.py split gsp570_fwimage.bin
python3 -I tools/corpus-diff/corpus_diff.py split gsp_fwimage.bin
python3 -I tools/corpus-diff/corpus_diff.py split gsp_ga10x_615.bin
```

**Observed data.**

```text
modules per branch        570: 9    595: 12    615: 13
added 570 -> 595          kernel_gb10y.elf, kernel_gb20y.elf, debug.elf
added 595 -> 615          kernel_gr10x.elf
rm.elf plaintext extent   0xd73000 / 0xdcd000 / 0xed2000 bytes
rm.bindata.bin extent     0x2c05000 / 0x33ad000 / 0x69b000 bytes
build lineage strings     r570_00 (570.144) / r596_84 (596.86) / r617_07 (617.52)
every shared module changed hash, including init.elf and every kernel
```

**Result.**

- **Answer:** the manifest layout is unchanged across the three branches, the
  module set only grows, and each package ships a different RM lineage: the
  615.78.08 driver carries a 617-lineage RM, one line ahead of its driver
  number.
- **What we learned:**
  - The 595.91.07 image sits on its own RM line (`r596`), so 570 and 615 are
    both one-line neighbors, not small patches of it.
  - The [615 corpus](16_crypto-model-compare.md#166-the-615-corpus-splits-and-resigns-the-fmc)
    bindata shrink reproduces from the manifest: `0x69b000` bytes in-image.
  - No module is byte-identical across any two branches; per-module comparison
    must go through strings, not hashes.
- **Related:**
  - [The secure-boot strings](#173-the-secure-boot-strings-vanish-in-615)
    explain what else the 617 line changed.

## 17.2 The FMC and GspRmBoot headers are stable

**Question.** Do any FMC or GspRmBoot header fields carry version-dependent or
key-shaped content?

**Why.**

- The [container census](16_crypto-model-compare.md#165-the-container-census-names-the-chips-and-the-keys)
  censused the thirteen 595 containers and the 615 arrays. The 570 containers
  and the linux-firmware sample were never in one table, and a header that
  changes per version could hide a per-build nonce or key slot.
- What it would give: the header closed as a key source with three-branch
  evidence, or a field that moves with the version.

**Method.**

- Tool: [corpus diff](../tools/corpus-diff/) `headers`.
- Target: the thirteen extracted 595 containers, the 570 package GB202
  container and the linux-firmware sample, and the 615 GB202 production and
  debug containers rebuilt from the generated arrays; offline.
- Steps:
  - Parse the `0x48`-byte header of each container: magic, body, code, data,
    flags, the `0x20` constant, and the `0x24..0x47` tail.
  - Check `body = code + data + 0xA00` and hash each container.
- Args used:
```bash
python3 -I tools/corpus-diff/corpus_diff.py headers \
  570-lf=fmc570_lf.bin 595-c00=c00.bin ... 615-prod=fmc615_prod.bin \
  615-debug=fmc615_debug.bin
```

**Observed data.**

```text
15 containers, three branches:
  magic 03044800 everywhere; flags 0x104 on GB202 (0x101 on the GB10B pair);
  constant 0x2801 everywhere; header tails 0x24..0x47 all zero;
  body = code + data + 0xA00 in all 15
code size, GB202 production: 0x25800 (570) / 0x33900..0x37000 (595) / 0x37000 (615)
570 package GB202 production == linux-firmware sample, byte-identical
  (sha256 e4d17650..)
615 GB202 production == debug container, byte-identical (sha256 5b74fefd..)
GspRmBoot: 570 200,812 B wrapped; 595 and 615 290,816 B;
  615 production and debug bodies differ, descriptors identical
```

**Result.**

- **Answer:** no header field moves with the version except the region sizes,
  and no field is key-shaped. The FMC header is closed as a key source on
  three branches.
- **What we learned:**
  - The public linux-firmware FMC is the 570 production container itself, so
    the public sample adds no independent build to the corpus.
  - The 615 production/debug merger extends from the FMC body to the whole
    container, while GspRmBoot keeps two distinct encrypted bodies behind one
    shared descriptor.
- **Related:**
  - [The signature envelope](../specs/04_firmware-formats.md#signature-envelope)
    carries the verified layout.

## 17.3 The secure-boot strings vanish in 615

**Question.** Which error and log string families move between branches?

**Why.**

- The [devinit scan](05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)
  rests on the `NV_UDE_ERR_DEVINIT` strings, and every parser lead is argued
  from named strings. If a later branch drops or reworks those families, the
  string-based method has a shelf life.
- What it would give: the branches where each family is readable, and any
  check that exists only in one branch.

**Method.**

- Tool: [corpus diff](../tools/corpus-diff/) `compare`.
- Target: the three GSP-RM images and the 615 `ucodes` container; offline.
- Steps:
  - Count every occurrence of each error-family prefix per image, and of the
    bare `DEVINIT`, `FWSEC`, and `UDE` substrings.
  - Diff the per-module string sets, filtered to a security namespace, across
    the 570-to-595 and 595-to-615 steps.
- Args used:
```bash
python3 -I tools/corpus-diff/corpus_diff.py compare \
  gsp570_fwimage.bin gsp_fwimage.bin 570 595
python3 -I tools/corpus-diff/corpus_diff.py compare \
  gsp_fwimage.bin gsp_ga10x_615.bin 595 615
```

**Observed data.**

```text
family prefix            570      595      615
NV_FWSECLIC_ERR          126      126      0
NV_DEVINIT_ERR            14       14      0
NV_COMPACTION_ERR         18       18      0
NV_GC6_ERR                 5        5      0
NV_UDE_ERR               103      103      0
GFW_BOOT_PROGRESS         10       10      0
GSP-FMC                    0        7      0
bare DEVINIT / FWSEC / UDE in 595: 47 / 128 / 144; in 615: 0 / 0 / 0
not present in the 615 ucodes container either
rm.elf strings            5514 ->  5797 -> 5651
```

**Result.**

- **Answer:** 570 and 595 carry identical secure-boot string tables, and the
  617-lineage image drops every one of them from its plaintext RM.
- **What we learned:**
  - The bench driver is on the last branch where the FWSEC-LIC, UDE, and
    devinit error names are readable. Later images cannot be string-mapped the
    same way, so the RM's own interface is mappable from strings on 595 only.
  - Whether the 617 line moved those checks into encrypted components or
    stripped the names is not decidable offline; the checks may well remain.
  - The GSP-FMC family exists only in 595, which dates it between the lines.
- **Related:**
  - [What each branch added](#174-what-each-branch-added) lists the families
    that do move.

## 17.4 What each branch added

**Question.** Which security-relevant strings appear in one branch only?

**Why.**

- The point of a cross-version diff: a check that appears only in a later
  version names a security-relevant parser and an older image to test.
- What it would give: dated checks, and differential targets for the parser
  leads.

**Method.**

- Tool: [corpus diff](../tools/corpus-diff/) `compare`, security-namespace
  filter.
- Target: the per-module string sets of the three images; offline.
- Steps: read the added and removed strings of each step, grouped by family.

**Observed data.**

```text
added 570 -> 595 (rm.elf, security namespace +72):
  GSP-FMC error family: "GSP-FMC ACR has failed!", "GSP-FMC error: LS
    signature verification failed!", "GSP-FMC error: PRI violation
    detected!", "GSP-FMC error: eFMC and GSP hash mismatch!", baremetal
    setup and initialization failures
  LOCAL_PRIV_ERR / REMOTE_PRIV_ERR
  per-unit "Uncorrectable SRAM error" names: PMU, PMU-RISCV, FECS, GPCCS,
    GCC, GPCMMU, LTC, L1 Data/Tag, LRF, LRC, MSE-RISCV, SEC2-RISCV, NVLINK
  X.509 / ASN.1 certificate block: key usage, ECDSA, RSA signature names,
    "PUBLICKEY_SIZE:"
added 595 -> 615 (rm.elf, security namespace +27):
  NVUCODES; "FSP boot completion"; CONFIG_SECURE / SECURE_CONFIG; PRIV_REG;
    SRAM_SLOT_OUT_OF_BOUND; SRAM_SLOT_PREEMPTED_INCORRECT;
    RMRistSramClearHash; RmSec2EnableMiracastDbg;
    dieletType/dieletId error formats (multi-die parts)
removed 595 -> 615: the entire FWSEC-LIC / UDE / devinit / GC6 families
  ([17.3](#173-the-secure-boot-strings-vanish-in-615))
```

**Result.**

- **Answer:** the dated checks are the 595-only `GSP-FMC` family (absent in
  570, so 570 is the older image where the FMC-to-RM handshake checks do not
  exist) and the 615-only SRAM-slot and hash-clear checks.
- **What we learned:**
  - The GSP-FMC family names RM-side validation of the FMC handoff: signature
    verification, PRI violation detection, and an eFMC-versus-GSP hash
    comparison. A parser differential between the 570 and 595 FMC paths is the
    follow-up this dates; nothing on the bench runs 570.
  - The 615 additions name no parser the parser leads can reach; they are
    engine-side bookkeeping with strings.
  - The vBIOS leg of the diff is empty by construction: no driver branch ships
    a vBIOS, so a version diff of init tables needs a second board source.
- **Related:**
  - The boot-input race lead is where a 570-versus-595 FMC differential would
    land; the hash-to-decrypt window is the shared target.
