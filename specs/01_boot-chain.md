# Boot chain

Scope: reset through the FSP, GSP BootROM, FMC, and GSP-RM, the host-built boot
inputs, and the suspend/resume path. Values are stock on the RTX 5090 (GB202,
`10de:2b85`) with driver and GSP-RM 595.91.07 unless marked. `[measured]` means
observed on the two local cards; `[source]` means public documentation or headers;
`[analogy]` means carried over from Ada/Ampere.

## Boot order

```
FSP (immutable ROM, PL3)
  -> GSP BootROM (ROM, PL3)
    -> FMC (host-supplied, signed, encrypted, PL3)
      -> GSP-RM (host-supplied, signed, plaintext, PL2)
        -> host driver / CUDA
```

| Stage | Origin | Privilege | Role | Code obtainable |
|---|---|---|---|---|
| FSP | Immutable ROM | PL3 / Heavy Secure | Runs first; hardware root of trust | No |
| GSP BootROM | Immutable ROM | PL3 / Heavy Secure | Verifies and starts the FMC | No |
| FMC | Host-supplied, signed, encrypted | PL3 / Heavy Secure | Parses COT and `WprMeta`; loads GSP-RM | Encrypted |
| GSP-RM | Host-supplied, signed, plaintext | PL2 / Light Secure | Main GPU firmware | Yes |

[source] The order comes from the public kernel documentation; an August 2026
correction moved the FMC ahead of GSP-RM. [measured] The component inventory and
the absence of a GB20x SEC2 booter are in [E02 and
E03](../experiments/07_plaintext-corpus.md).

Blackwell has no SEC2 booter image for GB20x; the FMC is the only mutable PL3 image.

## What the host sends

Three host-built structures reach secure firmware: the COT, `WprMeta`, and
`SRMeta`. All are ordinary sysmem or vidmem structures; the host encrypts none.

### COT v2

| Field | Value |
|---|---|
| Version / size | 2 / `0x35c` |
| FMC image address | Sysmem pointer, varies per boot |
| FRTS region | Vidmem offset and size; stock offset `0x1b40000`, size `0x100000` |
| GSP boot args | Sysmem pointer |
| Hash | SHA-384, 48 bytes |
| Public key | P-384 uncompressed point, 97 bytes |
| Signature | Concatenated `r` and `s`, 96 bytes |
| Stock FMC | `GspRmFmcGfwProdSigned_GB202` container `c04`, 287,304 bytes |

[measured] The stock baseline, the `c04` match, and the per-boot addresses are in
[E28](../experiments/05_fmc-fsp-boot-inputs.md). The COT hash first bytes are
`ee0988fe a62832c4 b2fe90d8 7e2f6104`; the public key begins `18f18b04`.

**FRTS size is exact.** `frtsVidmemSize` must be `0x100000`. Half the size
(`0x80000`) and double the size (`0x200000`) are both refused with `0xd9`, at
every placement the driver tries. A clean retry with the stock size boots, so the
code belongs to the value. [measured: [E29–E30](../experiments/05_fmc-fsp-boot-inputs.md)]

**Offset is from the end of FB.** The field is not an absolute address; it is an
offset from the end of framebuffer, aligned to 128 KiB. The FSP rejects rather
than rounds.

| COT offset | Meaning | Result |
|---|---|---|
| `0x1b40000` | 27.25 MiB from FB end, stock | Accepted |
| `0x10520000` | 261.1 MiB from FB end | Accepted |
| `0x10500000` | 261.0 MiB from FB end | Accepted |
| `0x40000000` | 1 GiB from FB end | Accepted |
| `0x10520001` | One byte off | `0xd6` |

[measured: [E31–E35](../experiments/05_fmc-fsp-boot-inputs.md)]

**Placement selects the whole WPR base.** The COT offset moves the firmware ELF,
boot image, WPR heap, non-WPR heap, and FRTS together:

```
GSP_frts    = FB_end - COT_offset - 0xA200000
nonWprHeap  = GSP_frts - span
span        = 0xCFE0000 + (gspFwHeapSize - 0x8700000)
```

The fixed gap is 162 MiB. At a 1 GiB COT base the model predicts
`frts = 0x7b5e00000` and `nonWprHeap = 0x7a8e20000`, and the measurement matches.
The tested window is at least 1 GiB; only exact size and 128 KiB alignment are
enforced. [measured: [E34–E35](../experiments/05_fmc-fsp-boot-inputs.md)]

**Hash and key are authenticated.** A one-bit flip in `hash384[0]` draws `0x377`.
A self-signed P-384 pair over the correct hash draws `0x1db`, before the
hash/signature check. Both leave WPR2 armed, so the next attempt reports
`unexpected WPR2 already up` and the machine needs a reboot. Pre-auth field
checks (`0xd9`, `0xd6`, `0x827`, `0x82e`, `0x885`) recover cleanly. [measured:
[E41](../experiments/05_fmc-fsp-boot-inputs.md),
[E61](../experiments/05_fmc-fsp-boot-inputs.md)]

