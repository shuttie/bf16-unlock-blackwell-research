# Firmware formats: containers, signatures, and the GSP-RM image

## At a glance

- **Scope.** The firmware images the host hands to the GPU: the FMC container,
  the signature envelope, `GspRmBoot`, the GSP-RM image, the inventory, and the
  FMC key search.
- **Bench.** Stock RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  two cards, unless the sentence says otherwise. Format facts checked against
  the linux-firmware sample say so.
- **Evidence.** Measured claims link to the experiment that established them.
  Claims from public headers or vendor documentation say so in the sentence. No
  firmware image or key is redistributed.

**The short version.**

- The FMC is a `0x48`-byte plaintext header plus an encrypted body; the body is
  code + data + a `0xA00` manifest, signed with P-384/SHA-384.
- `GspRmBoot` is a raw encrypted 290,816-byte blob with no plaintext header.
- The GSP-RM image is a libos container: a manifest at file `0x6cff00` lists
  ten modules, about 18.5 MB of plaintext (the RM ELF, six per-chip kernels,
  two helper ELFs), and a 53.8 MB encrypted `rm.bindata.bin` that carries the
  engine ucode
  ([the manifest](../experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)).
- The bindata blobs are AES-encrypted by SEC2 in High-Secure mode with
  per-blob derived keys; each blob keeps a plaintext load descriptor
  ([the secure-data unit](../experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)).
- The corpus keys are not device-bound and the bindata key is version-stable;
  duplicated ucode copies carry a per-copy 16-byte seed, so the corpus is not
  one key in ECB mode
  ([the crypto-model compare](../experiments/16_crypto-model-compare.md)).
- The FMC container is bound to the COT hash; a one-byte change draws `0x33`.
- The FMC encryption mode and key remain unknown. The published MD5-IV key
  family is exhausted on GB202 under the tested modes.

**In this spec.**

