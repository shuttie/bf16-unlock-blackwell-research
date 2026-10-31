# Open leads: things the log has not tried

## At a glance

- **Scope.** Experiments the published log does not contain. Each lead names
  the record that raises it, the gap, and the next run.
- **Bench.** Stock RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  two cards.
- **Evidence.** Every claim links to the experiment or spec that establishes it.
  This page adds no measurements.
- **Not this page.** The closed routes and the current verdict are in [the
  README](README.md#where-it-stands).

**The short version.**

- The direct FEAT (rate-control) routes are closed. Host (PL0) and GSP-RM (the
  main firmware on the GPU's RISC-V coprocessor, PL2) writes drop, the bank's
  write mask admits PL3 (boot firmware) only, and the pre-lock writer runs
  before the host.
- The full-rate readout is measured: two RTX PRO 6000s read
  `FEAT_READOUT_1 = 0` with every arithmetic speed fuse at 0. The remaining
  target question is the `SS0`/`SS1` override payload. Two leads could reach a
  primitive cheaply: the SR (suspend/resume) saved state and the boot-input
  race.
- The rest are parser and address probes around the FMC (first-stage mutable
  GPU firmware), the FSP (security processor), and the per-SM register space.

## The index

| ID | Lead | What it tests | Cost | Decision value |
|---|---|---|---|---|
| C04 | [Override payload](#override-payload-format) | Does the SS0/SS1 override set full rate? | 1 PRO cold-boot series | Settles the write target |
| C03 | [vBIOS app 0x23](#vbios-app-0x23) | Is there a host-editable pre-lock template? | 1 day + 1 boot | Only direct-unlock candidate |
| C01 | [SR state integrity](#sr-state-integrity) | Is the saved state malleable? | 1 day | PL2 code execution |
| C20 | [Boot-input race](#boot-input-race) | Is there a hash-to-use window? | 1–2 days | PL2 or PL3 code execution |
| C02 | [WPR layout](#wpr-layout) | Can a mis-sized WPR expose the boot image? | 1–2 days | Decrypted boot corpus |
| C05 | [Below-PLM lock](#below-plm-lock) | Is a PL3 write even sufficient? | 1 hour | Changes the whole plan |
| C06 | [Name the writer](#name-the-writer) | Is the re-lock FSP or PMU? | 1 hour | Names the pre-lock actor |
| C12 | [Host FECS doorbell](#host-fecs-doorbell) | Can the host command FECS? | 1 hour | PL0 consumer interface |
| C07 | [COT address trust](#cot-address-trust) | Does the FSP trust a relocated COT pointer? | 1 run | Pre-auth address trust |
| C08 | [Signature header](#signature-header) | Is the signature header parsed before authentication? | 1 run each | Pre-auth parser surface |
| C09 | [WprMeta addresses](#wprmeta-addresses) | Are the address fields consumed? | 1 day | Address trust |
| C10 | [Per-SM channel](#per-sm-channel) | Is per-SM reachable with a real channel? | 1–2 days | Last non-PL3 register space |
| C11 | [Context patch buffer](#context-patch-buffer) | Can the host edit the post-fill context image? | 1 day | PL2 pointer primitive |
| C13 | [FSP framing](#fsp-framing) | Is the FSP parser weak at the framing layer? | 2–3 days | PL3 parser surface |
| C15 | [Readout decode](#readout-decode) | What are the un-decoded readout bits? | offline | May change the target |
| C16 | [The 0x137200 register](#the-0x137200-register) | What is the refused PL2 register? | offline, read-only | Free lead |
| C17 | [Ada payload from PL2](#ada-payload-from-pl2) | Does the exact payload take a different gate? | minutes | Completes the record |
| C18 | [vBIOS ucode corpus](#vbios-ucode-corpus) | Can the FECS/GPCCS consumer be decoded? | weeks | Answers the rate semantics |

## Override payload format

**Where it comes from.** The full-rate readout and fuse target is measured on
two RTX PRO 6000s: both read `FEAT_READOUT_1 = 0` with every arithmetic speed
fuse at 0, and card A runs BF16 at 518 TF/s with the FP16-accumulate rate equal
([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
Both cards also have every `SS0`/`SS1` enable bit clear, so the full rate comes
from the fuses, not a live override. The override payload format is the
remaining target question. The two cards differ in the runtime words, but a
same-card cold-boot series is unsampled.

**Try.** Run the existing FP16-accumulate mode on the 5090 to measure its cap
ratio locally ([the issue-rate probe](tools/issue-rate-probe/)). Get a same-card
cold-boot series on a PRO 6000 and compare `SS0`/`SS1` movement with the 5090's
([the FEAT-bank boot
test](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
An authoritative header or a PL3 write is the only way to settle the payload's
efficacy.

**Decision.** If the PRO's `SS0`/`SS1` move across cold boots like the 5090's,
the words are runtime state and the override path stays unvalidated. If a PRO
boot shows an enable bit, that is the payload. A PL3 write remains the decisive
test.

## vBIOS app 0x23

**Where it comes from.** The app `0x23` data tail is the only vBIOS artifact
carrying the exact FEAT PLM (privilege-level mask) values, in low-entropy
sentinel-structured data ([the devinit
scan](experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)).
The published scan looked for literal addresses, which an implicit-addressing
template would not contain ([the vBIOS
scan](experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address)).

**Try.** Decode the data as a 4-byte-stride array against the live block maps
([the FEAT bank](specs/03_register-map.md#feat-bank)). Map the four ucode
app/target IDs to their loaders in the GSP-RM ([the microcode
table](specs/05_vbios-and-devinit.md#microcode-table)). Then edit one benign
byte in the host copy of the image, boot, and if it boots change `0xfffffb8f`
at `0xD40E8` to `0xffffffff` and read `0x823804` and `0x823800`.

**Decision.** A clean `0xaff` closes the data-edit route. A boot with the edit
opens the pre-lock template. Use [the vBIOS tools](tools/vbios-tools/) for the
dump and parse.

## SR state integrity

**Where it comes from.** The saved state is encrypted, but the log only tests
confidentiality: entropy and a scan for known constants ([the saved
state](experiments/06_sr-resume.md#063-the-saved-state-is-high-entropy-ciphertext)).
It never flips a bit. The state spans the WPR (write-protected VRAM region) and
includes the GSP-RM ELF code ([the
radix3](experiments/06_sr-resume.md#064-the-radix3-is-plaintext-and-fully-mapped)),
and the host builds the radix3 (the three-level page table) ([the host-driven
cycle](experiments/06_sr-resume.md#061-the-suspend-and-resume-cycle-is-host-driven)).

**Try.** Add phase markers or netconsole, then use [the driver
harness](tools/driver-harness/) to flip one ciphertext bit in a zero page, a
heap page, and a code page. Then permute two valid page-table entries. Under
CTR or ECB, a code flip is a controlled patch of known plaintext.

**Decision.** A code flip that boots and executes gives PL2 code execution. A
hang on every data-page flip points to authentication.

## Boot-input race

**Where it comes from.** The FMC container is bound to the COT hash, and a
static byte change draws `0x33` ([the tampered
container](experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered)).
A statically patched GSP-RM image draws `0xaff` ([the patched
image](experiments/05_fmc-fsp-boot-inputs.md#052-patched-gsp-rm-image-rejected-by-the-fmc)).
Every test changed bytes before the read. None changed them during it, and the
hash-to-decrypt window is still open ([the boot error
codes](specs/08_errors-and-logging.md#boot-error-codes)).

**Try.** Flip the FMC header's `bodySize` or `codeSize` at high rate while
booting and watch for an error other than `0x33`. Then swap a plaintext GSP-RM
image between stock and patched copies during boot. Then alternate the
`WprMeta` bootloader, signature, and radix3 pointers between two valid copies.

**Decision.** A patched plaintext GSP-RM that boots is PL2 code execution. A
modified FMC image that boots runs at PL3 and can write the FEAT gate. A uniform
`0x33` or `0xaff` closes the race. Use [the driver
harness](tools/driver-harness/) and expect reboots.

## WPR layout

**Where it comes from.** The FMC honors `gspFwHeapSize` and does not
sanity-check it ([the heap-size
test](experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward)),
and the BAR0 PRAMIN window already reads framebuffer outside the WPR ([the FB
route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)). `fbSize`,
`nonWprHeapSize`, the ACR (the loader before the FMC) fields, and the FMC
`wprCarveout*` fields were never varied ([the WprMeta
spec](specs/01_boot-chain.md#wprmeta)).

**Try.** Vary one field per run, then read the poison boundary, the boot-image
slot, the ELF code, and the non-WPR heap after boot ([the memory
spec](specs/07_memory-and-host-access.md#wpr-and-frts-layout)).

**Decision.** A boundary that moves with a host field may leave the decrypted
boot image readable. A fixed boundary closes the field.

## Below-PLM lock

**Where it comes from.** FUSE writes drop even where the page mask reads
write-all ([the FUSE
test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)),
and FECS PL2 writes drop under masks that admit L2 ([the FECS
probe](experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)).
The FEAT drop is consistent with the L3 mask, but it has never been tested from
a level the mask admits ([the PLM
spec](specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)). The
PRO 6000 has the same PL3-only gate at full rate, so the gate is not the cap; the
fuses are ([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

**Try.** Read and write the fuse security words `0x82038c`, `0x8203f0`,
`0x8200d0`–`0x8200fc`, and `0x820040`; read the FEAT words across the FLR
(function-level reset) window.

**Decision.** If FEAT has a below-PLM lock, a PL3 payload is not sufficient.
That changes the whole plan.

## Name the writer

**Where it comes from.** The PLM re-lock is GPU-side and happens before the
first open ([the re-lock
test](experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)),
but the "PMU" (power-management microcontroller) attribution is an inference.
The reset mask admits both L2 and L3,
and the FSP is equally admitted ([the reset
window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm)).

**Try.** Poll the FSP core status, scratch, engine, and PLM alongside the FEAT
PLM across the FLR window.

**Decision.** FSP activity at the re-lock names the FSP or BootROM class. No
activity leaves the PMU or a hardware latch in play.

## Host FECS doorbell

**Where it comes from.** The FECS (graphics front-end microcode) block is
read/write-all at `0x4096d0`, and the GSP's doorbell write landed ([the FECS
probe](experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)).
Every doorbell write was GSP-mediated; the host never wrote `0x409500` or
`0x409504`, and the handler is encrypted ([the command
protocol](experiments/03_fecs-and-gr-context.md#032-the-fecs-command-protocol-statically)).

**Try.** Host-write `0x409800`, `0x409500`, and `0x409504` with readback;
replay the known-safe IDs `0x21` and `0x30`; if they execute, vary the `0x21`
feature mask and read the bank. Use [register access](tools/register-access/).

**Decision.** Dropped host writes close the path. Accepted writes make the
FECS command interface a PL0 surface.

## COT address trust

**Where it comes from.** The COT (chain-of-trust message) hash and key are
authenticated ([the key
anchor](experiments/05_fmc-fsp-boot-inputs.md#0518-cot-public-key-anchored)),
and the tampered-byte test proves the binding is to the content ([the hash
check](experiments/05_fmc-fsp-boot-inputs.md#0516-cot-hash-authenticated-auth-failure-wedges)).
The pointer fields were never varied, and a relocated second copy of the same
bytes should still verify ([the COT spec](specs/01_boot-chain.md#cot-v2)).

**Try.** Copy the stock container to a second buffer and point the COT at the
copy. Then vary the length and place it across a page boundary.

**Decision.** A boot proves the FSP trusts a host-chosen DMA address before
authentication. An auth failure closes it.

## Signature header

**Where it comes from.** The 4 KiB signature buffer is the GSP-RM
`.fwsignature` section in unprotected sysmem, and the FMC parses its header
([the signature
envelope](specs/04_firmware-formats.md#signature-envelope)). Only the
`WprMeta` (256-byte boot descriptor) size field was varied, not the buffer's
own count, stride, or size
([the bootloader
description](experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images)).

**Try.** Vary count `0xFFFF`, count 0, stride 0, size 0, one bit in the first
block, and a duplicate-buffer address.

**Decision.** A clean `0xaff` for every variant closes the parser. A new code
or a hang opens it.

## WprMeta addresses

**Where it comes from.** The `WprMeta` field matrix skipped the three pointer
fields and the FMC boot params ([the bootloader
description](experiments/05_fmc-fsp-boot-inputs.md#0523-wprmeta-bootloader-description-and-images)).
The radix3 size is bound into authentication, so the address may be consumed on
the same path.

**Try.** Relocate the bootloader, signature, and radix3 to duplicate copies;
then vary `gspRmDescSize`, `gspRmDescOffset`, `wprCarveoutOffset`, and
`wprCarveoutSize`.

**Decision.** A boot from a relocated copy proves address trust. A refusal
closes it.

## Per-SM channel

**Where it comes from.** `GR_CTX`, `TPC`, `SM`, and `QUAD` return `0x1f` with
every route ([the GR_CTX
probe](experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).
The host validation checks only the offset; the rejection comes from the GSP,
so it is a caller-identity check, not proof the space is unreachable.

**Try.** Issue the typed read with `hChannelTarget` set to a live channel owned
by the calling client; then sweep `0x504xxx` read-only and compare with the FEAT
decode.

**Decision.** A successful read makes the per-SM space live. A rejection with a
real channel closes it.

## Context patch buffer

**Where it comes from.** The patch buffer is host-owned, and the post-use
differential shows 10 changed address values in 287 entries ([the patch
differential](experiments/03_fecs-and-gr-context.md#035-the-post-use-patch-buffer-differential)).
The host can edit it after the GSP fills it and before the next use.

**Try.** Rewrite one of the 10 changed values to a valid and then an invalid
framebuffer address; observe the launch, the GSP log, and any Xid (GPU error
report).

**Decision.** A context that uses the changed address is a host-controlled
pointer into the GSP/FECS image. A clean crash closes it.

## FSP framing

**Where it comes from.** The FSP has no length field. The host controls the
transmit length through `NV_PFSP_QUEUE_TAIL(0)`, and the response identity is
unchecked ([the static FSP
pass](experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp),
[the FSP command surface](specs/01_boot-chain.md#fsp-command-surface)).

**Try.** Vary the transmit tail distance by ±1..N; send a never-EOM fragment;
craft a response with a mismatched task, tag, or SEID (source endpoint ID). Use
netconsole and a sacrificial card.

**Decision.** A new error code or state is a parser surface. A clean refusal
closes the framing.

## Readout decode

**Where it comes from.** Only bit 16 of `READOUT_0` and bits 5 and 10 of
`READOUT_2` are decoded, and A100 reads a completely different `READOUT_0`
([the readout decode](specs/03_register-map.md#readout-decode)). The PRO 6000
adds `READOUT_0 = 0x00000300` and `READOUT_2 = 1`, but the bits remain
undecoded ([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

**Try.** Decompile the `0x3814` and `0x3828` readers from the plaintext GSP-RM
and name every bit ([the GSP-RM tools](tools/gsp-rm-tools/)).

**Decision.** A rate or override-enable bit changes the target. Otherwise close
it.

## The 0x137200 register

**Where it comes from.** The GSP log contains a refused PL2 access at
`0x137200` during boot ([the sentinel
analysis](experiments/08_assessment-and-cross-checks.md#089-sentinel-and-raw-function-analysis)).
The register is not identified ([the sentinel
spec](specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)).

**Try.** Probe `0x137200` and its neighbours from the host and the GSP; record
the PLM and sentinels; search the headers and vBIOS for the address.

**Decision.** A security or handshake register is a lead. An unrelated power
register is not.

## Ada payload from PL2

**Where it comes from.** The PL2 test wrote `SS0 = 0`; it never wrote the exact
payload `0x88888888` and `0x8` ([the FUSE and rate
test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
The mask predicts a drop. The two PRO 6000s run full rate with every enable bit
clear, so the override may be unused on Blackwell ([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).

**Try.** Write `SS0 = 0x88888888` and `SS1 = 0x8` from the GSP, read back, and
restore.

**Decision.** A drop closes the record. A change is the unlock.

## vBIOS ucode corpus

**Where it comes from.** The vBIOS carries four encrypted ucode images, the
likely FECS/GPCCS (graphics front-end and context-switch microcode) consumer
([the microcode table](specs/05_vbios-and-devinit.md#microcode-table)). The FMC
key search targeted the FMC and the SEC2 booter, not these ([the key
search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).

**Try.** Map the app/target IDs to the loaders in the GSP-RM; check whether the
bodies share the FMC key family; if they are Falcon FUC5, build a Falcon
parcels oracle ([the FMC tools](tools/fmc-tools/)).

**Decision.** A decoded consumer answers what the selector does and whether a
command sets it. High effort, no hardware.

## Closed, do not retry

- The all-zero full-rate target. Two PRO 6000s read `FEAT_READOUT_1 = 0` with
  every arithmetic speed fuse at 0; one runs BF16 at 518 TF/s. Do not re-plan
  around the A100 inference ([the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- More 16! MD5-IV key passes. The family is exhausted under ECB, CBC-zero and
  header-IV, and CTR starts 0 and 1 ([the key
  search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).
- FUSE-shadow writes. Dropped from PL0 and PL2 ([the FUSE
  test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
- ICD write memory. The public header defines read and control opcodes only
  ([the live ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).
- Direct PL2 FEAT or PLM writes. Dropped by the mask ([the write
  test](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)).
- Registry speed keys. Parsed, stored, booleanized, inert ([the registry
  sweep](experiments/02_registry-and-static-audit.md#024-speed-select-keys-are-inert-on-hardware)).
- BAR1 and physical address `0x5dd00000`. Structurally closed ([the FB
  route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)).

---

This page contains no exploit. Every mutating run needs a stock restore and an
expected reboot.
