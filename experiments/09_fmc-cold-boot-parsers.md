# The FMC cold-boot parsers

## Summary

**The idea.**

- The [FEAT](../specs/03_register-map.md#feat-bank) routes are closed, so the
  parsers of the host-fed [PL3](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
  firmware are the remaining surface. The FSP is immutable ROM with a
  three-command surface. The [FMC](../specs/04_firmware-formats.md#fmc-container)
  is the only mutable host-supplied image, and it parses the host boot inputs.
- The host fills the FMC's inputs: the [COT](../specs/01_boot-chain.md#cot-v2),
  [`WprMeta`](../specs/01_boot-chain.md#wprmeta), the
  [`GspRmBoot`](../specs/04_firmware-formats.md#gsprmboot) image and its
  signature section, the [`GSP-RM`](../specs/01_boot-chain.md#boot-order) image,
  and the FMC container.
  I treated those inputs as black-box parsers: one field, buffer byte, or
  pointer delta per boot, then recorded the FMC reply.
- What it would give: a memory-safety or trust bug at PL3, or a field-by-field
  map of what the parser bounds. The stable check map, section layout, and
  pointer rules are collected in [the FMC parser spec](../specs/09_fmc-parsers.md);
  the records below are the evidence.

**What it found.**

- [`sizeOfBootloader`](../specs/01_boot-chain.md#wprmeta) is a 4 KiB alignment
  check, not an exact length. Every aligned value is accepted into image
  authentication; any non-stock value fails with
  [`0xaff`](../specs/08_errors-and-logging.md#boot-error-codes), and 256 MiB
  draws a size-limit code
  ([the size test](#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length)).
- The signature section is a 20-byte header, four 0x200 slots, and a plaintext
  table at `0x814`. Slots 0 and 1 are verified, slots 2 and 3 are not, and the
  table is checked through a different path
  ([the section layout](#092-the-signature-section-layout-and-the-checked-records)).
- The field at `+0x10` is a record size with a `[0x180, 0x200]` window. Below
  the window is an authentication failure; above it is a bounds refusal
  ([the record-size test](#093-the-signature-record-size-is-a-bounded-window)).
- The table tail at `0x87c` is a mode with the valid set `{1,2}`; anything else
  is a bounds refusal. The `0x880` and `0x884` fields are bound into image
  authentication
  ([the table test](#094-the-signature-table-and-mode-fields-are-validated)).
- The bootloader address is used in authentication, the
  [radix3](../specs/01_boot-chain.md#suspendresume) address is pinned, and the
  signature address is a 4-byte-aligned pointer with a magic check
  ([the address tests](#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth),
  [the signature pointer](#096-the-signature-address-is-a-4-byte-aligned-pointer)).
- [`nonWprHeapSize`](../specs/01_boot-chain.md#wprmeta) is honored 1:1: 256 MiB
  moves the published non-WPR heap by the exact delta from a fixed WPR base,
  and 4 GiB wedges the boot
  ([the heap test](#097-the-non-wpr-heap-size-is-a-11-layout-lever)).
- [`revision`](../specs/01_boot-chain.md#wprmeta) must be 1, and
  [`bootloaderManifestOffset`](../specs/01_boot-chain.md#wprmeta) must be 0
  ([the revision and manifest
  test](#098-the-revision-and-manifest-offset-are-exact-checks)).
- Every byte of the `GspRmBoot` manifest, data, and code fails image
  authentication
  ([the image test](#099-the-bootloader-image-bytes-are-authenticated-end-to-end)).

**What it did not find.**

- No PL3 code execution, no authentication bypass, and no FEAT or PLM write.
- No pre-authentication parse of the manifest or the bootloader image bytes.
- No read of a moved radix3 pointer. The signature pointer is read, but it
  points at the host buffer the host already controls.
- No effect from the signature header's magic, size, count, or the `+0x0c`
  field when the pointer is stock.
- No layout that exposes the WPR through the non-WPR heap size.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 09.1 | [The bootloader size is a 4 KiB-aligned authentication length](#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length) | Alignment, auth length, size limit |
| 09.2 | [The signature section layout and the checked records](#092-the-signature-section-layout-and-the-checked-records) | Slots 0/1 checked; table separate |
| 09.3 | [The signature record size is a bounded window](#093-the-signature-record-size-is-a-bounded-window) | `0x180`–`0x200`; `0xaaa` above |
| 09.4 | [The signature table and mode fields are validated](#094-the-signature-table-and-mode-fields-are-validated) | Mode `{1,2}`; `0xa0f` outside |
| 09.5 | [The bootloader and radix3 addresses are consumed pre-auth](#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth) | `0xaff` and `0x83e` |
| 09.6 | [The signature address is a 4-byte-aligned pointer](#096-the-signature-address-is-a-4-byte-aligned-pointer) | Alignment, magic, one hit |
| 09.7 | [The non-WPR heap size is a 1:1 layout lever](#097-the-non-wpr-heap-size-is-a-11-layout-lever) | Exact delta; wild wedges |
| 09.8 | [The revision and manifest offset are exact checks](#098-the-revision-and-manifest-offset-are-exact-checks) | `0x828`, `0x841`, `0x885` |
| 09.9 | [The bootloader image bytes are authenticated end to end](#099-the-bootloader-image-bytes-are-authenticated-end-to-end) | All flips `0xaff` |

## 09.1 The bootloader size is a 4 KiB-aligned authentication length

**Question.** What does the FMC check in
[`WprMeta.sizeOfBootloader`](../specs/01_boot-chain.md#wprmeta)?

**Why.**

- The [bootloader
  description](../experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images)
  changed `0x47000` to `0x47001` and got
  [`0x82e`](../specs/08_errors-and-logging.md#boot-error-codes), which read as an
  exact-length check. Values above stock were never tried.
- A host-controlled length used in a read or hash before authentication is the
  Ada booter-bug analogue.
- What it would give: the real size rule, or a length that is copied before it
  is checked.

**Method.**

- Tool: `wpr_oracle.sh 8` from [the driver harness](../tools/driver-harness/),
  one `WprMeta` field per module reload.
- Target: both cards, stock COT and images.
- Steps: set one size, build, load, boot, capture the `Fatal GSP-FMC Error`
  line, restore the stock driver.

Args used:

```bash
sudo tools/driver-harness/wpr_oracle.sh 8 0x47000
sudo tools/driver-harness/wpr_oracle.sh 8 0x47001
sudo tools/driver-harness/wpr_oracle.sh 8 0x48000
sudo tools/driver-harness/wpr_oracle.sh 8 0x10000000
```

**Observed data.** Nineteen values, one boot each, both cards:

| `sizeOfBootloader` | Result |
|---|---|
| `0x0`, `0x1`, `0x47001`, `0x47002`, `0x47004`, `0x47008`, `0x47040`, `0x47100`, `0x47800`, `0xffffffff` | `0x82e`, info `0x0` |
| `0x1000`, `0x2000`, `0x40000`, `0x46000`, `0x48000`, `0x100000`, `0x1000000` | `0xaff`, info `0xb` |
| `0x47000` (stock) | boot |
| `0x10000000` (256 MiB) | `0x836`, info `0x0` |

Every `0x82e` value is misaligned to 4 KiB. Every 4 KiB-aligned value except
stock reaches image authentication, apart from the 256 MiB value, which hits
the size limit.

**Result.**

- **Answer:** the field is checked for 4 KiB alignment. An aligned value sets the
  length of the region the FMC reads and authenticates; any non-stock value
  fails authentication. `0x82e` is an alignment refusal, not an exact-length
  check.
- **What we learned:**
  - `0x47001`, `0x0`, and `0xffffffff` are all misaligned and all draw `0x82e`.
    The earlier reading of a length check was too strong.
  - Values smaller and larger than stock both fail with the image-authentication
    info `0xb`, so the size bounds the hashed region.
  - A 16 MiB request is accepted into authentication, so the host controls a
    pre-authentication read of at least 16 MiB. No content oracle appeared:
    every aligned value returned the same code and info.
  - At 256 MiB the failure changes to `0x836`, a size or read limit.
  - The re-run in the same session reproduced every code on both cards.
- **Related:**
  - The [old bootloader
    description](../experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images)
    supplies the stock geometry and the `0x82e` sample.
  - The [image test](#099-the-bootloader-image-bytes-are-authenticated-end-to-end)
    covers the bytes at the stock length.
- **Open question:** the `0x836` boundary between 16 MiB and 256 MiB is not
  mapped, and the error does not say whether the FMC refused the size or failed
  the read.

## 09.2 The signature section layout and the checked records

**Question.** Which parts of `.fwsignature_gb20x` does the FMC verify, and where
are they?

**Why.**

- [The signature
  envelope](../specs/04_firmware-formats.md#signature-envelope) described four
  384-byte blocks on a 0x200 stride, but only the header had been varied.
- A verified slot that the host can edit is a verifier input; an unverified slot
  is a place to hide data.
- What it would give: the record map, or a slot the verifier skips.

**Method.**

- Tool: `sig_oracle.sh xor <off> 0x01` from [the driver
  harness](../tools/driver-harness/). It maps `pSignatureMemdesc`, applies one
  `BF16_SIG_*` edit per module load, and prints the old and new 32-bit word.
- Target: both cards.
- Steps: flip one byte at the start of each candidate slot, then the table, with
  every other field stock.

Args used:

```bash
sudo tools/driver-harness/sig_oracle.sh xor 0x14 0x01
sudo tools/driver-harness/sig_oracle.sh xor 0x214 0x01
sudo tools/driver-harness/sig_oracle.sh xor 0x414 0x01
sudo tools/driver-harness/sig_oracle.sh xor 0x614 0x01
sudo tools/driver-harness/sig_oracle.sh xor 0x814 0x01
```

**Observed data.** The section is 0x1000 bytes on both cards; its byte map is
in [the parser spec](../specs/09_fmc-parsers.md#signature-section-layout). The
stock table words are `0x00010001`, `0x00020001`, and `0x00000001` at `0x814`,
`0x818`, and `0x81c`; `0x00000001` at `0x87c`; `0x000003c3` at `0x880`
(595.91.07; `0x2c2` on 570.144); and `0x00000001` at `0x884`.

The byte flips:

| Offset | Result |
|---|---|
| `0x14` (slot 0) | `0xaff`, info `0x1` |
| `0x214` (slot 1) | `0xaff`, info `0x1` |
| `0x414` (slot 2) | boot |
| `0x614` (slot 3) | boot |
| `0x814` (table) | `0xaff`, info `0x2` |

**Result.**

- **Answer:** slots 0 and 1 are verified, slots 2 and 3 are not, and the table
  at `0x814` is checked through a different path with a different info value.
- **What we learned:**
  - The section is not four identical records. Two slots carry verified data;
    two are inert on this boot path.
  - The table is plaintext, structured, and validated. Its first entry changes
    produce info `0x2`.
  - The stock table's `0x880` value differs between the local 570.144 firmware
    and the running 595.91.07 image, so that field is firmware-specific.
- **Related:**
  - The [record-size test](#093-the-signature-record-size-is-a-bounded-window)
    uses the same section.
  - The [table test](#094-the-signature-table-and-mode-fields-are-validated)
    edits the validated entry.
- **Open question:** what selects the two verified slots, and whether slots 2
  and 3 become live on another image or another mode.

## 09.3 The signature record size is a bounded window

**Question.** What does the field at `+0x10` control in the signature section?

**Why.**

- The header declares `0x200` at `+0x10`. The earlier reading was a stride
  between records.
- If the verifier uses a host-controlled stride to walk records, a large value
  is an out-of-bounds read.
- What it would give: a walk outside the 4 KB buffer, or a bounds check.

**Method.**

- Tool: `sig_oracle.sh poke 0x10 4 <value>`.
- Target: both cards.
- Steps: one 32-bit value per module load; every other field stock.

Args used:

```bash
sudo tools/driver-harness/sig_oracle.sh poke 0x10 4 0x180
sudo tools/driver-harness/sig_oracle.sh poke 0x10 4 0x201
sudo tools/driver-harness/sig_oracle.sh poke 0x10 4 0xffffffff
```

**Observed data.** The field is a record size, not a stride:

| `+0x10` | Result |
|---|---|
| `0x0`, `0x1`, `0x10`, `0x100` | `0xaff`, info `0x7` |
| `0x40`, `0x80` | `0xaff`, info `0x1` |
| `0x180`, `0x1ff`, `0x200` (stock) | boot |
| `0x201`, `0x280`, `0x300`, `0x3ff`, `0x400`, `0x800`, `0x2000`, `0x7fffffff`, `0x80000000`, `0xfffffe00`, `0xffffffff` | `0xaaa`, info `0x0` |

Changing the header words at `+0x00` (`0x00020002`), `+0x04`
(`0x8cc`, `0xffff`, `0`), `+0x08` (`0x0d`, `0xffff`, `0`), or `+0x0c`
(`0`, `0x100`) still boots.

**Result.**

- **Answer:** the field is a per-record size with a `[0x180, 0x200]` window. Below
  384 the record is truncated and authentication fails; above 512 the record
  overruns its slot and the verifier refuses with `0xaaa`.
- **What we learned:**
  - `0x180` (384) and `0x1ff` (511) both boot, so the slot stride is fixed at
    0x200 and the field describes the record length.
  - The refusal at one byte over the window is sharp, and the unsigned
    extremes `0x7fffffff`, `0x80000000`, and `0xfffffe00` all hit `0xaaa`. No
    wrap was found.
  - The header's size, count, and `+0x0c` words are not used on the stock path.
    The first word is only a section marker, and changing its low bit still
    boots.
- **Related:**
  - The [section layout](#092-the-signature-section-layout-and-the-checked-records)
    locates the slots.
  - The [table test](#094-the-signature-table-and-mode-fields-are-validated)
    covers the fields after the slots.

## 09.4 The signature table and mode fields are validated

**Question.** Do the plaintext table fields at `0x814`–`0x884` control the
verifier, and does any value skip a check?

**Why.**

- The table is host-controlled and checked, which makes it the policy surface of
  the verifier.
- A field that is not covered by the integrity check would select records or
  skip a comparison.
- What it would give: a verifier policy lever, or proof the table is closed.

**Method.**

- Tool: `sig_oracle.sh poke <off> 4 <value>`.
- Target: both cards.
- Steps: one table word per module load, stock records and mode.

Args used:

```bash
sudo tools/driver-harness/sig_oracle.sh poke 0x814 4 0x00010002
sudo tools/driver-harness/sig_oracle.sh poke 0x87c 4 0x00000002
sudo tools/driver-harness/sig_oracle.sh poke 0x87c 4 0x00000000
```

**Observed data.** The table splits into a validated entry and a mode entry:

| Change | Result |
|---|---|
| `0x814` = `0x10002`, `0x1`, `0x0` | `0xaff`, info `0x2` |
| `0x818` = `0x20000`, `0x0` | `0xaff`, info `0x2` |
| `0x818` = `0x10001` | `0xaff`, info `0x1` |
| `0x81c` = `0` | `0xaff`, info `0x2` |
| `0x87c` = `0` | `0xa0f`, info `0x0` |
| `0x87c` = `1` (stock) | boot |
| `0x87c` = `2` | `0xaff`, info `0xb` |
| `0x87c` = `3`, `4`, `0xc`, `0x10`, `0x100`, `0xffffffff` | `0xa0f`, info `0x0` |
| `0x880` = `0`, `0x2c1`, `0xffffffff`, `0x3c4`, `0x3c2`, `0x180`, `0x200`, `0x7c6` | `0xaff`, info `0xb` |
| `0x884` = `0`, `2`, `3` | `0xaff`, info `0xb` |

**Result.**

- **Answer:** the first table entry is validated with info `0x2` and is tied to
  the slot check through `0x818`. The tail at `0x87c` is a mode with the valid
  set `{1,2}`; outside it the verifier refuses with `0xa0f`. The length and flag
  fields at `0x880` and `0x884` are bound into image authentication.
- **What we learned:**
  - Mode 2 is structurally accepted and reaches image authentication, then
    fails with info `0xb`. It is not a skipped check.
  - `0x818 = 0x10001` produces the slot-mismatch info `0x1`, the one table edit
    that reaches the record path.
  - The stock `0x880` value is `0x3c3` on 595.91.07; the 570.144 image carries
    `0x2c2`. The field is version-specific.
- **Related:**
  - The [record-size test](#093-the-signature-record-size-is-a-bounded-window)
    covers the field before the table.
  - The [section layout](#092-the-signature-section-layout-and-the-checked-records)
    has the byte map.
- **Open question:** what a valid mode-2 record layout looks like. The mode is
  host-controlled, but every value other than the stock set is refused before
  or at authentication.

## 09.5 The bootloader and radix3 addresses are consumed pre-auth

**Question.** Do the `WprMeta` bootloader and radix3 pointers reach the FMC as
addresses, and does an invalid address produce a distinct refusal?

**Why.**

- The [address fields](../specs/01_boot-chain.md#wprmeta) had never been varied.
- A pre-authentication read from a host-chosen address is the address-trust
  primitive.
- What it would give: a pointer check and a code, or a read.

**Method.**

- Tool: `wpr_oracle.sh 9` (bootloader address) and `wpr_oracle.sh 15` (radix3
  ELF address).
- Target: both cards.
- Steps: one absolute address per boot: zero, 4 GiB, and the stock control.

Args used:

```bash
sudo tools/driver-harness/wpr_oracle.sh 9 0x0
sudo tools/driver-harness/wpr_oracle.sh 9 0x100000000
sudo tools/driver-harness/wpr_oracle.sh 15 0x0
sudo tools/driver-harness/wpr_oracle.sh 15 0x100000000
```

**Observed data.**

| Field | Value | Result |
|---|---|---|
| `sysmemAddrOfBootloader` | `0x0`, `0x100000000` | `0xaff`, info `0xb` |
| `sysmemAddrOfRadix3Elf` | `0x0`, `0x100000000` | `0x83e`, info `0x0` |
| `sysmemAddrOfRadix3Elf` | stock `+1`, `+0x1000`, `+0x100000`, `-0x1000` | `0x83e`, info `0x0` |

**Result.**

- **Answer:** the bootloader address falls through to image authentication. The
  radix3 address has its own refusal, and every moved value draws it. The
  radix3 pointer is effectively pinned.
- **What we learned:**
  - `0x83e` is a radix3 image-address check, not an authentication failure.
  - The bootloader address has no distinct check on this path; a bad address
    fails the same image authentication as a bad image. That does not show a
    read of a host-chosen buffer, only that the field is used.
  - The radix3 checks are alignment-insensitive: the `+1` delta draws the same
    code as the page-aligned deltas.
- **Related:**
  - The [signature pointer](#096-the-signature-address-is-a-4-byte-aligned-pointer)
    is the one address with a different behavior.
  - The [heap lever](#097-the-non-wpr-heap-size-is-a-11-layout-lever) is the
    other layout field.

## 09.6 The signature address is a 4-byte-aligned pointer

**Question.** Is
[`sysmemAddrOfSignature`](../specs/01_boot-chain.md#wprmeta) pinned like the
radix3 pointer, or does the FMC read the signature section at the host address?

**Why.**

- The signature address had never been varied, and the section is the verifier
  input.
- A pointer with only an alignment check would let the FMC read a section the
  host chooses.
- What it would give: an address-trust primitive, or a pinned pointer.

**Method.**

- Tool: `wpr_oracle.sh 13` (absolute) and `wpr_oracle.sh 17` (address plus a
  delta, because the absolute address changes every boot).
- Target: both cards.
- Steps: one address or delta per boot, stock section contents.

Args used:

```bash
sudo tools/driver-harness/wpr_oracle.sh 13 0x0
sudo tools/driver-harness/wpr_oracle.sh 17 0x1
sudo tools/driver-harness/wpr_oracle.sh 17 0x4
sudo tools/driver-harness/wpr_oracle.sh 17 0x818
```

**Observed data.** The deltas split by 4-byte alignment, and one aligned
offset reaches authentication:

| Delta | Result |
|---|---|
| `0` (stock) | boot |
| `+1`, `+2`, `+7` | `0x885`, info `0x0` |
| `+4`, `+8`, `+0x10`, `+0x814`, `+0x1000`, `+0x10000`, `+0x100000`, `-0x1000`, `-0x100000` | `0xa97`, info `0x0` |
| `+0x818` | `0xaff`, info `0x2` |

The word at section offset `0x818` is `0x00020001`, the same magic the stock
header carries at `0x00`.

**Result.**

- **Answer:** the FMC reads a signature section at the host pointer. It requires
  4-byte alignment and a recognizable first word, and the check is not exact:
  `0x00020002` at the stock address still boots, while the shifted words at `+4`
  and `+8` do not. Unaligned addresses draw the generic parameter code `0x885`;
  aligned addresses with the wrong first word draw `0xa97`; the `+0x818` offset
  carries the stock first word and proceeds to the table check, which fails with
  info `0x2`.
- **What we learned:**
  - `0xa97` is a signature-header parse failure, not an address-range check.
  - The `+0x818` failure carries info `0x2`, the table code. The shifted section
    passes the header and fails at the table.
  - `0x885` is a generic alignment or range refusal. The earlier `0x885` from
    `bootloaderManifestOffset = 0xffffffff` was the same class, not a
    manifest-specific result.
  - The pointer is not pinned. Because the stock address points at the same
    host buffer the host already edits, this is address trust without a new
    input.
- **Related:**
  - The [section layout](#092-the-signature-section-layout-and-the-checked-records)
    explains the `0x818` magic collision.
  - The [radix3 address](#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth)
    is pinned in comparison.
- **Open question:** a second host buffer whose first word is `0x00020001` has
  not been tried. That would show whether the FMC will verify a section outside
  the stock allocation.

## 09.7 The non-WPR heap size is a 1:1 layout lever

**Question.** Does
[`nonWprHeapSize`](../specs/01_boot-chain.md#wprmeta) move the protected layout,
and what happens above the stock value?

**Why.**

- The field had never been varied. The other heap field,
  [`gspFwHeapSize`](../experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward),
  already moves the WPR downward without a sanity check.
- A host-controlled boundary near the WPR could expose protected data.
- What it would give: a layout model, or a boundary that stays fixed.

**Method.**

- Tool: `wpr_oracle.sh 7`.
- Target: both cards.
- Steps: 256 MiB and 4 GiB, with the stock 3 MiB control from the earlier
  session; read the post-boot GSCI layout from dmesg.

Args used:

```bash
sudo tools/driver-harness/wpr_oracle.sh 7 0x10000000
sudo tools/driver-harness/wpr_oracle.sh 7 0xffffffff
```

**Observed data.** The 256 MiB request boots and moves the heap exactly:

| Run | `nonWprHeapSize` | GSCI `nonWprHeap` | GSCI `frts` |
|---|---:|---:|---:|
| stock | `0x300000` | `0x7e72e0000` | `0x7f42c0000` |
| 256 MiB | `0x10000000` | `0x7d75e0000` | `0x7f42c0000` |

The heap start moves by `0xFD00000`, exactly the increase over the stock size.
The heap end stays at `0x7e75e0000`, the stock WPR base. FRTS does not move.

The 4 GiB request does not reach the FMC error path. The driver reports
`RmInitAdapter failed (0x62:0x40)`, then six retries report
`unexpected WPR2 already up`.

**Result.**

- **Answer:** the non-WPR heap is honored 1:1. It grows downward from a fixed WPR
  base, and FRTS stays anchored. The wild value wedges the boot and leaves WPR2
  armed.
- **What we learned:**
  - The host controls the unprotected heap boundary without a sanity check, the
    same pattern as `gspFwHeapSize`.
  - The WPR base does not move, so this field does not expose the protected
    region or the decrypted boot image.
  - A bad value here costs a reboot, unlike the structured refusals elsewhere in
    this group.
- **Related:**
  - The [heap-size
    test](../experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward)
    covers the other end of the layout.
  - The [memory
    spec](../specs/07_memory-and-host-access.md#wpr-and-frts-layout) has the
    stock layout model.
- **Open question:** the intermediate values between 3 MiB and 256 MiB, and the
  ACR and `wprCarveout*` boot-parameter fields, are not mapped.

## 09.8 The revision and manifest offset are exact checks

**Question.** Are
[`WprMeta.revision`](../specs/01_boot-chain.md#wprmeta) and
[`bootloaderManifestOffset`](../specs/01_boot-chain.md#wprmeta) exact, or
range-checked?

**Why.**

- The revision was never varied. The old manifest result used `0xffffffff`,
  which conflates an out-of-range value with a misaligned one.
- An exact check is a closed field; a range check is a parser surface.
- What it would give: the check type and the manifest-specific code.

**Method.**

- Tool: `wpr_oracle.sh 2` (revision) and `wpr_oracle.sh 12` (manifest offset).
- Target: both cards.
- Steps: one value per boot; the manifest sweep uses aligned values inside and
  outside the 0x47000 image.

Args used:

```bash
sudo tools/driver-harness/wpr_oracle.sh 2 0x0
sudo tools/driver-harness/wpr_oracle.sh 12 0x800
sudo tools/driver-harness/wpr_oracle.sh 12 0x47000
sudo tools/driver-harness/wpr_oracle.sh 12 0xfffffff8
```

**Observed data.**

| Field | Value | Result |
|---|---|---|
| `revision` | `0`, `2`, `0xffffffff` | `0x828`, info `0x0` |
| `bootloaderManifestOffset` | `0` (stock) | boot |
| `bootloaderManifestOffset` | `0x800`, `0x1000`, `0x47000`, `0x48000` | `0x841`, info `0x0` |
| `bootloaderManifestOffset` | `0xfffffff8` | `0x885`, info `0x0` |

**Result.**

- **Answer:** the revision is an exact version check. The manifest offset must be
  exactly zero. In-range non-stock offsets draw the manifest code `0x841`;
  out-of-range values draw the generic `0x885`.
- **What we learned:**
  - The stock revision is 1. The earlier spec said "not varied"; any other value
    is refused pre-auth.
  - `0x841` is the manifest-specific code. The old `0x885` came from the
    out-of-range `0xffffffff`, so the earlier "the offset is used" reading is
    right but the code attribution was not.
  - `fbSize` is inert: `0xffffffff` and `0x10000000` both boot.
- **Related:**
  - The [manifest byte
    test](#099-the-bootloader-image-bytes-are-authenticated-end-to-end) covers
    the contents.
  - The [signature pointer](#096-the-signature-address-is-a-4-byte-aligned-pointer)
    supplies the other `0x885` instance.

## 09.9 The bootloader image bytes are authenticated end to end

**Question.** Does the FMC parse any part of the `GspRmBoot` image before it
authenticates it?

**Why.**

- The [bootloader
  description](../experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images)
  proved the size and manifest offset are consumed. The image bytes were only
  tested at the first ciphertext byte.
- A pre-authentication manifest parse would be the Ada-equivalent parser.
- What it would give: an ordering result, or a pre-auth parser surface.

**Method.**

- Tool: `boot_tamper_run.sh <off> 0x01` from
  [the driver harness](../tools/driver-harness/).
- Target: both cards.
- Steps: flip one ciphertext byte at the manifest, data, and code offsets, with
  the COT, signature buffer, and every `WprMeta` field stock.

Args used:

```bash
sudo tools/driver-harness/boot_tamper_run.sh 0x0 0x01
sudo tools/driver-harness/boot_tamper_run.sh 0x9ff 0x01
sudo tools/driver-harness/boot_tamper_run.sh 0xa00 0x01
sudo tools/driver-harness/boot_tamper_run.sh 0xf200 0x01
sudo tools/driver-harness/boot_tamper_run.sh 0x46ff 0x01
```

**Observed data.** Ten offsets: `0x0`, `0x10`, `0x100`, `0x200`, `0x400`,
`0x800`, `0x9ff` in the 0xA00 manifest; `0xa00` at the data start; `0xf200` at
the code start; `0x46ff` at the last byte.

Every flip returned `0xaff`, info `0xb`.

**Result.**

- **Answer:** every part of the image is behind the image authentication. The
  manifest is not parsed before the check.
- **What we learned:**
  - The ordering is the same at the manifest, data, and code offsets. The FMC
    does not distinguish them before authentication.
  - The 0xA00 region is not a pre-auth parser surface on this path.
- **Related:**
  - The [old bootloader
    test](../experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images)
    covers the description fields.
  - The [bootloader buffer
    test](../experiments/05_fmc-fsp-boot-inputs.md#0524-bootloader-buffer-not-decrypted-in-place)
    shows the FMC does not decrypt in place.