- [FMC container](#fmc-container)
  - [Header](#header)
  - [Body layout](#body-layout)
  - [Entropy and variant separation](#entropy-and-variant-separation)
  - [Host buffer and COT binding](#host-buffer-and-cot-binding)
  - [What the FMC consumes](#what-the-fmc-consumes)
- [Signature envelope](#signature-envelope)
- [GspRmBoot](#gsprmboot)
- [GSP-RM image](#gsp-rm-image)
  - [Container layout](#container-layout)
  - [Address model](#address-model)
  - [Signed-image boundary](#signed-image-boundary)
  - [Secure-data blobs](#secure-data-blobs)
  - [Module map](#module-map)
  - [FWSEC-LIC unit map](#fwseclic-unit-map)
- [Firmware inventory](#firmware-inventory)
- [FMC encryption and key search](#fmc-encryption-and-key-search)
  - [The four layers](#the-four-layers)
  - [The published test-key family](#the-published-test-key-family)
  - [Why the first-block magic filter was wrong](#why-the-first-block-magic-filter-was-wrong)
  - [What decryption buys](#what-decryption-buys)
- [What remains open](#what-remains-open)
- [Evidence map](#evidence-map)
- [Terms](#terms)

## FMC container

The FMC is the first-stage mutable firmware. It is host-supplied, signed, and
encrypted, and it runs in Heavy Secure. The production and debug variants share
a plaintext wrapper and differ in the encrypted body. See [the FMC container
format](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature).

### Header

The header is `0x48` bytes. All multi-byte fields are little-endian.

| Offset | Field | GB202 production | linux-firmware sample |
|---:|---|---:|---:|
| `0x00` | magic `03 04 48 00`; header size `0x48` | `0x48` | `0x48` |
| `0x04` | body size | `0x46200` | `0x30A00` |
| `0x0C` | code size | `0x37000` | `0x25800` |
| `0x14` | data size | `0xE800` | `0xA800` |
| `0x18` | flags / version | `0x104` | `0x104` |
| `0x20` | constant | `0x2801` | `0x2801` |

The first four dwords of the production header:

```text
03 04 48 00   00 62 04 00   00 00 00 00   00 70 03 00
```

Those are the magic/header size, body size `0x46200`, a reserved word, and code
size `0x37000`.

### Body layout

The body is exactly `code + data + 0xA00` bytes in all 14 samples. The order is:

```text
body[0 : codeSize]                    code
body[codeSize : codeSize+dataSize]    data
body[codeSize+dataSize : ]            manifest (0xA00)
```

```text
0x48  +----------------+----------------+----------------+
      | code  0x37000  | data   0xE800  | manifest 0xA00 |
      +----------------+----------------+----------------+
```

The three regions match the matching `GspRmBoot` image byte-for-byte: `code` is
a prefix of the bootloader's code, `data` matches
`GspRmBoot[0xA00 : 0xA00+dataSize]`, and the `0xA00` residue matches
`GspRmBoot[0 : 0xA00]`. The manifest is encrypted with the rest; there is no
plaintext tail beyond the `0x48` header. See [the FMC body
layout](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).

Because the same component encrypts identically at different absolute offsets in
the two images, there is no cross-component chaining. The mode is ECB or a
per-component reset (CBC or CTR with an IV/counter that restarts per component).
The first plaintext block of the body is code, not a container header.

### Entropy and variant separation

| Property | Measurement |
|---|---|
| Body entropy | 7.999 bits/byte in every sample |
| Repeated 16-byte ECB blocks | at most 1 per FMC image |
| Header nonce | none |
| Production vs debug body | 99.6% of bytes differ |
| Production/debug XOR | 1,154 zero bytes in 287,232 (chance rate) |
| Shared keystream | none |

Signing is not decryption. The debug signing key is public; the debug encryption
key is not in any package.

### Host buffer and COT binding

The host places the container in unprotected sysmem at the COT's FMC address.
Read-only samples after the copy-in, after the FSP response, and at memdesc
release are byte-identical to the stock container on both cards. The FSP neither
decrypts in place nor scrubs the buffer. See [the tampered
container](../experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered).

A one-byte change while the COT hash, signature, and key stay stock is refused
before boot:

| Change | FSP response | WPR2 | Release dump |
|---|---:|---|---|
| ciphertext body byte at `0x1048` | `0x33` | left up | unchanged |
| plaintext header magic at `0x00` | `0x33` | left up | unchanged |

`0x33` is distinct from the `0x377` hash failure. The order is: verify the
signature over the claimed hash, then bind the image bytes to that hash. The
binding covers the plaintext header as well as the encrypted body, so a
corrupted ciphertext byte never reaches the decrypted image.

### What the FMC consumes

After decryption the FMC is handed `GSP_FMC_BOOT_PARAMS` plus the COT. The host
fills registry keys, the GSP-RM image descriptor and address, the boot-args
pointer, SPDM parameters in confidential-compute mode, and the COT's addresses,
sizes, hash, key, and signature. Every one is a 64-bit address or a 32-bit
length consumed by code that runs before or after the hash/signature check. That
is the parser surface. The container bytes are not part of it: they are bound to
the COT hash.

## Signature envelope

The `0xF8` bytes before a signed container are:

```text
publickey[104] || signature[96] || hash[48] || container
```

| Field | Meaning |
|---|---|
| `publickey[104]` | Uncompressed P-384 point plus a 7-byte record tail |
| `signature[96]` | `r \|\| s`, 48 bytes each |
| `hash[48]` | SHA-384 over the entire container, header included |

The record tail is zero on the GB202 and GB100 containers and non-zero on the
other chips. An earlier reading split the record as a 97-byte key plus 7
padding bytes; the generated arrays fix the record at 104 bytes
([the container census](../experiments/16_crypto-model-compare.md#165-the-container-census-names-the-chips-and-the-keys)).

The encoding is ECDSA P-384 over SHA-384. Both shipped signatures verify with
OpenSSL:

```bash
openssl dgst -sha384 -verify pub.pem -signature sig.der container.bin
# Verified OK
```

Each chip signs with its own production and debug keys; GB202 and GB100 share
theirs. See [the signature
analysis](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature)
and [the census](../experiments/16_crypto-model-compare.md#165-the-container-census-names-the-chips-and-the-keys).

| Key | Signs |
|---|---|
| GB202 production | The production FMC and the linux-firmware FMC; also verifies the GB100 production container |
| GB202 debug | The debug FMC; also verifies the GB100 debug container |

The signature section of the GSP-RM image is separate. `.fwsignature_gb20x` is
`0x1000` bytes: a 20-byte header (`0x00020001`, size `0x8c8`, count `0x0c`,
`0x0101`, stride `0x200`), four 0x200 slots holding 0x180-byte records, and a
plaintext table at `0x814`. The FMC verifies slots 0 and 1; slots 2 and 3 are
inert on this boot path. The record size at `+0x10` must be in `[0x180, 0x200]`,
and the table tail at `0x87c` is a mode with the valid set `{1,2}`. It contains
no SHA-384 of `.fwimage`, no valid P-384 point at any `0x04` candidate, and no
block shared across the ten chip sections. The GSP-RM verification key is
therefore fused or inside the FMC, not supplied by the image. See [the COT key
anchor](../experiments/05_fmc-fsp-boot-inputs.md#0518-cot-public-key-anchored)
and [the section layout](../experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records).

## GspRmBoot

`GspRmBoot` is the bootloader image the host supplies alongside the FMC. It is a
raw encrypted blob, not an FMC-style container. See [the bootloader
description](../experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images).

| Property | Value |
|---|---|
| Size | 290,816 B (`0x47000`) |
| Format | raw encrypted image, no plaintext header |
| Entropy | 7.9835 bits/byte |
| Production vs debug | 98.4% of bytes differ |
| Production/debug XOR | 1,167 zero bytes in 290,816 (0.401%, chance rate) |
| Execution address | `0xefd00000` during boot |
| Authentication | one-byte ciphertext flip draws `0xaff` / info `0xb` |

The `WprMeta` bootloader geometry is: manifest at offset 0, data at `0xA00`, code
at `0xF200`, signature buffer `0x1000`. The host buffer is byte-identical before
the FMC reads it and after GSP-RM is up, so the FMC does not decrypt it in place
and does not scrub it. See [the bootloader
buffer](../experiments/05_fmc-fsp-boot-inputs.md#0524-bootloader-buffer-not-decrypted-in-place).

## GSP-RM image

The GSP-RM is the main GPU firmware. The 72,830,976-byte `.fwimage` is a libos
container, not one flat ELF: a plaintext manifest lists ten modules, about
18.5 MB of the file is plaintext code and data, and a 53.8 MB encrypted
`rm.bindata.bin` carries the engine ucode
([the manifest](../experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)).
The same image is shared across GA10x, AD10x, and GB20x; the kernel list
(`kernel_ga10x` through `kernel_gb20y`) selects per chip. The driver package
and the local image show this; see [the PL3 component
inventory](../experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package).

### Container layout

The manifest sits at file `0x6cff00`–`0x6d8xx`, and its offsets are counted
from a `0x6d000` base. Each entry names the module and lists its sections —
vaddr, file offset, alignment, size — matching the ELF program headers for
`rm.elf`. The modules pack contiguously, and every boundary below is verified
by an ELF magic or an entropy boundary at the computed offset
([the manifest](../experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)).

| Region (file) | Module | State |
|---|---|---|
| `0x0`–`0x6d000` | bootstrap | plaintext |
| `0x6e000`–`0x18f000` | six per-chip kernels (`kernel_ga10x.elf`, `kernel_gh100.elf`, `kernel_gb10x.elf`, `kernel_gb10y.elf`, `kernel_gb20x.elf`, `kernel_gb20y.elf`) | plaintext |
| `0x18f000`–`0x10fe000` | `rm.elf`: code, data, TLS | plaintext |
| `0x10fe000`–`0x11b9000` | `vgpu.elf` | plaintext |
| `0x11b9000`–`0x11c8000` | `mnoc.elf` | plaintext |
| `0x11c8000`–`0x4508000` | `rm.bindata.bin` (`0x33ad000` B) | encrypted |
| `0x4508000`–`0x4570000` | per-chip signature sections | opaque |

The 936 corpus "functions" above file offset `0x11d0000` are disassembler
artifacts over encrypted bytes; the decompiled corpus covers the plaintext
region and nothing else
([the plaintext boundary](../experiments/13_fwimage-map-and-bindata.md#132-the-plaintext-boundary)).

### Address model

```text
.fwimage file                 72,830,976 B
manifest                      file 0x6cff00, offsets from base 0x6d000
ELF64 at file offset          0x18F000
code                          ELF-relative 0x0, vaddr 0x01000000, filesz 0xDCD000, RX
data                          ELF-relative 0xDCD000, vaddr 0x04000000, filesz 0x1A1000, RW
TLS                           ELF-relative 0xF6E000, vaddr 0x20393000, memsz 0x1000
entry                         0x01A0F3DA
loaded at core address        0x01000000
runtime VA                    link VA + 0x92000000
Ghidra VA                     link VA + 0x18F000
```

File offsets come from the program headers (ELF base plus the
ELF-relative offset), not from a link-VA subtraction. The earlier
`file offset = link VA − 0x00E71000` relation holds only inside the code
segment, where the ELF-relative offset is zero; it is wrong for the data
segment and for every other module. The manifest offsets above are the
authoritative cross-check
([the manifest](../experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)).

The loaded image is not identity-mapped at host framebuffer physical address
`0x01000000`; that address reads zero. The backing is in the write-protected
region. A Ghidra address is a file address, not a runtime address. See [the live
ICD read window](../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port).

### Signed-image boundary

A single-instruction patch is rejected before the image runs:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
```

A four-byte change at the entry of the FEAT readout decoder is enough. The
per-chip signature section carries no host key, so there is no key-substitution
target in the image. See [the patched-image
test](../experiments/05_fmc-fsp-boot-inputs.md#052-patched-gsp-rm-image-rejected-by-the-fmc).

### Secure-data blobs

`rm.bindata.bin` carries the engine ucode. It is a sequence of secure-data
blobs — there is no central directory — and each blob is a plaintext generic
header plus an AES-encrypted body. The format is named by its error strings,
and the decryption runs on SEC2: the RM-side firmware-security unit validates
the image and hands each blob over, SEC2 derives the per-blob key and runs
AES-ECB in High-Secure mode, and the RM never holds the key
([the secure-data unit](../experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)).

The generic header holds:

| Field | Meaning |
|---|---|
| ID words | per-blob identity; e.g. `0x49`, `0x6d` on two twin headers |
| `0xff` magic | record separator |
| `{flag, start, end}` records | falcon load descriptors: where the decrypted body lands in engine memory |

Sixty-six headers survive a structured-window scan of the blob; one at
bindata offset `0x30aed40` maps a `0x400`-byte data segment and a
`0xbe00`-byte code image loaded at `0xf900` — a falcon ucode load map
([the blob directory](../experiments/13_fwimage-map-and-bindata.md#135-the-generic-header-blob-directory)).
The ID words have no public mapping, so blob-to-engine assignment is open.
The headers, and one structured block at `0x3cbc000`, are the known-plaintext
surface for any future key search
([the encryption](../experiments/13_fwimage-map-and-bindata.md#133-bindata-is-encrypted-not-compressed)).

### Module map

The local static split has 69 module files. Function counts are for navigation,
not ground truth.

| Module | Functions | Notes |
|---|---:|---|
| registry | 534 | registry parser |
| platform | 434 | GeForce / Quadro / self-hosted |
| gr_fecs | 984 | FECS/GPCCS/context-switch interfaces |
| sec2_acr | 22 | SEC2/ACR/FWSEC interfaces |
| pmu_devinit | 10 | PMU/devinit strings |
| fsp_fmc | 7 | FSP/FMC strings |
| memory_wpr | 25 | WPR/FBPA |
| display | 482 | display registry keys and code |
| pcie_bif | 9 | BIF/LTR/PCIe strings |
| logging_debug | 600 | NVRM/assert/dump |
| libos | 1,539 | kernel/task/rootfs/memory pool |
| crypto | 454 | AES/RNG/PKA/CCC |
| inforom | 158 | inforom |
| rm_core | 3,044 | generic RM core |
| feat_rate | 0 | no FEAT/SS access in the binary |

The decoder is `FUN_ram_015ffae8`; it reads fuse HAL offset `0x3818` and fills the
getter's nine bytes. A second implementation, `FUN_ram_015ff1dc`, is selected for
descriptor variants `{5…9}` and reads `0x9668` instead. `FUN_ram_01615a40`
extracts the DP byte from `FEAT_READOUT_1[30:28]`. The per-chip HAL initializer
`FUN_ram_01c1c374` installs the decoder at `obj+0xC20` and the context functions
at `obj+0xD00`. The decoder is table-installed code, not dead code. See [the
decoder audit](../experiments/07_plaintext-corpus.md#078-the-decoder-is-installed-by-the-hal).

The reference audit is a useful trap: a scan that only looks for literal
addresses misses the negative 20-bit `auipc` immediate. Five materializations sit
inside the initializer. Absence of a literal is not evidence of dead code.

### FWSEC-LIC unit map

The certificate-vocabulary strings belong to a three-part unit. The head
(`0x0130ca64`–`0x0130f78c`, 93 small functions) decodes error codes through a
relative-offset switch and logs them; the middle
(`0x0130f78c`–`0x0134bc74`, about 200 functions) is a descriptor-driven loader
with version-gated stride tables and a `0x930`-byte staging object; the tail
(`0x0134bc74`–`0x01351000`) is a shared RM log-thunk pool holding one 34-byte
report unit per error string, every unit tail-jumping into the RM-task log
writer. The unit takes 153 direct-call entries from the surrounding RM and
carries no certificate parsing, no FEAT-family register constant in any
immediate form, and no DEVID list; the reader, `3AES` verify, and SEC2 opcode
interpreter the error strings name live in encrypted code. See [the handler
resolution](../experiments/26_fwseclic-handler-resolution.md).

## Firmware inventory

| Artifact | Size | Format / measurement |
|---|---:|---|
| GSP-RM image | 72,830,976 B | libos container: manifest at `0x6cff00`, ten modules, ~18.5 MB plaintext |
| `rm.bindata.bin` | 54,185,984 B | inside the GSP-RM image at file `0x11c8000`; 66 secure-data blobs, AES-encrypted bodies with plaintext load descriptors |
| FMC bootloader (linux-firmware) | 200,812 B | `0x10de` container, version 1; entropy 7.990 |
| FMC image (linux-firmware) | 199,820 B | ELF32; body `0x30A00` = `0x25800` + `0xA800` + `0xA00`; entropy 7.999; signature verifies |
| GspRmBoot production | 290,816 B | raw encrypted, no plaintext header, entropy 7.999 |
| GspRmBoot debug | 290,816 B | 98.4% different, entropy 7.999 |
| FMC production `c04` | 287,304 B | `0x48` header; body `0x46200`; P-384/SHA-384 verify |
| FMC debug `c09` | 287,304 B | 99.6% body difference; debug key |
| FMC debug GB20B | 212,296 B | 384-byte signature and public key |
| Concatenated FMC | 478,454 B | entropy 8.000 |
| SEC2 booter TU102 | 303 B | Turing only |
| SEC2 secure scrub AD10X | 6,233 B | Ada only |
| Board vBIOS | 819,200 B dumped of >= 876,544 B | encrypted microcode; no FWSEC entries |
| PROM head blob | 218 KiB | encrypted; plaintext board metadata follows |
| FSP / GSP BootROM | n/a | no image in any package; immutable ROM |

The FSP and BootROM never appear in a driver package or firmware bundle. The
obtainable images are the board vBIOS, the encrypted FMC, the encrypted
`GspRmBoot`, and the plaintext GSP-RM. See [the PL3 component
inventory](../experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package).

## FMC encryption and key search

### The four layers

| Layer | What it is | Crypto | Key | Recoverable |
|---|---|---|---|---|
| FSP | RISC-V security processor, immutable ROM | ROM-resident, no host image | fused / hardware | no corpus |
| GSP BootROM | immutable ROM | ROM | fused | no |
| FMC | host-loaded HS bootloader; `0x48` header + encrypted body; ECDSA P-384/SHA-384 | mode unknown: no ECB repeats, no nonce, entropy 7.999 | debug key for the debug FMC; production likely `csecret(6)` in SCP | only software target |
| SEC2 booter | HS booter; GA100/GA102/AD102 debug images | AES-128-ECB | test key #37 (MD5-IV permutation) | yes on those parts; negative on GB202 |
| GSP-RM | post-boot RISC-V firmware | plaintext | n/a | available |

The FSP and BootROM rows come from public documentation; the FMC and SEC2 rows
come from the local images. The production `csecret(6)` is held in SCP hardware
and is not software-recoverable. The debug FMC is the only software-key target.

### The published test-key family

The older SEC2 debug booters use AES-128-ECB with test key #37, a permutation of
the 16 MD5 initialization-vector bytes. The public known-answer test is:

```text
AES-ECB(key37, 00 * 16) = 717d1494eaca317ff106195258b38377
```

The full permutation space is `16! = 20,922,789,888,000` keys. See [the GA100
key test](../experiments/07_plaintext-corpus.md#075-the-ga100-test-key-does-not-fit).

On GB202 the family does not reproduce. The corrected exhaustive passes:

| Pass | Coverage | Time (GPU 0 / GPU 1) | Result |
|---|---|---|---|
| zero-block KAT | all 16! | 442.5 / 440.2 s | no match |
| FF-block KAT | all 16! | 443.2 / 440.9 s | no match |
| last-round-key transform | all 16! | 555.4 / 553.3 s | no match |
| FMC `c09`, five modes | all 16! | 1,902 s | 0 valid |
| FMC `c11`, five modes | all 16! | 1,907 s | 0 valid |

The FMC passes test five hypotheses per key: ECB (mode 0), CBC with a zero IV
(1), CBC with the container header as IV (3), CTR start 0 (2), and CTR start 1
(4). Three chance records were written across both containers; the full-code
RISC-V verifier rejected all three at 8.6–8.9% invalid instructions, the random
rate. See [the FMC key
search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).

The debug GB202 (`c09`) and `0x30500` (`c11`) FMCs are not decrypted by any
MD5-IV permutation under ECB, per-component CBC with a zero or header IV, or CTR
with counter start 0 or 1. The IV-permutation avenue is exhausted for the FMC
under the tested modes.

### Why the first-block magic filter was wrong

The body starts with code. The earlier FMC oracle accepted a candidate only if
its first decrypted block looked like a container or compression header. A
correct key whose first block is real RISC-V code would have been discarded. The
replacement oracle scores 16-bit parcels against a log-probability table trained
on the plaintext GSP-RM code segment:

- 7,233,536 parcels, entropy 11.588 bits/parcel.
- Stage 1: one block, threshold `t1 = -256`.
- Stage 2: eight blocks for survivors, threshold `t2 = -2102`.
- Exact-DP staged false-positive rate: `1.2e-14` per hypothesis.
- Rate: 8.5 G keys/s per 5090 with Stage 2; 6.0 G keys/s with all five modes.
- Controls: the rank-0 synthetic key is recovered in every mode; random
  plaintext is rejected; the full-code walk accepts the synthetic at 0.046%
  invalid and rejects a random key at 8.8%.

See [the FMC key
search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).

### What decryption buys

The FMC is the PL3 bootloader that parses the COT and `WprMeta` and loads the
GSP-RM. Its code is the static PL3 corpus: parsers, copy routines, and gadgets.
Production and debug code are identical, so the debug FMC is enough for static
analysis. It does not give execution on a retail card, which still needs debug
fuse state, and it does not give the production key.

No key was recovered. Do not read the negative searches as a partial key or a
pending release.

## What remains open

- The FMC encryption mode and key remain unknown. The negative results cover the
  MD5-IV permutation family under the tested modes, not every AES mode or key
  source.
- The FMC and GspRmBoot keys stay untestable by comparison: every driver
  version rebuilds both, so no cross-version ciphertext reuse exists
  ([the shared-ciphertext check](../experiments/16_crypto-model-compare.md#164-the-fmc-and-gsprmboot-share-ciphertext-in-every-version)).
- The GSP-RM module map comes from local decompilation; this spec publishes maps
  and short excerpts, not bulk decompiled code.
- No firmware image, container, or key is included in this repo.
- The FSP and GSP BootROM have no obtainable image; their behavior is inferred
  from the boot protocol and the host-side error codes.

## Evidence map

| Fact | Experiment |
|---|---|
| FMC header, body algebra, component identity | [07.4 FMC container](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature), [07.10 FMC body](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative) |
| Container/COT binding, tamper response | [05.19 tampered container](../experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered) |
| Signature envelope and keys | [07.4 FMC container](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature), [05.18 key anchor](../experiments/05_fmc-fsp-boot-inputs.md#0518-cot-public-key-anchored) |
| GspRmBoot size, entropy, authentication | [04.5 boot-window gate](../experiments/04_hs-sec2-fsp-memory.md#045-boot-window-icd-route-is-blocked), [05.23 bootloader description](../experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images), [05.24 bootloader buffer](../experiments/05_fmc-fsp-boot-inputs.md#0524-bootloader-buffer-not-decrypted-in-place) |
| GSP-RM address model | [04.4 live ICD window](../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port) |
| Patched-image rejection | [05.2 patched image](../experiments/05_fmc-fsp-boot-inputs.md#052-patched-gsp-rm-image-rejected-by-the-fmc) |
| Module map and decoder | [07.8 decoder audit](../experiments/07_plaintext-corpus.md#078-the-decoder-is-installed-by-the-hal) |
| Test-key family and FMC search | [07.5 GA100 key test](../experiments/07_plaintext-corpus.md#075-the-ga100-test-key-does-not-fit), [07.10 FMC key search](../experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative) |
| Key binding, per-copy seeds, version stability | [16.1 card-independent vBIOS](../experiments/16_crypto-model-compare.md#161-the-encrypted-vbios-is-card-independent), [16.2 version-stable bindata](../experiments/16_crypto-model-compare.md#162-the-bindata-key-is-version-stable), [16.3 per-copy seed](../experiments/16_crypto-model-compare.md#163-duplicated-ucode-diverge-at-a-per-copy-seed) |
| Inventory and availability | [07.1 PL3 components](../experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package), [07.4 FMC container](../experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature), [16.6 615 corpus](../experiments/16_crypto-model-compare.md#166-the-615-corpus-splits-and-resigns-the-fmc) |

Related specs: [boot chain](01_boot-chain.md), [register map](03_register-map.md).
Extraction and search tools: [FMC tools](../tools/fmc-tools/),
[GSP-RM tools](../tools/gsp-rm-tools/), [crypto compare](../tools/crypto-compare/).

## Terms

| Term | Meaning |
|---|---|
| FSP | Security processor that runs first out of reset, from immutable ROM |
| FMC | First-stage mutable GPU firmware; host-supplied, signed, encrypted; runs at PL3 |
| GSP-RM | Main GPU firmware; host-supplied, signed, plaintext; runs at PL2 |
| `GspRmBoot` | Bootloader image supplied alongside the FMC |
| COT | Chain-of-trust message from the host to the FSP |
| `.fwimage` | Plaintext code and data image inside the GSP-RM ELF |
| HS | Heavy Secure, the PL3 privilege level |
| SCP | Secure coprocessor that holds the production `csecret(6)` |
| WPR2 | Second write-protected region; armed before COT authentication |
| ELF | Executable and linkable format |
| P-384 / SHA-384 | Elliptic curve and hash used by the COT and FMC signatures |
| ECDSA | Elliptic Curve Digital Signature Algorithm |
| AES | Advanced Encryption Standard |
| ECB / CBC / CTR | Block-cipher modes tested on the FMC body |
