# Firmware formats

This spec covers the firmware images the host hands to the GPU, their layouts,
signatures, and the encrypted FMC. It is the reference layer for the boot-chain
and plaintext-corpus experiments. Tags: `[measured]` on the two cards,
`[source]` from public headers or vendor documentation, `[analogy]` carried over
from Ampere/Ada. Unmarked statements are measured.

The images themselves are not redistributed. Every fact below is either inlined
or linked to the experiment that produced it.

## 1. FMC container

The FMC is the first-stage mutable firmware. It is host-supplied, signed, and
encrypted, and it runs in Heavy Secure. The production and debug variants share a
plaintext wrapper and differ in the encrypted body. `[measured]`

### 1.1 Header

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

### 1.2 Body layout

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

The three regions match the matching `GspRmBoot` image byte-for-byte:
`code` is a prefix of the bootloader's code, `data` matches
`GspRmBoot[0xA00 : 0xA00+dataSize]`, and the `0xA00` residue matches
`GspRmBoot[0 : 0xA00]`. The manifest is encrypted with the rest; there is no
plaintext tail beyond the `0x48` header. `[measured]`

Because the same component encrypts identically at different absolute offsets in
the two images, there is no cross-component chaining. The mode is ECB or a
per-component reset (CBC or CTR with an IV/counter that restarts per component).
The first plaintext block of the body is code, not a container header. `[measured]`

### 1.3 Entropy and variant separation

| Property | Measurement |
|---|---|
| Body entropy | 7.999 bits/byte in every sample |
| Repeated 16-byte ECB blocks | at most 1 per FMC image |
| Header nonce | none |
| Production vs debug body | 99.6% of bytes differ |
| Production/debug XOR | 1,154 zero bytes in 287,232 (chance rate) |
| Shared keystream | none |

Signing is not decryption. The debug signing key is public; the debug encryption
key is not in any package. `[measured]`

### 1.4 Host-supplied buffer and COT binding

The host places the container in unprotected sysmem at the COT's FMC address.
Read-only samples after the copy-in, after the FSP response, and at memdesc
release are byte-identical to the stock container on both cards. The FSP neither
decrypts in place nor scrubs the buffer. `[measured]`

A one-byte change while the COT hash, signature, and key stay stock is refused
before boot:

| Change | FSP response | WPR2 | Release dump |
|---|---:|---|---|
| ciphertext body byte at `0x1048` | `0x33` | left up | unchanged |
| plaintext header magic at `0x00` | `0x33` | left up | unchanged |

`0x33` is distinct from the `0x377` hash failure. The order is: verify the
signature over the claimed hash, then bind the image bytes to that hash. The
binding covers the plaintext header as well as the encrypted body, so a corrupted
ciphertext byte never reaches the decrypted image. `[measured]`

### 1.5 What the FMC consumes from the host

After decryption the FMC is handed `GSP_FMC_BOOT_PARAMS` plus the COT. The host
fills registry keys, the GSP-RM image descriptor and address, the boot-args
pointer, SPDM parameters in confidential-compute mode, and the COT's addresses,
sizes, hash, key, and signature. Every one is a 64-bit address or a 32-bit
length consumed by code that runs before or after the hash/signature check.
That is the parser surface. The container bytes are not part of it: they are
bound to the COT hash. `[measured]`

## 2. Signature envelope

The `0xF8` bytes before a signed container are:

```text
publickey[97] || pad[7] || signature[96] || hash[48] || container
```

| Field | Meaning |
|---|---|
| `publickey[97]` | Uncompressed P-384 point |
| `pad[7]` | Alignment |
| `signature[96]` | `r || s`, 48 bytes each |
| `hash[48]` | SHA-384 over the entire container, header included |

The encoding is ECDSA P-384 over SHA-384. Both signatures verify with OpenSSL:

```bash
openssl dgst -sha384 -verify pub.pem -signature sig.der container.bin
# Verified OK
```

Two keys ship in the retail package: `[measured]`

| Key | First bytes | Signs |
|---|---|---|
| Production | `04 8b f1 18 bb …` | 4 containers, including the production FMC and the linux-firmware FMC |
| Debug | `04 d3 0b d5 4b …` | 2 containers, including the debug FMC |

The signature section of the GSP-RM image is separate. `.fwsignature_gb20x` is
`0x1000` bytes: a 20-byte header (`0x00020001`, size `0x8c8`, count `0x0c`,
`0x0101`, stride `0x200`) followed by four 384-byte high-entropy blocks on a
`0x200` stride. It contains no SHA-384 of `.fwimage`, no valid P-384 point at any
`0x04` candidate, and no block shared across the ten chip sections. The GSP-RM
verification key is therefore fused or inside the FMC, not supplied by the image.
`[measured]`

## 3. GspRmBoot

`GspRmBoot` is the bootloader image the host supplies alongside the FMC. It is a
raw encrypted blob, not an FMC-style container. `[measured]`

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
and does not scrub it. `[measured]`

## 4. GSP-RM image

The GSP-RM is the main GPU firmware. It is a 72,830,976-byte RISC-V ELF with a
large plaintext `.fwimage` and per-chip signature sections. The same image is
shared across GA10x, AD10x, and GB20x; Blackwell behavior is selected by chip
tables inside the image. `[source]` `[measured]`

### 4.1 Address model

```text
.fwimage file                 72,830,976 B
wrapper before the loaded ELF 0x18F000 B
ELF64 at file offset          0x18F000
code                          vaddr 0x01000000, filesz 0xDCD000, RX
data                          vaddr 0x04000000, filesz 0x1A1000, RW
entry                         0x01A0F3DA
loaded at core address        0x01000000
runtime VA                    link VA + 0x92000000
file offset                   link VA - 0x00E71000
Ghidra VA                     link VA + 0x18F000
```