### WprMeta

`WprMeta` is 256 bytes, host-filled, and read by the FMC from sysmem.

| Field | Stock | Behavior |
|---|---|---|
| `magic` | `0xdc3aae21371a60b3` | Wrong value draws `0x827` |
| `revision` | 1 | Not varied |
| `verified` | 0 | Accepted at boot; does not bypass image authentication |
| `fbSize` | 0 | Untested |
| `frtsSize` | `0x100000` | Disagreement with the COT is ignored; the COT value wins |
| `gspFwHeapSize` | `0x8700000` | Honored; grows the WPR downward |
| `nonWprHeapSize` | 0 | Untested |
| `sizeOfBootloader` | `0x47000` | `0x47001` draws `0x82e` |
| `bootloaderCodeOffset` | `0xf200` | A wild value still boots; unused on this path |
| `bootloaderDataOffset` | `0xa00` | A wild value still boots; unused on this path |
| `bootloaderManifestOffset` | 0 | A wild value draws `0x885` |
| `sizeOfSignature` | `0x1000` | `0x100000` still boots; the verifier uses a fixed `0x1000` parse |
| `sizeOfRadix3Elf` | 72,830,976 | `0x100000` draws `0xaff`, additional info `0xb` |

[measured: [E36–E40](../experiments/05_fmc-fsp-boot-inputs.md),
[E69](../experiments/05_fmc-fsp-boot-inputs.md)]

**Heap size is a second layout lever.** Raising `gspFwHeapSize` from
`0x8700000` (135 MiB) to `0x10000000` (256 MiB) boot moves the non-WPR heap down
by exactly `0x7900000`, while FRTS stays anchored to the COT base. Shrinking to
`0x1000000` (16 MiB) is accepted, applies the layout, and then wedges GSP-RM with
`NV_ERR_TIMEOUT` (`0x65`) after about 2.7 million retries. The FMC does not
sanity-check the heap against GSP-RM's needs. [measured: [E38–E39](../experiments/05_fmc-fsp-boot-inputs.md)]

**Both boot images are authenticated.** The bootloader image is a raw
290,816-byte (`0x47000`) blob in the driver bindata. Stock geometry: manifest at
0, data at `0xa00`, code at `0xf200`, signature buffer `0x1000`. A one-byte
ciphertext flip in the bootloader or a patched GSP-RM ELF draws `0xaff`,
additional info `0xb`; the untampered second card boots normally. [measured:
[E15](../experiments/05_fmc-fsp-boot-inputs.md),
[E69](../experiments/05_fmc-fsp-boot-inputs.md)]

## Suspend/resume

A device-level cycle (`pm_test=devices`, then `mem`) completes in about 8 seconds
without a power cycle. On resume the boot uses `bootMode=1`, and the FMC is handed
`GspFwSRMeta` instead of `WprMeta`:

```c
typedef struct {
    NvU64 magic;                          // 0x8a3bb9e6c6c39d93
    NvU64 revision;                       // 2
    NvU64 sysmemAddrOfSuspendResumeData;  // radix3 page table
    NvU64 sizeOfSuspendResumeData;
    NvU32 internal[32];                   // zero
    NvU32 flags;                          // 0
    NvU32 subrevision;
    NvU32 padding[22];
} GspFwSRMeta;
```

The radix3 is built by the host in unprotected sysmem. The state size is
`frtsOffset + frtsSize - (nonWprHeapOffset + nonWprHeapSize)` = `0xcde0000` =
215,875,584 bytes = 205.875 MiB. The earlier 231.875 MiB figure was a unit error;
the 97/205 chunk count agrees with 205.875 MiB. [measured:
[E42](../experiments/06_sr-resume.md)]

| State property | Value |
|---|---|
| Zero 1 MiB chunks | 97 / 205, same mask on both cards |
| Nonzero spans | 0–7, 11–17, 112–204 MiB |
| Entropy, nonzero chunks | 7.9998 bits/byte |
| Headers or vendor strings | None |
| Bytes equal between cards outside zero chunks | 2,258,261 of about 108 MiB |
| FEAT or selector constants | 0 |

[measured: [E45](../experiments/06_sr-resume.md)]

The radix3 itself is plaintext and fully mapped:

| Level | Content |
|---|---|
| Root | One page, `root[0]` points to L1 at `+0x1000` |
| L1 | One page, `L1[0..102]` points to 103 L2 pages |
| L2 | 103 pages holding 52,704 nonzero, unique, 4K-aligned PTEs in 52,736 slots |

