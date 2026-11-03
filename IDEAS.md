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
- The public record reproduces the drop on GB202 and GB203M before the driver
  binds and places the missing primitive at PL3 code execution in the security
  firmware ([the external
  cross-check](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).
- The full-rate readout is measured: two RTX PRO 6000s read
  `FEAT_READOUT_1 = 0` with every arithmetic speed fuse at 0. The
  override-enable fuses are measured on both product classes — two 5090s, two
  PRO 6000s — and every card reads `FUSE_EN_SW_OVERRIDE = 0`, so the
  software-override path is fused off on this generation and the unlock target
  is the fuse words, not a live override ([the debugger
  group](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read),
  [the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- The cold-boot parser map is measured. The [FMC parser
  group](experiments/09_fmc-cold-boot-parsers.md) varied every host field and
  buffer byte the FMC consumes; the result is a bounded parser, and no
  authentication bypass appeared.
- The CUDA debugger class is exposed and reads the FEAT bank, the GR context,
  and the `0x137000` block; its FEAT write drops like the host and GSP paths
  ([the debugger group](experiments/10_debugger-class-and-fecs-ucode.md)).
- The readout decode is closed: every RM consumer of `FEAT_READOUT_0` and
  `FEAT_READOUT_2` is an ECC capability flag, clear on all four measured
  cards, so `READOUT_1` is the only selector carrier
  ([the readout decode](experiments/12_feat-readout-decode.md)).
- The fwimage is a libos container: about 18.5 MB of plaintext and a 53.8 MB
  encrypted `rm.bindata.bin` that holds the engine ucode behind per-blob
  SEC2 key derivation. The decrypted FECS/GPCCS ucode transits RM memory at
  boot, so a timed capture reads it without the key
  ([the fwimage map](experiments/13_fwimage-map-and-bindata.md)).
- The FECS, GPCCS, and PMU falcon bases return decode or not-implemented
  markers, and the GR window the GSP-RM admits is empty. The host has no FECS
  code or state window ([the falcon probe](experiments/11_falcon-and-gr-window-probe.md)).
- The space above that window is decode refusals plus the vBIOS ROM at
  `0x300000`–`0x4fffff` and one per-card table at `0x1f2000`–`0x1f3fff`. Neither
  is GR ucode ([the GR
  map](experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom)).
- The vBIOS table is the PMU lookup table, the two target-`0x01` images are not
  FECS/GPCCS, and no component in the open stack reads the table on GB202
  ([the table
  decode](experiments/11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table),
  [the consumer
  record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
- The remaining PL3 parsers are the [suspend/resume
  descriptor](#sr-descriptor-and-page-table) and the [FSP
  framing](#fsp-framing). The SR harness now has a relative radix3 address and
  disk phase markers.
- The rest are foothold probes, cheap reads, and offline questions. The
  override payload (C04) becomes relevant only after a writer exists.

## The index

Rows are ordered by the decision each one buys. The staged-ucode capture sits
first because it settles the fork everything else depends on; the rest are
ordered by whether the lead can produce the PL3 primitive, not by cost.

| ID | Lead | What it tests | Cost | Decision value |
|---|---|---|---|---|
| C26 | [Staged-ucode capture](#staged-ucode-capture) | Can the decrypted FECS/GPCCS ucode be read out of RM memory at boot? | 1–2 days | Settles whether any PL3 plan can work |
| C01 | [SR descriptor and page table](#sr-descriptor-and-page-table) | Can a malformed resume descriptor or PTE steer the parser? | 1–2 days | PL3 code execution |
| C02 | [Carveout layout fields](#carveout-layout-fields) | Do the ACR and `wprCarveout*` fields move the protected layout? | 1 day | Layout lever |
| C20 | [Boot-input race](#boot-input-race) | Is there a hash-to-use window? | 1–2 days | PL2 or PL3 code execution |
| C13 | [FSP framing](#fsp-framing) | Is the ROM's message parser weak at the framing layer? | 2–3 days | PL3 parser surface |
| C11 | [Context patch buffer](#context-patch-buffer) | Can the host edit a GSP-consumed pointer list? | 1 day | PL2 write primitive |
| C19 | [SR saved-state malleability](#sr-saved-state-malleability) | Is the saved ciphertext malleable? | 1 day | PL2 foothold |
| C05 | [Below-PLM lock](#below-plm-lock) | Does a PL3 write even suffice? | 1 hour | Prerequisite for any PL3 plan |
| C12 | [Host FECS doorbell](#host-fecs-doorbell) | Can the host command FECS? | 1 hour | PL0 consumer interface |
| C17 | [Ada payload from PL2](#ada-payload-from-pl2) | Does the exact payload take a different gate? | minutes | Completes the record |
| C06 | [Name the writer](#name-the-writer) | Is the re-lock FSP or PMU? | 1 hour | Names the pre-lock actor |
| C10 | [Per-SM channel](#per-sm-channel) | Is per-SM reachable with a real channel? | 1–2 days | Last non-PL3 register space |
| C03 | [vBIOS app 0x23](#vbios-app-0x23) | Is the plaintext data tail a devinit template? | offline decode | Only direct-unlock candidate |
| C04 | [Override payload](#override-payload-format) | Does the SS0/SS1 override set full rate? | 1 PRO cold-boot series | Validates a writer, not a route |
| C22 | [vBIOS ucode key search](#vbios-ucode-key-search) | Do the encrypted devinit bodies decrypt under the FMC key family? | offline, days | May name the FEAT writer |
| C23 | [Computed-offset sweep and devinit handlers](#computed-offset-sweep-and-devinit-handlers) | Do computed-offset references to the rate registers exist in the plaintext GSP-RM? | offline, days | Closes the no-RM-writer claim |
| C24 | [Boot-args buffer](#boot-args-buffer) | Is the fourth host-built boot structure parsed with checks? | 1–2 days | Live input, mapped or not |
| C25 | [ICD write opcodes](#icd-write-opcodes) | Does the halted-core debug port accept a write opcode? | 1 hour | PL2 code-modification foothold |
| C18 | [vBIOS ucode corpus](#vbios-ucode-corpus) | Which stack consumes the vBIOS bodies? | days | Low, closed here |

## Measured: the cold-boot parser map

The [boot-input parser group](experiments/09_fmc-cold-boot-parsers.md) varied
every host field and buffer byte the FMC consumes at cold boot. The result is a
bounded parser; no primitive appeared. The check order and section layout are in
[the parser spec](specs/09_fmc-parsers.md).

- The [bootloader size](experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length)
  is a 4 KiB alignment check. Aligned values set the authentication length, and
  256 MiB hits a size limit. There is no exact-length check.
- The [signature section](experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records)
  is a header, four slots, and a table. Slots 0 and 1 are verified; slots 2 and
  3 are not.
- The [record size](experiments/09_fmc-cold-boot-parsers.md#093-the-signature-record-size-is-a-bounded-window)
  must be in `[0x180, 0x200]`; above it is a bounds refusal. The header words at
  `+0x00`, `+0x04`, `+0x08`, and `+0x0c` are ignored on the stock path.
- The [table tail](experiments/09_fmc-cold-boot-parsers.md#094-the-signature-table-and-mode-fields-are-validated)
  is a mode with the valid set `{1,2}`; the length and flag fields at `0x880`
  and `0x884` are bound into image authentication.
- The [bootloader and radix3 addresses](experiments/09_fmc-cold-boot-parsers.md#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth)
  are pinned (`0xaff` and `0x83e`). The [signature
  address](experiments/09_fmc-cold-boot-parsers.md#096-the-signature-address-is-a-4-byte-aligned-pointer)
  is a 4-byte-aligned pointer with a magic check; it reads the host buffer at
  the chosen address, but that is the buffer the host already controls.
- The [revision and manifest
  offset](experiments/09_fmc-cold-boot-parsers.md#098-the-revision-and-manifest-offset-are-exact-checks)
  are exact; `fbSize` is inert.
- The [image bytes](experiments/09_fmc-cold-boot-parsers.md#099-the-bootloader-image-bytes-are-authenticated-end-to-end)
  are all behind image authentication.
- The [non-WPR heap size](experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever)
  is a 1:1 layout lever from a fixed WPR base; it does not expose the WPR.

What remains from this group: the second-buffer signature test, the `0x836`
boundary, the mode-2 record layout, and the [carveout
fields](#carveout-layout-fields). None has a run behind it.

## SR descriptor and page table

**Where it comes from.** The host builds [`SRMeta`](specs/01_boot-chain.md#suspendresume)
in unprotected memory and the FMC is handed it on resume instead of `WprMeta`
([the host-driven
cycle](experiments/06_sr-resume.md#061-the-suspend-and-resume-cycle-is-host-driven)).
The descriptor carries `sysmemAddrOfSuspendResumeData` and
`sizeOfSuspendResumeData`, and the radix3 page table is plaintext and fully
mapped ([the
radix3](experiments/06_sr-resume.md#064-the-radix3-is-plaintext-and-fully-mapped)).
Only the magic was varied; a wrong value hangs the resume
([the bad-magic
test](experiments/06_sr-resume.md#062-a-bad-srmeta-magic-hangs-the-resume)).
The size, the pointer, the flags, and the PTE values are host-controlled and
untested.

**Try.** The [driver harness](tools/driver-harness/) now has field 6 (radix3
address plus a delta) and disk phase markers (`phase_loaded`,
`phase_pre_suspend`, `phase_post_resume`). A failed resume leaves the
pre-suspend marker and no post-resume marker. Run the stock control first, then
`revision` (0, 1, 3), `flags` (1, 2), `sizeOfSuspendResumeData` (stock, half,
16 MiB), and radix3 deltas. Then a PTE that points at a duplicate page, a PTE
that crosses a 4 MiB run boundary, and an unmapped entry.

**Decision.** A resume that completes with a changed size or pointer, or a new
hang point, is a parser surface. Heavy Secure validating the PTEs before walking
them closes the table. Every failed variant costs a reboot.

## Carveout layout fields

**Where it comes from.** The two heap-size levers are measured: `gspFwHeapSize`
moves the WPR downward ([the heap-size
test](experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward)),
and `nonWprHeapSize` grows the unprotected heap 1:1 from a fixed WPR base
([the non-WPR heap
test](experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever)).
The ACR (the loader before the FMC) fields and the FMC `wprCarveout*` fields in
the boot parameters were never varied ([the boot-parameter
print](experiments/05_fmc-fsp-boot-inputs.md#051-host-side-boot-and-static-info-instrumentation)).

**Try.** Vary one ACR or carveout field per boot and read the GSCI layout. Then
a field that moves the WPR start or the FRTS anchor.

**Decision.** A boundary that moves with a host field is a layout lever. A fixed
boundary closes the fields.

## Boot-input race

**Where it comes from.** The FMC container is bound to the COT hash, and a
static byte change draws `0x33`
([the tampered
container](experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered)).
The GSP-RM and bootloader images are bound the same way and draw `0xaff`
([the patched
image](experiments/05_fmc-fsp-boot-inputs.md#052-patched-gsp-rm-image-rejected-by-the-fmc)).
Every test changed bytes before the read. None changed them during it, and the
hash-to-decrypt window is still open
([the container
record](experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered)).

**Try.** The [cold-boot map](experiments/09_fmc-cold-boot-parsers.md) shows the
image bytes are behind authentication and the bootloader and radix3 pointers are
pinned. The race is the remaining way past the image hash. Flip the FMC header's
`bodySize` or `codeSize` at high rate while booting and watch for an error other
than `0x33`. Then swap a plaintext GSP-RM image between stock and patched copies
during boot. Then alternate the `WprMeta` bootloader and radix3 pointers between
two valid copies.

**Decision.** A patched plaintext GSP-RM that boots is PL2 code execution. A
modified FMC image that boots runs at PL3 and can write the FEAT gate. A uniform
`0x33` or `0xaff` closes the race. Use [the driver
harness](tools/driver-harness/) and expect reboots.

## FSP framing

**Where it comes from.** The FSP has no length field. The host controls the
transmit length through `NV_PFSP_QUEUE_TAIL(0)`, and the response identity is
unchecked ([the static FSP
pass](experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp),
[the FSP command surface](specs/01_boot-chain.md#fsp-command-surface)). The FSP
is immutable ROM, so this is a black-box parser probe.

**Try.** Vary the transmit tail distance by ±1..N; send a never-EOM fragment;
craft a response with a mismatched task, tag, or SEID (source endpoint ID). Use
netconsole and a sacrificial card.

**Decision.** A new error code or state is a parser surface. A clean refusal
closes the framing.

## Boot-args buffer

**Where it comes from.** The host builds three boot structures that secure
firmware parses: the COT, `WprMeta`, and `SRMeta`. The COT also carries a
GSP boot-args sysmem pointer ([the COT](specs/01_boot-chain.md#cot-v2)) — a
fourth host-built buffer. The cold-boot group varied every `WprMeta` field
and the boot-buffer geometry ([the parser
group](experiments/09_fmc-cold-boot-parsers.md)); the boot-args buffer itself
was never varied, and which stage consumes it is part of the question.

**Try.** Add a boot-args oracle to [the driver
harness](tools/driver-harness/): stock control first, then one field per boot
— the size, the flags, the per-engine offsets, and a moved pointer. Watch for
a structured error, a hang, or a GSP log line.

**Decision.** A bounded parser with clean refusals closes the buffer. A hang
or a structured error is a new parser surface in the same class as [the SR
descriptor](#sr-descriptor-and-page-table) — a foothold probe, not a selector
route.

## Context patch buffer

**Where it comes from.** The patch buffer is host-owned, and the post-use
differential shows 10 changed address values in 287 entries
([the patch
differential](experiments/03_fecs-and-gr-context.md#035-the-post-use-patch-buffer-differential)).
The host can edit it after the GSP fills it and before the next use.

**Try.** Rewrite one of the 10 changed values to a valid and then an invalid
framebuffer address; observe the launch, the GSP log, and any Xid (GPU error
report).

**Decision.** A context that uses the changed address is a host-controlled
pointer into the GSP/FECS image. A clean crash closes it. A working pointer is a
PL2 write primitive and changes what C01 and C13 can observe.

## SR saved-state malleability

**Where it comes from.** The saved state is encrypted, but the log only tests
confidentiality: entropy and a scan for known constants
([the saved
state](experiments/06_sr-resume.md#063-the-saved-state-is-high-entropy-ciphertext)).
It never flips a bit. The state spans the WPR through the GSP-RM heap and code,
and the host builds the radix3
([the host-driven
cycle](experiments/06_sr-resume.md#061-the-suspend-and-resume-cycle-is-host-driven)).

**Try.** Use [the driver harness](tools/driver-harness/) to flip one ciphertext
bit in a zero page, a heap page, and a code page, then permute two valid
page-table entries. Under CTR or ECB, a code flip is a controlled patch of known
plaintext.

**Decision.** A code flip that boots and executes gives PL2 execution, a
foothold rather than the selector. A hang on every data-page flip points to
authentication. Run this only after C01, because a descriptor bug is the
stronger route.

## Below-PLM lock

**Where it comes from.** FUSE writes drop even where the page mask reads
write-all ([the FUSE
test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)),
and FECS PL2 writes drop under masks that admit L2
([the FECS
probe](experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)).
The FEAT drop is consistent with the L3 mask, but it has never been tested from
a level the mask admits ([the PLM
spec](specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)).
The PRO 6000 has the same PL3-only gate at full rate, so the gate is not the
cap; the fuses are ([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
The public record places the older unlock at HS code execution, which is the
only level the mask admits ([the external
cross-check](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).

**Try.** Read and write the fuse security words `0x82038c`, `0x8203f0`,
`0x8200d0`–`0x8200fc`, `0x820040`, and `0x820084`; read the FEAT words across
the FLR (function-level reset) window.

**Decision.** The reads show whether a separate secure-write qualification
exists below the PLM, one that a future PL3 exploit would also have to satisfy.
They cannot prove sufficiency; only a passing PL3 write can. Treat a closed
qualification as a prerequisite, not a route.

## Host FECS doorbell

**Where it comes from.** The FECS (graphics front-end microcode) block is
read/write-all at `0x4096d0`, and the GSP's doorbell write landed
([the FECS
probe](experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)).
Every doorbell write was GSP-mediated; the host never wrote `0x409500` or
`0x409504`, and the handler is encrypted
([the command
protocol](experiments/03_fecs-and-gr-context.md#032-the-fecs-command-protocol-statically)).

**Try.** Host-write `0x409800`, `0x409500`, and `0x409504` with readback;
replay the known-safe IDs `0x21` and `0x30`; if they execute, vary the `0x21`
feature mask and read the bank and the issue rate. Use [register
access](tools/register-access/) and [the issue-rate
probe](tools/issue-rate-probe/). Only `0` and `1` were ever written to the
doorbell, and `0x409504` is read-blocked but was never write-tested — the write
path may differ from the read path. The command-ID injection is the missing
step: the live probes mapped the protocol statically but never pushed an
attacker-chosen ID through it.

**Decision.** Dropped host writes close the path. Accepted writes make the
FECS command interface a PL0 surface, and the mask sweep answers whether a
command can select the rate.

## ICD write opcodes

**Where it comes from.** The PRISCV ICD is a live host debug port: after a
halt, `RREG`, `RCSR`, and `RDM` read the RM code segment byte-exact
([the live ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).
The write-memory closure rests on the public header's opcode list — the
driver's API, not the hardware command set — and no write opcode was ever
sent. The halt harness already exists in [the driver
harness](tools/driver-harness/).

**Try.** While halted, send the write-opcode candidates around the known read
commands, read back, and restore.

**Decision.** A refused opcode confirms the header list and closes the port.
A write that lands is a code-modification primitive over the RM segment at
PL2 — the same foothold class as [the SR saved
state](#sr-saved-state-malleability), and it would let the [readout
decode](experiments/12_feat-readout-decode.md) be checked against live
state.

## Ada payload from PL2

**Where it comes from.** The PL2 test wrote `SS0 = 0`; it never wrote the exact
payload `0x88888888` and `0x8` ([the FUSE and rate
test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
The mask predicts a drop. The two PRO 6000s run full rate with every enable bit
clear, so the override may be unused on Blackwell
([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
The override-enable fuses now bound the read: `FUSE_EN_SW_OVERRIDE` reads `0`
on both 5090s as well ([the debugger
group](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read)),
so the override path is not fuse-enabled on this generation.

**Try.** Write `SS0 = 0x88888888` and `SS1 = 0x8` from the GSP, read back, and
restore.

**Decision.** A drop is expected twice over — the mask and the fuse disable
both predict it — so it closes the record but not the fuse question. A change
is the unlock.

## Name the writer

**Where it comes from.** The PLM re-lock is GPU-side and happens before the
first open ([the re-lock
test](experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)),
but the "PMU" (power-management microcontroller) attribution is an inference.
The reset mask admits both L2 and L3,
and the FSP is equally admitted ([the reset
window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm)).

**Try.** Poll the FSP core status, scratch, engine, and PLM alongside the FEAT
PLM across the FLR window. The offline side is already negative: the GSP-RM
literal scan over the rate registers, the PLM included, came back empty
([the static
audit](experiments/02_registry-and-static-audit.md)), so the writer is not RM
code; a computed-offset re-check would close the residual doubt
([C23](#computed-offset-sweep-and-devinit-handlers)).

**Decision.** FSP activity at the re-lock names the FSP or BootROM class. No
activity leaves the PMU or a hardware latch in play.

## Computed-offset sweep and devinit handlers

**Where it comes from.** The static audit scanned the plaintext region of the
GSP-RM image — about 18.5 MB of the 72.8 MB file; the rest is encrypted
([the plaintext
boundary](experiments/13_fwimage-map-and-bindata.md#132-the-plaintext-boundary))
— for references to the six rate registers and found zero literal hits; the
computed-offset correction was applied to the `0x3814` decoder only
([the static audit](experiments/02_registry-and-static-audit.md)). Runtime
base-plus-offset and table-indexed forms were never swept, so the no-RM-writer
claim rests on the literal pass. The devinit app-ID loaders and the
`0x8238b0` and `0x9668` consumers are also unmapped in the image
([the register map](specs/03_register-map.md#limits-and-open-questions)).

**Try.** Use [the GSP-RM tools](tools/gsp-rm-tools/) to sweep the image for
computed references to `0x823804`, `0x82381c`, `0x823820`, `0x8207d8`, and
`0x504204`, then name the devinit app-ID handlers and the small-object
consumers.

**Decision.** A computed reference reopens the no-RM-writer claim and feeds
[name the writer](#name-the-writer). An empty sweep leaves the devinit
attribution resting on the live poll alone.

## Per-SM channel

**Where it comes from.** `GR_CTX`, `TPC`, `SM`, and `QUAD` return `0x1f` with
every subdevice route ([the GR_CTX
probe](experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).
The host validation checks only the offset; the rejection comes from the GSP,
so it is a caller-identity check, not proof the space is unreachable.
The CUDA debugger class has the channel context the RM path lacked. Its
`GR_CTX` reads the space; `TPC`/`SM`/`QUAD` still return `regStatus=2`, and the
space has no FEAT-selector mirror. The only rate register is the inert
`0x504204` ([the context
record](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read)).

**Try.** The remaining piece is the typed read with `hChannelTarget` set to a
live channel, and a per-SM offset under a valid group/subgroup mask. The
`0x504xxx` sweep is done.

**Decision.** The space is readable; it is not a rate lever. A per-SM offset
that changes with the selector would reopen it; the inert `0x504204` and the
`0x504240` table do not.

## Staged-ucode capture

**Where it comes from.** The engine ucode lives in `rm.bindata.bin`, encrypted
with per-blob keys that SEC2 derives in High-Secure mode; the plaintext parts
are the load descriptors, not the code
([the blob
directory](experiments/13_fwimage-map-and-bindata.md#135-the-generic-header-blob-directory)).
But the boot capture shows the RM starting GR through `sec2_acr` with
RM-memory pointers ([the consumer
record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)),
and the debug engine reads RM memory byte-exact after a halt
([the live ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).
The decrypted FECS/GPCCS ucode therefore transits RM-visible memory between
SEC2's decrypt and the falcon's IMEM load
([the transit
record](experiments/13_fwimage-map-and-bindata.md#136-the-decrypted-ucode-transits-rm-memory)).

**Try.** Time a read against the `sec2_acr` window. Arm the driver harness's
samplers or a direct probe around GR boot, halt the GSP through the debug
engine at the staged point, and dump the staging buffers. Identify the GR
blobs by their load maps first — one header maps a `0x400` data segment and a
`0xbe00` code image at `0xf900` — then search the captured image for the FEAT
bank words (`0x8238xx` family) and the fuse words. Use [the driver
harness](tools/driver-harness/) and [the GSP-RM
tools](tools/gsp-rm-tools/); expect a hang-and-reboot budget.

**Decision.** If the captured FECS code reads the FEAT bank, the PL3 program
is validated and the capture names the exact words a PL3 write must set. If it
does not, the enforcement is silicon-side and no firmware route changes the
rate — the honest stopping condition for the register program. The staging
buffer's lifetime is the unknown; the first run measures it.

## vBIOS app 0x23

**Where it comes from.** The app `0x23` data tail is the only vBIOS artifact
carrying the exact FEAT PLM (privilege-level mask) values, in low-entropy
sentinel-structured data ([the devinit
scan](experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan)).
The devinit tables and scripts are authenticated in Heavy Secure and bound to
the device ID, so a host edit does not reach the GPU-side devinit
([the devinit authentication](specs/05_vbios-and-devinit.md#devinit-authentication)).

**Try.** Decode the data as a 4-byte-stride array against the live block maps
([the FEAT bank](specs/03_register-map.md#feat-bank)). Map the four ucode
app/target IDs to their loaders in the GSP-RM
([the microcode table](specs/05_vbios-and-devinit.md#microcode-table)). This is
an offline task; the earlier boot-edit idea is not a pre-lock template.

**Decision.** A decoded write table or loader mapping opens the data tail. A
plain configuration table closes it. Use [the vBIOS tools](tools/vbios-tools/)
for the dump and parse.

## Override payload format

**Where it comes from.** The full-rate readout and fuse target is measured on
two RTX PRO 6000s: both read `FEAT_READOUT_1 = 0` with every arithmetic speed
fuse at 0, and card A runs BF16 at 518 TF/s with the FP16-accumulate rate equal
([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
Both cards also have every `SS0`/`SS1` enable bit clear, so the full rate comes
from the fuses, not a live override — and the override path is not fuse-enabled
on this generation, so the payload is not the plan
([the closed list](#closed-do-not-retry)). The override payload format is a
post-writer question: without a write that passes the PLM, no boot series can
validate it.

**Try.** Run the existing FP16-accumulate mode on the 5090 to measure its cap
ratio locally ([the issue-rate probe](tools/issue-rate-probe/)). Get a same-card
cold-boot series on a PRO 6000 and compare `SS0`/`SS1` movement with the 5090's
([the FEAT-bank boot
test](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
The 2026-10-31 rentals captured only the register banks and the issue rate —
add the PRO 6000's vBIOS and GSP-RM image to the same session, so [vBIOS app
0x23](#vbios-app-0x23) and [the vBIOS ucode key search](#vbios-ucode-key-search)
get the full-rate card's corpus. Run the exact payload only after a PL3 writer
exists.

**Decision.** If a PRO boot shows an enable bit, that is the payload. Otherwise
the words are runtime state and the payload stays unvalidated. Fold the
cold-boot series into a future PRO rental; do not plan a run around it.

## vBIOS ucode corpus

**Where it comes from.** The vBIOS carries four encrypted ucode images. The
table is the PMU lookup table and target `0x01` is PMU in the only public
mapping, so the two target-`0x01` bodies are a PMU-family pair, not FECS/GPCCS
([the table
decode](experiments/11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table)).
All four descriptors are version 6, `0x50` bytes. The stored size equals the body
length, and the two target-`0x01` images share a plaintext preamble
([the bodies](experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)).
The FMC key search targeted the FMC and the SEC2 booter, not these
([the key search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).

**What closed.** No component in the open stack reads the table on GB202. The
host FWSEC loader is the only parser, it accepts apps `0x05`/`0x45`/`0x85` and
descriptor versions 2 and 3, and the Blackwell chip binding maps the VBIOS
extraction to a stub returning `NV_ERR_NOT_SUPPORTED`, which the init path
treats as success. The GSP-RM has no BIT parser, and the RM boot log starts GR
through `sec2_acr` with RM-memory pointers ([the consumer
record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
The four bodies are not GR ucode on this card.

**Try.** Identify target `0x0E` and find the consumer in another stack, such as
the Windows driver or the device firmware. Check the encrypted bodies against
the FMC key family. The Falcon parcels oracle only matters after a FECS/GPCCS
consumer is named ([the FMC tools](tools/fmc-tools/)).

**Decision.** The corpus is closed for the Linux open-driver route. Only a
consumer in a different stack would reopen it. Low value, offline.

## vBIOS ucode key search

**Where it comes from.** The 16! key search targeted the FMC and SEC2 booter
containers only ([the key
search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).
The four encrypted vBIOS bodies — the two PMU-family target-`0x01` images, app
`0x23`, and target `0x0E` — were never searched, and the PMU devinit is the
leading FEAT-writer candidate ([name the writer](#name-the-writer)). The two
target-`0x01` bodies share a plaintext preamble
([the bodies](experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)),
a known-plaintext structure the FMC oracle was not built to exploit. The
search's own leftovers are also unrun: the ~1.9 h intermediate round keys 1–9,
and the XTS and compressed-then-ECB modes the ECB, CBC, and CTR passes did not
cover. A third corpus exists now: `rm.bindata.bin` holds the engine ucode
behind per-blob AES, but the keys are derived inside SEC2's High-Secure
ucode, not embedded in the image
([the secure-data
unit](experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)),
so an offline search there attacks a derivation, not a stored key.

**Try.** Point [the FMC tools](tools/fmc-tools/) at the four vBIOS bodies and
the encrypted PROM head blob: the exhausted permutation family under the
tested modes first, then the intermediate round keys, then the untested
modes. Add a known-plaintext oracle around the shared target-`0x01`
preamble. For the bindata corpus, use the 66 plaintext headers and the
structured block at `0x3cbc000` as known plaintext
([the blob
directory](experiments/13_fwimage-map-and-bindata.md#135-the-generic-header-blob-directory)).

**Decision.** A decrypted PMU body names the pre-lock writer and may carry
the FEAT write table — it feeds [name the writer](#name-the-writer) and
[vBIOS app 0x23](#vbios-app-0x23) at once. A negative result extends the FMC
conclusion to the vBIOS corpus and closes the decrypt route for good. For the
bindata corpus, weigh the search against [the staged-ucode
capture](#staged-ucode-capture) first: the capture reads the same code with
no key at all.

## Closed, do not retry

- The flanking readouts as a target. Every RM consumer of `FEAT_READOUT_0`
  and `FEAT_READOUT_2` is an ECC capability flag with a config-byte fallback,
  clear on both 5090s and both PRO 6000s; the bits that differ between the
  product classes have no reader in the image, and the three reader slots
  without callers cannot gate anything
  ([the readout decode](experiments/12_feat-readout-decode.md)). `READOUT_1`
  is the only selector carrier. Do not re-plan around the other readouts.
- The all-zero full-rate target. Two PRO 6000s read `FEAT_READOUT_1 = 0` with
  every arithmetic speed fuse at 0; one runs BF16 at 518 TF/s. Do not re-plan
  around the A100 inference ([the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- Planning around the `SS0`/`SS1` override payload as the unlock mechanism.
  Every measured GB202 card — two 5090s, two PRO 6000s — reads
  `FUSE_EN_SW_OVERRIDE = 0`: the override path is not fuse-enabled on this
  generation, so the payload faces a fuse disable before the PLM ([the
  debugger
  group](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read),
  [the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
  The cheap payload write ([Ada payload from PL2](#ada-payload-from-pl2))
  still completes the record; it is not the plan.
- More 16! MD5-IV key passes. The family is exhausted under ECB, CBC-zero and
  header-IV, and CTR starts 0 and 1; the untested modes and the intermediate
  round keys live in [the vBIOS ucode key
  search](#vbios-ucode-key-search) ([the key
  search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).
- FUSE-shadow writes. Dropped from PL0 and PL2 ([the FUSE
  test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
- ICD write memory, as a driver-API claim. The public header defines read and
  control opcodes only; the hardware check is [the one-hour opcode
  probe](#icd-write-opcodes), not a retry of the read path ([the live
  ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).
- Direct PL2 FEAT or PLM writes. Dropped by the mask ([the write
  test](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)).
- Registry speed keys. Parsed, stored, booleanized, inert ([the registry
  sweep](experiments/02_registry-and-static-audit.md#024-speed-select-keys-are-inert-on-hardware)).
- BAR1 and physical address `0x5dd00000`. Structurally closed ([the FB
  route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)).
- CUDA debugger-class FEAT writes. The class reads the bank and the write drops
  ([the debugger
  test](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- Reading FECS/GPCCS code or state from the host. The FECS, GPCCS, and PMU falcon
  bases return decode or not-implemented markers, the security engines block
  their boot vectors, and the GR window the GSP-RM admits is empty. The space
  above it is the vBIOS ROM and one per-card table, not ucode ([the falcon
  probe](experiments/11_falcon-and-gr-window-probe.md), [the
  window](experiments/11_falcon-and-gr-window-probe.md#112-the-admitted-gr-window-is-empty),
  [the GR
  map](experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom)).
- Reading ucode through the vBIOS table on GB202. The host FWSEC path is
  chip-gated to a stub and the RM boots GR through `sec2_acr` from RM memory
  ([the consumer
  record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
- The `0x137200` lead. It is a privilege-protected FECS/GR register
  (`0xc120048a` in a `0x30`-byte entry pattern); the FECS log pairs it with
  `0x14252215` and the refusal `0xbadf5128` ([the descriptor
  record](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read)).
- JTAG pads. Production parts gate them with secure-debug fuses and signed
  unlock tokens; no public GeForce success exists. The retail card's class list
  exposes the debugger class instead, and its FEAT write drops ([the debugger
  group](experiments/10_debugger-class-and-fecs-ucode.md)).

---

This page contains no exploit. Every mutating run needs a stock restore and an
expected reboot.
