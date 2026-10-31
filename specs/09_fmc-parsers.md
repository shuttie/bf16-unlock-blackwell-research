# FMC boot-input parsers

## At a glance

- **Scope.** The checks the FMC (first-stage mutable firmware) applies to the
  host boot inputs: the COT, `WprMeta`, the `GspRmBoot` image and its signature
  section, the GSP-RM image, and the heap layout. It covers the check order, the
  signature section map, the pointer rules, and the codes.
- **Bench.** Two RTX 5090s (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  one module reload per field. The firmware-version differences say so in the
  sentence.
- **Evidence.** Every check links to the [parser
  experiments](../experiments/09_fmc-cold-boot-parsers.md) or the earlier
  boot-input records that established it. The `WprMeta` field table is in
  [the boot-chain spec](01_boot-chain.md#wprmeta), the boot codes in [the error
  spec](08_errors-and-logging.md#boot-error-codes), and the heap model in [the
  memory spec](07_memory-and-host-access.md#wpr-and-frts-layout).

**The short version.**

- The FMC checks the inputs in a fixed order: COT and FSP fields, `WprMeta`
  version and geometry, the signature section and the radix3 pointer, the image
  authentication, then the heap layout.
- The checks are alignment, exact value, bounds, or authentication. The size
  fields are not exact lengths: `sizeOfBootloader` is 4 KiB-aligned, and the
  signature record size is a `[0x180, 0x200]` window.
- The signature address is a host pointer, not a pinned value. It requires
  4-byte alignment and a recognizable first word. The radix3 address is pinned.
- Every bootloader image byte is behind authentication.
- The heap size moves the unprotected heap from a fixed WPR base. It does not
  move the protected region.
- The parser codes are `0x828`, `0x82e`, `0x836`, `0x83e`, `0x841`, `0x885`,
  `0xa97`, `0xaaa`, and `0xa0f`, plus four `0xaff` info values.

**In this spec.**

- [Check order](#check-order)
- [WprMeta checks](#wprmeta-checks)
- [Signature section layout](#signature-section-layout)
- [Record size and mode](#record-size-and-mode)
- [Address rules](#address-rules)
- [Heap layout](#heap-layout)
- [Codes](#codes)
- [Evidence map](#evidence-map)
- [Limits and open questions](#limits-and-open-questions)

## Check order

The FMC consumes the host inputs in this order. A clean pre-authentication
refusal recovers with a module reload; an authentication failure can leave
[WPR2](01_boot-chain.md#failure-modes) armed; the heap wild value wedges.

| Stage | Check | Input | Result | Evidence |
|---|---|---|---|---|
| FSP | FRTS size exactly `0x100000` | COT | `0xd9` | [the FRTS-size rejection](../experiments/05_fmc-fsp-boot-inputs.md#054-frts-size-rejected-by-the-fsp) |
| FSP | FRTS offset 128K-aligned | COT | `0xd6` | [the misaligned base](../experiments/05_fmc-fsp-boot-inputs.md#057-misaligned-frts-base-draws-0xd6) |
| FSP | COT hash, key, container binding | COT and container | `0x377`, `0x1db`, `0x33` | [the hash check](../experiments/05_fmc-fsp-boot-inputs.md#0516-cot-hash-authenticated-auth-failure-wedges), [the key anchor](../experiments/05_fmc-fsp-boot-inputs.md#0518-cot-public-key-anchored), [the tampered container](../experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered) |
| FMC | `WprMeta` magic | `WprMeta` | `0x827` | [the magic test](../experiments/05_fmc-fsp-boot-inputs.md#0511-wprmeta-magic-enforced-verified-accepted) |
| FMC | `revision` is 1 | `WprMeta` | `0x828` | [the revision sweep](../experiments/09_fmc-cold-boot-parsers.md#098-the-revision-and-manifest-offset-are-exact-checks) |
| FMC | `sizeOfBootloader` 4 KiB-aligned | `WprMeta` | `0x82e` | [the size sweep](../experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length) |
| FMC | bootloader length is stock and the image authenticates | `WprMeta`, image | `0xaff` info `0xb` | [the size sweep](../experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length) |
| FMC | bootloader size at 256 MiB | `WprMeta` | `0x836` | [the size sweep](../experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length) |
| FMC | `bootloaderManifestOffset` is 0 | `WprMeta` | `0x841`, out-of-range `0x885` | [the manifest sweep](../experiments/09_fmc-cold-boot-parsers.md#098-the-revision-and-manifest-offset-are-exact-checks) |
| FMC | signature pointer alignment and first word | `WprMeta` | `0x885`, `0xa97` | [the signature address](../experiments/09_fmc-cold-boot-parsers.md#096-the-signature-address-is-a-4-byte-aligned-pointer) |
| FMC | radix3 image pointer | `WprMeta` | `0x83e` | [the address tests](../experiments/09_fmc-cold-boot-parsers.md#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth) |
| FMC | bootloader manifest, data, and code bytes | `GspRmBoot` | `0xaff` info `0xb` | [the image test](../experiments/09_fmc-cold-boot-parsers.md#099-the-bootloader-image-bytes-are-authenticated-end-to-end) |
| FMC | signature slots and table | signature section | `0xaff` info `0x1`, `0x2`, `0x7` | [the section layout](../experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records) |
| FMC | signature record size | signature section | `0xaaa` | [the record-size test](../experiments/09_fmc-cold-boot-parsers.md#093-the-signature-record-size-is-a-bounded-window) |
| FMC | signature mode | signature section | `0xa0f` | [the table test](../experiments/09_fmc-cold-boot-parsers.md#094-the-signature-table-and-mode-fields-are-validated) |
| FMC | heap layout | `WprMeta` | boot or WPR2 | [the heap test](../experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever) |

## WprMeta checks

The field table is in [the boot-chain spec](01_boot-chain.md#wprmeta). The
parser-relevant behavior:

- `magic` must be `0xdc3aae21371a60b3`; a wrong value draws `0x827`.
- `revision` must be 1; any other value draws `0x828`.
- `sizeOfBootloader` must be 4 KiB-aligned. An aligned non-stock value is
  accepted into the authentication read, so the check is alignment plus the
  image binding, not an exact length ([the size
  sweep](../experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length)).
- `bootloaderManifestOffset` must be 0. An aligned non-zero value draws `0x841`;
  an out-of-range value draws `0x885` ([the manifest
  sweep](../experiments/09_fmc-cold-boot-parsers.md#098-the-revision-and-manifest-offset-are-exact-checks)).
- `bootloaderCodeOffset`, `bootloaderDataOffset`, `fbSize`, and the signature
  size field are inert on this path. The address fields carry the checks in
  [address rules](#address-rules).
- The heap fields are in [heap layout](#heap-layout).

## Signature section layout

`.fwsignature_gb20x` is `0x1000` bytes. The layout is the same on the local
570.144 and running 595.91.07 images except for the `0x880` value.

| Offset | Content |
|---|---|
| `0x000` | header: `0x00020001`, `0x8c8`, `0x0c`, `0x0101`, `0x200` |
| `0x014`, `0x214`, `0x414`, `0x614` | four 0x200 slots; each holds a 0x180-byte record, padded to 0x200 |
| `0x814` | table: `0x00010001`, `0x00020001`, `0x00000001` |
| `0x87c` | mode, stock `0x00000001` |
| `0x880` | length or flag, stock `0x000003c3` on 595.91.07 (`0x2c2` on 570.144) |
| `0x884` | flag, stock `0x00000001` |

The FMC verifies slots 0 and 1. A byte flip at `0x14` or `0x214` draws `0xaff`
info `0x1`; a flip at `0x414` or `0x614` still boots. The table at `0x814` is
checked through a different path: `0x814`–`0x81c` changes draw `0xaff` info
`0x2`, except `0x818 = 0x10001`, which draws info `0x1` ([the section
layout](../experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records)).

The first word at the pointer is a section marker, not an exact magic. Changing
the stock first word from `0x00020001` to `0x00020002` still boots, and the word
at `0x818` is `0x00020001`, so pointing the signature address at `0x818` passes
the marker check and fails at the table. The size, count, and `+0x0c` header
words are not used on the stock path.

## Record size and mode

The field at `+0x10` is the record size, not the slot stride. The slot stride is
fixed at 0x200.

| Record size | Result |
|---|---|
| `0x180`–`0x200` | boot |
| below `0x180` | `0xaff`, info `0x7` or `0x1` |
| above `0x200` | `0xaaa`, info `0x0` |

`0x180` (384) and `0x1ff` (511) both boot, which fixes the slot stride. A value
one byte over the window draws `0xaaa`; `0x7fffffff`, `0x80000000`, and
`0xfffffe00` also draw it, so no unsigned wrap was found ([the record-size
test](../experiments/09_fmc-cold-boot-parsers.md#093-the-signature-record-size-is-a-bounded-window)).

The tail at `0x87c` is a mode with the valid set `{1,2}`. Mode 1 boots; mode 2
reaches image authentication and fails with `0xaff` info `0xb`; `0`, `3`, and
above draw `0xa0f`. The `0x880` and `0x884` fields are bound into image
authentication: any change draws `0xaff` info `0xb` ([the table
test](../experiments/09_fmc-cold-boot-parsers.md#094-the-signature-table-and-mode-fields-are-validated)).

## Address rules

| Field | Rule | Result |
|---|---|---|
| `sysmemAddrOfBootloader` | used in the image authentication | a moved value falls through to `0xaff` |
| `sysmemAddrOfSignature` | host pointer; 4-byte aligned; first-word marker | unaligned `0x885`; wrong word `0xa97`; `+0x818` reaches the table check |
| `sysmemAddrOfRadix3Elf` | effectively pinned | every moved value draws `0x83e` |

The signature pointer is read, so the FMC parses a section at the host-chosen
address. Because the stock address points at the host buffer the host already
edits, this is address trust without a new input. The radix3 pointer is not
read from a moved address: the `+1` delta draws the same `0x83e` as the
page-aligned deltas ([the address
tests](../experiments/09_fmc-cold-boot-parsers.md#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth),
[the signature
address](../experiments/09_fmc-cold-boot-parsers.md#096-the-signature-address-is-a-4-byte-aligned-pointer)).

## Heap layout

The heap fields do not change the protected region's top. `nonWprHeapSize` is
honored 1:1: a 256 MiB request moves the unprotected heap start down by the
exact increase over the 3 MiB stock value while the heap end stays at the stock
WPR base and FRTS stays anchored. A 4 GiB request wedges the boot with WPR2 up.
`gspFwHeapSize` moves the WPR downward ([the non-WPR heap
test](../experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever),
[the heap-size
test](../experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward)).
The layout model is in [the memory spec](07_memory-and-host-access.md#wpr-and-frts-layout).

## Codes

The full boot-code table is in [the error
spec](08_errors-and-logging.md#boot-error-codes). The parser-specific codes:

| Code | Trigger |
|---|---|
| `0x828` | `revision` is not 1 |
| `0x82e` | `sizeOfBootloader` not 4 KiB-aligned |
| `0x836` | `sizeOfBootloader` is 256 MiB |
| `0x83e` | radix3 image address moved |
| `0x841` | `bootloaderManifestOffset` in range and not 0 |
| `0x885` | parameter out of range or misaligned |
| `0xa97` | signature address aligned, first word wrong |
| `0xaaa` | signature record size above `0x200` |
| `0xa0f` | signature mode not 1 or 2 |

`0xaff` covers the image and signature checks: info `0x1` is a slot mismatch,
`0x2` a table mismatch, `0x7` an undersized record, and `0xb` image
authentication.

## Evidence map

| Fact | Experiment |
|---|---|
| Bootloader size alignment and the 256 MiB limit | [the size sweep](../experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length) |
| Signature section layout and checked slots | [the section layout](../experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records) |
| Record-size window | [the record-size test](../experiments/09_fmc-cold-boot-parsers.md#093-the-signature-record-size-is-a-bounded-window) |
| Table entry, mode window, auth-bound fields | [the table test](../experiments/09_fmc-cold-boot-parsers.md#094-the-signature-table-and-mode-fields-are-validated) |
| Bootloader and radix3 addresses | [the address tests](../experiments/09_fmc-cold-boot-parsers.md#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth) |
| Signature pointer alignment and marker | [the signature address](../experiments/09_fmc-cold-boot-parsers.md#096-the-signature-address-is-a-4-byte-aligned-pointer) |
| Heap layout lever | [the heap test](../experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever) |
| Revision and manifest offset | [the revision and manifest sweep](../experiments/09_fmc-cold-boot-parsers.md#098-the-revision-and-manifest-offset-are-exact-checks) |
| Bootloader image authentication | [the image test](../experiments/09_fmc-cold-boot-parsers.md#099-the-bootloader-image-bytes-are-authenticated-end-to-end) |

## Limits and open questions

- The signature pointer has only been tested inside the stock buffer. A second
  host buffer whose first word is a marker has not been tried.
- The `0x836` boundary between 16 MiB and 256 MiB is not mapped, and the code
  does not say whether the FMC refused the size or failed the read.
- A valid mode-2 record layout is not known. Mode 2 is structurally accepted and
  fails at authentication.
- The ACR and `wprCarveout*` boot-parameter fields are not mapped.
- The `0xaff` info values are inferred from the failing path, not decoded in the
  FMC.
