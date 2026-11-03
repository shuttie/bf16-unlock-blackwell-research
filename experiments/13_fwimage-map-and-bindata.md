# The fwimage map and the bindata blob directory

## Summary

**The idea.**

- The BF16 cap is enforced somewhere between the fuse and the SM issue rate,
  and the two candidates left standing were FECS/GPCCS microcode and SM
  hardware. The falcon blocks are host-unreadable
  ([the falcon probe](11_falcon-and-gr-window-probe.md)), so the offline
  window into FECS code is the GSP-RM image itself.
- This group maps the whole firmware image, finds where the engine ucode
  lives, and names the mechanism that keeps it unreadable. All of it is
  offline statics over the extracted image; no hardware.

**What it found.**

- The image is a libos container, not one flat ELF. A manifest at file
  `0x6cff00` lists ten modules — six per-chip kernels, the RM, two small
  helper ELFs, and a 53.8 MB `rm.bindata.bin` — with offsets counted from a
  `0x6d000` base ([the manifest](#131-the-libos-manifest-and-the-module-chain)).
- Only about 18.5 MB of the 72.8 MB file is plaintext: the bootstrap, the
  kernels, the RM ELF, and the two helpers. The decompiled corpus ends at
  that boundary; the 936 "functions" above it are disassembler noise over
  encrypted bytes
  ([the plaintext boundary](#132-the-plaintext-boundary)).
- `rm.bindata.bin` is encrypted. Entropy sits near 8 bits/byte across the
  whole blob, no standard compression format appears, and no decompressor
  exists in the image
  ([the encryption](#133-bindata-is-encrypted-not-compressed)).
- The decryption mechanism is named by its own error strings: a firmware
  security unit validates the image and hands encrypted blobs to SEC2, which
  derives per-blob keys and runs AES-ECB in High-Secure mode
  ([the secure-data unit](#134-the-fwsec-lic-secure-data-unit)).
- The blob directory is real but smaller than it first looked. Of the
  sixty-six plaintext regions inside the encrypted mass, fourteen are falcon
  load descriptors with a signature, ID words, a `0xff` magic, and
  `{flag, start, end}` records, two are bare `{addr, size}` code loads at
  `0xf900` — the GR-falcon shape — and the rest are app descriptors,
  trailers, and permutation tables
  ([the blob directory](#135-the-generic-header-blob-directory),
  [the census](#138-the-blob-census-five-families)).

**What it did not find.**

- No FECS or GPCCS code in readable form. The ucode bodies stay encrypted;
  only their load descriptors are plaintext, and the six low-entropy islands
  once read as falcon code are permutation tables
  ([the census](#138-the-blob-census-five-families)).
- No absolute FEAT or fuse address in the entire file. Twenty-five
  `0x008238xx`/`0x008207xx`/`0x504204` probes return zero hits, in the
  plaintext code and the encrypted mass alike.
- No software AES tables. The decryption runs on the hardware
  crypto-compression engine, so there is no key table to recover either.
- No engine name for any of the blobs. The ID words in the A1 descriptors
  are ucode identity — both copies of a pair carry the same words — but they
  have no public mapping.

## Experiments

| ID | Short name | Result |
|---|---|---|
| 13.1 | [The libos manifest and the module chain](#131-the-libos-manifest-and-the-module-chain) | ten modules, offsets chained |
| 13.2 | [The plaintext boundary](#132-the-plaintext-boundary) | 18.5 MB of 72.8 readable |
| 13.3 | [bindata is encrypted, not compressed](#133-bindata-is-encrypted-not-compressed) | no plaintext, no codec |
| 13.4 | [The FWSEC-LIC secure-data unit](#134-the-fwsec-lic-secure-data-unit) | SEC2 AES-ECB, HS mode |
| 13.5 | [The generic-header blob directory](#135-the-generic-header-blob-directory) | 66 regions, five families |
| 13.6 | [The decrypted ucode transit and its read route](#136-the-decrypted-ucode-transit-and-its-read-route) | transit unproven, ICD read closed |
| 13.7 | [The `sec2_acr` args are a timeout pair](#137-the-sec2_acr-args-are-a-timeout-pair) | 20 ms window, no pointers |
| 13.8 | [The blob census: five families](#138-the-blob-census-five-families) | two `0xf900` GR candidates |

## 13.1 The libos manifest and the module chain

**Question.** What does the GSP-RM firmware image actually contain, and
where does each part sit in the file?

**Why.**

- The image was treated as a flat 72.8 MB plaintext ELF, but the corpus
  decompiled only a fraction of it and strings existed for six per-chip
  kernels. A wrong layout map makes every offset claim unreliable.
- What it would give: the true extent of the plaintext, and the container
  the falcon ucode must live in.

**Method.**

- Tools: string search, raw-byte hexdumps, and an ELF64 parse of the
  embedded header; offline over the extracted `.fwimage`.
- Steps: locate the kernel-name strings and the manifest that repeats them,
  parse the manifest entries, parse the ELF64 at `0x18f000`, and verify the
  chain by checking for ELF magic at each computed module start.

**Observed data.**

- A manifest at file `0x6cff00`–`0x6d8xx` lists ten modules. Its offsets are
  counted from a `0x6d000` base:

| Module | Manifest offset | File range | State |
|---|---|---|---|
| bootstrap | — | `0x0`–`0x6d000` | plaintext |
| six kernel ELFs | — | `0x6e000`–`0x18f000` | plaintext |
| `rm.elf` | `0x122000` | `0x18f000`–`0x10fe000` | plaintext |
| `vgpu.elf` | `0x1091000` | `0x10fe000`–`0x11b9000` | plaintext |
| `mnoc.elf` | `0x114c000` | `0x11b9000`–`0x11c8000` | plaintext |
| `rm.bindata.bin` | `0x115b000` | `0x11c8000`–`0x4508000` | encrypted |
| per-chip signatures | — | `0x4508000`–`0x4570000` | opaque |

- The kernel names are `kernel_ga10x.elf`, `kernel_gh100.elf`,
  `kernel_gb10x.elf`, `kernel_gb10y.elf`, `kernel_gb20x.elf`,
  `kernel_gb20y.elf`; the other four are `rm.elf`, `vgpu.elf`, `mnoc.elf`,
  and `rm.bindata.bin`.
- ELF magic appears at exactly the computed module starts: `0x18f000` for
  the RM, `0x10fe000` for `vgpu.elf`, `0x11b9000` for `mnoc.elf`, and at the
  six kernel slots `0x6e000`, `0x95000`, `0xbd000`, `0xec000`, `0x11b000`,
  `0x14a000`.
- The RM ELF64 at `0x18f000` parses cleanly: machine `0xf3` (RISC-V), entry
  `0x1a0f3da`, code segment at ELF-relative `0x0` (vaddr `0x1000000`,
  filesz `0xdcd000`), data at ELF-relative `0xdcd000` (vaddr `0x4000000`,
  filesz `0x1a1000`), TLS at `0xf6e000` (vaddr `0x20393000`, memsz `0x1000`).
  The manifest's section records for `rm.elf` repeat the same three
  segments.
- The `rm.bindata.bin` extent (`0x33ad000` bytes from `0x11c8000`) ends at
  `0x4508000`, leaving `0x68000` bytes of per-chip signature tail, which
  matches the earlier claim that the image carries per-chip signature
  sections.

**Result.**

- **Answer:** the image is a container of ten modules, and the manifest's
  `0x6d000`-relative offsets chain exactly from module to module.
- **What we learned:**
  - The earlier address model's `file offset = link VA − 0x00E71000`
    relation holds only inside the code segment. The program headers and the
    manifest are the authoritative offsets; [firmware
    formats](../specs/04_firmware-formats.md#container-layout) now carries
    the corrected table.
  - `vgpu.elf` and `mnoc.elf` are new named modules. The RM that runs on
    GB202 is the `rm.elf` module, `0xfaf000` bytes of code plus data and
    TLS, not the whole file.
- **Related:**
  - [The address model](../specs/04_firmware-formats.md#address-model) is
    corrected by this record.
  - [The plaintext corpus](07_plaintext-corpus.md#071-pl3-components-in-the-driver-package)
    inventoried the driver package; this record inventories the image.
- **Open question:** what the `vgpu.elf` and `mnoc.elf` modules are for.
  Their names suggest a virtual-GPU RM variant and a telemetry engine, but
  nothing here parses them.

## 13.2 The plaintext boundary

**Question.** How much of the image is readable, and where does the
decompiled corpus really stop?

**Why.**

- The audits describe scanning "the 72.8 MB plaintext GSP-RM". If most of
  the file is not plaintext, the negative results need their scope stated
  correctly.
- What it would give: the true scan scope, and a verdict on the corpus
  functions above the readable range.

**Method.**

- Tools: a block-entropy scan over the file (Shannon entropy per 4 KiB and
  64 KiB window) plus the corpus index; offline.
- Steps: classify every block, merge the blocks into plateaus, and compare
  the plateau boundary against the corpus function distribution.

**Observed data.**

- Code-like entropy (6.7–6.9 bits/byte) runs from file `0x0` to `0x11c8000`
  — about 18.5 MB — with a near-zero region at `0x11b0000`–`0x11c8000`
  where the manifest's last modules end.
- From `0x11c8000` to the end of the file, entropy sits at 7.95–7.99 in
  every 64 KiB block, the signature tail included.
- Inside the plaintext region, scattered 4–44 KiB islands reach 7.5–7.9
  bits/byte. Dumping them shows float32 tables: 4-byte words with the high
  bytes cycling through the `0x3d`–`0x3f` and `0xbd`–`0xbe` exponent
  range. They are LUTs, not code.
- The corpus index holds 22,941 functions. 22,005 sit below file offset
  `0x11d0000`; the 936 above it are spread thin (11–27 per MB) across the
  encrypted mass, with tiny sizes and no references. They are disassembler
  artifacts over encrypted bytes, not code.

**Result.**

- **Answer:** about 18.5 MB of the 72.8 MB file is plaintext, and the corpus
  covers that region and nothing else.
- **What we learned:**
  - The literal audits scanned everything that can be scanned; their negative
    results stand, but their scope is the plaintext region. Docs that say
    "the 72.8 MB plaintext GSP-RM" now say "the plaintext region".
  - The corpus function count (22,941) inflates by 936 junk functions above
    the boundary. Function-level claims should cite addresses below
    `0x21d0000` in Ghidra terms.
- **Related:**
  - [The static audit](02_registry-and-static-audit.md) and [the static
    pass](08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp)
    are the scans whose scope this record corrects.
- **Open question:** none. The boundary is measured.

## 13.3 bindata is encrypted, not compressed

**Question.** Is the content of `rm.bindata.bin` compressed or encrypted?

**Why.**

- Compression with a public format would make the blob readable with no key;
  encryption moves the question to the key.
- The blob is the only remaining home for the engine ucode, so its state
  decides whether the enforcement question can be answered offline.
- What it would give: the verdict, and the cryptanalysis surface if it is
  encryption.

**Method.**

- Tools: block-entropy scans, magic-value searches, and a corpus string
  grep; offline.
- Steps: entropy at 16 KiB granularity over the whole blob, search for the
  standard compression magics (`zstd`, `lz4`, gzip, zlib, zip, bzip2, xz),
  grep the corpus for decompressor names, and search the file for the two
  AES S-boxes.

**Observed data.**

- The 16 KiB scan covers 3,280 blocks. Mean entropy is 7.981 bits/byte;
  3,279 blocks sit above 7.9. The one exception, at `0x3cbc000` (6.980),
  holds encrypted u32 words sharing the high three bytes `f6 e3 e0` with a
  varying low byte — an encrypted table that preserves word locality.
- No compression magic appears at any alignment. The two-byte gzip and zlib
  patterns hit at chance rate (about 850 occurrences across 72.8 MB) and none
  starts a decodable stream.
- The corpus contains no `lz4`, `zlib`, `deflate`, `decompress`,
  `huffman`, `snappy`, or `zstd` string.
- Neither AES S-box nor its inverse appears anywhere in the file. The RM's
  AES runs on the hardware crypto-compression engine, which the module
  table's crypto module (`AES/RNG/PKA/CCC`) already suggested.
- A scan for the engine registers and fuses as 32-bit words — the
  `0x8238xx` FEAT family, the `0x8207xx` fuse words, `0x820040`,
  `0x820084`, `0x8203f0`, and `0x504204`, twenty-five probes — returns zero
  hits across the whole file.

**Result.**

- **Answer:** the blob is encrypted. Uniform near-8-bit entropy with no
  codec and no decompressor is an AES-class ciphertext, not packed data.
- **What we learned:**
  - No plaintext code anywhere in the image addresses the FEAT bank or the
    fuse words by absolute address. The RM reads them through computed
    HAL offsets, and any engine ucode that reads them is inside the
    ciphertext.
  - The `0x3cbc000` block is the one known structure in the blob and a
    known-plaintext foothold for any key search that follows.
- **Related:**
  - [The key search](07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)
    exhausted the FMC container family; this blob is a different corpus.
  - [The readout decode](12_feat-readout-decode.md) found the RM reads the
    bank only through HAL offsets.
- **Open question:** whether the per-blob keys are image-wide (recoverable
  offline) or device-derived (only recoverable on a live card). The
  secure-data strings name a key-derivation helper
  ([the secure-data unit](#134-the-fwsec-lic-secure-data-unit)), which points
  at the second, harder case.

## 13.4 The FWSEC-LIC secure-data unit

**Question.** Which code decrypts `rm.bindata.bin`, and how?

**Why.**

- The blob directory and the loader had to be named before any key work.
- Error strings are plaintext even when the payload is not, and this unit's
  strings name the mechanism.
- What it would give: the decryption path, its privilege level, and where
  the keys come from.

**Method.**

- Tools: the raw reference scan and Ghidra headless;
  [GSP-RM tools](../tools/gsp-rm-tools/). Offline.
- Steps: find the corpus references to the secure-data and image-parser
  error strings, disassemble the block that references them, resolve the
  log-message IDs against the decoder table, and read the surrounding unit's
  string inventory.
- Args used:

```text
refscan.py gsp_fwimage.bin 0x01ef1698 0x01ef16d8 0x01ef1718 0x01ef1768 0x01ef17c0
refscan.py gsp_fwimage.bin 0x01ef37f8 0x01ef3830 0x01ef3868 0x01ef38a0 0x01ef38d8 0x01ef3918
ghidra.sh DisasmRange.java 0x134eb80,240
```

**Observed data.**

- A contiguous log-thunk array occupies `0x134bc98`–`0x1352000`. Each entry
  is about `0x22` bytes: restore a register, load an error string and a
  log-message ID, load the error code, and tail-jump to the logger. The
  entries are reached by compressed dispatch, so no static caller exists;
  neither the reference scan nor the disassembler's call analysis finds
  one.
- The verify-secure-data family sits at error codes `0x20c`–`0x211`:

| Code | String |
|---|---|
| `0x20c` | `NV_UCODE_ERR_VERIFY_SECURE_DATA_GENERIC_HEADER_NOT_FOUND` |
| `0x20d` | `NV_UCODE_ERR_VERIFY_SECURE_DATA_IMEM_TO_DMEM_COPY_INVALID_PARA` |
| `0x20e` | `NV_UCODE_ERR_VERIFY_SECURE_DATA_DERIVE_SEC_DATA_KEY_HELPER_AESECB_NOT_IN_HSMODE` |
| `0x20f` | `NV_UCODE_ERR_VERIFY_SECURE_DATA_COMPUTE_SEC_DATA_SIGNATURE_HELPER_AESECB_NOT_IN_HSMODE` |
| `0x210` | `NV_UCODE_ERR_VERIFY_SECURE_DATA_SIGNATURE_INVALID` |

- The same unit's array carries the image-parser codes: `0x280`
  (`GFWIMAGEPARSER_INVALID_IFR_IMAGE`), `0x284`
  (`GFWIMAGEPARSER_INVALID_ROM_SIGN`), and the neighbors for
  `INVALID_FW_IMAGE`, `IFR_INVALID_SIZE`, `INVALID_EXTIMG_DATA`, and
  `INVALID_DATA_STRUCT_SIGN`.
- The verify-secure-data thunks log with message IDs `0x203fede8`–
  `0x203fee48`, a contiguous allocation in the same unit as
  `FUN_ram_0134af34`'s `0x203fe548`+ (the ID table steps by `0x18`).
- The unit's wider string inventory is the FWSEC-LIC family: SEC2 mutex
  acquire and release over the BSI write mutex, PLM read and write channels,
  mutex IDs, an IMEM-to-DMEM copy, and `NV_UDE_ERR_FWSECLIC_DID_NOT_EXECUTE`
  for the GC6 re-execution path. The registry string
  `RMForceNvdecUcodeEncryption` sits in the same image, so per-ucode
  encryption is a configured property, not a constant.

**Result.**

- **Answer:** a firmware-security unit inside the RM validates the image
  (the GFWIMAGEPARSER codes), walks the secure-data blobs, and hands them to
  SEC2. SEC2 derives the per-blob key and runs AES-ECB in High-Secure mode;
  the two `AESECB_NOT_IN_HSMODE` strings are the High-Secure-mode
  qualification failures. The RM never holds the key.
- **What we learned:**
  - The blob format is "generic header plus encrypted body", which the next
    record confirms on the data.
  - The keys are derived, not embedded. An offline key search has to attack
    the derivation, and the derivation helper runs inside SEC2's own
    High-Secure ucode — the same class of code this hunt is trying to read.
  - The GC6 path re-runs this unit (`FWSECLIC_DID_NOT_EXECUTE`), so the
    decryption happens again on every GC6 cycle, not only at cold boot.
- **Related:**
  - [The secure-data blob format](../specs/04_firmware-formats.md#secure-data-blobs)
    carries the header layout this unit parses.
  - [The error-code ranges](../specs/08_errors-and-logging.md#fwsec-lic-error-codes)
    are tabulated in the logging spec.
  - [The FMC rejection](05_fmc-fsp-boot-inputs.md#052-patched-gsp-rm-image-rejected-by-the-fmc)
    is the outer boundary of the same trust chain.
- **Open question:** the exact command sequence from this unit to SEC2. The
  callers sit in a corpus gap and are only reachable by compressed dispatch,
  so the sequence needs either a manual disassembly pass or a live log.

## 13.5 The generic-header blob directory

**Question.** Does `rm.bindata.bin` carry an internal structure that is
readable without the key?

**Why.**

- The secure-data strings name a "generic header"; if headers are plaintext,
  they give blob extents, load maps, and a per-blob identity, and they are
  known plaintext for any later key work.
- What it would give: the blob census, and possibly the FECS/GPCCS blobs by
  their load-map shape.

**Method.**

- Tools: a structured-window scan over the blob; offline.
- Steps: slide a 64-byte window over `rm.bindata.bin` at `0x40` stride,
  flag windows where at least 11 of 16 u32 words are below `0x4000000`
  (plausible header fields rather than ciphertext), merge adjacent windows,
  and dump the survivors as words.

**Observed data.**

- Sixty-six header regions survive. They are the plaintext islands the 16
  KiB entropy scan could not see: 64–256 bytes of structure against
  ciphertext on both sides.
- The recurring header shape is ID words, a `0xff` magic, then load records
  of the form `{flag, start, end}`. Two blobs at bindata offsets `0x990040`
  and `0x9ba040` open with ID words `0x49` and `0x6d`, then records
  `{1, 0, 0}`, `{1, 0x700, 0x1400}`, `{1, 0, 0}`, four times
  `{1, 0x6d00, 0x6d00}`, and `{1, 0x6d00, 0x7100}`.
- A pair of identical headers at `0x807b40` and `0x82e640` lists
  `{1, 0x600, 0x1900}` then five `{1, 0x8000, 0x8000}`-family records ending
  `{1, 0x8000, 0x8400}`. Another pair lists ranges from `0x300` to
  `0x25700` in eight records.
- One header at `0x4276d40` (bindata offset `0x30aed40`) lists
  `{0, 0x400}` and `{0xf900, 0xbe00}` twice, then ciphertext: a
  `0x400`-byte data segment and a `0xbe00`-byte code image loaded at
  `0xf900` — a falcon ucode load map. Its body entropy is 7.95 immediately
  after the header.
- Six islands (bindata offsets `0x2600f40` through `0x2890ac0`) are not
  headers but structured halfword data with `0x40`-pattern words. I first
  read them as falcon code; the census corrects that — they carry 16-value
  bit-reversed index runs, the signature of permutation or FFT twiddle
  tables, and they produce no hits under a code-shape detector that lights
  up on real code
  ([the census](#138-the-blob-census-five-families)).

**Result.**

- **Answer:** yes. Each blob carries its own plaintext generic header —
  there is no central directory — and the headers are falcon load
  descriptors: they say where the decrypted body lands in engine memory.
- **What we learned:**
  - The blob census is 66 headers for 53.8 MB of payload, so the average
    blob is large; the GR falcon pair should be findable by load-map shape
    (tens of KiB of code), once the ID words are mapped.
  - The headers are the known-plaintext surface for any future key search,
    together with the `0x3cbc000` block
    ([the encryption](#133-bindata-is-encrypted-not-compressed)).
- **Related:**
  - [The secure-data blob format](../specs/04_firmware-formats.md#secure-data-blobs)
    carries the header layout.
  - [The vBIOS ucode table](11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table)
    is a different, dead corpus; this one is live.
- **Open question:** which blob is FECS and which is GPCCS. The ID words have
  no public mapping, and identifying them needs either the load maps of a
  live boot or a key.

## 13.6 The decrypted ucode transit and its read route

**Question.** Does the plaintext FECS/GPCCS ucode exist in host-readable
memory at some point on a live card?

**Why.**

- The enforcement question — FECS microcode or SM hardware — is the fork
  that decides whether a PL3 register write can change the rate at all. The
  encrypted blob cannot answer it, but the load path might.
- What it would give: a route to the FECS code that skips the key entirely.

**Method.**

- Tools: the decoded boot logs, the corpus decompile of the wait function,
  and the halted-core aperture scan
  ([driver harness](../tools/driver-harness/)); no firmware was modified.
- Steps: decode the two `sec2_acr` log lines that motivated the transit
  claim, then measure every host read path that could reach a staging
  buffer: the ICD over the halted core, the FB windows, and the falcon
  ports.

**Observed data.**

- The transit claim rested on the `sec2_acr` log args, read as RM-memory
  pointers. They are a timeout pair — a 4-second deadline and the current
  time — and the wait is a poll for a completion flag, not a load with
  published pointers
  ([the timeout pair](#137-the-sec2_acr-args-are-a-timeout-pair)). The
  same misreading is corrected in the consumer record
  ([11.6](11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
- The load is issued through a compressed-dispatch vtable slot in the boot
  function `FUN_ram_0197f704` before the wait starts; no staging address
  appears anywhere in the boot capture.
- The halted-core ICD reads exactly the RM code segment
  `0x01000000–0x01DCD000` and refuses everything else: the container's own
  bindata, the data segment, the whole runtime range `0x90000000–0xA8000000`
  at 1 MiB steps, and every WPR address
  ([the aperture measurement](04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
- The FB windows return the access-denied fill over the WPR
  ([host FB reads](../specs/07_memory-and-host-access.md#host-fb-reads-and-the-wpr)),
  and the falcon ports are host-blocked
  ([the falcon probe](11_falcon-and-gr-window-probe.md)).

**Result.**

- **Answer:** the transit through RM-visible memory is unproven; its only
  positive evidence was the misread log pair. Every host read path tested so
  far is shut: the ICD aperture, BAR1/PRAMIN, and the EMEM ports at steady
  state. The boot-window port capture is a separate, unrun test ([the timed
  port capture](../IDEAS.md#timed-emem-and-dmem-capture)).
- **What we learned:**
  - The enforcement fork stays open, but its answer has to be behavioral
    or PL3, not a code capture through the ICD: the [FECS doorbell
    probe](../IDEAS.md#host-fecs-doorbell) tests whether a FECS command
    can move the rate without reading any ucode.
  - The GC6 re-execution of the decrypt
    ([the secure-data unit](#134-the-fwsec-lic-secure-data-unit)) stands,
    so a future read primitive — if one appears — can trigger the window
    on demand rather than at cold boot.
- **Related:**
  - [The aperture measurement](04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)
    closes the ICD read and write paths.
  - [The staged-ucode capture](../IDEAS.md#staged-ucode-capture) is the
    rewritten lead entry.
  - [The blob census](#138-the-blob-census-five-families) names the two
    `0xf900` blobs a working capture would have targeted.
- **Open question:** whether the GSP EMEM, SEC2 DMEM, or FSP EMEM ports carry
  plaintext during the FMC or ACR window. They were sampled only with the
  driver bound ([the timed port
  capture](../IDEAS.md#timed-emem-and-dmem-capture)).

## 13.7 The `sec2_acr` args are a timeout pair

**Question.** What do the two `sec2_acr` log lines' arguments actually
carry?

**Why.**

- The boot capture's `sec2_acr` entries were read as RM-memory pointers and
  became the evidence that GR boots through SEC2 with a published staging
  buffer. If the args are times, that reading falls.
- What it would give: the true shape of the RM-side ACR wait, and the real
  width of the decrypt window.

**Method.**

- Tools: the Ghidra project over the extracted image
  ([GSP-RM tools](../tools/gsp-rm-tools/)) and the three decoded boot
  captures; offline.
- Steps: decompile the function behind the log IDs `0x204d9558` and
  `0x204d95b8`, read the two log calls and the timeout builder, then check
  the arg arithmetic across all three captures.

**Observed data.**

- `FUN_ram_0197ee20` is a wait-for-completion: it builds a timeout
  descriptor with `FUN_ram_01593570` (`time + 0x20 + timeout_ns`, a
  4-second default), logs `(deadline, now)` as `0x204d9558` at entry,
  polls a completion flag at falcon-state `+0x443` while servicing the
  SEC2 command queue (engine tag `0x2f`), and logs `(time)` as `0x204d95b8`
  when the flag is observed.
- The arithmetic agrees on every capture: `deadline − now` is
  `0xEE6B2820` (4.000000032 s) on both cards and `0xEE6B2800` on the
  verbose capture; the wait lasts 19.62 ms, 19.63 ms, and 20.27 ms.
- The caller `FUN_ram_0197f704` logs `0x204d97c8` immediately before the
  wait, the first post-boot `gr_fecs` line follows ~50 ms after
  completion, and one wait pair appears per GR boot.

**Result.**

- **Answer:** the args are a deadline and a clock, not pointers. The ACR
  decrypt-and-load window is ~20 ms wide, bracketed by two watchable log
  lines, and re-runs on every GC6 cycle — but nothing in the log names a
  staging buffer.
- **What we learned:**
  - Two records carried the pointer reading: this group's transit argument
    and the consumer record's "RM-memory pointers". Both are corrected;
    the surviving fact is that the RM waits on SEC2's ACR completion.
  - A userspace halt armed on the first `sec2_acr` line would have ~20 ms
    of budget — the timing was sound; the read side is what failed
    ([the aperture measurement](04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
- **Related:**
  - [The boot log capture](08_assessment-and-cross-checks.md#088-live-gsp-log-capture-and-decode)
    produced the three captures the arithmetic uses.
  - [The transit record](#136-the-decrypted-ucode-transit-and-its-read-route)
    is the corrected lead.
- **Open question:** none.

## 13.8 The blob census: five families

**Question.** What are the sixty-six structured regions inside
`rm.bindata.bin`, and can the GR falcon pair be identified offline?

**Why.**

- The directory record called all sixty-six load descriptors and read the
  six islands as falcon code. A wrong census sends a capture after the
  wrong shapes — and if any blob were stored unencrypted, the whole key
  question would change.
- What it would give: the true blob inventory, the FECS/GPCCS candidates
  by load-map shape, and a dump matcher ready for any future read
  primitive.

**Method.**

- Tools: a window scan reproducing the directory record, a word dump of
  every region, a direct `0xff`-word scan for descriptor parsing, a
  bit-reversed-run test for the islands, and a dump matcher with tag,
  ciphertext-anchor, and code-shape detectors; offline.
- Steps: classify each region by its signature constants; group the
  descriptor blobs by identical record lists; validate the matcher on a
  synthetic dump with planted artifacts and on the image itself.

**Observed data.**

- Five families. Fourteen descriptors carry the signature
  `ed300700 ee703000 ce300300`, a record count, two ID words, the `0xff`
  magic, and `{flag, start, end}` records — seven distinct ucode, each
  stored twice with identical records and IDs (pairs like `0x990048` and
  `0x9ba048`, IDs `0x4900,0x6d00`).
- Two blobs hold bare `{addr, size}` records with no signature:
  `0x2fa7178` lists `{0, 0x600} {0xf900, 0xba00}` and `0x30aed48` lists
  `{0, 0x400} {0xf900, 0xbe00}`, each twice — 47.6 and 48.6 KiB code
  images at the same engine-memory base.
- The remaining regions are three-to-five app descriptors (tag
  `60606263 46620160 90a26628` plus engine-ID lists), twelve trailers
  (recurring `9f35f43d 0149fe04 bf1c9990` blocks with per-blob size
  words), and the six islands.
- The islands carry 16-value bit-reversed index runs in their low halfword
  bytes (`5,9,3,d,7,b,f,0,4,8,2,c,6,a,1,e` and rotations) — permutation or
  twiddle tables. They also return zero hits from the code-shape detector,
  which lights up over 1.4 MB of the plaintext region and nothing else.
- The matcher self-test finds five planted artifacts in a 16 MiB synthetic
  dump with zero false code windows on random fill; on the image it
  recovers the fourteen descriptor signatures, four `0xf900` markers, and
  sixteen 128-byte ciphertext anchors, all at census offsets.

**Result.**

- **Answer:** the directory is five families, not sixty-six descriptors;
  the two `0xf900` blobs are the GR-falcon shape — different code, same
  layout, similar magnitude, which is what FECS and GPCCS should look
  like — and no plaintext engine code exists anywhere in the blob.
- **What we learned:**
  - The `RMForceNvdecUcodeEncryption` hint that per-ucode encryption is
    configured loses its only unencrypted candidate: the islands were that
    candidate, and they are tables.
  - The identical descriptor pairs are two falcon instances sharing one
    ucode — engine pairs like the decoder or encoder falcons — so they
    cannot be the GR pair, whose two falcons run different code.
  - The matcher's ciphertext anchors locate any blob's encrypted copy in a
    future dump with no address assumptions; they are the tool a new read
    primitive should be handed first.
- **Related:**
  - [The blob directory](#135-the-generic-header-blob-directory) is the
    record this census corrects.
  - [The transit record](#136-the-decrypted-ucode-transit-and-its-read-route)
    names these two blobs as the capture targets.
- **Open question:** which of the two `0xf900` blobs is FECS and which is
  GPCCS. Settling it needs either the ID-word mapping or the code itself.