The data pages sit in 52 physical runs, mostly 1,024 pages (4 MiB). The ciphertext
is per-boot and per-card: zero of 27,322 nonzero pages match across boots, and
zero of 27,427 match across cards. [measured:
[E46](../experiments/06_sr-resume.md)]

A bad `SRMeta.magic` hangs the resume. The previous boot's log ends at
`Filesystems sync`, because journald freezes before post-freeze printk can flush;
a failed resume leaves no host-visible log. Use a netconsole or phase markers
(files written at prepare, save, resume-start, and restore-done) before probing
the structure. [measured: [E43](../experiments/06_sr-resume.md)]

The resume boot reuses the cold-boot COT and the already-mapped GSP-RM image; it
does not re-read the firmware file. Only the restored state can change what runs.
[measured: [E61](../experiments/05_fmc-fsp-boot-inputs.md)]

## FMC container

The FMC is a `0x48`-byte plaintext header followed by an encrypted body.

| Offset | Field | GB202 production | linux-firmware |
|---|---:|---:|---:|
| `0x00` | Magic `03 04 48 00` | Header size `0x48` | Same |
| `0x04` | Body size | `0x46200` | `0x30A00` |
| `0x0C` | Code size | `0x37000` | `0x25800` |
| `0x14` | Data size | `0xE800` | `0xA800` |
| `0x18` | Flags / version | `0x104` | `0x104` |
| `0x20` | Constant | `0x2801` | `0x2801` |

The size algebra holds in all 14 samples: body = code + data + `0xA00`. The body
order is `[code][data][manifest 0xA00]`; the data and manifest are byte-identical
to the matching `GspRmBoot` components, and the FMC code is a prefix of the
bootloader code. The first plaintext block is therefore code, not a header.
[measured: [E73](../experiments/07_plaintext-corpus.md)]

The `0xF8` bytes before a signed container are:

```
publickey[97] || pad[7] || signature[96] || hash[48] || container
```

The key is an uncompressed P-384 point, the signature is `r || s`, and the hash
is SHA-384 over the whole container including its header. Both shipped keys verify
with OpenSSL.

| Key | First bytes | Signs |
|---|---|---|
| Production | `04 8b f1 18 bb …` | Four containers, including the GB202 production FMC |
| Debug | `04 d3 0b d5 4b …` | Two containers, including the GB202 debug FMC |

Body entropy is 7.999, no 16-byte ECB block repeats, and the header carries no
nonce. Production and debug bodies differ by 99.6%, and their XOR is at the
chance rate. The debug signing key is public; the debug encryption key is not in
any package. [measured: [E05](../experiments/07_plaintext-corpus.md),
[E06](../experiments/07_plaintext-corpus.md)]

The FMC container is bound to the COT hash. A one-byte change to the plaintext
header or the ciphertext body draws `0x33` while the COT hash is stock; the FSP
does not decrypt in place or scrub the buffer. A corrupted ciphertext never
reaches the decrypted image. [measured:
[E62](../experiments/05_fmc-fsp-boot-inputs.md)]

The full container format, signature envelope, and key search are in
[Firmware formats](../specs/04_firmware-formats.md).

## FSP command surface

Only three NVDM commands are live on GB202:

| Command | ID | Purpose |
|---|---|---|
| COT | `0x14` | Boot chain-of-trust |
| Caps | `0x16` | Capability query |
| Clock boost | `0x20` | Clock request |
| PRC | `0x13` | GH100 only; not sent here |

Nine other NVDM types are defined and never sent. There is no memory, fuse,
register, or debug command. FSP state is read out-of-band from scratch registers
and CMS2, not through a command. [measured:
[E58](../experiments/08_assessment-and-cross-checks.md)]

The framing has no length field. Message length is the queue head/tail distance
in the FSP EMEM channel. The host controls the transmit length through
`NV_PFSP_QUEUE_TAIL(0)`; the FSP controls the receive length and bounds-checks it
before the copy. MCTP type/vendor and a minimum 13-byte response are checked, but
the response's task ID, command type, tag, sequence, and SEID are not; only the
error code is used. A malformed or unsolicited response can satisfy an unrelated
pending command, and there is no copy-before-verify on the receive path. The
fuse-error check is log-only on GB202. [measured:
[E58](../experiments/08_assessment-and-cross-checks.md)]

## SEC2

No GB20x SEC2 booter ships. The only SEC2 archives are a 303-byte Turing booter
and a 6,233-byte Ada secure-scrub image. The image that carried the Ada-era stack
overflow does not exist for this chip. [measured:
[E02](../experiments/07_plaintext-corpus.md),
[E03](../experiments/07_plaintext-corpus.md)]

