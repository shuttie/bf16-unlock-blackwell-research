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
- The FECS command mailbox is a host (PL0) surface. BAR0 writes to `0x409500`
  and `0x409504` execute a command, and the completion echo lands at
  `0x409800`; the known `0x21` command does not move the bank or the rate, and
  an unassigned ID fatal-errors the FECS, so the encrypted command table cannot
  be swept ([the host command
  record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).
- The exact override payload is dropped from PL2, and the rate does not move
  ([the payload
  test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).
- The FLR re-lock at 1353 ms moves only `FUSE_SS_PLM` and no FSP register; the
  PMU or a hardware latch remains ([the re-lock
  record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).
- The public record reproduces the drop on GB202 and GB203M before the driver
  binds and places the missing primitive at PL3 code execution in the security
  firmware ([the external
  cross-check](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).
- The full-rate readout is measured: two RTX PRO 6000s read
  `FEAT_READOUT_1 = 0` with every arithmetic speed fuse at 0. The target is
  the live `SS0`/`SS1` override, not the fuse words: `FUSE_FEAT_OVR_DIS`
  reads 0 on every measured card, and the CMP 170HX reaches full rate with
  `FUSE_EN_SW_OVERRIDE` also at 0 ([the two override
  paths](specs/02_privilege-and-rate-control.md#the-two-override-paths),
  [the debugger
  group](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read),
  [the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- The cold-boot parser map is measured. The [FMC parser
  group](experiments/09_fmc-cold-boot-parsers.md) varied every field it
  reached; the result is bounded on those paths, and no authentication bypass
  appeared. The unrun paths are in [the parser map](#measured-the-cold-boot-parser-map).
- The CUDA debugger class is exposed and reads the FEAT bank, the GR context,
  and the `0x137000` block; its FEAT write drops like the host and GSP paths
  through the register-op command. The class's other commands, including the
  memory reads and SM error-state dumps, were never issued ([the debugger
  group](experiments/10_debugger-class-and-fecs-ucode.md), [the command
  census](#debugger-class-command-census)).
- The readout decode is closed: every RM consumer of `FEAT_READOUT_0` and
  `FEAT_READOUT_2` is an ECC capability flag, clear on all four measured
  cards, so `READOUT_1` is the only selector carrier
  ([the readout decode](experiments/12_feat-readout-decode.md)).
- The fwimage is a libos container: about 18.5 MB of plaintext and a 53.8 MB
  encrypted `rm.bindata.bin` that holds the engine ucode behind per-blob
  SEC2 key derivation. The blob census names two `0xf900` code-load blobs as
  the GR-falcon shape, and the timed-capture lead through the ICD is closed:
  the `sec2_acr` args are a timeout pair, and the ICD reads the code segment
  only ([the fwimage map](experiments/13_fwimage-map-and-bindata.md),
  [the aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
  The EMEM and DMEM ports were sampled only at steady state, so [the timed
  port capture](#timed-emem-and-dmem-capture) is still unrun.
- The FECS, GPCCS, and PMU falcon bases return decode or not-implemented
  markers at the documented bases, and the GR window the GSP-RM admits is
  empty. The host has no FECS code or state window there; the PMU base is
  unknown, so [the engine map is
  incomplete](#engine-map-completion) ([the falcon
  probe](experiments/11_falcon-and-gr-window-probe.md)).
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

Rows are ordered by the decision each one buys. Session A measured the FECS
doorbell, the below-PLM read, the writer name, and the PL2 payload; they are in
[Measured in Session A](#measured-in-session-a) and out of the open ranking.
The first open row is now C01: the FECS command set has no selector and the
unknown-ID path is fatal, so the SR page table is the cheapest remaining path
to the PL3 primitive. The rest are ordered by whether the lead can produce the
PL3 primitive, not by cost.

| ID | Lead | What it tests | Cost | Decision value |
|---|---|---|---|---|
| C01 | [SR descriptor and page table](#sr-descriptor-and-page-table) | Can a malformed resume descriptor or PTE steer the parser? | 1–2 days | PL3 code execution |
| C02 | [Carveout layout fields](#carveout-layout-fields) | Do the ACR and `wprCarveout*` fields move the protected layout? | 1 day | Layout lever |
| C20 | [Boot-input race](#boot-input-race) | Is there a hash-to-use window? | 1–2 days | PL2 or PL3 code execution |
| C13 | [FSP framing](#fsp-framing) | Is the ROM's message parser weak at the framing layer? | 2–3 days | PL3 parser surface |
| C11 | [Context patch buffer](#context-patch-buffer) | Can the host edit a GSP-consumed pointer list? | 1 day | PL2 write primitive |
| C19 | [SR saved-state malleability](#sr-saved-state-malleability) | Is the saved ciphertext malleable? | 1 day | PL2 foothold |
| C10 | [Per-SM channel](#per-sm-channel) | Is per-SM reachable with a real channel? | 1–2 days | Last non-PL3 register space |
| C03 | [vBIOS app 0x23](#vbios-app-0x23) | Is the plaintext data tail a devinit template? | offline decode | Only direct-unlock candidate |
| C04 | [Override payload](#override-payload-format) | Does the SS0/SS1 override set full rate? | 1 PRO cold-boot series | Validates a writer, not a route |
| C22 | [vBIOS ucode key search](#vbios-ucode-key-search) | Do the encrypted devinit bodies decrypt under the FMC key family? | offline, days | May name the FEAT writer |
| C23 | [Computed-offset sweep and devinit handlers](#computed-offset-sweep-and-devinit-handlers) | Do computed-offset references to the rate registers exist in the plaintext GSP-RM? | offline, days | Closes the no-RM-writer claim |
| C24 | [Boot-args buffer](#boot-args-buffer) | Is the fourth host-built boot structure parsed with checks? | 1–2 days | Live input, mapped or not |
| C18 | [vBIOS ucode corpus](#vbios-ucode-corpus) | Which stack consumes the vBIOS bodies? | days | Low, closed here |

The Session A measurements are closed out here; the evidence is in the
experiment records.

### Measured in Session A

| ID | Lead | Outcome | Record |
|---|---|---|---|
| C12 | [Host FECS doorbell](#host-fecs-doorbell) | PL0 command surface; `0x21` executes but does not move the rate; an unassigned ID fatal-errors the FECS | [03.10](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal) |
| C05 | [Below-PLM lock](#below-plm-lock) | Re-lock at 1353 ms; only `FUSE_SS_PLM` moves; no second gate | [01.9](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register) |
| C06 | [Name the writer](#name-the-writer) | No FSP register activity; PMU or hardware latch remains | [01.9](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register) |
| C17 | [Ada payload from PL2](#ada-payload-from-pl2) | Dropped; rate unchanged | [01.10](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2) |

The index above buys decisions about the unlock. The leads below buy
information: each is a measurement program whose output can generate new
hypotheses. They are ranked by information per cost, not by the unlock
decision.

| ID | Lead | What it would reveal | Cost |
|---|---|---|---|
| C27 | [Debugger-class command census](#debugger-class-command-census) | A memory or state read path through the exposed debug class | 1 day |
| C28 | [Timed EMEM and DMEM capture](#timed-emem-and-dmem-capture) | FMC or SEC2 plaintext during the boot window | 1–2 days |
| C29 | [Engine-map completion](#engine-map-completion) | The PMU falcon and the unknown blocks; the FEAT writer | 1 day |
| C30 | [RM interface and log census](#rm-interface-and-log-census) | Unexposed control handlers, falcon accessors, and the FWSEC→SEC2 path | offline, days |
| C31 | [Cross-version corpus diff](#cross-version-corpus-diff) | Which parsers and checks NVIDIA changed, and where older bugs live | offline, days |
| C32 | [Crypto-model and key-source program](#crypto-model-and-key-source-program) | Whether the FMC and bindata keys are image-wide, and what the cipher is | offline, days |
| C33 | [PL2 read oracle](#pl2-read-oracle) | Decrypted FECS/GPCCS ucode and WPR contents through an RM primitive | weeks |

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
The magic and the revision were varied; both reject non-stock values and hang
the resume ([the bad-magic
test](experiments/06_sr-resume.md#062-a-bad-srmeta-magic-hangs-the-resume)).
The size, the pointer, the flags, the radix3 delta, and the PTE values are
host-controlled and untested.

**Try.** The [driver harness](tools/driver-harness/) now has field 6 (radix3
address plus a delta) and disk phase markers (`phase_loaded`,
`phase_pre_suspend`, `phase_post_resume`). A failed resume leaves the
pre-suspend marker and no post-resume marker. Run the stock control first, then
`flags` (1, 2), `sizeOfSuspendResumeData` (stock, half, 16 MiB), and radix3
deltas. The PTE tests need a new hook: `sr_oracle.sh` varies only the scalar
fields. Then a PTE that points at a duplicate page, a PTE that crosses a 4 MiB
run boundary, and an unmapped entry.

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

**Decision.** A patched plaintext GSP-RM that boots is PL2 code execution. It
is also the read oracle in [the PL2 read oracle](#pl2-read-oracle); treat a
success as an information primitive even before it helps the FEAT write. A
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

**Measured.** Across an FLR the FEAT PLM re-locks at 1353 ms, 1821 ms before
the first GSP-RM program counter at 3174 ms. Only one fuse security word moves:
`FUSE_SS_PLM` (`0x8200fc`) takes the FLR's `0x80842bcf`, the same value as the
FEAT PLM, and re-locks to `0xfffffbff` at the same instant; the FEAT PLM
re-locks to `0xfffffb8f`. The other sampled words are constant. That is a
reset-domain coupling, not a second gate; the effective gate is still the FEAT
PLM ([the re-lock
record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).

**Decision.** The measurement is done and shows no separate qualification. It
cannot prove a PL3 write suffices; only a passing PL3 write can. The
prerequisite remains open on sufficiency.

## Host FECS doorbell

**Where it comes from.** The FECS (graphics front-end microcode) block is
read/write-all at `0x4096d0`, and the GSP's doorbell write landed
([the FECS
probe](experiments/03_fecs-and-gr-context.md#031-live-fecs-fsp-and-sec2-probes)).
Before this test every doorbell write was GSP-mediated, and the handler is
encrypted ([the command
protocol](experiments/03_fecs-and-gr-context.md#032-the-fecs-command-protocol-statically)).

**Measured.** The mailbox is a host surface. BAR0 writes to `0x409500` and
`0x409504` execute a command; the completion echo lands at `0x409800` (`0x21`
for command `0x21`), and the ID read is blocked. Command `0x21` executes from
both PL2 and the host, but the FEAT bank and the issue rate do not move across
four feature masks. An unassigned ID (`0x7ff`) leaves the status clear and
fatal-errors the FECS (`Xid 13`; `Xid 154` reset required), so the handler has
no safe default ([the host command
record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).

**What remains.** The context-buffer loader (`0x30`–`0x32`, `0x75`, `0x76`)
takes host-supplied addresses. That is a pointer-injection test, not a rate
test, and a bad address is likely another FECS fatal, so it needs a sacrificial
card. A hidden selector command would have to be named from the encrypted
handler; the unknown-ID fatal makes brute-force enumeration destructive.

**Decision.** Closed as a rate route and as a safe enumeration route. The host
command surface is a PL0 DoS primitive, not a lever.

## ICD write opcodes

**Where it comes from.** The PRISCV ICD is a live host debug port: after a
halt, `RREG`, `RCSR`, and `RDM` read the RM code segment byte-exact
([the live ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).
The write-memory closure rested on the public header's opcode list — the
driver's API, not the hardware command set — and no write opcode had ever
been sent.

**What closed.** Twenty-four candidate opcodes were sent to a halted core
against a zero span inside the code window, each with data latched and a
readback. The unassigned opcodes all return `ERROR[14]` and change nothing;
four "accepted" candidates are `RDM` aliases in disguise. The port is
read-only on hardware
([the aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).

**Decision.** Closed. No code-modification foothold exists at this port.

## Ada payload from PL2

**Where it comes from.** The PL2 test wrote `SS0 = 0`; it never wrote the exact
payload `0x88888888` and `0x8` ([the FUSE and rate
test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
The mask predicts a drop. The two PRO 6000s run full rate with every enable bit
clear, so the override may be unused on Blackwell
([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
`FUSE_EN_SW_OVERRIDE = 0` on both 5090s ([the debugger
group](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read))
does not bound this payload: that fuse gates the CTRL_OPT floorsweep override,
not the speed selectors, and the prior art writes the same payload on the CMP
170HX, which also reads `0` ([the two override
paths](specs/02_privilege-and-rate-control.md#the-two-override-paths)).

**Measured.** PL2 writes `SS0 = 0x88888888` and `SS1 = 0x8`; both read back the
stock words (`0x21265043`, `0x00000006`) and the BF16→FP32 rate stays about
226 TF/s. The PLM drops the write ([the payload
test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).

**Decision.** Closed from PL2. The payload is only testable after a PL3 write
opens `FEAT_OVR_PLM`; [the override payload
format](#override-payload-format) remains the post-writer question.

## Name the writer

**Where it comes from.** The PLM re-lock is GPU-side and happens before the
first open ([the re-lock
test](experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)),
but the "PMU" (power-management microcontroller) attribution is an inference.
The reset mask admits both L2 and L3,
so the FSP was equally admissible at the outset ([the reset
window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm)).

**Measured.** The FLR poll samples the FSP core status, scratch, version,
engine, block PLM, core PLM, and the 16-byte constant every 5 ms. Every one is
constant through the 1353 ms re-lock and the GSP start at 2991–3174 ms. The
writer is the PMU or a hardware latch, not the FSP/BootROM on the visible
registers ([the re-lock
record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).

**What remains.** The offline side is negative: the GSP-RM literal scan over
the rate registers, the PLM included, came back empty ([the static
audit](experiments/02_registry-and-static-audit.md)), so the writer is not RM
code. The PMU base is unknown; [engine-map
completion](#engine-map-completion) is where the actor is named. Naming it does
not unlock the card.

**Decision.** Measured: the FSP is excluded on the visible registers. The PMU
or a hardware latch remains.

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
The transit record proposed that the decrypted FECS/GPCCS ucode passes
through RM-visible memory between SEC2's decrypt and the falcon's IMEM load,
and that a timed halt-and-dump through the debug engine would capture it
with no key
([the transit
record](experiments/13_fwimage-map-and-bindata.md#136-the-decrypted-ucode-transit-and-its-read-route)).

**What closed.** Both legs are measured out. The `sec2_acr` log args that
motivated the transit were a 4-second timeout pair, not staging pointers —
the transit itself is unproven
([the decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)).
And the halted-core ICD reads exactly the RM code segment and refuses the
heap, the runtime range, and the WPR, with no write opcode either — so no
read at any moment reaches a staging buffer
([the aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
The census work survives: the two `0xf900` blobs are the GR-falcon shape,
and the dump matcher is ready for any future read primitive
([the census](experiments/13_fwimage-map-and-bindata.md#138-the-blob-census-five-families)).

**Decision.** Closed as designed. The enforcement fork — FECS ucode or
silicon — moves to [the FECS doorbell](#host-fecs-doorbell), which answers
behaviorally whether a FECS command can select the rate. A new read
primitive into WPR memory would reopen this lead; none is known.

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

**Where it comes from.** The full-rate readout is measured on two RTX PRO
6000s: both read `FEAT_READOUT_1 = 0` with every arithmetic speed fuse at 0,
and card A runs BF16 at 518 TF/s with the FP16-accumulate rate equal
([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
Both cards also have every `SS0`/`SS1` enable bit clear, so their full rate
comes from the absence of a fuse penalty: an already-zero selector needs no
override. A throttled part needs the override, and its format is the one the
prior art measured, `SS0 = 0x88888888` and `SS1 = 0x8`, written from the host
once PL3 code opens `FEAT_OVR_PLM` ([the two override
paths](specs/02_privilege-and-rate-control.md#the-two-override-paths)). The
payload is therefore a post-writer question: without a write that passes the
PLM, no boot series can validate it on GB202. The PL2 variant is now measured
and drops ([the payload
test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2));
only the post-writer form remains.

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

**Decision.** A PRO enable bit would mean the full-rate part also sets the
override; its absence leaves the words as runtime state. The format is already
measured on the prior art, so the cold-boot series sharpens the picture but
does not validate the payload on GB202. Fold it into a future PRO rental; do
not plan a run around it.

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

## Discovery: what produces new information

These leads do not test a route to the FEAT bank. Each one is a measurement
program that can generate new hypotheses, and each is a prerequisite for
judging the leads above.

### Debugger-class command census

**Where it comes from.** The class is exposed to a CUDA process and reads the
FEAT bank through `NV83DE_CTRL_CMD_DEBUG_EXEC_REG_OPS` ([the class
record](experiments/10_debugger-class-and-fecs-ucode.md#101-the-class-is-exposed-and-allocatable)).
The public `0x83de` interface also defines `READ_MEMORY` and `WRITE_MEMORY`
(`0x83de0315` and `0x316`), the batch forms (`0x326` and `0x327`),
`READ_SURFACE`, `GET_MAPPINGS`, `SUSPEND_CONTEXT`,
`READ_ALL_SM_ERROR_STATES` (`0x30c`), and the ERRbar and single-step commands.
Only the register-op command was issued ([the debugger
test](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).

**Try.** With the existing `LD_PRELOAD` debugger object, issue one command per
boot. Start with `READ_ALL_SM_ERROR_STATES` and `GET_MAPPINGS`; then the memory
reads and `SUSPEND_CONTEXT` against the handle the class already holds, then a
global or PRAMIN handle. Read only; a bad command can drop the CUDA context.

**Decision.** A memory read that reaches a buffer the caller did not map, or an
SM error state that exposes a selector copy, is a new read surface. A uniform
`NV_ERR_INVALID_ARGUMENT` or `NOT_SUPPORTED` closes the non-register commands
and leaves the class as an observability path only.

### Timed EMEM and DMEM capture

**Where it comes from.** The GSP EMEM, the FSP EMEM channels, and the SEC2
DMEM port are host-readable. They were sampled with the driver bound and the
GSP-RM running, and read empty or constant ([the GSP EMEM
record](experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty),
[the ICD aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
The FMC decrypts and runs before the GSP-RM exists, and the SEC2 decrypt window
is about 20 ms, bracketed by the `sec2_acr` log pair ([the timeout
decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)).
The steady-state sample cannot see either window.

**Try.** Use [the direct probe](tools/direct-probe/) on a cold boot and stream
the GSP EMEM (`0x110ac0`), the SEC2 DMEM port (`0x8401c0`), and the four FSP
EMEM channels (`0x8f0ac0`–`0x8f0adc`) with the auto-increment read flag. Arm on
the first `sec2_acr` line, again on the first `gr_fecs` line, and across a GC6
re-decrypt. Read only, and budget a wedge. Also capture a GSP core dump and
check whether it carries RM heap or engine state.

**Decision.** Any plaintext parcel or key-shaped block in a port is a read
primitive and the first decrypted FMC or ucode bytes. A uniform zero or
constant across all windows closes the ports and leaves the ICD as the only
measured read path.

### Engine-map completion

**Where it comes from.** At the documented bases the PMU is all sentinel,
FECS `0x409000` is a sparse GR block rather than a falcon, and GPCCS is absent
([the falcon probe](experiments/11_falcon-and-gr-window-probe.md#111-the-falcon-blocks-answer-or-refuse)).
The PMU is the leading FEAT-writer candidate ([name the
writer](#name-the-writer)), and the `0x500000` block, the `0x1c0000` PLM, and
target `0x0e` are unidentified ([the GR
map](experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom),
[the ucode table](experiments/11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table),
[the bodies](experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)).
The map is incomplete, so "no host window" is a statement about the tested
bases only.

**Try.** Scan BAR0 read-only for the falcon `HWCFG2`, `CPUCTL`, and
`ENGINE_RESET` signature, skipping the `0x300000`–`0x400000` hazard. Compare
the signature offsets with the GSP, FSP, and SEC2 blocks. Then map the
`0x500000` block and the `0x1c0000` PLM with the same three-register test.

**Decision.** A new falcon block with a readable `HWCFG2` is a new engine
window; if it is the PMU it names the writer. A scan with no new signature
closes the undocumented-base search and leaves the documented map.

### RM interface and log census

**Where it comes from.** The GR control table has 44 entries and no rate setter
([the rate getter](experiments/07_plaintext-corpus.md#076-the-rate-getter-has-no-hidden-setter)).
That census covers one control class. The plaintext RM also holds the other
control classes, the falcon accessors, and the FWSEC-LIC unit whose strings
name the secure-data path ([the secure-data
unit](experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)).
The exact FWSEC-to-SEC2 sequence and the falcon accessors are unmapped.

**Try.** Enumerate every control-table entry and handler in the plaintext RM:
control ID, parameter size, and whether the handler touches the `0x8238xx`
bank, a fuse word, a falcon base, or the FWSEC path. Build a log-string map for
`override`, `speed`, `PLM`, `fuse`, `ucode`, `secure`, and `falcon`, and
resolve each string to its log thunk. Then decompile the FWSEC-LIC callers and
the falcon accessors.

**Decision.** A host-callable handler that reads or writes engine memory, or
that selects a ucode image, is a new surface. A complete map with no such
handler narrows the search to the PL3 code and the debugger class.

### Cross-version corpus diff

**Where it comes from.** Every static claim is one driver and one GSP-RM
version, 595.91.07, plus one PRO 615.71.09 ([the fwimage
map](experiments/13_fwimage-map-and-bindata.md#131-the-libos-manifest-and-the-module-chain)).
The driver package ships production and debug FMC containers, and the
14-container corpus already exists for the key search ([the FMC
container](experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature)).
No version-to-version diff has been run.

**Try.** Extract the GSP-RM, `GspRmBoot`, FMC headers, and vBIOS from every
available driver branch, Linux and Windows, plus the public `linux-firmware`
sample. Diff the plaintext GSP-RM per module, the vBIOS init tables, and the
FMC headers; correlate header fields with production/debug, version, and the
inline key block.

**Decision.** A check that appears only in a later version names a
security-relevant parser and an older image to test. A stable header with no
key field closes the header as a key source.

### Crypto-model and key-source program

**Where it comes from.** The MD5-IV permutation family is exhausted on the FMC
under five modes ([the key
search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)),
but the mode, key size, and key source are unestablished, and the corpus was
never compared across cards or versions. The same component encrypts
identically at different offsets within one image, which rules out a global
chaining mode but not a per-component reset ([the FMC
container](experiments/07_plaintext-corpus.md#074-fmc-container-format-and-signature)).
The vBIOS bodies have a shared plaintext preamble the FMC search never used
([the bodies](experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)).

**Try.** Compare the same FMC, `GspRmBoot`, and bindata component across two
cards and two driver versions. If the ciphertext is identical, the key is
image-wide; if it differs, it is device- or image-bound. Then correlate the
14 FMC headers with production/debug and the inline key block, test the
untested modes and key sizes, and run a known-plaintext oracle on the vBIOS
preamble.

**Decision.** Identical cross-card ciphertext makes an offline key attack
meaningful and gives the mode constraints. Different ciphertext ends the
offline FMC route and moves the program to [the timed port
capture](#timed-emem-and-dmem-capture) and the [PL2 read
oracle](#pl2-read-oracle).

### PL2 read oracle

**Where it comes from.** The GSP-RM runs at PL2, owns the WPR, and loads the
engine ucode. A patched RM is treated as a foothold for probes, not as a read
path ([the
assessment](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).
The RM's falcon accessors and the FWSEC path are unmapped ([the
census](#rm-interface-and-log-census)), and the boot race is the enabler
([the boot-input race](#boot-input-race)).

**Try.** After a boot-race or RM-bug primitive, read FECS and GPCCS IMEM
through the RM's own falcon access, and dump the WPR and FRTS through its heap
access. Start with the ucode the RM just staged, then the saved state. Keep the
stock restore path.

**Decision.** A single byte of decrypted engine ucode confirms the RM as the
read oracle and turns the enforcement question into a code review. A primitive
that cannot read engine memory leaves the ICD and the ports as the only read
paths.

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
- More 16! MD5-IV key passes. The family is exhausted under ECB, CBC-zero and
  header-IV, and CTR starts 0 and 1; the untested modes and the intermediate
  round keys live in [the vBIOS ucode key
  search](#vbios-ucode-key-search) ([the key
  search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).
- FUSE-shadow writes. Dropped from PL0 and PL2 ([the FUSE
  test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
- ICD write memory. The public header defines read and control opcodes only,
  and the hardware sweep confirms it: twenty-four write candidates refused
  or aliased to `RDM` on a halted core
  ([the aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
- ICD reads outside the code segment from a halted core. The aperture is
  `0x01000000–0x01DCD000`; the container bindata, the data segment, the
  whole runtime range at 1 MiB steps, and every WPR address refuse
  ([the aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
- The staged-ucode capture through the ICD. The transit through RM-visible
  memory is unproven — its evidence was a misread timeout pair — and no tested
  host read path reaches the heap or WPR ([the transit
  record](experiments/13_fwimage-map-and-bindata.md#136-the-decrypted-ucode-transit-and-its-read-route)).
  The EMEM and DMEM ports were sampled only at steady state; [the timed port
  capture](#timed-emem-and-dmem-capture) is the untested route.
- Direct PL2 FEAT or PLM writes, including the exact `0x88888888`/`0x8`
  payload. Dropped by the mask, with no rate change ([the write
  test](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped),
  [the payload
  test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).
- The FECS command set as a rate selector. The host and PL2 can issue commands,
  but the known `0x21` command does not move the bank or the rate, and the
  plaintext command map has no selector ([the host command
  record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).
- Unassigned FECS command IDs as a probe. An unknown ID fatal-errors the FECS
  (`Xid 13`), so a blind sweep is destructive ([the host command
  record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).
- Registry speed keys. Parsed, stored, booleanized, inert ([the registry
  sweep](experiments/02_registry-and-static-audit.md#024-speed-select-keys-are-inert-on-hardware)).
- BAR1 and physical address `0x5dd00000`. Structurally closed ([the FB
  route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)).
- CUDA debugger-class FEAT writes. The class reads the bank and the write drops
  ([the debugger
  test](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- Reading FECS/GPCCS code or state from the host at the documented bases. The
  FECS, GPCCS, and PMU falcon bases return decode or not-implemented markers,
  the security engines block their boot vectors, and the GR window the GSP-RM
  admits is empty. The space above it is the vBIOS ROM and one per-card table,
  not ucode ([the falcon
  probe](experiments/11_falcon-and-gr-window-probe.md), [the
  window](experiments/11_falcon-and-gr-window-probe.md#112-the-admitted-gr-window-is-empty),
  [the GR
  map](experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom)).
  The PMU base is unknown; [engine-map
  completion](#engine-map-completion) is where the search continues.
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
