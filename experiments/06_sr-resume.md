# SR-resume

Recorded October 2026 on 2× RTX 5090 (GB202, `10de:2b85`), host driver and
GSP-RM 595.91.07, Linux, CUDA 13. Both cards are suspended and resumed in one
cycle.

## Reproducing this group

**Hardware.** 2× RTX 5090 (GB202, `10de:2b85`), host driver and GSP-RM 595.91.07,
Linux, CUDA 13. The host builds `SRMeta` and the radix3; the FMC consumes them on
resume.

**Tools.** [Driver harness](../tools/driver-harness/) with the SR scripts:
`sr_resume_test.sh` (stock cycle), `sr_oracle.sh` (field override), and
`sr_dump_test.sh` (state dump). They build an instrumented 595.91.07 tree, load it,
trigger the cycle, and restore stock in a trap. Root is required. The analyzers are
`analyze_srdump.py`, `analyze_srdump2.py`, and `analyze_ptes.py`.

**Inputs.** The 595.91.07 open driver tree, the stock firmware already in
`/lib/firmware`, and root. No extra images. The dumps are written locally and are
not part of this repo.

**Boot state and cost.** Start from a clean boot with the stock driver loaded, no
Xid, and both cards visible. The stock cycle takes about 8 s and returns without a
reboot. A bad SR field hangs the resume; journald freezes before the failure, so add
netconsole or phase markers first. Every failed variant costs a reboot.

**Terms.** SR is suspend/resume. `SRMeta` is the 256-byte host-built descriptor that
carries the saved-state size, flags, and radix3 pointer. The radix3 is a three-level
page table, built by the host in unprotected memory, that maps the saved state.
FRTS is the firmware runtime state region inside the WPR, the write-protected
firmware region. The non-WPR heap is the unprotected allocation outside it. See the
[boot-chain spec](../specs/01_boot-chain.md) and the
[memory spec](../specs/07_memory-and-host-access.md).

## E42 · The SR path is live and host-driven

*2026-10-26 · Revision 41 · status: LIVE*

**Hypothesis.** A device-level suspend/resume cycle exercises the SR path, and the
host builds `SRMeta` plus the radix3 that the FMC consumes on resume.

**Instrument.** [Driver harness](../tools/driver-harness/) `sr_resume_test.sh`,
which builds and loads the instrumented 595.91.07 tree, triggers the cycle, captures
dmesg, and restores stock in a trap. Root required.

**Method.** Run a device-level s2idle test cycle, capture the `SRMeta` and FMC boot
parameter lines, and check that both cards return.

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

**Result.** The host builds `SRMeta` and the radix3 in unprotected memory and hands
the descriptor to the FMC on resume. Both `SRMeta` sizes are `0xcde0000`, matching
the WPR span measured at boot. Both cards return in about 8 s.

**Reproduce.**
1. Build and load the instrumented tree:
   `sudo tools/driver-harness/sr_resume_test.sh` (the script does both and restores
   stock in its trap).
2. Trigger the cycle:
   `echo devices > /sys/power/pm_test; echo mem > /sys/power/state`.
3. The machine returns in about 8 s. Capture `dmesg` and `nvidia-smi -L`.
4. Expect two `SRMeta` lines with `size=0xcde0000`, the FRTS/non-WPR inputs, and
   `bootMode=1` on resume.

**Limits.** Shows the host builds and passes the descriptor and that the cycle
returns. It does not show whether HS validates the structure.

## E43 · A bad SRMeta magic hangs the resume

*2026-10-26 · Revision 42 · status: hang, blind*

**Hypothesis.** The FMC/SR code consumes `SRMeta.magic`; a wrong magic hangs the
resume instead of returning an error.

**Instrument.** [Driver harness](../tools/driver-harness/) `sr_oracle.sh 1`, which
sets `BF16_SR_VARY=1` and `BF16_SR_VALUE=0xdeadbeefdeadbeef`, rebuilds, loads, and
triggers the same cycle.

**Method.** Run the stock cycle with only the magic changed, then inspect the
previous boot's log. Add netconsole or phase markers first, because journald freezes
before the failure.

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

