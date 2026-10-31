# vBIOS and devinit: the plaintext layer

## At a glance

- **Scope.** The board vBIOS: where it sits, the PCI image chain, the BIT (BIOS
  Information Table) and microcode tables, the plaintext scans, the DEVINIT
  (GPU-side initialization) authentication, and why the no-flash custom-vBIOS
  route cannot reach the rate selector. This is the
  plaintext layer only; the executable devinit is encrypted microcode.
- **Bench.** Stock RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  two cards.
- **Evidence.** Measured claims link to the experiment that established them.
  Public-document or Ada/Ampere claims say so in the sentence.

**The short version.**

- The vBIOS sits at BAR0 + `0x338000` behind a `0x38000` head; the full 2 MiB
  PROM aperture is the complete view.
- The image is a PCI chain: PciAt, EFI, and two FwSec (firmware-security image)
  partitions.
- The BIT (BIOS Information Table) has 20 tokens; the microcode table has 35
  entries, four real images and two placeholders.
- No plaintext scan finds a FEAT (rate-control register bank) or FUSE address or
  selector constant. The only PLM (privilege-level mask) values are in app `0x23`
  data.
- The DEVINIT tables and scripts are authenticated in Heavy Secure and bound to
  the device ID.
- A no-flash custom vBIOS is a table edit, not a privilege escalation; a custom
  GSP-RM (main GPU firmware) still runs at PL2 (Light Secure).
- The FEAT writer is a GPU-side devinit before the first open. The plaintext
  table route is closed; the writer is open.

**In this spec.**