The loaded image is not identity-mapped at host framebuffer physical address
`0x01000000`; that address reads zero. The backing is in the write-protected
region. A Ghidra address is a file address, not a runtime address. `[measured]`

### 4.2 Signed-image boundary

A single-instruction patch is rejected before the image runs:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0xaff, additional info=0xb
```

A four-byte change at the entry of the FEAT readout decoder is enough. The
per-chip signature section carries no host key, so there is no key-substitution
target in the image. `[measured]`

### 4.3 Module map

The local static split has 69 module files. Function counts are for navigation,
not ground truth. `[source]`

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
at `obj+0xD00`. The decoder is table-installed code, not dead code. `[measured]`

The reference audit is a useful trap: a scan that only looks for literal
addresses misses the negative 20-bit `auipc` immediate. Five materializations sit
inside the initializer. Absence of a literal is not evidence of dead code.
`[measured]`

## 5. Firmware inventory

| Artifact | Size | Format / measurement |
|---|---:|---|
| GSP-RM image | 72,830,976 B | RISC-V ELF, base `0x01000000`; `.fwimage` plaintext |
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
| FSP / GSP BootROM | — | no image in any package; immutable ROM |

The FSP and BootROM never appear in a driver package or firmware bundle. The
obtainable images are the board vBIOS, the encrypted FMC, the encrypted
GspRmBoot, and the plaintext GSP-RM. `[measured]`

## 6. FMC encryption and key search

### 6.1 The four layers

| Layer | What it is | Crypto | Key | Recoverable |
|---|---|---|---|---|
| FSP | RISC-V security processor, immutable ROM | ROM-resident, no host image | fused / hardware | no corpus |
| GSP BootROM | immutable ROM | ROM | fused | no |
| FMC | host-loaded HS bootloader; `0x48` header + encrypted body; ECDSA P-384/SHA-384 | mode unknown: no ECB repeats, no nonce, entropy 7.999 | debug key for the debug FMC; production likely `csecret(6)` in SCP | only software target |
| SEC2 booter | HS booter; GA100/GA102/AD102 debug images | AES-128-ECB | test key #37 (MD5-IV permutation) | yes on those parts; negative on GB202 |
| GSP-RM | post-boot RISC-V firmware | plaintext | — | available |

The production `csecret(6)` is held in SCP hardware and is not
software-recoverable. The debug FMC is the only software-key target. `[source]`

### 6.2 The published test-key family

The older SEC2 debug booters use AES-128-ECB with test key #37, a permutation of
the 16 MD5 initialization-vector bytes. The public known-answer test is:

```text
AES-ECB(key37, 00 * 16) = 717d1494eaca317ff106195258b38377
```

The full permutation space is `16! = 20,922,789,888,000` keys. `[source]`

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
rate. `[measured]`

The debug GB202 (`c09`) and `0x30500` (`c11`) FMCs are not decrypted by any
MD5-IV permutation under ECB, per-component CBC with a zero or header IV, or CTR
with counter start 0 or 1. The IV-permutation avenue is exhausted for the FMC
under the tested modes. `[measured]`

### 6.3 Why the first-block magic filter was wrong

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
  invalid and rejects a random key at 8.8%. `[measured]`

### 6.4 What decryption buys

The FMC is the PL3 bootloader that parses the COT and `WprMeta` and loads the
GSP-RM. Its code is the static PL3 corpus: parsers, copy routines, and gadgets.
Production and debug code are identical, so the debug FMC is enough for static
analysis. It does not give execution on a retail card, which still needs debug
fuse state, and it does not give the production key. `[measured]`

No key was recovered. Do not read the negative searches as a partial key or a
pending release.

## 7. Limits

- The FMC encryption mode and key remain unknown. The negative results cover the
  MD5-IV permutation family under the tested modes, not every AES mode or key
  source.
- The GSP-RM module map comes from local decompilation; this spec publishes maps
  and short excerpts, not bulk decompiled code.
- No firmware image, container, or key is included in this repo.
- The FSP and GSP BootROM have no obtainable image; their behavior is inferred
  from the boot protocol and the host-side error codes.

## 8. Evidence map

| Fact | Experiment |
|---|---|
| FMC header, body algebra, component identity | [E05](../experiments/07_plaintext-corpus.md), [E73](../experiments/07_plaintext-corpus.md) |
| Container/COT binding, tamper response | [E62](../experiments/05_fmc-fsp-boot-inputs.md) |
| Signature envelope and keys | [E05](../experiments/07_plaintext-corpus.md), [E61](../experiments/05_fmc-fsp-boot-inputs.md) |
| GspRmBoot size, entropy, authentication | [E68](../experiments/04_hs-sec2-fsp-memory.md), [E69](../experiments/05_fmc-fsp-boot-inputs.md), [E72](../experiments/05_fmc-fsp-boot-inputs.md) |
| GSP-RM address model | [E67](../experiments/04_hs-sec2-fsp-memory.md) |
| Patched-image rejection | [E15](../experiments/05_fmc-fsp-boot-inputs.md) |
| Module map and decoder | [E17](../experiments/07_plaintext-corpus.md) |
| Test-key family and FMC search | [E06](../experiments/07_plaintext-corpus.md), [E73](../experiments/07_plaintext-corpus.md) |
| Inventory and availability | [E02](../experiments/07_plaintext-corpus.md), [E05](../experiments/07_plaintext-corpus.md) |

Related specs: [boot chain](../specs/01_boot-chain.md), [register map](../specs/03_register-map.md).
Extraction and search tools: [FMC tools](../tools/fmc-tools/),
[GSP-RM tools](../tools/gsp-rm-tools/).