The host-driven FMC bootstrap is deadlocked by design. `RmDisableCotCmd=0x10`
selects `_kgspBootstrapGspFmc_GH100`, whose first step is a GSP reset. On GB100
that reset requires the level-0 read and write enables in
`NV_PGSP_FALCON_RESET_PRIV_LEVEL_MASK` (`0x1103c4`). At cold boot those bits are
clear, and only running GSP firmware clears them. The host cannot reset the GSP it
needs to reset in order to boot it. A failed attempt leaves an ioctl that never
returns, so treat it as one-shot. [measured:
[E11](../experiments/02_registry-and-static-audit.md)]

SEC2 hardware is present but empty. DMEM `0x8401c0`/`0x8401c4` is a real port and
`AINCR` advances it, but the first 8 KiB is zero. IMEM is blocked to the host
(`0xbadf5720`) and the GSP (`0xbadf5723`). EMEM reads `0x02000040`/`0`. The PLM at
`0x8403c4` is `0x00000b0f`: read all, write none. [measured:
[E18](../experiments/03_fecs-and-gr-context.md)]

The debug FMC path requires debug fuse state and a debug-signed image. No public
method enters that state on a retail 5090.

## Failure modes

The boot-specific codes are `0x83d`, `0xd9`, `0xd6`, `0x827`, `0x82e`, `0x885`,
`0x377`, `0x1db`, `0x33`, and `0xaff`. They fall into four classes: clean
pre-auth refusals, authentication failures that leave WPR2 armed, hangs with no
host log, and hard wedges from an undersized heap. The full code and sentinel
reference is in [Errors and logging](../specs/08_errors-and-logging.md).

## Firmware inventory

Image sizes and formats are in [Firmware formats](../specs/04_firmware-formats.md).
The FSP and GSP BootROM have no obtainable image; the FMC and `GspRmBoot` ship
encrypted; the GSP-RM is plaintext. [measured:
[E02–E03](../experiments/07_plaintext-corpus.md)]

## Evidence map

| Fact | Experiment |
|---|---|
| Boot order, component inventory, no SEC2 booter | [E02–E03](../experiments/07_plaintext-corpus.md) |
| Host boot baseline, `c04` FMC identity | [E28](../experiments/05_fmc-fsp-boot-inputs.md) |
| COT size, offset, placement | [E29–E35](../experiments/05_fmc-fsp-boot-inputs.md) |
| COT hash and key checks | [E41](../experiments/05_fmc-fsp-boot-inputs.md), [E61](../experiments/05_fmc-fsp-boot-inputs.md) |
| `WprMeta` field matrix and heap lever | [E36–E40](../experiments/05_fmc-fsp-boot-inputs.md) |
| Bootloader description and image authentication | [E69](../experiments/05_fmc-fsp-boot-inputs.md) |
| FMC container binding | [E62](../experiments/05_fmc-fsp-boot-inputs.md) |
| FMC body layout and key search | [E73](../experiments/07_plaintext-corpus.md) |
| Suspend/resume structure and state | [E42–E46](../experiments/06_sr-resume.md) |
| FEAT bank final before the FMC; re-lock | [E54, E64–E65](../experiments/05_fmc-fsp-boot-inputs.md) |
| vBIOS devinit-table route | [E66](../experiments/05_fmc-fsp-boot-inputs.md) |
| Bootloader host buffer | [E72](../experiments/05_fmc-fsp-boot-inputs.md) |
| Host-driven FMC bootstrap deadlock | [E11](../experiments/02_registry-and-static-audit.md) |
| FSP command surface and framing | [E58](../experiments/08_assessment-and-cross-checks.md) |
| SEC2 memory windows | [E18](../experiments/03_fecs-and-gr-context.md) |

The rate-control side of the boot is in
[Privilege and rate control](../specs/02_privilege-and-rate-control.md). The
memory layout behind the COT placement is in
[Memory and host access](../specs/07_memory-and-host-access.md).

## Terms

| Term | Meaning |
|---|---|
| FSP | Security processor that runs first out of reset, from immutable ROM |
| GSP BootROM | Immutable ROM on the GSP that authenticates and starts the FMC |
| FMC | First-stage mutable GPU firmware; signed, encrypted; runs in Heavy Secure |
| GSP-RM | Main GPU firmware; plaintext; runs in Light Secure |
| COT | Chain-of-trust message the host sends to the FSP |
| `WprMeta` | 256-byte host boot descriptor consumed by the FMC |
| `SRMeta` | 256-byte host suspend/resume descriptor consumed by secure firmware |
| FRTS | Firmware runtime state region inside the WPR |
| WPR | Write-protected VRAM region holding firmware, heaps, and FRTS |
| PL3 / PL2 | Heavy Secure / Light Secure privilege levels |
| WPR2 | The second write-protected region; armed before COT authentication |
| GSCI | Driver query that returns the post-boot WPR layout |
| P-384 / SHA-384 | Elliptic curve and hash used by the COT and FMC signatures |