- [Where it sits](#where-it-sits): PROM aperture and vBIOS offset.
- [PCI image chain](#pci-image-chain): PciAt, EFI, FwSec.
- [BIT](#bit): 20 tokens.
- [Microcode table](#microcode-table): 35 entries, four real.
- [What the plaintext layer does not contain](#what-the-plaintext-layer-does-not-contain):
  scans and PLM hits.
- [Devinit authentication](#devinit-authentication): HS signature and device-ID
  binding.
- [The custom-VBIOS route](#the-custom-vbios-route): no-flash table edits.
- [What this means for the rate selector](#what-this-means-for-the-rate-selector):
  writer open, table route closed.
- [Evidence map](#evidence-map)
- [Terms](#terms)
- [Limits and open questions](#limits-and-open-questions)

## Where it sits

The flash sits behind the PROM aperture at BAR0 + `0x300000`. On GB202 the vBIOS
image starts at BAR0 + `0x338000`, after a `0x38000` head. The PCI expansion ROM
BAR exposes only the PciAt and EFI images; the rest needs the PROM window. This
board has no ERoT. See [the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address).

The full 2 MiB PROM aperture maps as follows ([the full PROM
scan](../experiments/07_plaintext-corpus.md#079-the-full-prom-has-no-feat-table)):

| Range | Content |
|---|---|
| `0x00000`–`0x38000` | Head: `4cc0` tag, FF fill, `NVFW` marker at `+0x1000`, an encrypted 218,688-byte blob at `0x1400`–`0x36a40` (entropy 8.0), plaintext board metadata at `0x36a40`–`0x36a90`, then FF |
| `0x38000`–`0x138000` | The vBIOS image |
| `0x138000`–`0x200000` | Not flash: every dword is the PROM sentinel `0xBADF1100` |

The head is 99.66% identical between the two local cards: 228,586 of 229,376
bytes match, 790 differ. The differences are the plaintext metadata block plus
seven longer runs. The metadata carries vendor codes `pcp` (ZOTAC) and `ask`
(InnoVISION), with part and board IDs. The `NVFW` marker is surrounded by FF and
is not a parseable header. See [the full PROM
scan](../experiments/07_plaintext-corpus.md#079-the-full-prom-has-no-feat-table).

The readable vBIOS image is 819,200 bytes of a larger image. The image extends
past the 1 MiB PROM window, so the 2 MiB aperture is the complete view of the
image and its head ([the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)).

## PCI image chain

The image is a little-endian PCI chain ([the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)).

| Image offset | Size | Type | Notes |
|---|---:|---|---|
| `0x000000` | `0xFA00` | PciAt | `PCIR` at `0xCA0`; device `10de:2b85`; BIT at `0xDF0` |
| `0x00FA00` | `0x18000` | EFI | `NPDE` clears `last_image` |
| `0x027A00` | `0x0FA00` | FwSec | First partition |
| `0x037400` | `0x9E800` | FwSec | Last image; extends past the 1 MiB readable window |

The EFI image forces a `0x18000` correction on offsets taken from the 1 MiB dump;
the 2 MiB aperture shows the same image at `+0x38000`.

## BIT

The BIOS Information Table is at image offset `0xDF0`: a 12-byte header, 6-byte
tokens, 20 tokens in total. `BIOSDATA` decodes to the `nvidia-smi` version. All
20 tokens resolve to configuration data ([the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)).

The Falcon-microcode token is `0x70`. Its data word is `0x10C1`, which points at
table pointer `0x4CE9D`; with the EFI correction the table is at image `0x64E9D`.
See [the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address).

## Microcode table

The table is version 1, header 6 bytes, stride 6, with 35 entries. Four entries
are real images; two are placeholders whose descriptors read `0xBADF1100`. See
[the vBIOS dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)
and [the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan).

| App ID | Target | vDesc | Encrypted | Body |
|---|---|---|---|---|
| `0x07` | `0x06` | 6 | yes | `0x6FDF0`–`0x8FFF0` |
| `0x19` | `0x01` | 6 | yes | `0x90040`–`0xB1B40` |
| `0x15` | `0x01` | 6 | yes | `0xB1C80`–`0xB7780` |
| `0x23` | `0x0E` | 6 | yes | `0xB780C`–`0xD5A0C` |
| `0x18` | `0x01` | n/a |; | Placeholder; descriptor `0xBADF1100` |
| `0x24` | `0x0F` | n/a |; | Placeholder; descriptor `0xBADF1100` |

All four real descriptors are version 6, size `0x50`, with the encrypted bit set.
The bodies begin with encrypted code, entropy 8.0. Only app `0x23` / target `0x0E`
has a plaintext tail: 64 KiB of encrypted code at `0xB780C`–`0xC780C`, a ~2 KiB
header at `0xC780C`–`0xC8000`, then plaintext data at `0xC8000`–`0xD5A0C` with
entropy 2–3. That data contains `0xFFFFFB8F` (4 hits), `0xFFFFFBFF` (7),
`0xFFFFFF8F` (9), `0xFFFFFF0F` (7), and a large `0xBADF5040` poison field. See
[the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan).

The driver looks for FWSEC app IDs `0x05`, `0x45`, `0x85`; none is present. That
is consistent with the FSP-based boot chain ([the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)).

Target IDs are not publicly mapped. The PLM-bearing image is consistent with the
SEC2 class identified in public CMP 170HX work, but "app `0x23` = SEC2" is
carried over by analogy, not a confirmed identification.

## What the plaintext layer does not contain

A 32-bit scan of the 819,200-byte image finds zero occurrences of the FEAT/FUSE
constants `0x00823804`, `0x00823818`, `0x0082381c`, `0x00823820`, `0x008207d4`,
`0x008207d8`, `0x0082059c`, `0x008200fc`, `0x008203f0`, `0x0082074c`, or
`0x00504204`. The x86 option ROM has no absolute MMIO store into
`0x0080xxxx`–`0x008fxxxx`. See [the vBIOS
dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address).

The full scan is wider: the 1 MiB image and the 2 MiB aperture, on both cards, in
either endianness, with the devinit address flags `0x20000000`, `0x40000000`, and
`0x80000000`. It finds zero occurrences of `0x00823800`, `0x00823804`,
`0x00823808`, `0x0082380c`, `0x00823810`, `0x00823814`, `0x00823818`,
`0x0082381c`, and `0x00823820`. See [the full PROM
scan](../experiments/07_plaintext-corpus.md#079-the-full-prom-has-no-feat-table).

No devinit opcode carries an address in `0x823800`–`0x8238FF`. The tested opcodes
are `0x6E`, `0x7A`, `0x48`, `0x47`, `0x10`–`0x13`, `0x20`–`0x23`, `0x2C`, `0x58`,
and `0x91`. The only register-address list is a 72-entry 64-bit FUSE/strap table
at `0x638E5`, covering `0x820800`–`0x8221A4`; it has no FEAT entry. See [the
devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan).

The PLM values live only in app `0x23` / target `0x0E`:

| Anchor | Hits | Owner |
|---|---:|---|
| `0xFFFFFB8F` (PLM locked) | 4 | app `0x23` / target `0x0E` |
| `0xFFFFFBFF` (PLM bit 10) | 7 | app `0x23` data |
| `0xFFFFFF8F` (Ada FEAT) | 9 | app `0x23` data |
| `0xFFFFFF0F` (Ada FBPA) | 7 | app `0x23` data |
| `0xBADF5040` poison | 10,701 | app `0x23` data |
| `0xBADF1100` sentinel | 241,883 | outside the image |

Two tail tables at `0xE8300` and `0xE9400` hold `0x0884CB8F`, `0x0884CBCF`,
`0xFFFFFB8F`, and `0x0085CB8F`, but no addresses. App `0x23`'s code is
byte-identical across the two cards; its data differs by 65 bytes of per-card
calibration ([the devinit
scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)).

## Devinit authentication

The plaintext table route is closed by authentication, not by a missing table. The
GSP-RM string table carries the DEVINIT authentication errors, including:

```text
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_HEADER_DATA_NOT_PRESENT
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_SIGNATURE_TYPE_MISMATCH
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_DERIVEHWKEY_DOAESECB_NOT_IN_HSMODE
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_COMPUTEAESSIGNATURE_DOAESECB_NOT_IN_HSMODE
NV_UDE_ERR_DEVINIT_TABLE_AUTHENTICATE_DATA_SIGNATURE_DATA_TYPE_DEVINIT
NV_UDE_ERR_DEVINIT_SCRIPT_AUTHENTICATE_...
NV_UDE_ERR_DEVINIT_AUTHENTICATE_DATA_PATCHER_...
NV_UDE_ERR_DEVINIT_RESIGN_DATA_PATCHER_...
NV_UDE_ERR_DEVICE_ID_WITH_DEVINIT_SCRIPTS_MISMATCH
NV_UDE_ERR_DEVICE_ID_WITH_DEVINIT_TABLES_MISMATCH
NV_UDE_ERR_UCODE_DMEM_VERIFICATION_FAILED
```

The DEVINIT tables and scripts are signed and authenticated in Heavy Secure with
AES-ECB, and the table is bound to the device ID. The microcode DMEM is verified
too. A plaintext edit of a table or data section fails authentication. See [the
devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan).

## The custom-VBIOS route

Since October 2026 a public no-flash toolset loads edited vBIOS images without
flashing: on Windows through a driver registry key, on Linux through patched open
kernel modules. The images keep NVIDIA's original signature, which no longer
matches, so `nvflash` refuses them; the tools use a host-side override path instead
of breaking a signature.

The route is a table edit, not a privilege escalation. Its demonstrated effects are
power limits, voltage ceilings, over-current protection, fan channels, and offsets:
data the GSP reads, not code that runs at elevated privilege. A custom GSP-RM runs
at PL2 whether stock or custom, because the Falcon start level is fixed by
hardware. Its writes to `FEAT_OVR_PLM`, `SS0`, and `SS1` are dropped exactly like
host PL0 (Non-Secure) writes ([the privilege
model](../specs/02_privilege-and-rate-control.md)).

The pre-driver writer is outside the edit's reach. The PLM re-lock happens before
the first open in a GPU-side master, and the DEVINIT tables and scripts are
authenticated in Heavy Secure. A no-flash table edit changes what the host driver
parses, not what the GPU's HS firmware authenticates from the flash. See [the
devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan).

If a custom image boots at all, something in the authentication path was bypassed:
driver-side loading, debug fuse state, or an in-memory patch. That is interesting,
but it does not cross the Light Secure / Heavy Secure line. As an instrument, a
minimal custom GSP-RM that attempts the `SS0` write and logs the readback would be
a cleaner PL2 test of the boundary than the host ioctl, with the same expected
refusal.

## What this means for the rate selector

The plaintext vBIOS layer is board configuration, not executable devinit bytecode.
The executable boot firmware is the encrypted head blob, the FwSec images, or the
encrypted app `0x23` code. "Who writes `SS0`/`SS1` at boot" cannot be separated
further from plaintext, but the timing and privilege are fixed:

- The writer is a GPU-side devinit action that runs while the reset PLM admits PL2
  writes and then locks the bank. The PMU is the leading candidate; the
  FSP/BootROM and a hardware re-latch are not excluded.
- The FMC, the host driver, and GSP-RM do not write the bank.
- No plaintext table names the FEAT block. The only PLM values are in an
  authenticated microcode data section.

The writer is open; the table route is closed. See [the FEAT-bank
timing](../experiments/05_fmc-fsp-boot-inputs.md#0517-feat-bank-final-before-the-fmc),
[the boot-to-boot
state](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr),
and [the re-lock test](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit).

## Evidence map

| Claim | Evidence |
|---|---|
| vBIOS location, image chain, BIT, microcode table | [the vBIOS dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address) |
| 2 MiB aperture map, head diff, sentinel tail | [the full PROM scan](../experiments/07_plaintext-corpus.md#079-the-full-prom-has-no-feat-table) |
| Four real images, two placeholders, body offsets | [the vBIOS dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address), [the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan) |
| Zero FEAT/FUSE literals, zero devinit FEAT addresses | [the vBIOS dump](../experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address), [the full PROM scan](../experiments/07_plaintext-corpus.md#079-the-full-prom-has-no-feat-table), [the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan) |
| 72-entry FUSE/strap list, PLM anchor ownership | [the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan) |
| DEVINIT authentication strings and device-ID binding | [the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan) |
| Custom-VBIOS route and PL2 ceiling | [the devinit scan](../experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan), [the privilege model](../specs/02_privilege-and-rate-control.md) |
| Pre-lock writer timing and privilege | [the FEAT-bank timing](../experiments/05_fmc-fsp-boot-inputs.md#0517-feat-bank-final-before-the-fmc), [the boot-to-boot state](../experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr), [the re-lock test](../experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit) |

## Terms

| Term | Meaning |
|---|---|
| vBIOS | Board firmware image stored on the flash and read through the PROM aperture. |
| PciAt | The x86 PCI option ROM image at the start of the chain. |
| EFI | The EFI option ROM image that follows PciAt. |
| FwSec | Firmware-security image partitions in the chain. |
| BIT | BIOS Information Table: 20 configuration tokens at image `0xDF0`. |
| Microcode table | The 35-entry Falcon microcode descriptors selected by the `0x70` BIT token. |
| DEVINIT | GPU-side initialization tables and scripts, authenticated in Heavy Secure. |
| PLM | Privilege-level mask: the read/write permission field on a register block. |
| FEAT bank | Register block holding the speed-selector override words. |
| `SS0` / `SS1` | The two SM speed-selector override words in the FEAT bank. |

For the boot chain and privilege levels, see [the boot chain](01_boot-chain.md) and
[the privilege model](02_privilege-and-rate-control.md). For the register values
named here, see [the register map](03_register-map.md). The tools that produced the
dumps and scans are in [vBIOS tools](../tools/vbios-tools/).

## Limits and open questions

- The scan is a plaintext scan. The encrypted head blob and the encrypted microcode
  bodies are not readable; the spec does not prove the executable devinit never
  targets the FEAT block. It closes the plaintext table route.
- Target IDs are not publicly mapped. The app `0x23` = SEC2 identification is
  inference.
- The writer is not named. The timing brackets it to a GPU-side devinit; the PMU is
  the leading candidate, not a proven one.
- The custom-VBIOS description is a ceiling argument, not a full audit of the
  no-flash toolset.
- **Open question:** does the encrypted app `0x23` code target the FEAT block at
  runtime? It is not decrypted.
- **Open question:** which devinit performs the FEAT write? The re-lock timing
  narrows it to a GPU-side master, not one named component.
