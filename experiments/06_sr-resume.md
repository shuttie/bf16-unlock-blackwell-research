# The host-built suspend and resume state

## Summary

**The idea.**

- A device-level suspend/resume (SR) cycle makes the host build two structures:
  [`SRMeta`](../specs/01_boot-chain.md#suspendresume), a 256-byte descriptor with the saved-state size, flags, and page-table
  pointer; and a three-level [radix3](../specs/01_boot-chain.md#suspendresume) page table that maps the saved state.
- The [FMC](../specs/01_boot-chain.md#terms) (first-stage mutable GPU firmware) consumes both on resume. The saved
  state covers the region from the [non-WPR heap](../specs/07_memory-and-host-access.md#the-non-wpr-heap) through [FRTS](../specs/07_memory-and-host-access.md#wpr-and-frts-layout), the firmware
  runtime state region inside the WPR, the write-protected firmware region.
- I ran the stock cycle, changed `SRMeta.magic`, dumped the state, and parsed the
  page table.

**What it found.**

- The [host builds SRMeta and the
  radix3](#061-the-suspend-and-resume-cycle-is-host-driven) in unprotected
  memory; both cards resume in about 8 s.
- A [wrong SRMeta.magic hangs the
  resume](#062-a-bad-srmeta-magic-hangs-the-resume) with no host-visible error.
- The [saved state is 205.875 MiB of high-entropy
  data](#063-the-saved-state-is-high-entropy-ciphertext) with none of the
  [selector constants](../specs/03_register-map.md#feat-bank).
- The [radix3 is plaintext and fully
  mapped](#064-the-radix3-is-plaintext-and-fully-mapped); the data pages are
  per-boot and per-card ciphertext.

**What it did not find.**

- The [cipher or key](#063-the-saved-state-is-high-entropy-ciphertext) for the
  saved state.
- Whether [Heavy Secure (HS) validates
  SRMeta](#062-a-bad-srmeta-magic-hangs-the-resume) or [the page-table
  entries](#064-the-radix3-is-plaintext-and-fully-mapped).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 06.1 | [The suspend and resume cycle is host-driven](#061-the-suspend-and-resume-cycle-is-host-driven) | Host builds SRMeta and radix3 |
| 06.2 | [A bad SRMeta magic hangs the resume](#062-a-bad-srmeta-magic-hangs-the-resume) | Hang; no error code |
| 06.3 | [The saved state is high-entropy ciphertext](#063-the-saved-state-is-high-entropy-ciphertext) | 205.875 MiB; no selectors |
| 06.4 | [The radix3 is plaintext and fully mapped](#064-the-radix3-is-plaintext-and-fully-mapped) | 52,704 PTEs; per-boot data |

## 06.1 The suspend and resume cycle is host-driven

**Question.** Does a device-level suspend/resume cycle exercise the SR path, and
does the host build [`SRMeta`](../specs/01_boot-chain.md#suspendresume) plus the radix3 that the [FMC](../specs/01_boot-chain.md#terms) consumes on resume?

**Why.**

- The host controls the suspend descriptor and page table. If they are plaintext,
  they are a host-facing input surface.
- The [4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) wrote the
  selector from a PL3 boot image; the SR path is another place where host-built
  data reaches secure firmware.
- What it would give: a live host-to-FMC input surface, or confirmation that the
  cycle is closed.

**Method.**

- Tool: `sr_resume_test.sh` from [driver harness](../tools/driver-harness/),
  which builds and loads the instrumented 595.91.07 tree, captures dmesg, and
  restores stock in a trap. Root required.
- Target: both RTX 5090s in one cycle.
- Steps:
  - Trigger a device-level s2idle cycle.
  - Capture the `SRMeta` and FMC boot parameter lines.
  - Check that both cards return.
- Trigger: write `devices` to `/sys/power/pm_test`, then `mem` to
  `/sys/power/state`.
- Args used:
```bash
sudo tools/driver-harness/sr_resume_test.sh
echo devices > /sys/power/pm_test
echo mem > /sys/power/state
```

**Observed data.** Captured dmesg from the stock cycle:

```text
PM: suspend entry (s2idle)
NVRM: kgspPrepareSuspendResumeData_TU102: BF16: SRMeta magic=0x8a3bb9e6c6c39d93 rev=2 size=0xcde0000 flags=0x0 radix3Addr=0x148c00000
NVRM: kgspPrepareSuspendResumeData_TU102: BF16: SRMeta inputs frts{off=0x7f42c0000 size=0x100000} nonWpr{off=0x7e72e0000 size=0x300000}
NVRM: kgspSetupGspFmcArgs_GH100: BF16: FMC boot params: bootMode=1 regkeys=0x0 bootGspRm{desc=0x1ae65c000 size=0x100 target=2 bBoot=1} ...
PM: suspend exit
Restarting tasks: Done
```

The second card printed the same fields with `radix3Addr=0x1af000000`.

**Result.**

- **Answer:** yes. The host builds `SRMeta` and the radix3 in unprotected memory
  and hands the descriptor to the FMC on resume. Both cards return in about 8 s.
- **What we learned:**
  - Both `SRMeta` sizes are [`0xcde0000`](../specs/01_boot-chain.md#suspendresume), matching the WPR span measured at boot
    ([memory and host access](../specs/07_memory-and-host-access.md#wpr-and-frts-layout)).
  - The descriptor carries [`magic=0x8a3bb9e6c6c39d93`](../specs/01_boot-chain.md#suspendresume), `rev=2`, `flags=0`, the
    FRTS/non-WPR inputs, and a per-card `radix3Addr`.
  - The resume uses `bootMode=1` and the host-built descriptor instead of
    [`WprMeta`](../specs/01_boot-chain.md#wprmeta), the cold-boot descriptor ([boot chain](../specs/01_boot-chain.md#suspendresume)).
  - The page table is built in unprotected sysmem, so the structure is readable.
- **Related:**
  - The [bad-magic run](#062-a-bad-srmeta-magic-hangs-the-resume) tests whether
    the FMC consumes the descriptor.
  - The [state dump](#063-the-saved-state-is-high-entropy-ciphertext) reads the
    mapped state.
- **Open question:** does [HS](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) validate the descriptor? This run shows the host
  builds and passes it, not that firmware checks it.

## 06.2 A bad SRMeta magic hangs the resume

**Question.** Does the FMC/SR code consume [`SRMeta.magic`](../specs/01_boot-chain.md#suspendresume), and does a wrong magic
return an error or hang?

**Why.**

- If the magic is unchecked, the host can hand arbitrary descriptors to secure
  firmware.
- If it hangs, the SR path is a blind probe surface: no host log, and every
  attempt costs a reboot.
- What it would give: evidence that the FMC parses the descriptor, and a warning
  about the cost of probing it.

**Method.**

- Tool: `sr_oracle.sh 1` from [driver harness](../tools/driver-harness/), which
  sets `BF16_SR_VARY=1` and `BF16_SR_VALUE=0xdeadbeefdeadbeef`, rebuilds, loads,
  and triggers the same cycle.
- Target: both cards.
- Steps:
  - Run the stock cycle with only the magic changed.
  - Inspect the previous boot's log.
  - Add netconsole or phase markers first, because journald freezes before the
    failure.
- Args used:
```bash
sudo tools/driver-harness/sr_oracle.sh 1
```

**Observed data.** The captured run log ends at the trigger:

```text
== BF16 SR oracle: field=1 value=0xdeadbeefdeadbeef
== pm_test=devices suspend/resume cycle
```

The previous boot's journal ends at:

```text
PM: suspend entry (s2idle)
Filesystems sync: 0.039 seconds
```

No later line was flushed. The kernel never resumed, so there is no post-freeze
dmesg.

**Result.**

- **Answer:** the machine enters suspend and does not return. The stock cycle
  returns with the same build and trigger, so the hang is attributable to the
  magic. The failure is a hang, not a structured error.
- **What we learned:**
  - The FMC/SR code consumes `SRMeta.magic`; a wrong value prevents resume.
  - The failure leaves no host-visible log: journald freezes before post-freeze
    printk flushes.
  - Probing non-stock descriptors needs netconsole, serial, or phase markers
    written to `/run/sr.phase`.
  - Every failed variant costs a reboot.
- **Related:**
  - The [stock cycle](#061-the-suspend-and-resume-cycle-is-host-driven) is the
    control that returns.
  - The [plaintext radix3](#064-the-radix3-is-plaintext-and-fully-mapped) is the
    next structural surface.
- **Open question:** whether [HS](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) validates the descriptor before the magic check,
  and which later stage hangs, need out-of-band logging.

## 06.3 The saved state is high-entropy ciphertext

**Question.** Is the saved SR state encrypted, and can it be edited to change
selectors?

**Why.**

- The state is restored into secure firmware. If it were plaintext, the host
  could edit it to change [rate selectors](../specs/03_register-map.md#feat-bank).
- If it is ciphertext, state editing is closed and the remaining surface is the
  page table.
- What it would give: a plaintext state-editing path, or proof that the state is
  opaque.

**Method.**

- Tool: `sr_dump_test.sh` from [driver harness](../tools/driver-harness/) with
  `BF16_SRDUMP=1`. At the resume FMC setup it maps the state region in 16 MiB
  chunks and writes one file per card.
- Target: both cards.
- Steps:
  - Read [`SRMeta`](../specs/01_boot-chain.md#suspendresume); compute the data region as the tail of the radix3 allocation.
  - Dump it and scan every 32-bit word.
  - The data offset is [`0xce49000 - 0xcde0000 = 0x69000`](../specs/01_boot-chain.md#suspendresume).
- Args used:
```bash
sudo tools/driver-harness/sr_dump_test.sh
python3 -I tools/driver-harness/analyze_srdump2.py <run>/sr_0.bin <run>/sr_1.bin
```

**Observed data.** Captured run log:

```text
SRDUMP meta magic=0x8a3bb9e6c6c39d93 size=0xcde0000 radix3=0x142c00000
SRDUMP pat 0x00c36180 count=0 first=0x0
SRDUMP pat 0x21240001 count=0 first=0x0
SRDUMP pat 0x54226037 count=0 first=0x0
SRDUMP pat 0x00888888 count=0 first=0x0
SRDUMP pat 0x00823804 count=0 first=0x0
SRDUMP pat 0x008207d8 count=0 first=0x0
SRDUMP pat 0x00504204 count=0 first=0x0
SRDUMP pat 0x00026005 count=0 first=0x0
SRDUMP done ... size=0xcde0000 dataOff=0x69000 total=0xce49000
```

The analyzer on the two dumps:

```text
chunks 205 zero0 97 zero1 97 same_zero_mask True
nonzero spans (MiB): [(0, 8), (11, 18), (112, 205)]
chunk 0 entropy 7.9998
chunk 151 entropy 7.9998
chunk 204 entropy 7.9998
equal bytes inside card0-nonzero chunks: 2258261
```

**Result.**

- **Answer:** the saved state is high-entropy ciphertext and contains none of the
  [selector constants](../specs/03_register-map.md#feat-bank). Editing it as plaintext does not work.
- **What we learned:**

| Metric | Value |
|---|---|
| State size | 205.875 MiB (215,875,584 B; 205 × 1 MiB chunks) |
| Zero 1-MiB chunks | 97 / 205, identical mask on both cards |
| Nonzero spans | 0–7, 11–17, 112–204 MiB |
| Entropy, nonzero chunks | 7.9998 bits/byte |
| ELF / [`WprMeta`](../specs/01_boot-chain.md#wprmeta) / `SRMeta` magic / vendor strings | none |
| zstd / gzip / lz4 / xz headers | none |
| Bytes equal between cards outside zero chunks | 2,258,261 of ~108 MiB |
| [FEAT](../specs/03_register-map.md#feat-bank)/selector constants | 0 |

- [`0xcde0000`](../specs/01_boot-chain.md#suspendresume) is 215,875,584 bytes, so the 205 chunks are the measurement.
- **Related:**
  - The [stock cycle](#061-the-suspend-and-resume-cycle-is-host-driven) provides
    the descriptor and the state size.
  - The [plaintext radix3](#064-the-radix3-is-plaintext-and-fully-mapped) is the
    readable structure that maps this state.
- **Open question:** the cipher and key are not identified. The state cannot be
  edited as plaintext, but it is not decrypted here.

## 06.4 The radix3 is plaintext and fully mapped

**Question.** Is the [radix3](../specs/01_boot-chain.md#suspendresume) page table plaintext and fully mapped, while the saved
data pages are per-boot and per-card ciphertext?

**Why.**

- The radix3 is host-built and maps the state. A malformed entry is a structural
  probe into secure firmware.
- If it is plaintext, the host controls the mapping the FMC walks on resume.
- What it would give: a readable mapping and a possible structural surface, or
  proof the state is opaque end to end.

**Method.**

- Tool: a second `sr_dump_test.sh` run from
  [driver harness](../tools/driver-harness/) with the hook extended to the whole
  descriptor, then `analyze_ptes.py`.
- Target: both cards.
- Steps:
  - Dump the whole descriptor (`0xce49000` per card; state [`0xcde0000`](../specs/01_boot-chain.md#suspendresume), data at
    `0x69000`).
  - Parse the root, L1, and L2 levels.
- Args used:
```bash
sudo tools/driver-harness/sr_dump_test.sh
python3 -I tools/driver-harness/analyze_ptes.py <run>/sr_0.bin <run>/sr_1.bin
```

**Observed data.** Captured run log:

```text
SRDUMP meta ... size=0xcde0000 radix3=0x1c2c00000
SRDUMP done ... stateSize=0xcde0000 dataOff=0x69000 dumped=0xce49000
```

The analyzer on the two dumps:

```text
[card0] root nonzero=[(0, '0x1c2c01000')] n=1
[card0] l1   nonzero=[(0, '0x1c2c02000'), (1, '0x1c2c03000'), (2, '0x1c2c04000'), (3, '0x1c2c05000')] n=103
[card0] l2 entries=52736 nonzero=52704
[card0] first=['0x1c2c69000', '0x1c2c6a000', '0x1c2c6b000', '0x1c2c6c000', '0x1c2c6d000', '0x1c2c6e000']
[card0] last =['0x1bce45000', '0x1bce46000', '0x1bce47000', '0x1bce48000']
[card0] 4k-aligned=52704/52704 min=0x147c00000 max=0x1d27ff000
[card0] delta top=[('0x1000', 52652), ('-0x7ff000', 46), ('-0xd3ff000', 1), ('-0x1bff000', 1)]
[card1] root nonzero=[(0, '0x1b9e01000')] n=1
[card1] l2 entries=52736 nonzero=52704
[card1] first=['0x1b9e69000', '0x1b9e6a000', '0x1b9e6b000', '0x1b9e6c000', '0x1b9e6d000', '0x1b9e6e000']
[card1] 4k-aligned=52704/52704 min=0x10c800000 max=0x1cbbff000
PTE lists identical: False
within-run equal 4K pages: 25277/52809
```

**Result.**

- **Answer:** yes. The radix3 is plaintext and fully mapped; the saved data pages
  are per-boot and per-card ciphertext.
- **What we learned:**

| Level | Content |
|---|---|
| root (1 page) | `root[0]` → L1 at `+0x1000` |
| L1 (1 page) | `L1[0..102]` → 103 L2 pages |
| L2 (103 pages) | 52,704 nonzero, unique, 4K-aligned [PTEs](../specs/01_boot-chain.md#suspendresume) (page-table entries) in 52,736 slots |

- The data pages sit in 52 physical runs, mostly 1,024 pages (4 MiB); card0
  starts at `0x1c2c69000`.
- 25,277 of the 52,704 state pages are zero, with the same mask every run.
- The `0x1000` delta dominates, so the data pages sit in contiguous 4 MiB runs.
  The two cards use different physical ranges.
- The analyzer counts the whole descriptor (52,809 pages); the state is 52,704
  pages, and the other 105 pages are the radix3 head.

| Comparison | Nonzero pages | Equal |
|---|---:|---:|
| Same card, previous boot | 27,322 | 0 |
| Other card, same cycle | 27,427 | 0 |

- **Related:**
  - The [stock cycle](#061-the-suspend-and-resume-cycle-is-host-driven) builds the
    descriptor.
  - The [state dump](#063-the-saved-state-is-high-entropy-ciphertext) shows the
    mapped data is ciphertext.
- **Open question:** whether [HS](../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) validates the PTEs before walking them. A
  malformed entry is the remaining structural probe, but a failed resume hangs
  with no host log.
