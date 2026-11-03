# The FEAT readout decode: ECC flags, not selectors

## Summary

**The idea.**

- Only bit 16 of [`FEAT_READOUT_0`](../specs/03_register-map.md#readout-decode)
  and bits 5 and 10 of [`FEAT_READOUT_2`](../specs/03_register-map.md#readout-decode)
  had a decode, and A100 read a completely different `READOUT_0`. An un-decoded
  rate or override-enable bit would have changed the unlock target.
- This group decompiles every GSP-RM consumer of the two readout registers,
  names the bits from the code that reads them, and closes the readout-decode
  lead. All of it is offline statics over the plaintext image; no hardware.

**What it found.**

- Ten one-bit wrappers read the two registers, all through the same generic
  fuse accessor the `READOUT_1` decoder uses. Eight are installed in the
  fuse-HAL vtable of a `0x320`-byte object built at `0x1ab1c6c`
  ([the reader family](#121-the-readout-reader-family)).
- Eight consumer getters pair each fuse bit with a capability byte in the
  device object, and the writer of those bytes is the ECC static-info
  initializer gated by the `RMEnableL1ECC`, `RMEnableSMECC`, and
  `RMEnableSHMECC` registry keys. Every decoded bit is an ECC capability
  flag ([the consumer class](#122-the-consumer-class-names-the-bits)).
- All decoded bits read zero on both 5090s and both RTX PRO 6000s. The bits
  that differ between the product classes have no reader in the image
  ([the same record](#122-the-consumer-class-names-the-bits)).
- Three reader slots (`+0x178`, `+0x190`, `+0x1c8`) are installed but never
  called anywhere in the corpus
  ([the unused slots](#123-three-reader-slots-have-no-callers)).
- The one function that looked like a rate-bucket classifier is an ECC
  step selector; its reference value is `READOUT_0` bits 18:19, and on every
  measured card it degenerates to a constant
  ([the false classifier](#124-the-rate-bucket-classifier-is-an-ecc-step-selector)).

**What it did not find.**

- No rate bit, override-enable bit, or selector consumer in either readout
  register. The selector mirror remains
  [`FEAT_READOUT_1`](../specs/03_register-map.md#readout-decode) alone.
- No consumer for `READOUT_0` bits 0–11, the bits that are actually set on
  the measured cards.
- No caller for the three unused reader slots, so their bits cannot gate RM
  behavior on this driver.

## Experiments

| ID | Short name | Result |
|---|---|---|
| 12.1 | [The readout reader family](#121-the-readout-reader-family) | ten one-bit wrappers |
| 12.2 | [The consumer class names the bits](#122-the-consumer-class-names-the-bits) | all ECC capability flags |
| 12.3 | [Three reader slots have no callers](#123-three-reader-slots-have-no-callers) | installed, never called |
| 12.4 | [The rate-bucket classifier is an ECC step selector](#124-the-rate-bucket-classifier-is-an-ecc-step-selector) | false lead closed |

## 12.1 The readout reader family

**Question.** Which code in the GSP-RM reads fuse offsets `0x3814` and
`0x3828`, and which bits does each read consume?

**Why.**

- The readout-decode lead held that a rate or override-enable bit in an
  un-decoded readout field would change the unlock target.
- The fuse-HAL offsets are byte offsets from the `0x820000` block, so `0x3814`
  is [`FEAT_READOUT_0`](../specs/03_register-map.md#readout-decode) and
  `0x3828` is `FEAT_READOUT_2`. The `0x3818` decoder proved the pattern
  ([the HAL decoder](../experiments/07_plaintext-corpus.md#078-the-decoder-is-installed-by-the-hal)).
- What it would give: the complete RM-side consumer map of the two registers.

**Method.**

- Tools: the corpus grep over the decompiled dump, the raw reference scan,
  and Ghidra headless; [GSP-RM tools](../tools/gsp-rm-tools/). Offline.
- Steps: grep the corpus for the two offsets passed to the fuse accessor,
  decompile the wrappers and their vtable neighborhood, disassemble the
  vtable initializer, and decode every slot store.
- Args used:

```text
grep -nE "0x3814|0x3828" gsp_decompiled.c
refscan.py gsp_fwimage.bin 0x015556c4 0x01558100 0x012289ac
ghidra.sh DisasmRange.java 0x1ab1c6c,400
```

**Observed data.**

- Three wrappers read the registers directly. `FUN_ram_015556c4` reads
  `0x3814` and returns `(word & 0xc0000) != 0`, bits 18 and 19.
  `FUN_ram_01558100` reads `0x3828` and returns bit 10. `FUN_ram_012289ac`
  reads `0x3828` and returns bit 5. All three call
  `(*(gpu+0x1d70)+0x100)` with the offset, the same generic fuse accessor the
  `0x3818` decoder uses.
- The vtable initializer at `0x1ab1c6c` builds a `0x320`-byte object and fills
  slots `+0x100` through `+0x2d0`. The family dispatch reads `desc[0x10] >> 5`;
  GB202 falls through to the default path, so the reader installs below are
  live on this part. The slot map from the disassembly:

| Slot | Function | Read |
|---|---|---|
| `+0x100` | `FUN_ram_015580d0` | generic accessor (loads `+0x2d0`) |
| `+0x108` | `FUN_ram_015550bc` | fuse-visibility filter over offsets |
| `+0x118` | `FUN_ram_01555120` | `0xff0000xx` named-property dispatcher |
| `+0x178` | `FUN_ram_01555650` | live BAR0 MMIO, extracts bits 16 and 15 |
| `+0x180` | `FUN_ram_01555880` | `0x3814` bit 12 |
| `+0x188` | `FUN_ram_01555930` | `0x3814` bits 14, 23, 24 (mask `0x1804000`) |
| `+0x190` | `FUN_ram_015558d8` | `0x3814` bit 13 |
| `+0x198` | `FUN_ram_0155598c` | `0x3814` bit 17 |
| `+0x1a0` | `FUN_ram_015556c4` | `0x3814` bits 18, 19 |
| `+0x1a8` | `FUN_ram_01555720` | `0x3814` bit 29 |
| `+0x1b0` | `FUN_ram_01555778` | `0x3814` bit 31 |
| `+0x1b8` | `FUN_ram_015557d0` | `0x3814` bit 27 |
| `+0x1c0` | `FUN_ram_01555828` | `0x3814` bit 26 |
| `+0x1c8` | `FUN_ram_01558100` | `0x3828` bit 10 |

- `FUN_ram_01555650` at `+0x178` takes a different path: it translates the
  offset through slot `+0x158`, reads live BAR0 memory, and extracts bits 16
  and 15. Bit 16 is the ECC-enablement readout the host driver fetches; the
  MMIO path confirms the register is live state, not a dead shadow.
- `FUN_ram_012289ac` (the `0x3828` bit-5 reader) is installed by a second
  initializer, `FUN_ram_01a0dcf8`, into a separate `0xb50`-byte object at
  slot `0x6c`, so the two registers have consumers in two classes.

**Result.**

- **Answer:** ten wrappers read the two registers, and the decoded bits are
  `0x3814` bits 12, 13, 14, 17, 18, 19, 23, 24, 26, 27, 29, 31 plus the
  live-MMIO pair 15 and 16, and `0x3828` bits 5 and 10.
- **What we learned:**
  - The FEAT bank is read through the fuse accessor with `0x820000` as the
    base, which ties the readouts, `SS0`/`SS1`, and the PLM into one address
    space from the RM's point of view. A dropped fuse write and a dropped
    FEAT write are the same check.
  - No wrapper reads `READOUT_0` bits 0–11. The bits that are set on the
    measured cards have no reader here.
  - The vtable also carries a visibility filter over fuse offsets
    (`0xc14`–`0xc1c` masked `0x111` inverted, `0xd38`, above `0xd70`), the
    same neighborhood the named-property dispatcher serves.
- **Related:**
  - [The HAL decoder](07_plaintext-corpus.md#078-the-decoder-is-installed-by-the-hal)
    owns the `0x3818` readout and the `gpu+0x1d70` accessor pattern.
  - [The static pass](08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp)
    owns the `SS0`/`SS1` write method through the same accessor.
  - [The write drop](01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)
    is the write side of the same gate.
- **Open question:** which subsystems call the `+0x178`, `+0x190`, and
  `+0x1c8` slots, if any. The corpus shows no caller
  ([the unused slots](#123-three-reader-slots-have-no-callers)).

## 12.2 The consumer class names the bits

**Question.** Who consumes the readout bits, and what feature does each one
gate?

**Why.**

- A bit read by rate logic would re-open the register route; a bit read by
  ECC logic closes the lead.
- The wrappers are vtable methods, so the consumers had to be found through
  the object, not by function-name search.
- What it would give: the semantic name of every decoded bit.

**Method.**

- Tools: corpus grep and Ghidra headless; [GSP-RM tools](../tools/gsp-rm-tools/).
- Steps: sweep every corpus reference to `gpu+0x1d70` (143 sites), extract
  the vtable slot each site calls, decompile the wrapper cluster around the
  surviving sites, and find the writer of the fallback bytes the wrappers
  consult.
- Args used:

```text
grep -nE "0x1d70" gsp_decompiled.c
ghidra.sh DecompileAt.java getters.c 0x163faf8,0x163fb34,0x163f954,0x163f9cc,0x163f990,0x163fa08,0x163fa44,0x163fa80
```

**Observed data.**

- Eight `0x3c`-byte getters form one cluster. Every one reads its fuse bit
  through `gpu+0x1d70` plus a slot, and if the read returns zero it falls
  back to a capability byte in the device object:

| Fuse slot | Bit | Fallback byte | Getter |
|---|---|---|---|
| `+0x180` | `0x3814` bit 12 | `+0x2b3` | `FUN_ram_0163fa80` |
| `+0x188` | bits 14, 23, 24 | `+0x2b7` | `FUN_ram_0163faf8` |
| `+0x198` | bit 17 | `+0x2b9` | `FUN_ram_0163fb34` |
| `+0x1a0` | bits 18, 19 | `+0x2bb` | `FUN_ram_0163f954` |
| `+0x1a8` | bit 29 | `+0x2bf` | `FUN_ram_0163f990` |
| `+0x1b0` | bit 31 | `+0x2c1` | `FUN_ram_0163f9cc` |
| `+0x1b8` | bit 27 | `+0x2c3` | `FUN_ram_0163fa08` |
| `+0x1c0` | bit 26 | `+0x2c5` | `FUN_ram_0163fa44` |

- The fallback bytes live in a capability struct at `gpu+0x1e98`, offsets
  `+0x2b0`–`+0x2ca`. Their writer is `FUN_ram_014a0b9c`, the ECC
  static-info initializer, and the writes are gated by the
  `RMEnableL1ECC`, `RMEnableSMECC`, and `RMEnableSHMECC` registry keys and
  the `RMNoECCFuseCheck` fuse check.
- Against the measured stock values — `READOUT_0` of `0x233` on the 5090s
  and `0x300` on the PRO 6000s, `READOUT_2` of `1` on all four cards — every
  decoded bit reads zero on every measured card. The bits that differ
  between the product classes (`0, 1, 4, 5, 8, 9`) have no reader at all.

**Result.**

- **Answer:** every decoded `READOUT_0`/`READOUT_2` bit the RM consumes is an
  ECC / memory-RAS capability flag, read at static-info init with a
  capability-byte fallback. No rate or override-enable bit exists in the
  two registers, and the readout-decode lead closes.
- **What we learned:**
  - The readouts are fuse-or-config getters: the RM reads the fused
    capability and falls back to a config byte when the read fails. That is
    the same shape as the Quadro/ECC classification words, not a selector
    path.
  - `READOUT_1` is confirmed as the only readout that carries the selector;
    its decoder and the nine-byte getter were already mapped
    ([the HAL decoder](07_plaintext-corpus.md#078-the-decoder-is-installed-by-the-hal)).
- **Related:**
  - [The ECC gating](05_fmc-fsp-boot-inputs.md#0520-feat-bank-across-boots-and-flr)
    covers the per-boot variance of the shadow words.
  - [The getter](08_assessment-and-cross-checks.md#087-static-pass-over-feat-and-fsp)
    covers the nine selector bytes that remain the only rate readout.
- **Open question:** none. The lead is closed at the decoded level.

## 12.3 Three reader slots have no callers

**Question.** Do the reader slots `+0x178`, `+0x190`, and `+0x1c8` have any
caller in the image?

**Why.**

- The `+0x178` slot reads live MMIO for the ECC-enablement bits, `+0x190`
  reads bit 13, and `+0x1c8` reads `READOUT_2` bit 10. If a subsystem calls
  them, their bits still matter.
- The sweep in the previous record only catches consumers that fetch the HAL
  from `gpu+0x1d70` near the call site.
- What it would give: either a consumer or proof the slots are dead weight.

**Method.**

- Tools: corpus grep; offline.
- Steps: for each of the 143 `gpu+0x1d70` sites, inspect the following
  instructions for the slot offset; then grep the corpus for any indirect
  call through the three offsets on any object.
- Args used:

```text
grep -nE "\+ 0x1d70\)" gsp_decompiled.c
grep -nE "\+ 0x178\)|\+ 0x190\)|\+ 0x1c8\)" gsp_decompiled.c
```

**Observed data.**

- No `gpu+0x1d70` site calls any of the three slots.
- The corpus-wide grep for the three offsets returns hits only on other
  classes' vtables — different object types with different calling
  signatures — and no call through this object.

**Result.**

- **Answer:** the three slots are installed and never called. Their bits
  cannot gate RM behavior on this driver.
- **What we learned:** a vtable entry can exist for interface completeness.
  Slot presence is not consumer evidence; the call-site sweep is.
- **Related:** [the reader family](#121-the-readout-reader-family) maps all
  fourteen slots.
- **Open question:** whether firmware below the RM (devinit, PMU ucode)
  reads the same bits through its own path. That consumer is outside this
  image.

## 12.4 The rate-bucket classifier is an ECC step selector

**Question.** Is `FUN_ram_0163fb70` a tensor-rate classifier?

**Why.**

- Its shape suggested one: it reads a reference value through an object
  slot, halves it on a platform flag, and buckets a parameter at 1/8, 1/4,
  and 1/2 with return codes `5, 3, 2, 1, 8, 0` — the selector-encoding
  family.
- It sits in the same method cluster as the readout getters.
- What it would give: a second rate consumer, or a closed false lead.

**Method.**

- Tools: the raw reference scan and Ghidra headless;
  [GSP-RM tools](../tools/gsp-rm-tools/). Offline.
- Steps: find the install sites, decode the slot map of the containing
  class, decompile the slot the reference value comes from.
- Args used:

```text
refscan.py gsp_fwimage.bin 0x0163fb70
ghidra.sh DecompileAt.java ref.c 0x163f954
```

**Observed data.**

- Three install sites (`0x1ae7af2`, `0x1ae91a0`, `0x1ae9532`) put the
  function at slot `+0x258` of the same class that holds the eight ECC
  getters, gated by the family and variant checks.
- The reference value comes from slot `+0x208`, which holds
  `FUN_ram_0163f954` — the `0x3814` bits-18/19 getter with fallback byte
  `+0x2bb`. The `0x14` argument in the call frame is ignored by the reader.
- With bits 18:19 as the count and a platform flag at `gpu+0x1ea8+0x191` as
  the halving condition, the function buckets a requested count against the
  available ECC granularity and returns a step code. On every measured card
  the reference value reads zero, so the function returns `5` for a zero
  request and `2` for anything else.
- Slot `+0x258` has no caller in the corpus.

**Result.**

- **Answer:** no. The function is an ECC step selector, and the bucket shape
  was the shape of a granularity picker, not a rate law.
- **What we learned:** the return codes `5, 3, 2, 1` belong to the ECC step
  enum in this cluster; do not read them as selector encodings without a
  consumer.
- **Related:** [the consumer class](#122-the-consumer-class-names-the-bits)
  names the cluster the function belongs to.
- **Open question:** none. The lead is closed.
