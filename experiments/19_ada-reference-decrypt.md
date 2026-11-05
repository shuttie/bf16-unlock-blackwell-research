# The Ada reference decrypt

## Summary

**The idea.**

- The Ada booters decrypt with a published test key. Reading the Ada corpus
  gives the crypto reference (mode, key scope, image structure in plaintext),
  the signature-parser template behind the only demonstrated PL3 primitive,
  and the key's own structure for the generator hunt
  ([the open lead](../IDEAS.md#corpus-key-search)).
- I validated the key against the published known-answer control, decrypted
  the GA102 and AD102 debug booters, tested the production booters and both
  Ada GspRmBoot images under the same key, and ran a new
  index-generator family against the GB202 containers.

**What it found.**

- The known-answer plaintext is settled: `AES-ECB(key37, 0^16)` is the
  published marker; the public gist's `FF^16` label is wrong
  ([19.1](#191-the-test-key-its-structure-and-the-known-answer)).
- The key is `csecret(37)` from NVIDIA's shared-secret table, and its body is
  a hand-typed hex ladder with the table index `0x25` (decimal 37) embedded
  as one byte.
- The debug booters decrypt; the production booters do not share the key
  (zero aligned ciphertext blocks), and Ada GspRmBoot is not under it either
  ([19.2](#192-the-debug-booters-decrypt-and-the-scope-closes-around-them)).
- The 257-candidate index family is negative on the GB202 production and
  debug FMC bodies under ECB, CBC-zero, and CTR-zero
  ([19.3](#193-the-index-generator-family-is-negative-on-gb202)).
- The GA102 and AD102 debug booters share only 3.1% of aligned blocks, and
  the public payload's gadget addresses land on dense code bytes in the
  decrypted AD102 image
  ([19.4](#194-two-chips-two-booters-and-the-gadget-grounding)).

**What it did not find.**

- No GB202 key. The generator hypothesis in its naive form (fixed tail plus
  index byte) is closed, and the Ada key itself was already known not to fit.
- No falcon disassembly yet; the V67 copy-loop location in the decrypted code
  needs a disassembler pass. The decrypted images are staged for it.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 19.1 | [The test key, its structure, and the known answer](#191-the-test-key-its-structure-and-the-known-answer) | KAT is zeros; key = hex ladder + index 37 |
| 19.2 | [The debug booters decrypt, and the scope closes around them](#192-the-debug-booters-decrypt-and-the-scope-closes-around-them) | Debug only; prod and GspRmBoot excluded |
| 19.3 | [The index-generator family is negative on GB202](#193-the-index-generator-family-is-negative-on-gb202) | 257 × 3 modes × 2 containers, 0 hits |
| 19.4 | [Two chips, two booters, and the gadget grounding](#194-two-chips-two-booters-and-the-gadget-grounding) | 3.1% shared; gadgets land in code |

## 19.1 The test key, its structure, and the known answer

**Question.** What are the key's exact bytes, does the published control
verify, and is the key a structured value a generator could reproduce?

**Why.**

- The record carried two different claims for the marker block: the spec's
  `AES-ECB(key37, 0^16) = 717d1494…` and the public gist's
  `AES_ECB(key, FF×16) = 717d1494…`. One is wrong, and every padding-based
  oracle depends on which.
- The key's structure decides whether the GB202 debug key can be guessed
  from a generator rather than searched.

**Method.**

- Offline. The key bytes come from the public
  [GA100 VBIOS comparison gist](https://gist.github.com/nvlight/fc7479629b0ace094873e58ba7d75eb2)
  (`debug_csecret(37)`, recovered by BlackSun and published there).
- AES through `openssl enc -aes-128-ecb -K … -nopad`; the analysis scripts
  are in the working area `analysis-tmp/c38/work/`.
- Args used:
```bash
python3 -I analysis-tmp/c38/work/key37_analysis.py csecret_index_family.txt
```

**Observed data.**

```text
AES-ECB(key37, 00*16)  = 717d1494eaca317ff106195258b38377   <- the marker
AES-ECB(key37, FF*16)  = fd7e5b57768a309baabcc6903118c8f5
key37 = 25 EF CD AB 89 67 45 23 10 32 54 76 98 BA DC FE
LE dwords: 0xABCDEF25 0x23456789 0x76543210 0xFEDCBA98
reversed byte string: FE DC BA 98 76 54 32 10 23 45 67 89 AB CD EF 25
                     = "FEDCBA9876543210" "23456789" "ABCDEF" 0x25
key37[0] = 0x25 = 37 decimal = the csecret table index
multiset: the MD5-IV bytes minus 0x01 plus 0x25
```

**Result.**

- **Answer:** the known answer is the zero block, the gist's `FF` label is
  wrong, and the key is `csecret(37)` — a hand-typed hex ladder with its own
  table index embedded as the first byte.
- **What we learned:**
  - The "permutation of the MD5 IV" description in
    [the firmware spec](../specs/04_firmware-formats.md#the-published-test-key-family)
    is close but not exact: one byte (0x01) is replaced by the index (0x25).
  - Test keys in the csecret table are mnemonic hand-typed values, which
    makes "guess the generator" a guess at another mnemonic, not at an
    algorithm.
- **Related:** [the index family](#193-the-index-generator-family-is-negative-on-gb202)
  tests the one generator the structure suggests.

## 19.2 The debug booters decrypt, and the scope closes around them

**Question.** Does the published key open the Ada debug booters (the
control), and does it open anything else — the production booters, or the
Ada GspRmBoot images?

**Why.**

- The Ada attack's gadget addresses came from the decrypted debug booter, so
  the debug decrypt is the reference the whole prior art stands on.
- The scope decides the GB202 retargets: the FMC is the booter analogue, and
  GspRmBoot was proposed as a second target in the key-search lead.

**Method.**

- Offline. The pinned 610.43.03 open-kernel-module source (SHA-256 checked by
  the upstream fetcher) supplies `IMAGE_DBG`/`HEADER_DBG`/`IMAGE_PROD` for
  GA102 and AD102; the Ada repo's extractor builds them with pinned hashes.
- Decrypt the code region `[code_offset, data_offset)` under ECB; score by
  zero-byte fraction and longest zero run (random data sits near 0.4% zeros).
- Args used:
```bash
python3 -I analysis-tmp/c38/work/ada_family_test.py
```

**Observed data.**

```text
GA102 debug: code 0x100..0x8a00, 3 zero-marker blocks, all decrypt to 0^16
            decrypted zerofrac 0.110
AD102 debug: code 0x100..0x7e00, decrypted zerofrac 0.097
headers (both): os 0x100 plain | code 0x7d00..0x8900 AES-ECB | DMEM plain
GA102 PROD under key37: zerofrac 0.003 (random), 0/2192 blocks shared with debug
AD102 PROD under key37: zerofrac 0.003 (random), 0/2000 blocks shared with debug
gsp_boot_ga102.bin (0x6000) and gsp_boot_ad102.bin (0x9000): random-looking;
  key37 under ECB/CBC-0/CTR-0 opens neither
```

**Result.**

- **Answer:** the debug control passes on both chips, and the scope closes
  tightly: the key is debug-booter-only. Production booters use a different
  key (not even aligned ciphertext is shared, so the plaintexts differ too),
  and the Ada GspRmBoot images are outside the debug key entirely.
- **What we learned:**
  - The Ada→GB202 analogy maps the *booter* to the FMC. The GB202 debug FMC
    stays the right decrypt target; the GspRmBoot retarget in the key-search
    lead loses its Ada support and drops to speculative.
  - The decrypted images (`analysis-tmp/c38/out/*-debug-code.bin`) are the
    first readable HS boot code in this project's hands.
- **Related:** the [signature-section sweep](../IDEAS.md#fmc-signature-section-sweep)
  reasons from this parser family.

## 19.3 The index-generator family is negative on GB202

**Question.** If csecret test keys are `index byte || fixed ladder tail`,
does any of the 256 index values open the GB202 FMC bodies?

**Why.**

- The structure in [19.1](#191-the-test-key-its-structure-and-the-known-answer)
  suggests exactly one free parameter. A hit would have collapsed the GB202
  debug-key space to nothing.

**Method.**

- Offline. Candidates: `byte(n) || key37[1:]` for all 256 n, plus key37
  itself. Targets: the 595 GB202 production (c09) and debug (c11) FMC bodies,
  first 8 KiB past the `0x48` container header. Modes: ECB, CBC-zero,
  CTR-zero. Score as in 19.2.
- Args used:
```bash
python3 -I analysis-tmp/c38/work/ada_family_test.py
```

**Observed data.**

```text
2 containers x 257 candidates x 3 modes: 0 hits
every decryption scored random-like (zerofrac < 0.012, maxrun < 8)
```

**Result.**

- **Answer:** no index value opens either body under the three modes.
- **What we learned:** the naive generator is closed, and this family was
  genuinely new — its candidates are not permutations of the MD5 IV, so the
  exhausted 16! search never covered them. The GB202 debug key, if
  structured at all, is a different mnemonic.
- **Related:** extends
  [the negative key search](07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative);
  the remaining families are in
  [the key-search lead](../IDEAS.md#corpus-key-search).

## 19.4 Two chips, two booters, and the gadget grounding

**Question.** How much code do the two Ada debug booters share, and do the
public payload's gadget addresses land on real instructions in the decrypted
image?

**Why.**

- The public record warns that a GA102 booter halts on AD102; quantifying
  the sharing measures how chip-specific the boot code is.
- The payload's patched words are IMEM addresses; if they land on dense code
  in our decrypt, the public analysis and this decrypt agree on the image
  layout.

**Method.**

- Offline. Aligned 16-byte block equality between the two decrypted code
  regions; byte dumps at the payload's gadget addresses under both
  base interpretations (IMEM address equals file offset, and plus `0x100`).

**Observed data.**

```text
GA102 vs AD102 debug code: 63/2000 aligned blocks equal (3.1%);
  dword level 271/8000 (3.4%)
gadget addresses (0x0d44 0x0d52 0x11fe 0x1fce 0x21b2 0x256f 0x31b5 0x771e ...):
  both interpretations land on dense non-uniform bytes, e.g.
  0x21b2 as addr: 0075a019c44fff94   0x31b5 as addr: 01c0f53c11acf53c
```

**Result.**

- **Answer:** the two booters are mostly different code (3.1% shared), and
  the gadget addresses fall inside dense instruction-shaped bytes, so the
  decrypted image matches the layout the public payload was built against.
- **What we learned:** boot code is chip-specific enough that GB202
  analogues cannot be transplanted — any Blackwell parser finding has to be
  found on Blackwell images.
- **Related:** a falcon disassembler pass over the staged plaintext is the
  remaining step for the [signature-section sweep](../IDEAS.md#fmc-signature-section-sweep)
  template.