**Result.** The machine enters suspend and does not return. The stock cycle
([E42](#e42--the-sr-path-is-live-and-host-driven)) returns with the same build and
trigger, so the hang is attributable to the magic. The failure is a hang, not a
structured error.

**Reproduce.**
1. Prepare an out-of-band log:
   - boot with a netconsole target on the kernel command line, or
   - add phase markers in the driver hooks at prepare / save / resume-start /
     restore-done, written to `/run/sr.phase`.
2. Run `sudo tools/driver-harness/sr_oracle.sh 1`; it rebuilds, loads, and triggers
   the cycle.
3. The machine will not return. Reboot after a few minutes.
4. Check the previous boot log (`journalctl -k -b -1 | tail`). Without a console it
   ends at `Filesystems sync`; with netconsole or phase markers it shows the last
   stage reached.
5. Compare with the stock cycle ([E42](#e42--the-sr-path-is-live-and-host-driven)),
   which returns with the same build and trigger.

**Limits.** The hang is attributable to the magic only because the stock control
returns. A failed resume leaves no host log; finer results need netconsole, serial,
or phase markers, and every attempt costs a reboot.

## E45 · The SR suspend image is encrypted

*2026-10-26 · Revision 44 · status: state editing closed*

**Hypothesis.** The saved SR state is encrypted, so editing it to change selectors
does not work.

**Instrument.** [Driver harness](../tools/driver-harness/) `sr_dump_test.sh` with
`BF16_SRDUMP=1`. At the resume FMC setup it maps the state region in 16 MiB chunks
and writes one file per card.

**Method.** Read `SRMeta`, compute the data region as the tail of the radix3
allocation, dump it, and scan every 32-bit word. The data offset is
`0xce49000 - 0xcde0000 = 0x69000`.

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

| Metric | Value |
|---|---|
| State size | 205.875 MiB (215,875,584 B; 205 × 1 MiB chunks) |
| Zero 1-MiB chunks | 97 / 205, identical mask on both cards |
| Nonzero spans | 0–7, 11–17, 112–204 MiB |
| Entropy, nonzero chunks | 7.9998 bits/byte |
| ELF / WprMeta / SRMeta magic / vendor strings | none |
| zstd / gzip / lz4 / xz headers | none |
| Bytes equal between cards outside zero chunks | 2,258,261 of ~108 MiB |
| FEAT/selector constants | 0 |

The saved state is high-entropy and contains none of the selector constants.
`0xcde0000` is 215,875,584 bytes, so the 205 chunks are the measurement.

**Reproduce.**
1. Run `sudo tools/driver-harness/sr_dump_test.sh`. It rebuilds, loads, triggers the
   cycle, and writes one state file per card.
2. The files are about 216 MB each (`0xcde0000` bytes) and stay local.
3. Analyze:
   `python3 -I tools/driver-harness/analyze_srdump2.py <run>/sr_0.bin <run>/sr_1.bin`.
4. Expect 205 chunks, 97 zero on each card, the same zero mask, entropy near 7.9998
   in the nonzero chunks, and no FEAT/selector constants.

**Limits.** Shows the saved state is high-entropy and contains none of the selector
constants. It does not identify the cipher or key; it rules out editing the state as
plaintext.

## E46 · Plaintext radix3, per-boot ciphertext

*2026-10-26 · Revision 45 · status: structure mapped*

**Hypothesis.** The radix3 page table is plaintext and fully mapped, while the saved
data pages are per-boot and per-card ciphertext.

**Instrument.** A second [Driver harness](../tools/driver-harness/)
`sr_dump_test.sh` run with the hook extended to the whole descriptor, then
`analyze_ptes.py`.

**Method.** Dump the whole descriptor (`0xce49000` per card; state `0xcde0000`, data
at `0x69000`) and parse the root, L1, and L2 levels.

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

| Level | Content |
|---|---|
| root (1 page) | `root[0]` → L1 at `+0x1000` |
| L1 (1 page) | `L1[0..102]` → 103 L2 pages |
| L2 (103 pages) | 52,704 nonzero, unique, 4K-aligned PTEs in 52,736 slots |

The data pages sit in 52 physical runs, mostly 1,024 pages (4 MiB); card0 starts at
`0x1c2c69000`. 25,277 of the 52,704 state pages are zero, with the same mask every
run.

| Comparison | Nonzero pages | Equal |
|---|---:|---:|
| Same card, previous boot | 27,322 | 0 |
| Other card, same cycle | 27,427 | 0 |

The `0x1000` delta dominates, so the data pages sit in contiguous 4 MiB runs. The
two cards use different physical ranges. The analyzer counts the whole descriptor
(52,809 pages); the state is 52,704 pages, and the other 105 pages are the radix3
head.

**Reproduce.**
1. Run `sudo tools/driver-harness/sr_dump_test.sh` with the whole-descriptor hook.
2. It writes `sr_0.bin` and `sr_1.bin`, about 216 MB each.
3. Analyze:
   `python3 -I tools/driver-harness/analyze_ptes.py <run>/sr_0.bin <run>/sr_1.bin`.
4. Expect one root entry, 103 L1 entries, 52,704 nonzero L2 PTEs, all 4K-aligned,
   and different PTE lists per card.

**Limits.** Shows the page table is plaintext and fully mapped, and the saved data
pages differ per card. It does not show whether HS validates the PTEs; that remains
open.
