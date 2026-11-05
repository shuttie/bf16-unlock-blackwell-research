# Open leads: the backlog

## At a glance

- **Scope.** The BF16 unlock backlog: what is established, what is open, and
  what a session can start today. Each idea is a card with a question, a next
  run, a stop condition, and the record it came from.
- **Bench.** Stock RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  two cards. Reference: two RTX PRO 6000s on the same die.
- **Evidence.** Every claim links to the experiment or spec that establishes
  it. This page adds no measurements.
- **Not this page.** The narrative and the current verdict are in [the
  README](README.md#where-it-stands).

**The short version.**

- The unlock needs code execution at PL3, the boot-firmware privilege level.
  Host (PL0), GSP-RM (PL2), and the CUDA debugger class are measured and
  dropped.
- The target is measured: full rate is the all-zero encoding, and the override
  path is not fused off. The FEAT write mask is the only gate.
- The endgame legs are measured: `SS0`/`SS1` survive an FLR and are rewritten
  at every cold boot, so the unlock is a per-cold-boot apply.
- The next action is offline. The Ada debug booters that carried the only PL3
  primitive ever demonstrated on a GeForce part are decrypted and unread.
- One RM path could change the shape of the work: the vendor's own
  speed-select override writes a host value into the GR ucode image header,
  and nothing has measured whether it reaches hardware at PL2.
- The vendor's certificate mechanism is alive, its slot is empty, and its
  signature is device-bound. It stays parked until a signing break exists.
- [P2P is live on the bench pair](experiments/27_p2p-peer-access.md#271-peer-to-peer-is-live-on-the-bench-pair),
  so the second-bus-master path is testable.

## The goal

Full rate on the FP32-accumulate tensor path: about 440 TF/s BF16 → FP32 on
the 5090, with the validation list in [the unlock
criteria](specs/02_privilege-and-rate-control.md#what-would-count-as-an-unlock).
The same die already runs it: an RTX PRO 6000 measures 518 TF/s with every
arithmetic speed fuse at 0 ([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)),
so the target is register state, not silicon.

The missing primitive is code execution at PL3. From there the endgame is the
Ada sequence, and its Blackwell legs are already measured:

```
  PL3 code execution          the missing primitive
    -> open FEAT_OVR_PLM      one write from PL3 ([the write gate](specs/03_register-map.md#write-gate))
    -> write SS0/SS1          the override payload, unverified on Blackwell
    -> FLR; stock driver      the words survive the FLR ([the bank across resets](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr))
```

### The theory of victory and its stop condition

The only PL3 primitive ever demonstrated on a GeForce part is the Ada
unlock's: a booter parser bug in host-supplied signature data, turned into a
ROP chain from the already-authenticated image ([how the 3090/4090 unlock
worked](README.md#how-the-30904090-unlock-worked)). The thesis is that the
same class exists in the Blackwell boot chain. [The signature
sweep](#fmc-signature-section-sweep) is the direct analogue; the SR, boot-race,
FSP, and boot-field leads are the same hunt in other host-built buffers.

Every black-box variant costs a reboot, so the force multipliers are offline
narrowing and repeater economics ([the GC6 lead](#gc6-re-run-and-bank-persistence)).
The string-mapping method also has a shelf life: the secure-boot string
families are gone from the 617-lineage image ([the string
removal](experiments/17_cross-version-corpus-diff.md#173-the-secure-boot-strings-vanish-in-615)),
so the bench stays on 595.91.07.

The stop condition. If the offline sweeps come back empty — no field class
from the Ada booters, no computed reference that reaches a privileged actor,
no host-callable handler, no dated hardening naming a weaker parser — and the
signature sweep is bounded, then the host-supplied-data route is exhausted.
The answer is then a different vehicle: a PL2 primitive combined with [the
speed-select path](#rm-speed-select-override-path), a debug-grade part, or
public work.

## The index

Access is the scheduling axis: what a session can do without a card, with a
card, or only after a reboot. Cost lives here; the cards carry no priority or
cost. **Ready now** needs no unlock and no reboot. **Reboot budget** mutates
boot inputs and costs a reboot per variant. **Blocked** needs a primitive, a
different stack, or a signing break.

**Ready now.**

| ID | Idea | Access | Cost |
|---|---|---|---|
| C39 | [Ada booter disassembly](#ada-booter-disassembly) | offline | 2–3 days |
| C40 | [RM speed-select override path](#rm-speed-select-override-path) | card, one reload per key | half a day |
| C41 | [Peer-to-peer access](#peer-to-peer-access) | card, read-only | short; write 1 day |
| C35 | [GC6 re-run and bank persistence](#gc6-re-run-and-bank-persistence) | card, read-only | short |
| C22 | [Corpus key search](#corpus-key-search) | offline | days |
| C30 | [RM static census](#rm-static-census) | offline | days |
| C29 | [Engine naming and the unmapped bands](#engine-naming-and-the-unmapped-bands) | card, read-only | short |
| C11 | [Context patch buffer](#context-patch-buffer) | card | 1 day |
| C28 | [Timed EMEM and DMEM capture](#timed-emem-and-dmem-capture) | card, read-only | 1–2 days, one wedge |
| C10 | [Per-SM channel](#per-sm-channel) | card, read-only | short |

**Reboot budget.**

| ID | Idea | Cost | Gated by |
|---|---|---|---|
| C34 | [FMC signature-section sweep](#fmc-signature-section-sweep) | ≤3 boots | C39 |
| C01 | [SR resume surface](#sr-resume-surface) | 1–2 days | — |
| C20 | [Boot-input race](#boot-input-race) | 1–2 days | C28 timing |
| C13 | [FSP framing](#fsp-framing) | 2–3 days, sacrificial card | — |
| C02 | [Unvaried boot fields](#unvaried-boot-fields) | 1 day | — |
| C37 | [Cross-version differential](#cross-version-differential) | one boot, then a harness port | — |

**Blocked.**

| ID | Idea | Needs |
|---|---|---|
| C04 | [Override payload format](#override-payload-format) | a PL3 writer |
| C33 | [PL2 read oracle](#pl2-read-oracle) | C11 or C20 |
| C18 | [vBIOS ucode corpus](#vbios-ucode-corpus) | a consumer in another stack |
| C36 | [HULK certificate path](#hulk-certificate-path) | a signing break, or an RM-side verifier |

## Known-unknowns

The backlog. Four load-bearing questions first, then one card per idea, in
index order: ready now, reboot budget, blocked.

### The load-bearing unknowns

1. **Does the Blackwell override path work at all?** No measured part has an
   override-enable bit set; the PRO 6000s reach full rate through absent fuse
   penalties. The first writer session answers it ([the two override
   paths](specs/02_privilege-and-rate-control.md#the-two-override-paths)).
2. **Does the rate follow a live write, or latch at init?**
   `SM_ISSUE_RATE_MODIFIER` is reasserted at every CUDA context creation, so
   re-assert paths exist in firmware ([the FUSE/rate
   test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
3. **Is the enforcement microcode or silicon?** The fork sits in the encrypted
   bindata ([the fwimage map](experiments/13_fwimage-map-and-bindata.md)). If
   silicon, the register override is the only lever.
4. **Who writes the bank at power-on?** The PMU or a hardware latch. The
   re-lock values are [table data in
   flash](experiments/18_vbios-app23-decode.md#183-the-plm-defaults-match-the-live-locked-map),
   and the selector's per-card base is absent from plaintext. Part is
   answerable from captures on disk: cross-plot the boot-phase read series
   against the PLM state. No new runs.

### Ada booter disassembly

**Question.** Which field of the signature data does the Ada booter copy with
a host-controlled length, and what should have clamped it?

**Next.** Falcon-disassemble the two staged decrypts. Find the copy, the
length field, and the missing bound; map the field class onto the GB202
signature section ([the
layout](experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records)).

**Stop.** A field class the GB202 section carries turns [the
sweep](#fmc-signature-section-sweep) into at most three variants. No analogous
field sends the work to [the key search](#corpus-key-search).

**Evidence.** [the reference
decrypt](experiments/19_ada-reference-decrypt.md#194-two-chips-two-booters-and-the-gadget-grounding).

### RM speed-select override path

**Question.** Does `RMOverrideSmSpeedSelect` reach GR ucode at runtime, or die
at the `EA4` gate?

**Next.** Instrument `FUN_ram_0217f718` and `FUN_ram_0216d680` to print `EA4`,
`EA8`, and the word written to the ucode image header, with the registry key
set. One reload, read-only instrumentation.

A second, cheaper check is the rest of the GSP-only registry surface: sweep
`RMForceGrUcodeLoad`, `RMSec2UseDebugFuseOnlyBinary`, `RMNoECCFuseCheck`, and
`RMForceNetlistNumber` against the issue-rate probe. All four are parsed by
595 GSP-RM and absent from the host header; none names a rate. The first two
change ucode selection, and the second and third can wedge the GSP, where
recovery is reboot-only.

**Stop.** A nonzero value at the header with no rate change kills the
ucode-header override and confirms the PL3 requirement with evidence. A zeroed
value leaves it untested and promotes [the context patch
buffer](#context-patch-buffer) and [the SR surface](#sr-resume-surface) to the
top. A null sweep closes the GSP-only registry surface as a rate lever.

**Evidence.** [the static
pass](experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp),
[the registry
audit](experiments/02_registry-and-static-audit.md#023-speed-select-keys-are-live-code-paths).

### Peer-to-peer access

**Question.** Does the fabric treat a peer GPU's requests differently from
the host's — can a peer engine read the protected framebuffer, or write the
bank through the open-mask window?

**Established.** P2P is live on the bench pair on stock 595.91.07: reads and
writes report OK and peer copies verify ([the
enablement](experiments/27_p2p-peer-access.md#271-peer-to-peer-is-live-on-the-bench-pair)).
The working enabler is a six-key registry set; the host force keys are the
lever and the 595 GSP key is narrower than the 590 write-up ([the
gates](experiments/27_p2p-peer-access.md#272-the-gates-behind-cns)).

**Ran.** The read side is closed. The static BAR1 window stops below the WPR,
so there is no BAR1 offset to aim at ([the window
geometry](experiments/27_p2p-peer-access.md#274-the-static-bar1-window-stops-below-the-wpr)).
A peer engine aimed at the WPR through the movable BAR0 window gets the same
`0xbad0ac00` fill the host gets, with no VRAM bytes, while the same path
returns a pattern allocation byte-for-byte ([the peer
read](experiments/27_p2p-peer-access.md#275-a-peer-engine-gets-the-wpr-fill)).
The stock driver refuses the I/O import, so the measurement runs on the
instrumented module with a registry key.

**Next.** The write half only. A peer write of the bank through the 1.3 s FLR
window: the copy engine aimed at the peer's BAR0 aperture, about a day of
harness work, small wedge risk.

**Stop.** A dropped write confirms the port model; a landed write is the write
primitive with no code execution. The read oracle is closed.

**Evidence.** [the reset
window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm),
[the FB route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut),
[the enablement](experiments/27_p2p-peer-access.md#271-peer-to-peer-is-live-on-the-bench-pair).

### GC6 re-run and bank persistence

**Question.** Does the boot chain re-parse the host containers at GC6 exit,
and does the power-on writer rewrite `SS0`/`SS1` across a cycle?

**Next.** One read-only session. Watch the GSP log across runtime PM for a
second `sec2_acr` pair with no reboot, and read `SS0`/`SS1` and the PLMs
across a GC6 entry and exit. If a cycle fires, one gated follow-up with a
stale FMC header field.

**Stop.** A chain that re-runs per cycle turns [the boot
race](#boot-input-race), [the boot fields](#unvaried-boot-fields), and the
sweep's run half into repeaters. A bank that survives GC6 is an endgame
persistence leg. A null result closes GC6 as a capture arm.

**Evidence.** [the secure-data
unit](experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit),
[the bank across
boots](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr).

### Corpus key search

**Question.** Which corpus yields first to the remaining derivation families:
the debug FMC, the bindata blobs, or the vBIOS bodies?

**Next.** Phase 1 named the mode and Phase 2 closed the FMC window scan ([no
shipped window is the FMC
key](experiments/16_crypto-model-compare.md#168-no-shipped-window-is-the-fmc-key)).
Phase 3, in cost order at the 595 debug FMC: the derivation family first —
`AES(KEY37, seed)` over the seed sources in hand, a pattern with public
precedent in NVIDIA's own falcon code, feeding it [the per-copy
seeds](experiments/16_crypto-model-compare.md#163-duplicated-ucode-diverge-at-a-per-copy-seed),
corpus ASCII strings, and `CODE_ENC`-style constants; then the build
constants and non-MD5-IV mnemonics (the multiset itself is closed by [the
index
family](experiments/19_ada-reference-decrypt.md#193-the-index-generator-family-is-negative-on-gb202));
then the intermediate round keys 1–9 and the permutation family retargeted
at the corpora it never touched. The secret tables are per-part — the
published Tegra entry hashes are not an oracle here — so no entry
transplants. The bindata and vBIOS passes wait on a falcon-validity oracle:
build it as a decoder over the public falcon ISA tables, calibrated on the
staged Ada decrypts, and score both ISAs since the cores run falcon and
RISC-V code. Keep every search inside a derivation family; a random AES-128
key is 2^128 regardless of known plaintext.

**Stop.** A decrypted debug FMC names the parser [the sweep](#fmc-signature-section-sweep)
probes blind; a decrypted PMU body names the pre-lock writer. A negative across
all three closes the decrypt route for good.

**Evidence.** [the key
search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative),
[the cross-corpus
census](experiments/16_crypto-model-compare.md#167-no-ciphertext-crosses-a-corpus-boundary),
[the test key](experiments/19_ada-reference-decrypt.md#191-the-test-key-its-structure-and-the-known-answer).

### RM static census

**Question.** Does the plaintext RM hold a handler that reads or writes engine
memory, or that passes a FEAT address to a privileged actor?

**Next.** Enumerate every control-table entry and handler: control ID,
parameter size, and whether it touches the `0x8238xx` bank, a fuse word, a
falcon base, or the FWSEC path. Sweep computed references to `0x823804`,
`0x82381c`, `0x823820`, `0x8207d8`, and `0x504204`, and extend the sweep to
references that reach SEC2 and FWSEC call sites. Decompile the FWSEC-LIC
callers and the falcon accessors.

**Stop.** A host-callable handler that reads engine memory feeds [the PL2 read
oracle](#pl2-read-oracle); a FEAT address reaching SEC2 turns [the
speed-select path](#rm-speed-select-override-path) into a design question. A
complete map with neither narrows the search to the PL3 code and the debugger
class. Every no-writer claim is scoped to about 18.5 MB of plaintext, not the
whole image, and that quarter shrinks in the 617 lineage ([the string
removal](experiments/17_cross-version-corpus-diff.md#173-the-secure-boot-strings-vanish-in-615)).

**Evidence.** [the rate
getter](experiments/07_plaintext-corpus.md#076-the-rate-getter-has-no-hidden-setter),
[the static
audit](experiments/02_registry-and-static-audit.md#021-static-scan-finds-no-rate-register-reference),
[the handler
resolution](experiments/26_fwseclic-handler-resolution.md#263-no-certificate-parser-in-the-readable-quarter).

### Engine naming and the unmapped bands

**Question.** What occupies `0x42f804`–`0x500000` and `0x525200`–`0x1000000`?

**Next.** Finish the `0x100`-stride map from `0x532c00` upward in one-batch
steps with the canary, skipping the crash windows, and stop at the first
refusal.

**Stop.** No second command surface closes the surface census below
`0x1000000` for good. Family names do not unlock the card.

**Evidence.** [the falcon-signature
census](experiments/14_engine-map-census.md#141-the-falcon-signature-census-completes-the-engine-map),
[the doorbell
census](experiments/14_engine-map-census.md#145-the-coarse-map-and-the-doorbell-census).

### Context patch buffer

**Question.** Can the host edit a post-use address in the patch buffer and
have a context consume it?

**Next.** Rewrite one of the 10 changed values to a valid, then an invalid
framebuffer address; watch the launch, the GSP log, and any Xid.

**Stop.** A clean crash closes it. A working pointer is a PL2 write primitive
and feeds [the PL2 read oracle](#pl2-read-oracle).

**Evidence.** [the patch
differential](experiments/03_fecs-and-gr-context.md#035-the-post-use-patch-buffer-differential).

### Timed EMEM and DMEM capture

**Question.** Do the GSP EMEM, SEC2 DMEM, and FSP EMEM ports carry plaintext
during the ~20 ms decrypt window or a GC6 re-decrypt?

**Next.** Free-run all five ports across a cold boot with timestamps ([the
direct probe](tools/direct-probe/)): the GSP EMEM (`0x110ac0`), the SEC2 DMEM
port (`0x8401c0`), and the four FSP channels (`0x8f0ac0`–`0x8f0adc`).
Pre-register the null mode; read only; budget a wedge. Also capture a GSP core
dump and check whether it carries RM heap or engine state.

**Stop.** Any plaintext parcel or key-shaped block is a read primitive.
A uniform zero or constant closes the ports. Every "reads empty" claim so far
is a steady-state sample ([the GSP EMEM
record](experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty)),
so this is the only run that can return something nobody predicted. The
capture also times the image read for [the boot race](#boot-input-race).

**Evidence.** [the timeout
decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair).

### Per-SM channel

**Question.** Does the per-SM register space answer a typed read on a live
channel, and does any offset track the selector?

**Next.** The typed read with `hChannelTarget` set to a live channel and a
per-SM offset under a valid group/subgroup mask. The `0x504xxx` sweep is done.

**Stop.** A per-SM offset that changes with the selector reopens the space.
The inert `0x504204` and the `0x504240` table do not. The earlier null used a
channel that was not implemented for context ops, so a caller-owned channel
was never actually tested ([the GR_CTX
probe](experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).

**Evidence.** [the context
record](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read).

### FMC signature-section sweep

**Question.** Does any signature-section field reach a copy length, a record
stride, or a destination offset without a bound?

**Next.** Take the field class from [the Ada
disassembly](#ada-booter-disassembly), then one cold-boot variant per named
field with [the driver harness](tools/driver-harness/): the mode-2 record
layout, a second buffer behind the signature pointer, and the `0x836`
boundary.

**Stop.** An unchecked length or offset that survives to authentication is the
Ada-class vehicle, at PL3, in code no driver update patches. Uniform bounds
refusals close the section and leave [the boot race](#boot-input-race) as the
container's remaining input surface. The record-size check is bounded at
`[0x180, 0x200]`, so the bug needs a second, unchecked field ([the record
size](experiments/09_fmc-cold-boot-parsers.md#093-the-signature-record-size-is-a-bounded-window)).

**Evidence.** [the signature
section](experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records),
[the table tail](experiments/09_fmc-cold-boot-parsers.md#094-the-signature-table-and-mode-fields-are-validated).

### SR resume surface

**Question.** Does the resume parser trust a host field, and is the saved
state encrypted only?

**Next.** Stock control first, then the descriptor's flags, size, and radix3
delta, then one ciphertext bit in a zero page, then a code page and two
permuted page-table entries. Design the patch offline first; the ICD reads the
live RM code segment byte-exact ([the live
ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).

**Stop.** A resume that completes with a changed size or pointer, or a new
hang point, is a parser surface. A consumed zero-page bit means
confidentiality only and opens the code-flip tests; a clean refusal closes the
integrity question. Heavy Secure validating the PTEs before walking them
closes the table. Every failed variant costs a reboot.

**Evidence.** [the host-driven
cycle](experiments/06_sr-resume.md#061-the-suspend-and-resume-cycle-is-host-driven),
[the radix3](experiments/06_sr-resume.md#064-the-radix3-is-plaintext-and-fully-mapped),
[the saved
state](experiments/06_sr-resume.md#063-the-saved-state-is-high-entropy-ciphertext).

### Boot-input race

**Question.** Can a plaintext boot field change between the hash check and its
use?

**Next.** Flip the FMC header's `bodySize` or `codeSize` at high rate during
boot and watch for an error other than `0x33`. Then swap a plaintext GSP-RM
image between stock and patched copies, then alternate the `WprMeta`
bootloader and radix3 pointers between two valid copies. Use the timing from
[the timed capture](#timed-emem-and-dmem-capture).

**Stop.** A patched GSP-RM that boots is PL2 code execution and a read oracle.
A modified FMC image that boots runs at PL3, but the container is encrypted, so
the race only reaches plaintext fields. A uniform `0x33` or `0xaff` closes it.

**Evidence.** [the tampered
container](experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered).

### FSP framing

**Question.** Does the FSP validate the host-controlled transmit length and
the response identity?

**Next.** Vary the transmit tail distance by ±1..N; send a never-EOM fragment;
craft a response with a mismatched task, tag, or SEID (source endpoint ID).
Netconsole and a sacrificial card.

**Stop.** A new error code or state is a parser surface in immutable ROM,
unpatchable by any driver update, so the finding outlives every other parser
result here. A clean refusal closes the framing.

**Evidence.** [the static FSP
pass](experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp),
[the FSP command surface](specs/01_boot-chain.md#fsp-command-surface).

### Unvaried boot fields

**Question.** Do the ACR, carveout, or boot-args fields move the protected
layout or open a parser?

**Next.** First enumerate from the driver source every sysmem buffer built for
secure firmware; the census either confirms the four known or names a fifth.
Then one field per boot: the ACR and `wprCarveout*` fields, then the boot-args
size, flags, per-engine offsets, and a moved pointer.

**Stop.** A boundary that moves with a host field is a layout lever; a hang or
a structured error is a new parser surface in the same class as [the SR
surface](#sr-resume-surface). Clean refusals close both.

**Evidence.** [the heap-size
test](experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward),
[the non-WPR heap
test](experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever),
[the boot-parameter
print](experiments/05_fmc-fsp-boot-inputs.md#051-host-side-boot-and-static-info-instrumentation).

### Cross-version differential

**Question.** Did the 570 FMC parse the same fields with weaker checks, and
when did each check appear?

**Next.** Install 570.144 and check that the card boots. If it does, port the
harness and rerun [the signature probes](#fmc-signature-section-sweep) on the
same card. In parallel, extend [the corpus diff](tools/corpus-diff/) across
every obtainable GSP image and date each security string family.

**Stop.** A 570 FMC that boots is the only dated, older, mutable PL3 parser
available; divergent refusals name the hardened check and reopen the older
image. An identical refusal set means the parser did not change. An
anti-rollback refusal is a one-boot answer that closes the route.

**Evidence.** [the header
census](experiments/17_cross-version-corpus-diff.md#172-the-fmc-and-gsprmboot-headers-are-stable),
[what each branch
added](experiments/17_cross-version-corpus-diff.md#174-what-each-branch-added).

### Override payload format

**Question.** Does the Ada payload (`SS0 = 0x88888888`, `SS1 = 0x8`) set the
Blackwell override, and does the rate follow a live write?

**Next.** Nothing until a PL3 writer exists. Then the exact payload in a
session that also reloads the driver and FLRs the card, to separate a live
write from a latched one.

**Stop.** This is the first session after a primitive and answers [the
load-bearing unknowns](#the-load-bearing-unknowns). The payload is Ampere/Ada
prior art and drops from PL2 ([the payload
test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).

**Evidence.** [the bank across
resets](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr).

### PL2 read oracle

**Question.** Can a PL2 primitive read FECS/GPCCS IMEM or the WPR?

**Next.** After [the context patch buffer](#context-patch-buffer) or [the boot
race](#boot-input-race), read engine IMEM through the RM's own falcon access
and dump the WPR and FRTS through its heap access. Start with the ucode the RM
just staged. Keep the stock restore path.

**Stop.** One byte of decrypted engine ucode confirms the RM as the read
oracle and turns the enforcement question into a code review.

**Evidence.** [the
assessment](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem).

### vBIOS ucode corpus

**Question.** Is there a consumer for the four vBIOS ucode images outside the
Linux open stack?

**Next.** Identify target `0x0e` and find the consumer in another stack, such
as the Windows driver or the device firmware. Check the bodies against the FMC
key family; the keys are [not
device-bound](experiments/16_crypto-model-compare.md#161-the-encrypted-vbios-is-card-independent).

**Stop.** The Linux route is closed: no stack component reads the table on
GB202 ([the consumer
record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
Only a consumer in another stack reopens it.

**Evidence.** [the ucode
table](experiments/11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table).

### HULK certificate path

**Question.** Does the RM verify the `3AES` certificate locally, or does SEC2?

**Next.** Answer from the plaintext call chain. If the RM verifies, test the
path from a PL2 primitive; if SEC2 does, park it until a signing break exists.

**Stop.** An RM-side verifier moves this above [the signature
sweep](#fmc-signature-section-sweep). An SEC2-side verifier keeps it parked:
the only input would be a valid NVIDIA-signed certificate for this GPU, and
the slot is empty, the license zone is outside every save, and writes are
GSP-rejected ([the empty
slot](experiments/24_nvflash-read.md#241-the-read-matrix), [the desktop
container](experiments/25_desktop-container.md#252-the-license-zone-is-not-in-saves)).

**Evidence.** [the cluster](experiments/20_hulk-cert-machinery.md#201-the-certificate-cluster-in-the-rm-plaintext),
[not in the readable
quarter](experiments/26_fwseclic-handler-resolution.md#263-no-certificate-parser-in-the-readable-quarter).

## Known-knowns

One line per fact; the record carries the values.

### The target and the wall

- Full rate is the all-zero encoding: PRO 6000s read `FEAT_READOUT_1 = 0`
  with every arithmetic speed fuse at 0 ([the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- The override is not fused off; the PLM is the only gate ([the two override
  paths](specs/02_privilege-and-rate-control.md#the-two-override-paths)).
- `FEAT_READOUT_1` is the only selector carrier ([the readout
  decode](experiments/12_feat-readout-decode.md)). Stock `SS0`/`SS1` are
  shadow state with every enable bit clear ([the bank across
  boots](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
- The write mask admits PL3 only; host, PL2, and debugger writes drop and
  still return `SUCCESS` ([the GSP
  write](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped),
  [the debugger
  write](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- An FLR opens PL2+PL3 for about 1.3 s; devinit re-locks by 1156–1353 ms,
  about 1.8 s before GSP-RM, moving only `FUSE_SS_PLM` ([the reset
  window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm),
  [the re-lock
  record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).
- The FUSE shadow is inert and the bank is final before the FMC ([the FUSE
  test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier),
  [the bank before the
  FMC](experiments/05_fmc-fsp-boot-inputs.md#0517-feat-bank-final-before-the-fmc)).
- The RM has an `SS0`/`SS1` write method with no visible caller, and a PL2
  write drops anyway ([the static
  pass](experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp)).

### The endgame legs

- `SS0`/`SS1` survive an FLR ([the bank across
  resets](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr))
  and are rewritten at power-on by a per-card source ([the bank across
  boots](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
- The exact Ada payload drops from PL2 ([the payload
  test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).

### The boot inputs

- The parser group varied every host field the FMC consumes; the check order
  is in [the parser spec](specs/09_fmc-parsers.md).
- Measured bounds: a 4 KiB-aligned bootloader size, a record size in
  `[0x180, 0x200]`, slots 0/1 verified and 2/3 not, a mode set `{1,2}` with
  only mode 1 mapped, pinned bootloader and radix3 addresses, an exact
  revision and manifest offset, end-to-end image authentication, and a 1:1
  non-WPR heap lever ([the parser
  group](experiments/09_fmc-cold-boot-parsers.md)).

### The firmware, crypto, and corpus model

- The fwimage is about 18.5 MB of plaintext plus a 53.8 MB encrypted
  `rm.bindata.bin` ([the fwimage map](experiments/13_fwimage-map-and-bindata.md)).
- Keys are not device-bound, the bindata key is version-stable, duplicated
  ucode carries a per-copy 16-byte seed, ECB stands nowhere, and no ciphertext
  crosses a corpus boundary ([the crypto
  model](experiments/16_crypto-model-compare.md#167-no-ciphertext-crosses-a-corpus-boundary)).
- Driver 615 moves the ucode into `NVUCODES` and signs the production FMC as
  the debug FMC, byte-identical ([the 615
  corpus](experiments/16_crypto-model-compare.md#166-the-615-corpus-splits-and-resigns-the-fmc)).
- The 570 GB202 FMC carries `0x25800` of code against 595's `0x37000`, and it
  is the public linux-firmware sample ([the header
  census](experiments/17_cross-version-corpus-diff.md#172-the-fmc-and-gsprmboot-headers-are-stable)).
- The DEVINIT area is a sparse register-default map whose PLM rows match the
  live lock; it carries no selector content and no loader ([the app `0x23`
  decode](experiments/18_vbios-app23-decode.md#183-the-plm-defaults-match-the-live-locked-map)).
- The Ada debug booters decrypt under `csecret(37)`; the production booters
  do not ([the Ada
  decrypt](experiments/19_ada-reference-decrypt.md#192-the-debug-booters-decrypt-and-the-scope-closes-around-them)).

### The vendor path

- The HULK cluster is alive in 570 and 595 and gone from 615; the certificate
  handlers are not in the readable quarter ([the
  cluster](experiments/20_hulk-cert-machinery.md#201-the-certificate-cluster-in-the-rm-plaintext),
  [the handler
  resolution](experiments/26_fwseclic-handler-resolution.md#263-no-certificate-parser-in-the-readable-quarter)).
- Stock InfoROM carries `IMG`, `OBD`, `OEM`, and `HLK` 2.0, with no `UL_GLOB`;
  the HLK slot is empty, writes are `0x9F`, and the license zone is outside
  every save ([the base
  state](experiments/21_inforom-base-state.md#211-the-object-battery), [the
  nvflash read](experiments/24_nvflash-read.md#241-the-read-matrix), [the
  desktop
  container](experiments/25_desktop-container.md#252-the-license-zone-is-not-in-saves)).

### The writer and the map

- Not the FSP and not GSP-RM; the PMU block at `0x8f4000` or a hardware latch
  remains ([the re-lock
  record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register),
  [the PMU block](experiments/14_engine-map-census.md#146-the-image-names-the-pmu-block)).
- The engine map is complete below `0x1000000` except two crash-bounded bands,
  and every engine family is named ([the falcon-signature
  census](experiments/14_engine-map-census.md#141-the-falcon-signature-census-completes-the-engine-map),
  [the engine-type
  table](experiments/15_tag-decoder.md#152-the-engine-type-table-names-the-rest-of-the-map)).
- Two read windows crash GSP-RM through the debugger path; carry the canary
  ([the read that crashes
  GSP-RM](experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm)).

### Host FECS doorbell

The host and PL2 can issue command `0x21`; the bank and the rate do not move,
and an unassigned ID fatal-errors the FECS (`Xid 13`, then `Xid 154`). Closed
as a rate route and as a safe enumeration route ([the host command
record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).

### ICD write opcodes

Twenty-four write candidates returned `ERROR[14]` or aliased to `RDM` on a
halted core. The port is read-only on hardware ([the
aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).

### Staged-ucode capture

The `sec2_acr` args are a timeout pair, not staging pointers, and the ICD
reads the code segment only. Closed as designed; a new read primitive into WPR
memory would reopen it ([the
decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)).

### Closed, do not retry

| Route | Closed by |
|---|---|
| The flanking readouts as a target | [the readout decode](experiments/12_feat-readout-decode.md) |
| Re-planning around the A100 inference for the all-zero target | [the reference dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump) |
| More 16! MD5-IV key passes | [the key search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative) |
| A verbatim shipped key for the FMC containers | [the window scan](experiments/16_crypto-model-compare.md#168-no-shipped-window-is-the-fmc-key) |
| FUSE-shadow writes | [the FUSE test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier) |
| ICD reads outside the code segment | [the aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment) |
| Direct PL2 FEAT or PLM writes, including the exact payload | [the write test](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped) |
| The FECS command set or unassigned IDs as a probe | [the host command record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal) |
| Registry speed keys as a supported override | [the registry sweep](experiments/02_registry-and-static-audit.md#024-speed-select-keys-are-inert-on-hardware) |
| BAR1 and physical address `0x5dd00000` | [the FB route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut) |
| CUDA debugger-class FEAT writes | [the debugger test](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it) |
| FECS/GPCCS/PMU falcon bases and the GR window from the host | [the falcon probe](experiments/11_falcon-and-gr-window-probe.md), [the window](experiments/11_falcon-and-gr-window-probe.md#112-the-admitted-gr-window-is-empty) |
| Reading ucode through the vBIOS table on GB202 | [the consumer record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table) |
| The `0x137200` lead | [the descriptor record](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read) |
| JTAG pads on a retail part | [the debugger group](experiments/10_debugger-class-and-fecs-ucode.md) |
| BAR0 reads in the two crash windows | [the read that crashes GSP-RM](experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm) |

## Unknown-unknowns

Holes no idea names. Each says what the hole is and which card shrinks it.

### The surface census has a first half

The BAR0 half ran; the other halves are open: all host-built buffers that
secure firmware parses (the COT, `WprMeta`, `SRMeta`, and boot-args are the
four known; is the list complete?) and all RM control classes. A surface
nobody thought to probe cannot appear here as an idea. Shrunk by [the RM
static census](#rm-static-census) and [the boot fields
card](#unvaried-boot-fields). The unmapped bands are bounded by measured crash
windows ([the doorbell
census](experiments/14_engine-map-census.md#145-the-coarse-map-and-the-doorbell-census)).

### The gate's requester model is inferred

Every measured drop arrived through the host port or the RM. What the PLM keys
on — the requesting port hardwired to a level, or per-requester state in the
fabric — is unstated. The read half is now measured: a peer engine reading the
WPR through the BAR0 window gets the same access-denied fill as the host, so
the protection does not spare a second bus master ([the peer
read](experiments/27_p2p-peer-access.md#275-a-peer-engine-gets-the-wpr-fill)).
If the host port is hardwired PL0, writes from a second bus master during the
1.3 s open-mask FLR window would arrive tagged PL0 and drop. If the gate keys
on the requester, that window is the one place a live agent could write at an
open level.

**Try.** A peer write from the second card's engine into the first card's BAR0
during its FLR window. A dropped write confirms the port model; a landed write
is a path that needs no code execution. Shrunk by [the peer-to-peer access
card](#peer-to-peer-access).

### The instrument destroys its own evidence

A failed variant ends in a reboot, and the post-failure state dies with it.
Standardize the netconsole, GSP-log, and Xid capture on every mutating run
before spending reboot budget, and carry a known-value canary read and an
RM-status check in every scan batch, the pattern [the census
crash](experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm)
forced.

---

This page contains no exploit. Every mutating run needs a stock restore and an
expected reboot.
