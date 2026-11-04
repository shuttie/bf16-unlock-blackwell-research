# Open leads: the knowns, the unknowns, and the next runs

## At a glance

- **Scope.** Where the BF16 unlock stands after the measured log: what is
  established, what is open, where the observation net has holes, and what I
  run next. Each open lead names the record that raises it, the gap, and the
  next run.
- **Bench.** Stock RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
  two cards. Reference: two RTX PRO 6000s on the same die, 2026-10-31.
- **Evidence.** Every claim links to the experiment or spec that establishes
  it. This page adds no measurements.
- **Not this page.** The narrative and the current verdict are in [the
  README](README.md#where-it-stands).

**The short version.**

- The unlock needs code execution at PL3, the boot-firmware privilege level.
  Every cheaper writer is measured and dropped: host (PL0), GSP-RM (the main
  firmware on the GPU's RISC-V coprocessor, PL2), and the CUDA debugger class.
- The target is measured. Full rate is the all-zero encoding, and the override
  path is not fused off; the FEAT write mask is the only gate.
- The endgame legs are measured. The `SS0`/`SS1` override words survive an
  FLR, so a written override persists through the reset the way the Ada
  unlock's did. The words are rewritten at every cold boot, so the unlock is a
  per-cold-boot apply.
- The remaining work splits three ways: produce the PL3 primitive, name the
  actors and surfaces, and shrink the holes no lead names. The
  [unknown-unknowns](#unknown-unknowns) section is new; the closed routes and
  the current verdict used to live here and now live in
  [Known-knowns](#known-knowns).

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

Two questions sit behind the endgame and only a writer can answer them:
whether the Blackwell override plumbing works at all, and whether the rate
follows a live write or latches at init. They are [load-bearing
unknowns](#the-load-bearing-unknowns), not leads.

## The index

Priorities first, decision value second. **P0** spends no reboot budget and
each row either gates a later lead or shrinks the
[unknown-unknown](#unknown-unknowns) surface; run them first. **P1** is the
reboot-budget route ladder, ordered by the decision each buys. **P2** rows are
bounded or gated on a P0 answer. **P3** rows are conditional on a primitive or
a different stack. Leads that already ran are in
[Known-knowns](#known-knowns).

| Pri | ID | Lead | What it buys | Cost |
|---|---|---|---|---|
| P0 | C29 | [Engine naming and the unmapped bands](#engine-naming-and-the-unmapped-bands) | Names done; only the map band remains | short, read-only after a reboot |
| P0 | C30 | [RM interface and log census](#rm-interface-and-log-census) | Every host-callable handler, mapped or ruled out | offline, days |
| P0 | C23 | [Computed-offset sweep and devinit handlers](#computed-offset-sweep-and-devinit-handlers) | Reopens or closes the no-RM-writer claim | offline, days |
| P1 | C01 | [SR descriptor and page table](#sr-descriptor-and-page-table) | PL3 code execution | 1–2 days, reboots |
| P1 | C11 | [Context patch buffer](#context-patch-buffer) | A PL2 write primitive | 1 day |
| P1 | C28 | [Timed EMEM and DMEM capture](#timed-emem-and-dmem-capture) | The only run that can return unpredicted information | 1–2 days, one wedge |
| P1 | C20 | [Boot-input race](#boot-input-race) | PL2 or PL3 code execution | 1–2 days, reboots |
| P1 | C13 | [FSP framing](#fsp-framing) | A parser surface in unpatchable ROM | 2–3 days, sacrificial card |
| P2 | C02 | [Carveout layout fields](#carveout-layout-fields) | A layout lever | 1 day, reboots |
| P2 | C24 | [Boot-args buffer](#boot-args-buffer) | A new parser surface or a closed buffer | 1–2 days, reboots |
| P2 | C19 | [SR saved-state malleability](#sr-saved-state-malleability) | A PL2 foothold | 1 day, after C01 |
| P2 | C10 | [Per-SM channel](#per-sm-channel) | The last non-PL3 register space | short, live card |
| P2 | C22 | [vBIOS ucode key search](#vbios-ucode-key-search) | May name the FEAT writer | offline, days |
| P3 | C04 | [Override payload](#override-payload-format) | Validates a writer; the endgame questions | post-writer; fold into a PRO rental |
| P3 | C33 | [PL2 read oracle](#pl2-read-oracle) | Decrypted ucode and WPR contents | weeks; needs a C11 or C20 primitive |
| P3 | C18 | [vBIOS ucode corpus](#vbios-ucode-corpus) | Only a different stack reopens it | offline |

## Known-knowns

Established by measurement. The dead-end registry is [Closed, do not
retry](#closed-do-not-retry) at the end of this section.

### The target is measured

- Full rate is the all-zero encoding: two RTX PRO 6000s read
  [`FEAT_READOUT_1 = 0`](specs/03_register-map.md#readout-decode) with every
  arithmetic speed fuse at 0; one runs BF16 → FP32 at 518 TF/s, equal to its
  FP16-accumulate rate ([the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
- The override path is not fused off: `FUSE_FEAT_OVR_DIS` reads 0 on all four
  measured cards, so the [write mask](specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
  is the only gate ([the two override
  paths](specs/02_privilege-and-rate-control.md#the-two-override-paths)).
- `FEAT_READOUT_1` is the only selector carrier; the flanking readouts are ECC
  capability flags with no rate reader in the image ([the readout
  decode](experiments/12_feat-readout-decode.md)).
- The stock `SS0`/`SS1` words are shadow state, not selectors: they vary
  across cold boots, are invariant within a boot and across warm reboots, and
  every override-enable bit is clear ([the bank across
  boots](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).

### The wall is one register

- The bank's write mask admits PL3 only at stock. Host (PL0), GSP-RM (PL2),
  and CUDA debugger-class writes are dropped, and the drop still returns
  `SUCCESS` ([the GSP
  write](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped),
  [the debugger
  write](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- An FLR opens write PL2+PL3 for about 1.3 s; a GPU-side devinit re-locks at
  1353 ms, about 1.85 s before the first GSP-RM program counter ([the reset
  window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm),
  [the autonomous
  re-lock](experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)).
- The re-lock moves only `FUSE_SS_PLM` and no FSP register; it is reset-domain
  coupling, not a second gate ([the re-lock
  record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).
- The FUSE shadow is inert from PL0 and PL2 ([the FUSE
  test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
- The bank is final before the FMC runs; the pre-lock writer precedes every
  host-visible stage ([the bank before the
  FMC](experiments/05_fmc-fsp-boot-inputs.md#0517-feat-bank-final-before-the-fmc)).

### The endgame legs are measured

- `SS0`/`SS1` are outside the FLR reset domain: across an FLR with the driver
  unbound, the words persisted while the PLM reset and re-locked ([the bank
  across
  resets](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
  A written override survives the reset the way the Ada unlock's did.
- The words are rewritten at power-on by a source with a fixed per-card base
  and a small variable component; the driver, the FMC, GSP-RM, POST, and the
  warm-boot path are all excluded ([the bank across
  boots](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
  The unlock is a per-cold-boot apply, not a one-shot flash.
- The exact Ada payload written from PL2 is dropped and the rate is unchanged;
  the payload is testable only after a PL3 write opens the gate ([the payload
  test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).

### The cold-boot parser map is measured

The [boot-input parser group](experiments/09_fmc-cold-boot-parsers.md) varied
every host field and buffer byte the FMC consumes at cold boot. The result is
a bounded parser; no primitive appeared. The check order and section layout
are in [the parser spec](specs/09_fmc-parsers.md).

- The [bootloader
  size](experiments/09_fmc-cold-boot-parsers.md#091-the-bootloader-size-is-a-4-kib-aligned-authentication-length)
  is a 4 KiB alignment check; aligned values set the authentication length,
  and 256 MiB hits a size limit. There is no exact-length check.
- The [signature
  section](experiments/09_fmc-cold-boot-parsers.md#092-the-signature-section-layout-and-the-checked-records)
  is a header, four slots, and a table. Slots 0 and 1 are verified; slots 2
  and 3 are not.
- The [record
  size](experiments/09_fmc-cold-boot-parsers.md#093-the-signature-record-size-is-a-bounded-window)
  must be in `[0x180, 0x200]`; above it is a bounds refusal. The header words
  at `+0x00` through `+0x0c` are ignored on the stock path.
- The [table
  tail](experiments/09_fmc-cold-boot-parsers.md#094-the-signature-table-and-mode-fields-are-validated)
  is a mode with the valid set `{1,2}`; the length and flag fields at
  `0x880` and `0x884` are bound into image authentication.
- The [bootloader and radix3
  addresses](experiments/09_fmc-cold-boot-parsers.md#095-the-bootloader-and-radix3-addresses-are-consumed-pre-auth)
  are pinned (`0xaff` and `0x83e`). The [signature
  address](experiments/09_fmc-cold-boot-parsers.md#096-the-signature-address-is-a-4-byte-aligned-pointer)
  is a 4-byte-aligned pointer with a magic check; it reads the host buffer at
  the chosen address, but that is the buffer the host already controls.
- The [revision and manifest
  offset](experiments/09_fmc-cold-boot-parsers.md#098-the-revision-and-manifest-offset-are-exact-checks)
  are exact; `fbSize` is inert. The [image
  bytes](experiments/09_fmc-cold-boot-parsers.md#099-the-bootloader-image-bytes-are-authenticated-end-to-end)
  are all behind image authentication.
- The [non-WPR heap
  size](experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever)
  is a 1:1 layout lever from a fixed WPR base; it does not expose the WPR.

What remains from this group: the second-buffer signature test, the `0x836`
boundary, the mode-2 record layout, and [the carveout
fields](#carveout-layout-fields). None has a run behind it.

### The debugger-class census ran

The CUDA debugger class was exposed and allocatable, and the census ran every
non-register command on both cards ([the command
census](experiments/10_debugger-class-and-fecs-ucode.md#104-the-non-register-commands-do-not-open-a-read-path)):

- `READ_ALL_SM_ERROR_STATES` and `READ_SINGLE_SM_ERROR_STATE` work for all 170
  SMs and return zero. There is no selector copy.
- `GET_MAPPINGS` returns `count=0` at every range, and `READ_SURFACE` refuses
  every VA, including the caller's own buffer.
- `READ_MEMORY` and `READ_BATCH_MEMORY` read Memory objects in the CUDA
  client's own handle database, including internal channel buffers the CUDA
  API does not map, but not another client's handles, the RM heap, or engine
  memory.
- `GET_HANDLES` is not supported; the mode getters work; `SUSPEND_CONTEXT` and
  `RESUME_CONTEXT` work.

The class is an observability path, not a write or a cross-client read.

### The firmware image is mapped to its ciphertext

- The fwimage is a libos container: about 18.5 MB of plaintext and a 53.8 MB
  encrypted `rm.bindata.bin` that holds the engine ucode behind per-blob SEC2
  key derivation ([the fwimage
  map](experiments/13_fwimage-map-and-bindata.md),
  [the secure-data
  unit](experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)).
- The blob census names two `0xf900` code-load blobs as the GR-falcon shape,
  and the dump matcher is ready for any future read primitive ([the
  census](experiments/13_fwimage-map-and-bindata.md#138-the-blob-census-five-families)).
- The `sec2_acr` args are a timeout pair, not staging pointers ([the
  decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)),
  and the ICD reads the code segment only ([the
  aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)),
  which closed the timed-capture-through-ICD route and left
  [Staged-ucode capture](#staged-ucode-capture) closed as designed.

### The crypto model is measured

- The corpus keys are not device-bound: the four encrypted vBIOS bodies are
  byte-identical between the two 5090s, and every per-card byte sits in a
  plaintext tail ([the card-independent
  vBIOS](experiments/16_crypto-model-compare.md#161-the-encrypted-vbios-is-card-independent)).
- The bindata key is version-stable: blobs that did not change carry
  byte-identical ciphertext across 570.144, 595.91.07, and 615.78.08, through
  the container split ([the version-stable
  bindata](experiments/16_crypto-model-compare.md#162-the-bindata-key-is-version-stable)).
- The corpus is not one key in ECB mode: the seven ucode images stored twice
  diverge exactly at a per-copy 16-byte seed stored after the descriptor, and
  copies that share the seed encrypt identically ([the per-copy
  seed](experiments/16_crypto-model-compare.md#163-duplicated-ucode-diverge-at-a-per-copy-seed)).
- The FMC body is the GspRmBoot image re-wrapped, with identical ciphertext at
  different offsets, in every version tested; the per-component reset is a
  format property ([the shared
  ciphertext](experiments/16_crypto-model-compare.md#164-the-fmc-and-gsprmboot-share-ciphertext-in-every-version)).
- No header or envelope carries key material. The envelope is
  `publickey[104] || signature[96] || hash[48]`; each chip signs with its own
  production and debug keys, and GB202 shares both with GB100 ([the container
  census](experiments/16_crypto-model-compare.md#165-the-container-census-names-the-chips-and-the-keys)).
- Driver 615.78.08 moves the engine ucode into a `NVUCODES` container and
  signs the production FMC image as the debug FMC, byte-identical, so no
  distinct debug code path exists to leak ([the 615
  corpus](experiments/16_crypto-model-compare.md#166-the-615-corpus-splits-and-resigns-the-fmc)).

### The corpus spans three RM lineages

- The three packages ship three RM lines — `r570_00`, `r596_84`, `r617_07` —
  and the 615.78.08 driver carries the 617-lineage RM; the manifest module set
  only grows per branch ([the module
  map](experiments/17_cross-version-corpus-diff.md#171-the-module-map-spans-three-rm-lineages)).
- The FMC header is frozen across the corpus: magic, flags, the `0x2801`
  constant, zero tails, and the `body = code + data + 0xA00` law hold in all
  fifteen containers on three branches, and the public linux-firmware sample
  is the 570 production container byte-for-byte, so the header is closed as a
  key source ([the header
  census](experiments/17_cross-version-corpus-diff.md#172-the-fmc-and-gsprmboot-headers-are-stable)).
- The secure-boot string families are identical in 570 and 595 and vanish from
  the 615 image: `NV_FWSECLIC_ERR` 126 to 0, `NV_UDE_ERR` 103 to 0, and the
  bare `DEVINIT`, `FWSEC`, and `UDE` substrings are gone, so the bench driver
  is the last branch where those names are readable ([the string
  removal](experiments/17_cross-version-corpus-diff.md#173-the-secure-boot-strings-vanish-in-615)).
- The 595 RM added the `GSP-FMC` error family over 570 (ACR failure, LS
  signature verification, PRI violation detection, an eFMC-versus-GSP hash
  mismatch), which dates the FMC-to-RM handshake checks and names 570 as the
  older image where they are absent; 615 added only bookkeeping strings
  ([what each branch
  added](experiments/17_cross-version-corpus-diff.md#174-what-each-branch-added)).
- No driver branch ships a vBIOS, so a version diff of init tables needs a
  second board source; that is the PRO rental in [the override
  payload](#override-payload-format).

### The DEVINIT data area is a default map

- The plaintext DEVINIT area is two regions — the app `0x23` tail
  `0xC8000`–`0xD5A0C` and a second `0xE8010`–`0xF7B18` beyond the last PCI
  image — and three of the four FEAT-PLM anchors belong to no ucode body, so
  the earlier "app `0x23` data tail" ownership was under-scoped ([the
  bounds](experiments/18_vbios-app23-decode.md#181-the-devinit-data-area-and-its-bounds)).
- The area is a sparse register-default map: about 95% sentinel/poison fill,
  eight per-instance 4 KiB pages, `0x200`-stride records, twin config blocks,
  and 155 per-card calibration dwords ([the
  structure](experiments/18_vbios-app23-decode.md#182-a-sparse-register-default-map)).
- The PLM rows decode one-to-one against the live locked map: the FEAT pair
  value, the `FUSE_SS_PLM` value, and the `0x500300` sparse-block family are
  table data in flash, so the autonomous re-lock reads its values from this
  table ([the PLM
  defaults](experiments/18_vbios-app23-decode.md#183-the-plm-defaults-match-the-live-locked-map)).
- No selector content exists anywhere in the area: zero occurrences of any
  live FEAT value, `SS0`/`SS1` sample or per-card mask, or `SS0` halfword
  shape on either card at any alignment, so the selector's per-card base is
  not on readable flash ([no selector
  content](experiments/18_vbios-app23-decode.md#184-no-selector-content-and-no-loader)).
- No loader exists: target `0x01` is PMU in the only public mapping, no stack
  component reads the table on GB202, and app `0x23` / target `0x0E` stays
  unidentified. The lead is closed as a rate lever.

### The writer is narrowed to two candidates

- Not the FSP: through the 1353 ms re-lock and the GSP start at 2991–3174 ms,
  every sampled FSP register is constant ([the re-lock
  record](experiments/01_software-register-writes.md#019-the-re-lock-moves-fuse_ss_plm-and-no-fsp-register)).
- Not GSP-RM: the re-lock precedes the first RM program counter, and the
  plaintext literal scan found no rate-register reference ([the reset
  window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm),
  [the static
  audit](experiments/02_registry-and-static-audit.md#021-static-scan-finds-no-rate-register-reference)).
- The PMU (power-management microcontroller) or a hardware latch remains.
  The aperture table in the RM image resolves the base question: the PMU is
  the blocked secure core at `0x8f4000`, tied to the legacy `0x10a000` stub
  by one engine tag ([the image names the PMU
  block](experiments/14_engine-map-census.md#146-the-image-names-the-pmu-block)).
  Naming it does not unlock the card; no measured read path enters the
  block.
- The re-lock's values are flash table data: the DEVINIT default map carries
  the locked PLM entries as table rows, authenticated in Heavy Secure, so the
  decode names the writer's data source, not an edit path ([the PLM
  defaults](experiments/18_vbios-app23-decode.md#183-the-plm-defaults-match-the-live-locked-map)).

### The engine map is measured

- BAR0 below `0x1000000` is censused for the falcon
  `HWCFG2`/`CPUCTL`/`ENGINE_RESET` signature at every `0x1000`-aligned base,
  skipping the `0x300000`–`0x400000` hazard; above `0x1000000` nothing but
  sentinels answers at `0x10000` stride ([the falcon-signature
  census](experiments/14_engine-map-census.md#141-the-falcon-signature-census-completes-the-engine-map)).
- Four secure cores answer in the `0x818xxxxx` RISC-V family — GSP, SEC2,
  FSP, and a new block at `0x848000` — with two more secure-shaped blocks at
  `0x8f4000` and `0x854000`. Every new block keeps boot and vector registers
  blocked: engine windows, not access.
- The RM image's engine-aperture table groups the bases by engine and names
  the PMU: `0x8f4000`, beside the FSP, same engine tag as the legacy
  `0x10a000` stub ([the image names the PMU
  block](experiments/14_engine-map-census.md#146-the-image-names-the-pmu-block)).
- The engine tags decode: power-code registry keys name six families, and a
  57-row table in the image maps every tag to the RM engine-type enum the
  open driver publishes. `0x400000` is GR (the FECS doorbells are its own),
  `0x848000`+ NVDEC, the `0x1c8000` quartet NVENC, `0x844000` OFA0,
  `0x9c0000`+ NVJPG, `0x104000` the first copy engine ([the engine-type
  table names the rest of the
  map](experiments/15_tag-decoder.md#152-the-engine-type-table-names-the-rest-of-the-map)).
  Four windows belong to non-engine classes whose descriptors sit in the
  encrypted bindata ([four windows are not
  engines](experiments/15_tag-decoder.md#153-four-windows-are-not-engines-and-their-names-are-encrypted)).
- The `0x100`-stride value map covers `0x0`–`0x42f804` and
  `0x500000`–`0x525100`. No second FECS-shaped command surface appears; the
  candidates are small-value pairs without the blocked command-id register
  ([the doorbell
  census](experiments/14_engine-map-census.md#145-the-coarse-map-and-the-doorbell-census)).
- The per-card table at `0x1f2000` persists across a cold boot and mutates in
  place: 603 of 1,155 words identical, 552 changed in one to four bytes, the
  record-0 header wholesale. Retained per-card state refreshed at power-on —
  training-shaped, not keys, not fuses ([the table across a cold
  boot](experiments/14_engine-map-census.md#144-the-per-card-table-persists-across-a-cold-boot)).
- Two read windows crash GSP-RM through the debugger path with the same fault
  (`pc:0x1368618`, task 3): `0x42f900`–`0x431004` and the `0x525200` batch.
  A read-only scan is code execution on the GSP, and the crash is measured,
  not inferred ([the read that crashes
  GSP-RM](experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm)).

### Host FECS doorbell

**Where it comes from.** The FECS (graphics front-end microcode) block is
read/write-all at `0x4096d0`, and the GSP's doorbell write landed ([the FECS
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
test, and a bad address is likely another FECS fatal, so it needs a
sacrificial card. A hidden selector command would have to be named from the
encrypted handler; the unknown-ID fatal makes brute-force enumeration
destructive.

**Decision.** Closed as a rate route and as a safe enumeration route. The host
command surface is a PL0 DoS primitive, not a lever.

### ICD write opcodes

**Where it comes from.** The PRISCV ICD is a live host debug port: after a
halt, `RREG`, `RCSR`, and `RDM` read the RM code segment byte-exact ([the live
ICD](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)).
The write-memory closure rested on the public header's opcode list, the
driver's API rather than the hardware command set, and no write opcode had
ever been sent.

**What closed.** Twenty-four candidate opcodes were sent to a halted core
against a zero span inside the code window, each with data latched and a
readback. The unassigned opcodes all return `ERROR[14]` and change nothing;
four "accepted" candidates are `RDM` aliases in disguise. The port is
read-only on hardware ([the
aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).

**Decision.** Closed. No code-modification foothold exists at this port.

### Staged-ucode capture

**Where it comes from.** The engine ucode lives in `rm.bindata.bin`, encrypted
with per-blob keys that SEC2 derives in High-Secure mode; the plaintext parts
are the load descriptors, not the code ([the blob
directory](experiments/13_fwimage-map-and-bindata.md#135-the-generic-header-blob-directory)).
The transit record proposed that the decrypted FECS/GPCCS ucode passes through
RM-visible memory between SEC2's decrypt and the falcon's IMEM load, and that
a timed halt-and-dump through the debug engine would capture it with no key
([the transit
record](experiments/13_fwimage-map-and-bindata.md#136-the-decrypted-ucode-transit-and-its-read-route)).

**What closed.** Both legs are measured out. The `sec2_acr` log args that
motivated the transit were a 4-second timeout pair, not staging pointers, so
the transit itself is unproven ([the
decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)).
And the halted-core ICD reads exactly the RM code segment and refuses the
heap, the runtime range, and the WPR, with no write opcode either, so no read
at any moment reaches a staging buffer ([the
aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
The census work survives: the two `0xf900` blobs are the GR-falcon shape, and
the dump matcher is ready for any future read primitive ([the
census](experiments/13_fwimage-map-and-bindata.md#138-the-blob-census-five-families)).

**Decision.** Closed as designed. The enforcement fork, FECS ucode or silicon,
moves to [the FECS doorbell](#host-fecs-doorbell), which answers behaviorally
whether a FECS command can select the rate. A new read primitive into WPR
memory would reopen this lead; none is known.

### Closed, do not retry

- The flanking readouts as a target. Every RM consumer of `FEAT_READOUT_0`
  and `FEAT_READOUT_2` is an ECC capability flag with a config-byte fallback,
  clear on both 5090s and both PRO 6000s; the bits that differ between the
  product classes have no reader in the image, and the three reader slots
  without callers cannot gate anything ([the readout
  decode](experiments/12_feat-readout-decode.md)). `READOUT_1` is the only
  selector carrier. Do not re-plan around the other readouts.
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
  or aliased to `RDM` on a halted core ([the
  aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
- ICD reads outside the code segment from a halted core. The aperture is
  `0x01000000–0x01DCD000`; the container bindata, the data segment, the whole
  runtime range at 1 MiB steps, and every WPR address refuse ([the
  aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
- The staged-ucode capture through the ICD. The transit through RM-visible
  memory is unproven (its evidence was a misread timeout pair), and no tested
  host read path reaches the heap or WPR ([the transit
  record](experiments/13_fwimage-map-and-bindata.md#136-the-decrypted-ucode-transit-and-its-read-route)).
  The EMEM and DMEM ports were sampled only at steady state; [the timed port
  capture](#timed-emem-and-dmem-capture) is the untested route.
- Direct PL2 FEAT or PLM writes, including the exact `0x88888888`/`0x8`
  payload. Dropped by the mask, with no rate change ([the write
  test](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped),
  [the payload
  test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).
- The FECS command set as a rate selector. The host and PL2 can issue
  commands, but the known `0x21` command does not move the bank or the rate,
  and the plaintext command map has no selector ([the host command
  record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).
- Unassigned FECS command IDs as a probe. An unknown ID fatal-errors the FECS
  (`Xid 13`), so a blind sweep is destructive ([the host command
  record](experiments/03_fecs-and-gr-context.md#0310-the-host-can-command-fecs-and-an-unknown-id-is-fatal)).
- Registry speed keys. Parsed, stored, booleanized, inert ([the registry
  sweep](experiments/02_registry-and-static-audit.md#024-speed-select-keys-are-inert-on-hardware)).
- BAR1 and physical address `0x5dd00000`. Structurally closed ([the FB
  route](experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)).
- CUDA debugger-class FEAT writes. The class reads the bank and the write
  drops ([the debugger
  test](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- Reading FECS/GPCCS code or state from the host at the documented bases. The
  FECS, GPCCS, and PMU falcon bases return decode or not-implemented markers,
  the security engines block their boot vectors, and the GR window the GSP-RM
  admits is empty. The space above it is the vBIOS ROM and one per-card
  table, not ucode ([the falcon
  probe](experiments/11_falcon-and-gr-window-probe.md), [the
  window](experiments/11_falcon-and-gr-window-probe.md#112-the-admitted-gr-window-is-empty),
  [the GR
  map](experiments/11_falcon-and-gr-window-probe.md#114-the-space-above-the-window-is-the-vbios-rom)).
  The PMU base is unknown; [engine naming](#engine-naming-and-the-unmapped-bands)
  is where the search continues among the [census
  candidates](experiments/14_engine-map-census.md#141-the-falcon-signature-census-completes-the-engine-map).
- Reading ucode through the vBIOS table on GB202. The host FWSEC path is
  chip-gated to a stub and the RM boots GR through `sec2_acr` from RM memory
  ([the consumer
  record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
- The `0x137200` lead. It is a privilege-protected FECS/GR register
  (`0xc120048a` in a `0x30`-byte entry pattern); the FECS log pairs it with
  `0x14252215` and the refusal `0xbadf5128` ([the descriptor
  record](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read)).
- JTAG pads. Production parts gate them with secure-debug fuses and signed
  unlock tokens; no public GeForce success exists. The retail card's class
  list exposes the debugger class instead, and its FEAT write drops ([the
  debugger group](experiments/10_debugger-class-and-fecs-ucode.md)).
- BAR0 reads in `0x42f900`–`0x431004` and the `0x525200`–`0x532c00` batch
  through the debugger path. Both fault the GSP task at the same PC (Xid
  120, `pc:0x1368618`) and end in Xid 154 with a forced reboot; a
  read-only scan is code execution on the GSP. Skip both windows, and carry
  a canary read in every batch ([the read that crashes
  GSP-RM](experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm)).

## Known-unknowns

Open questions with a named next run, ordered by the [index](#the-index)
priority.

### The load-bearing unknowns

Four questions decide whether the endgame works. None has a run behind it,
and the first two are answerable only after a PL3 writer exists.

1. **Does the Blackwell override path work at all?** No measured part has an
   override-enable bit set: the PRO 6000s reach full rate through absent fuse
   penalties, not through the override. The `0x88888888`/`0x8` payload is
   Ampere/Ada prior art ([the two override
   paths](specs/02_privilege-and-rate-control.md#the-two-override-paths),
   [the payload
   test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).
   The first writer session answers it.
2. **Does the rate follow a live write, or latch at init?**
   `SM_ISSUE_RATE_MODIFIER` is reasserted at every CUDA context creation, so
   runtime re-assert paths exist in firmware ([the FUSE/rate
   test](experiments/01_software-register-writes.md#014-the-fuse-shadow-and-the-inert-modifier)).
   Whether `SS0`/`SS1` are sampled live or latched at GR init decides whether
   the writer test needs a driver reload mid-run.
3. **Is the enforcement microcode or silicon?** The FECS-ucode-versus-silicon
   fork sits in the encrypted bindata, behind per-blob keys ([the fwimage
   map](experiments/13_fwimage-map-and-bindata.md)). If silicon, the register
   override is the only lever and the fork stops mattering.
4. **Who writes the bank at power-on?** The PMU or a hardware latch. The
   PMU half is now concrete: the aperture table in the RM image names its
   block `0x8f4000`, a blocked secure core beside the FSP ([the image names
   the PMU
   block](experiments/14_engine-map-census.md#146-the-image-names-the-pmu-block)).
   The re-lock values are [table data in
   flash](experiments/18_vbios-app23-decode.md#183-the-plm-defaults-match-the-live-locked-map),
   and the selector's per-card base is absent from readable plaintext, so the
   writer reads per-card state the flash does not carry. What stays open is
   PMU-versus-latch, a timing question, not a base question.

### Engine naming and the unmapped bands

**Where it comes from.** The engine-map census ran and the aperture table
named the one block that matters: the PMU is `0x8f4000`
([the image names the PMU
block](experiments/14_engine-map-census.md#146-the-image-names-the-pmu-block)).
The naming half of this lead then closed without hashing: the power code's
registry keys and a static engine-type table in the image name thirteen
tags, and only four non-engine windows stay encoded behind the bindata
([the engine-type table names the rest of the
map](experiments/15_tag-decoder.md#152-the-engine-type-table-names-the-rest-of-the-map)).
What stays open is the map itself: two holes, both bounded by measurement:
`0x42f804`–`0x500000` (contains a crash window) and `0x525200`–`0x1000000`
(the map run died at its first batch past `0x525100`).

**Try.** With the crash windows skipped, finish the `0x100`-stride map from
`0x532c00` upward in one-batch steps with the canary, stopping at the first
refusal.

**Decision.** Family names complete the engine map but do not unlock the
card; they are in hand. A complete map with no second command surface closes
the surface census below `0x1000000` for good.

### RM interface and log census

**Where it comes from.** The GR control table has 44 entries and no rate
setter ([the rate
getter](experiments/07_plaintext-corpus.md#076-the-rate-getter-has-no-hidden-setter)).
That census covers one control class. The plaintext RM also holds the other
control classes, the falcon accessors, and the FWSEC-LIC unit whose strings
name the secure-data path ([the secure-data
unit](experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)).
The exact FWSEC-to-SEC2 sequence and the falcon accessors are unmapped.

**Try.** Enumerate every control-table entry and handler in the plaintext RM:
control ID, parameter size, and whether the handler touches the `0x8238xx`
bank, a fuse word, a falcon base, or the FWSEC path. Build a log-string map
for `override`, `speed`, `PLM`, `fuse`, `ucode`, `secure`, and `falcon`, and
resolve each string to its log thunk. Then decompile the FWSEC-LIC callers
and the falcon accessors.

**Decision.** A host-callable handler that reads or writes engine memory, or
that selects a ucode image, is a new surface. A complete map with no such
handler narrows the search to the PL3 code and the debugger class.

### Computed-offset sweep and devinit handlers

**Where it comes from.** The static audit scanned the plaintext region of the
GSP-RM image, about 18.5 MB of the 72.8 MB file; the rest is encrypted ([the
plaintext
boundary](experiments/13_fwimage-map-and-bindata.md#132-the-plaintext-boundary)),
for references to the six rate registers and found zero literal hits; the
computed-offset correction was applied to the `0x3814` decoder only ([the
static
audit](experiments/02_registry-and-static-audit.md#021-static-scan-finds-no-rate-register-reference)).
Runtime base-plus-offset and table-indexed forms were never swept, so the
no-RM-writer claim rests on the literal pass. The devinit app-ID loaders and
the `0x8238b0` and `0x9668` consumers are also unmapped in the image ([the
register map](specs/03_register-map.md#limits-and-open-questions)).

**Try.** Use [the GSP-RM tools](tools/gsp-rm-tools/) to sweep the image for
computed references to `0x823804`, `0x82381c`, `0x823820`, `0x8207d8`, and
`0x504204`, then name the devinit app-ID handlers and the small-object
consumers.

**Decision.** A computed reference reopens the no-RM-writer claim and feeds
[the load-bearing unknowns](#the-load-bearing-unknowns). An empty sweep
leaves the devinit attribution resting on the live poll alone.

### SR descriptor and page table

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
pre-suspend marker and no post-resume marker. Run the stock control first,
then `flags` (1, 2), `sizeOfSuspendResumeData` (stock, half, 16 MiB), and
radix3 deltas. The PTE tests need a new hook: `sr_oracle.sh` varies only the
scalar fields. Then a PTE that points at a duplicate page, a PTE that crosses
a 4 MiB run boundary, and an unmapped entry.

**Decision.** A resume that completes with a changed size or pointer, or a new
hang point, is a parser surface. Heavy Secure validating the PTEs before
walking them closes the table. Every failed variant costs a reboot.

### Context patch buffer

**Where it comes from.** The patch buffer is host-owned, and the post-use
differential shows 10 changed address values in 287 entries ([the patch
differential](experiments/03_fecs-and-gr-context.md#035-the-post-use-patch-buffer-differential)).
The host can edit it after the GSP fills it and before the next use.

**Try.** Rewrite one of the 10 changed values to a valid and then an invalid
framebuffer address; observe the launch, the GSP log, and any Xid (GPU error
report).

**Decision.** A context that uses the changed address is a host-controlled
pointer into the GSP/FECS image. A clean crash closes it. A working pointer
is a PL2 write primitive, feeds [the PL2 read oracle](#pl2-read-oracle), and
changes what the parser leads can observe.

### Timed EMEM and DMEM capture

**Where it comes from.** The GSP EMEM, the FSP EMEM channels, and the SEC2
DMEM port are host-readable. They were sampled with the driver bound and the
GSP-RM running, and read empty or constant ([the GSP EMEM
record](experiments/04_hs-sec2-fsp-memory.md#041-gsp-emem-is-real-but-empty),
[the ICD
aperture](experiments/04_hs-sec2-fsp-memory.md#046-the-icd-aperture-is-the-code-segment)).
The FMC decrypts and runs before the GSP-RM exists, and the SEC2 decrypt
window is about 20 ms, bracketed by the `sec2_acr` log pair ([the timeout
decode](experiments/13_fwimage-map-and-bindata.md#137-the-sec2_acr-args-are-a-timeout-pair)).
The steady-state sample cannot see either window.

**Try.** Use [the direct probe](tools/direct-probe/) on a cold boot and
stream the GSP EMEM (`0x110ac0`), the SEC2 DMEM port (`0x8401c0`), and the
four FSP EMEM channels (`0x8f0ac0`–`0x8f0adc`) with the auto-increment read
flag. Arm on the first `sec2_acr` line, again on the first `gr_fecs` line,
and across a GC6 re-decrypt. Read only, and budget a wedge. Also capture a
GSP core dump and check whether it carries RM heap or engine state.

**Decision.** Any plaintext parcel or key-shaped block in a port is a read
primitive and the first decrypted FMC or ucode bytes. A uniform zero or
constant across all windows closes the ports and leaves the ICD as the only
measured read path. The capture also times the image read, which is what
[the boot race](#boot-input-race) needs to aim its flip.

### Boot-input race

**Where it comes from.** The FMC container is bound to the COT hash, and a
static byte change draws `0x33` ([the tampered
container](experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered)).
The GSP-RM and bootloader images are bound the same way and draw `0xaff`
([the patched
image](experiments/05_fmc-fsp-boot-inputs.md#052-patched-gsp-rm-image-rejected-by-the-fmc)).
Every test changed bytes before the read. None changed them during it, and
the hash-to-decrypt window is still open ([the container
record](experiments/05_fmc-fsp-boot-inputs.md#0519-fmc-container-read-back-and-tampered)).

**Try.** The [cold-boot map](experiments/09_fmc-cold-boot-parsers.md) shows
the image bytes are behind authentication and the bootloader and radix3
pointers are pinned. The race is the remaining way past the image hash. Flip
the FMC header's `bodySize` or `codeSize` at high rate while booting and
watch for an error other than `0x33`. Then swap a plaintext GSP-RM image
between stock and patched copies during boot. Then alternate the `WprMeta`
bootloader and radix3 pointers between two valid copies.

**Decision.** A patched plaintext GSP-RM that boots is PL2 code execution. It
is also the read oracle in [the PL2 read oracle](#pl2-read-oracle); treat a
success as an information primitive even before it helps the FEAT write. A
modified FMC image that boots runs at PL3 and can write the FEAT gate. A
uniform `0x33` or `0xaff` closes the race. Use [the driver
harness](tools/driver-harness/) and expect reboots. Run it after [the timed
capture](#timed-emem-and-dmem-capture), which tells you when the read
happens.

### FSP framing

**Where it comes from.** The FSP has no length field. The host controls the
transmit length through `NV_PFSP_QUEUE_TAIL(0)`, and the response identity is
unchecked ([the static FSP
pass](experiments/08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp),
[the FSP command surface](specs/01_boot-chain.md#fsp-command-surface)). The
FSP is immutable ROM, so this is a black-box parser probe.

**Try.** Vary the transmit tail distance by ±1..N; send a never-EOM fragment;
craft a response with a mismatched task, tag, or SEID (source endpoint ID).
Use netconsole and a sacrificial card.

**Decision.** A new error code or state is a parser surface. A clean refusal
closes the framing. The FSP is ROM, so a framing bug is unpatchable by any
driver update; the finding would outlive every other parser result on this
page.

### Carveout layout fields

**Where it comes from.** The two heap-size levers are measured:
`gspFwHeapSize` moves the WPR downward ([the heap-size
test](experiments/05_fmc-fsp-boot-inputs.md#0513-heap-size-request-honoured-downward)),
and `nonWprHeapSize` grows the unprotected heap 1:1 from a fixed WPR base
([the non-WPR heap
test](experiments/09_fmc-cold-boot-parsers.md#097-the-non-wpr-heap-size-is-a-11-layout-lever)).
The ACR (the loader before the FMC) fields and the FMC `wprCarveout*` fields
in the boot parameters were never varied ([the boot-parameter
print](experiments/05_fmc-fsp-boot-inputs.md#051-host-side-boot-and-static-info-instrumentation)).

**Try.** Vary one ACR or carveout field per boot and read the GSCI layout.
Then a field that moves the WPR start or the FRTS anchor.

**Decision.** A boundary that moves with a host field is a layout lever. A
fixed boundary closes the fields.

### Boot-args buffer

**Where it comes from.** The host builds three boot structures that secure
firmware parses: the COT, `WprMeta`, and `SRMeta`. The COT also carries a
GSP boot-args sysmem pointer ([the COT](specs/01_boot-chain.md#cot-v2)), a
fourth host-built buffer. The cold-boot group varied every `WprMeta` field
and the boot-buffer geometry ([the parser
group](experiments/09_fmc-cold-boot-parsers.md)); the boot-args buffer itself
was never varied, and which stage consumes it is part of the question.

**Try.** First enumerate from the driver source every sysmem buffer built for
secure firmware; the census either confirms the four or names a fifth, and a
fifth is a new parser surface before any hardware run. Then add a boot-args
oracle to [the driver harness](tools/driver-harness/): stock control first,
then one field per boot — the size, the flags, the per-engine offsets, and a
moved pointer. Watch for a structured error, a hang, or a GSP log line.

**Decision.** A bounded parser with clean refusals closes the buffer. A hang
or a structured error is a new parser surface in the same class as [the SR
descriptor](#sr-descriptor-and-page-table); a foothold probe, not a selector
route.

### SR saved-state malleability

**Where it comes from.** The saved state is encrypted, but the log only
tests confidentiality: entropy and a scan for known constants ([the saved
state](experiments/06_sr-resume.md#063-the-saved-state-is-high-entropy-ciphertext)).
It never flips a bit. The state spans the WPR through the GSP-RM heap and
code, and the host builds the radix3 ([the host-driven
cycle](experiments/06_sr-resume.md#061-the-suspend-and-resume-cycle-is-host-driven)).

**Try.** Use [the driver harness](tools/driver-harness/) to flip one
ciphertext bit in a zero page, a heap page, and a code page, then permute two
valid page-table entries. Under CTR or ECB, a code flip is a controlled patch
of known plaintext.

**Decision.** A code flip that boots and executes gives PL2 execution, a
foothold rather than the selector. A hang on every data-page flip points to
authentication. Run this only after [the SR descriptor](#sr-descriptor-and-page-table),
because a descriptor bug is the stronger route.

### Per-SM channel

**Where it comes from.** `GR_CTX`, `TPC`, `SM`, and `QUAD` return `0x1f` with
every subdevice route ([the GR_CTX
probe](experiments/01_software-register-writes.md#017-per-context-registers-need-a-caller-owned-channel)).
The host validation checks only the offset; the rejection comes from the GSP,
so it is a caller-identity check, not proof the space is unreachable. The
CUDA debugger class has the channel context the RM path lacked. Its `GR_CTX`
reads the space; `TPC`/`SM`/`QUAD` still return `regStatus=2`, and the space
has no FEAT-selector mirror. The only rate register is the inert `0x504204`
([the context
record](experiments/10_debugger-class-and-fecs-ucode.md#102-the-context-and-descriptor-spaces-read)).

**Try.** The remaining piece is the typed read with `hChannelTarget` set to a
live channel, and a per-SM offset under a valid group/subgroup mask. The
`0x504xxx` sweep is done.

**Decision.** The space is readable; it is not a rate lever. A per-SM offset
that changes with the selector would reopen it; the inert `0x504204` and the
`0x504240` table do not.

### vBIOS ucode key search

**Where it comes from.** The 16! key search targeted the FMC and SEC2 booter
containers only ([the key
search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)).
The four encrypted vBIOS bodies — the two PMU-family target-`0x01` images,
app `0x23`, and target `0x0e` — were never searched, and the PMU devinit is
the leading FEAT-writer candidate ([the load-bearing
unknowns](#the-load-bearing-unknowns)). The two target-`0x01` bodies share a
plaintext preamble ([the
bodies](experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)),
a known-plaintext structure the FMC oracle was not built to exploit. The
search's own leftovers are also unrun: the ~1.9 h intermediate round keys 1–9,
and the XTS and compressed-then-ECB modes the ECB, CBC, and CTR passes did
not cover. A third corpus exists now: `rm.bindata.bin` holds the engine ucode
behind per-blob AES, but the keys are derived inside SEC2's High-Secure
ucode, not embedded in the image ([the secure-data
unit](experiments/13_fwimage-map-and-bindata.md#134-the-fwsec-lic-secure-data-unit)),
so an offline search there attacks a derivation, not a stored key.

**Try.** The gate is answered: the corpus keys are [not
device-bound](experiments/16_crypto-model-compare.md#161-the-encrypted-vbios-is-card-independent),
so a key found on one card decrypts every card of the same board build. Point
[the FMC tools](tools/fmc-tools/) at the four vBIOS bodies and the encrypted
PROM head blob: the exhausted permutation family under the tested modes
first, then the intermediate round keys, then the untested modes. Add a
known-plaintext oracle around the shared target-`0x01` preamble; the two
bodies share only the 8-byte family header, so the oracle starts there. For
the bindata corpus, use the 66 plaintext headers and the structured block at
`0x3cbc000` as known plaintext, and consume the [per-copy 16-byte
seed](experiments/16_crypto-model-compare.md#163-duplicated-ucode-diverge-at-a-per-copy-seed)
as a per-blob IV or key-derivation input rather than hunting for it ([the
blob
directory](experiments/13_fwimage-map-and-bindata.md#135-the-generic-header-blob-directory)).

**Decision.** A decrypted PMU body names the pre-lock writer and may carry
the FEAT write table; it feeds [the load-bearing unknowns](#the-load-bearing-unknowns)
and would confirm the [DEVINIT default-map](#the-devinit-data-area-is-a-default-map)
decode at once. A negative result extends the
FMC conclusion to the vBIOS corpus and closes the decrypt route for good. For
the bindata corpus, weigh the search against [the staged-ucode
capture](#staged-ucode-capture) first: the capture reads the same code with
no key at all.

### Override payload format

**Where it comes from.** The full-rate readout is measured on two RTX PRO
6000s: both read `FEAT_READOUT_1 = 0` with every arithmetic speed fuse at 0,
and card A runs BF16 at 518 TF/s with the FP16-accumulate rate equal ([the
reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
Both cards also have every `SS0`/`SS1` enable bit clear, so their full rate
comes from the absence of a fuse penalty: an already-zero selector needs no
override. A throttled part needs the override, and its format is the one the
prior art measured, `SS0 = 0x88888888` and `SS1 = 0x8`, written from the host
once PL3 code opens `FEAT_OVR_PLM` ([the two override
paths](specs/02_privilege-and-rate-control.md#the-two-override-paths)). The
payload is a post-writer question: without a write that passes the PLM, no
boot series can validate it on GB202. The PL2 variant is measured and drops
([the payload
test](experiments/01_software-register-writes.md#0110-the-exact-override-payload-is-dropped-from-pl2)).
The FLR leg is already measured in the other direction: the words survive the
reset ([the bank across
resets](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)),
so the Ada write-then-FLR sequence keeps the override.

**Try.** Run the existing FP16-accumulate mode on the 5090 to measure its cap
ratio locally ([the issue-rate probe](tools/issue-rate-probe/)). Get a
same-card cold-boot series on a PRO 6000 and compare `SS0`/`SS1` movement
with the 5090's ([the FEAT-bank boot
test](experiments/05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)).
The 2026-10-31 rentals captured only the register banks and the issue rate;
add the PRO 6000's vBIOS and GSP-RM image to the same session, so [the vBIOS
ucode key search](#vbios-ucode-key-search) gets the full-rate card's corpus
and the [DEVINIT default map](#the-devinit-data-area-is-a-default-map) gets a
cross-board compare. Run the exact payload only after a PL3
writer exists, and treat that session as the answer to [the load-bearing
unknowns](#the-load-bearing-unknowns): the override plumbing and the
live-or-latched question.

**Decision.** A PRO enable bit would mean the full-rate part also sets the
override; its absence leaves the words as runtime state. The format is
already measured on the prior art, so the cold-boot series sharpens the
picture but does not validate the payload on GB202. Fold it into a future PRO
rental; do not plan a run around it.

### PL2 read oracle

**Where it comes from.** The GSP-RM runs at PL2, owns the WPR, and loads the
engine ucode. A patched RM is treated as a foothold for probes, not as a read
path ([the
assessment](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).
The RM's falcon accessors and the FWSEC path are unmapped ([the RM
census](#rm-interface-and-log-census)), and [the boot race](#boot-input-race)
and [the context patch buffer](#context-patch-buffer) are the enablers.

**Try.** After a boot-race, patch-buffer, or RM-bug primitive, read FECS and
GPCCS IMEM through the RM's own falcon access, and dump the WPR and FRTS
through its heap access. Start with the ucode the RM just staged, then the
saved state. Keep the stock restore path.

**Decision.** A single byte of decrypted engine ucode confirms the RM as the
read oracle and turns the enforcement question into a code review. A
primitive that cannot read engine memory leaves the ICD and the ports as the
only read paths.

### vBIOS ucode corpus

**Where it comes from.** The vBIOS carries four encrypted ucode images. The
table is the PMU lookup table and target `0x01` is PMU in the only public
mapping, so the two target-`0x01` bodies are a PMU-family pair, not
FECS/GPCCS ([the table
decode](experiments/11_falcon-and-gr-window-probe.md#113-the-ucode-table-is-the-pmu-lookup-table)).
All four descriptors are version 6, `0x50` bytes. The stored size equals the
body length, and the two target-`0x01` images share a plaintext preamble
([the
bodies](experiments/10_debugger-class-and-fecs-ucode.md#103-the-vbios-ucode-bodies)).

**What closed.** No component in the open stack reads the table on GB202. The
host FWSEC loader is the only parser, it accepts apps `0x05`/`0x45`/`0x85`
and descriptor versions 2 and 3, and the Blackwell chip binding maps the VBIOS
extraction to a stub returning `NV_ERR_NOT_SUPPORTED`, which the init path
treats as success. The GSP-RM has no BIT parser, and the RM boot log starts
GR through `sec2_acr` with RM-memory pointers ([the consumer
record](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).
The four bodies are not GR ucode on this card.

**Try.** Identify target `0x0e` and find the consumer in another stack, such
as the Windows driver or the device firmware. Check the encrypted bodies
against the FMC key family; the corpus keys are [not
device-bound](experiments/16_crypto-model-compare.md#161-the-encrypted-vbios-is-card-independent),
so the check is meaningful. The Falcon parcels oracle
only matters after a FECS/GPCCS consumer is named ([the FMC
tools](tools/fmc-tools/)).

**Decision.** The corpus is closed for the Linux open-driver route. Only a
consumer in a different stack would reopen it.

## Unknown-unknowns

Where the observation net has holes no lead names. Each block says what the
hole is, why the closed claims do not cover it, and which lead shrinks it.
The P0 rows in [the index](#the-index) exist to attack these.

### The surface census has a first half

The BAR0 half ran: every `0x1000`-aligned base below `0x1000000` answered the
falcon-signature question, and the `0x100`-stride value map covers
`0x0`–`0x42f804` and `0x500000`–`0x525100`. No sibling of the
`0x409500`/`0x409800` pair appears in the mapped bands ([the doorbell
census](experiments/14_engine-map-census.md#145-the-coarse-map-and-the-doorbell-census)),
and the two unmapped bands are bounded by measured crash windows. The other
halves are still open: all host-built buffers that secure firmware parses
(the COT, `WprMeta`, `SRMeta`, and boot-args are the four known; is the list
complete?), and all RM control classes. A surface nobody thought to probe
still cannot appear on this page as a lead. Shrunk further by [the RM
census](#rm-interface-and-log-census) and the driver-source enumeration in
[the boot-args buffer](#boot-args-buffer).

### Every empty read carries a hidden "at steady state"

The port and memory reads that came back empty were taken with the driver
bound and the GSP-RM running. The FMC decrypt, the ~20 ms SEC2 window, and
the GC6 re-decrypt have never been observed by anything. Every "reads empty
or constant" claim therefore describes steady state only. Shrunk by [the
timed port capture](#timed-emem-and-dmem-capture), the one lead that can
return information nobody predicted.

### One driver version carries every static claim

Every parser result and every static closure is 595.91.07, plus the two PRO
reference versions. The corpus diff ran and inverted the worry: the string
families that carry the static claims are identical in 570 and 595 and are
dropped entirely from the 617-lineage image ([the string
removal](experiments/17_cross-version-corpus-diff.md#173-the-secure-boot-strings-vanish-in-615)),
so the readable window closes at the bench driver and later branches cannot
be string-mapped the same way. What the diff did date is the 595-only
`GSP-FMC` check family, absent in 570; no card on the bench runs 570, so a
behavioral differential across that step stays untested.

### The readable quarter of the image

About 18.5 MB of the 72.8 MB GSP-RM file is plaintext. The no-RM-writer claim
and the FECS command map rest on scans of the readable part; the enforcement
ucode and any RM-loaded applet sit in the encrypted `rm.bindata.bin`. The
honest form of those claims is "no writer in the readable quarter," and the
quarter itself shrinks: the 617-lineage image drops the secure-boot string
families from its plaintext ([the string
removal](experiments/17_cross-version-corpus-diff.md#173-the-secure-boot-strings-vanish-in-615)).
Shrunk by
[the computed-offset sweep](#computed-offset-sweep-and-devinit-handlers), [the
crypto-model
compare](experiments/16_crypto-model-compare.md), and [the PL2 read
oracle](#pl2-read-oracle).

### The instrument destroys its own evidence

A failed resume or boot variant ends in a reboot, and the post-failure state
dies with it. The success signal for the reboot-budget leads is a new hang
point, and whether that signal is readable depends on the Xid and GSP-log
capture, not on the probe. Standardize the netconsole, GSP-log, and Xid
capture on every mutating run before spending the P1 reboots. The census
adds a second, quieter failure: a degraded read path that returns silent
zeros. Every scan batch should carry a known-value canary read and an
RM-status check, the pattern [the census
crash](experiments/14_engine-map-census.md#143-a-read-through-the-debugger-path-crashes-gsp-rm)
forced; without it a dead path is indistinguishable from an empty register.

---

This page contains no exploit. Every mutating run needs a stock restore and an
expected reboot.
