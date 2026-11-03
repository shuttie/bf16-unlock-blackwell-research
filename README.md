# RTX 5090 BF16 Unlock experiments

This repo is a log of 87 unsuccessful experiments I did to unlock BF16 full rate on
the 5090, the way it was done on [4090](https://github.com/JustAResearcher/gpu-unlock-ada)
and [3090](https://github.com/Zagitta/gpu-unlock) cards.

1. **Can I unlock my 5090?** Not yet. Blackwell uses a completely different boot
   process, so the 3090/4090 exploits don't work.
2. **Is it the silicon?** No. The same [GB202](specs/03_register-map.md) die
   runs BF16 at full rate in the [RTX PRO
   6000](specs/02_privilege-and-rate-control.md#the-cap-is-product-segmentation);
   I measured 518 TF/s and [`FEAT_READOUT_1 =
   0`](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)
   on one.
3. **What's in the repo?**
   - [the cap, and how the 3090/4090 unlock worked](#the-cap-and-the-30904090-unlock)
   - [Blackwell's boot chain and why the old route is closed](#blackwells-boot-chain-and-why-the-old-route-is-closed)
   - [the levers I tried, and what happened to each](#what-i-tried)
   - [where it stands and what's left](#where-it-stands)
   - [the reverse-engineered specs](#reverse-engineered-specs)
   - [the tools](#tools)

**Test rig.**

- 2× RTX 5090 (GB202, `10de:2b85`), different board vendors and VBIOS revisions.
- Host driver and GPU firmware 595.91.07, compute capability 12.0, CUDA 13 on
  Linux, 575 W.
- Experiments ran 2026-10-25 to 2026-11-03.
- Reference run: one RTX PRO 6000 Blackwell Workstation Edition (same GB202 die,
  `10de:2bb1`), 96 GB, driver and GSP-RM 615.71.09, CUDA 13.2, 500 W,
  2026-10-31.

This is research. I'm not redistributing NVIDIA firmware.

## The cap and the 3090/4090 unlock

**The cap.** A consumer 5090 uses the same GB202 die as an RTX PRO 6000. NVIDIA
sells the consumer card with a 1/2 throughput limit on the
[FP32-accumulate path](specs/02_privilege-and-rate-control.md#the-cap-is-product-segmentation).
Every BF16 tensor op uses that path, so BF16 lands at half rate. The limit is a
fuse-programmed [3-bit
selector](specs/02_privilege-and-rate-control.md#selector-encoding). The
professional card runs the same path at full rate.

**The chain.** From fuse to issue rate:

```
  one-time fuse -> SS0/SS1 override -> FECS/GPCCS microcode -> SM issue rate
                          ^
                   FEAT_OVR_PLM  (write gate: PL3 only)
```

`SS0` and `SS1` are the override words in the [FEAT register
bank](specs/03_register-map.md#feat-bank). [FECS/GPCCS](specs/03_register-map.md#fecs)
is the GPU's front-end and context-switch microcode; SM is the streaming
multiprocessor. The [PLM](specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
is the bank's read/write permission mask; on the 5090 its write field admits only
PL3, the level where NVIDIA's boot firmware runs.

**The measured baseline.**

| What | Measured | Source |
|---|---:|---|
| BF16 → FP32 issue rate | 222.8 TF/s | ai.rs, driver 610.57.04 |
| FP16 → FP32 issue rate | 224.3 TF/s | ai.rs, driver 610.57.04 |
| FP16 → FP16 issue rate | 441.4 TF/s | ai.rs, driver 610.57.04 |
| RTX PRO 6000, BF16 → FP32 | 518.0 TF/s | my run, driver 615.71.09; whitepaper 503.8 |
| RTX PRO 6000, FP16 → FP16 | 515.0 TF/s | same run |
| BF16 cuBLAS GEMM 8192³ | 234.8 TF/s | 5090 D, different SKU |

My two cards measure 226.6 and 229.6 TF/s on the BF16 → FP32 path on 595.91.07.
On the PRO 6000 the same probe measured 518.0 TF/s BF16 → FP32 and 515.0 TF/s
with an FP16 accumulator; the vendor whitepaper's 503.8 is within 3% of the
first. The 5090 has no local FP16-accumulate measurement, so its 441.4 TF/s
comes from ai.rs.

### How the 3090/4090 unlock worked

The technique came from the CMP 170HX mining-card work
([cmp170hx](https://github.com/Consensus-Protocol/cmp170hx)).
[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) packaged it for
consumer Ampere, and
[gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada) ported it to
Ada in October 2026. It roughly doubled throughput: 165 → 331 TF/s on a 4090
issue-rate probe, and 87.5 → 157.4 TF/s on a 3090 Ti BF16 GEMM.

The route depended on a leaked NVIDIA test key. The debug booters were encrypted
with it ([published test
key](https://gist.github.com/nvlight/fc7479629b0ace094873e58ba7d75eb2/743ca6adaa87034054112936f37e146126b7705c)),
so researchers could decrypt them and mine the code for gadgets. That key does not
work on GB202: it gives no known-answer match, and the full 16! search over the
key's [permutation family came back
empty](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative).

- A kernel module starts a signed [SEC2](specs/01_boot-chain.md#sec2) boot
  image. SEC2 is the GPU's security coprocessor.
- The booter copies signature data with a length the host controls.
- The copy overflows the stack. A ROP chain (return-oriented programming), built
  from instructions already in the signed image, takes over.
- It writes [`FEAT_OVR_PLM`](specs/03_register-map.md#write-gate) to open the
  bank, then [`SS0`](specs/03_register-map.md#ss0-and-ss1) = `0x88888888` and
  [`SS1`](specs/03_register-map.md#ss0-and-ss1) = `0x8`.
- A [PCI function-level reset
  (FLR)](specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
  resets the card; the stock driver binds; the override stays.

```
  signed SEC2 booter
    -> host-controlled copy length -> stack overflow
    -> ROP chain from authenticated booter instructions
    -> FEAT_OVR_PLM opened to all levels
    -> SS0 = 0x88888888, SS1 = 0x8
    -> PCI FLR; stock driver binds; override survives
```

## Blackwell's boot chain and why the old route is closed

Blackwell boots through an immutable security processor and a host-supplied
first-stage firmware image. The names:

| Name | What it is |
|---|---|
| FSP | Security processor that runs first out of reset, from immutable ROM |
| GSP BootROM | Immutable ROM on the GSP, the GPU's RISC-V coprocessor; verifies the next stage |
| FMC | First-stage mutable GPU firmware; host-supplied, signed, encrypted; runs in Heavy Secure |
| GSP-RM | Main GPU firmware; host-supplied, plaintext; runs in Light Secure |
| PL0 / PL2 / PL3 | Privilege levels: host (PL0), GSP-RM (PL2), boot firmware (PL3) |
| FEAT bank | Register block holding the speed-selector overrides |
| PLM | Per-block read/write permission mask |
| WPR | Write-protected VRAM region holding firmware and heaps |

The boot order:

```
  FSP (ROM) -> GSP BootROM (ROM) -> FMC (host-supplied, signed, encrypted, PL3)
            -> GSP-RM (host-supplied, plaintext, PL2) -> host driver / CUDA
```

Three things changed, and together they close the old route:

1. **The SEC2 route is gone.** [No GB20x SEC2 booter
   ships](experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package),
   and the leaked test key [does not reproduce on
   GB202](experiments/07_plaintext-corpus.md#075-the-ga100-test-key-does-not-fit).
   The Linux kernel's nova-core documentation confirms there is no SEC2
   involvement, no Booter ucode, and no FWSEC-FRTS stage on Hopper/Blackwell
   ([FSP and Secure Boot](https://docs.kernel.org/gpu/nova/core/fsp.html)).
2. **The FEAT bank is [final before the FMC
   runs](experiments/05_fmc-fsp-boot-inputs.md#0517-feat-bank-final-before-the-fmc).**
   A GPU-side devinit (an initialization routine that runs before the driver)
   writes the override words and locks the bank. The driver and GSP-RM do not
   write it.
3. **The write mask is
   [PL3-only](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped).**
   Host writes (PL0) are dropped. GSP-RM writes (PL2) are also dropped. An FLR
   briefly opens a PL2 window, but [a GPU-side
   devinit](experiments/05_fmc-fsp-boot-inputs.md#0521-plm-re-lock-is-autonomous-devinit)
   [re-locks it 1.85 s before GSP-RM
   starts](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm).

That leaves PL3. A GSP-RM bug is not enough because GSP-RM runs at PL2; a host
write is not enough because the host is PL0. The host-facing surfaces at PL3 are
the [FSP message parser](specs/01_boot-chain.md#fsp-command-surface), the [FMC
boot-parameter parser](specs/01_boot-chain.md#wprmeta), and the
[suspend/resume page table](specs/01_boot-chain.md#suspendresume). A bug in one
of those is the remaining class.

The [vBIOS](specs/05_vbios-and-devinit.md) is not a shortcut either. Its
plaintext init tables [do not name the
FEAT block](experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan),
and the tables that do exist are authenticated in Heavy Secure.

## What I tried

I tried eight kinds of attack. None of them wrote the selector. Each row links to
the experiment record with the commands and artifacts.

| What I did | Result | Status | Records |
|---|---|---|---|
| Wrote the speed registers from the host window, from GSP firmware, and through the CUDA debugger class; tried the [fuse shadow](specs/03_register-map.md#fuse-and-otp) and the graphics engine's [rate register](specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view); read the falcon blocks | Success returned, writes dropped; the rate register is writable but reasserted and inert; the debugger class reads the bank but cannot write it; the FECS/GPCCS falcon blocks are absent, and the vBIOS ucode table has no consumer on GB202 | Dead, measured | [register writes](experiments/01_software-register-writes.md), [debugger class](experiments/10_debugger-class-and-fecs-ucode.md), [falcon probe](experiments/11_falcon-and-gr-window-probe.md) |
| Used the driver's registry knobs (`RMOverrideSmSpeedSelect*`, `RMDisableFeatureDisablement`) | Parsed and stored, no rate or bank change | Dead, measured | [registry keys](experiments/02_registry-and-static-audit.md) |
| Poked the GPU command ring ([FECS doorbell](specs/03_register-map.md#fecs) and [graphics engine context buffers](specs/03_register-map.md#sm-and-gr)) | Payloads are addresses and sizes, no selector field | Dead, measured/static | [FECS and context](experiments/03_fecs-and-gr-context.md) |
| Read firmware memory (GSP, FSP, and SEC2 local memory; [RISC-V debug engine](specs/06_gsp-riscv-and-priscv.md#priscv-register-map)) | Local memory empty or locked to PL3; the debug engine reads the 14.4 MB GSP-RM code segment after a halt, not secure memory or the WPR | Dead or diagnostic | [secure memory](experiments/04_hs-sec2-fsp-memory.md) |
| Fed the boot firmware bad input (the host-built [boot descriptors](specs/01_boot-chain.md#wprmeta)) | Seventeen structured error codes, control over where firmware lands in VRAM, authentication enforced | Live input, mapped, no exploit | [boot inputs](experiments/05_fmc-fsp-boot-inputs.md), [parser map](experiments/09_fmc-cold-boot-parsers.md) |
| Hooked suspend/resume (the host-built [descriptor and page table](specs/01_boot-chain.md#suspendresume)) | Page table is plaintext; saved state is encrypted per boot and card | Live structure, no exploit yet | [suspend/resume](experiments/06_sr-resume.md) |
| Edited the [vBIOS](specs/05_vbios-and-devinit.md) and its [init tables](specs/05_vbios-and-devinit.md#devinit-authentication), including the no-flash loader route | No FEAT address in plaintext, tables authenticated, custom route tops out at PL2 | Dead, static | [vBIOS](experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address), [devinit](experiments/05_fmc-fsp-boot-inputs.md#0522-vbios-devinit-table-scan) |
| Raced the reset (the [PL2-writable window](specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) after an FLR) | Window is 1.32 s; the re-lock lands 1.85 s before GSP-RM starts | Dead, measured | [reset window](experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm) |
| Decoded the readout consumers and mapped the firmware image (offline statics) | The readout bits the RM reads are ECC capability flags, not selectors; the image is a container with about 18.5 MB of plaintext and a 53.8 MB encrypted ucode blob whose decrypted contents transit RM memory at boot | Readout lead closed, capture lead opened | [readout decode](experiments/12_feat-readout-decode.md), [fwimage map](experiments/13_fwimage-map-and-bindata.md) |

[The FMC debug-key search](experiments/07_plaintext-corpus.md#0710-the-fmc-key-search-comes-back-negative)
is negative too: three known-answer variants and both debug containers over all
16! permutations, under five mode variants. No key came out.

Full records, commands, and artifacts are in [the experiment
files](experiments/).

## Where it stands

The open leads, ranked by the decision each one buys, are in [Open
leads](IDEAS.md). The short version: the FEAT readout and fuse target is
validated ([the reference
dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump));
the `SS0`/`SS1` override format is still open. The public record reproduces the
drop on GB202 and GB203M and names the missing primitive as PL3 code execution
in the security firmware ([the external
cross-check](experiments/08_assessment-and-cross-checks.md#0811-the-register-route-is-a-pl3-problem)).
The cold-boot FMC parser map is measured ([the parser
group](experiments/09_fmc-cold-boot-parsers.md)): the boot inputs are bounded or
exact, and the image bytes are authenticated. Next is the suspend/resume
descriptor and page table, then the FSP framing. The vBIOS app `0x23` tail and
the per-SM probes follow. The FECS/GPCCS read route is closed: the falcon blocks
are absent at the documented bases, the GR window the GSP-RM admits is empty,
and the space above it is the vBIOS ROM plus one per-card table. The vBIOS
ucode table has no consumer in the open stack on GB202, and the RM boots GR
through `sec2_acr` from RM memory ([the falcon
probe](experiments/11_falcon-and-gr-window-probe.md), [the
consumer](experiments/11_falcon-and-gr-window-probe.md#116-no-stack-component-reads-the-ucode-table)).

Two offline groups landed since. The readout decode is closed: every RM
consumer of the flanking readout registers is an ECC capability flag, so
`READOUT_1` is the only selector carrier ([the readout
decode](experiments/12_feat-readout-decode.md)). And the firmware image is
mapped as a container: about 18.5 MB of plaintext, then a 53.8 MB encrypted
`rm.bindata.bin` that holds the engine ucode behind per-blob SEC2 key
derivation, with plaintext load descriptors inside
([the fwimage map](experiments/13_fwimage-map-and-bindata.md)). The decrypted
FECS/GPCCS ucode transits RM memory at every boot, so a timed capture reads
it without the key — the [staged-ucode
capture](IDEAS.md#staged-ucode-capture) is the lead that settles whether FECS
microcode or SM silicon enforces the cap, and with it whether any PL3 write
can change the rate at all.

The [RISC-V debug
engine](experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)
is no longer on that list. A register sweep at the boot-image halt could explain
why its memory read is gated, but it cannot read the image.

**Not viable.**

- A [GSP-RM bug](experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)
  as a direct FEAT write path. PL2 is too late; a patched GSP-RM is still a
  foothold for other probes ([Open leads](IDEAS.md)).
- CUDA debugger-class FEAT writes. The class reads the bank and its write is
  dropped ([the debugger
  test](experiments/01_software-register-writes.md#018-the-debugger-class-reads-the-bank-but-cannot-write-it)).
- [vBIOS flashing](experiments/07_plaintext-corpus.md#073-the-vbios-has-no-feat-address).
  It is signed.
- Fuse editing. The boot fuse check fails.
- Voltage glitching. There is no public method.
- [Entering debug fuse
  state](experiments/07_plaintext-corpus.md#071-pl3-components-in-the-driver-package).
  There is no retail path.

One measurement and one primitive were missing. I now have the measurement.

- A PRO 6000 reads [`FEAT_READOUT_1 =
  0`](specs/03_register-map.md#readout-decode) with every arithmetic speed fuse
  at 0, and runs BF16 → FP32 at 518 TF/s, equal to its FP16-accumulate rate
  ([the reference
  dump](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump)).
  That is what to aim for.
- The missing primitive is code execution at PL3. That is how the selector gets
  written. The dump gives the target; it does not unlock the card.

**What would count as an unlock:**

- The driver's [rate
  getter](specs/02_privilege-and-rate-control.md#the-rm-getter-and-the-host-view)
  reports the capped field clear.
- [BF16 issue
  rate](specs/02_privilege-and-rate-control.md#the-cap-is-product-segmentation)
  near 440 TF/s, with a matched BF16 GEMM and numerical validation.
- The override survives an FLR, a driver reload, and a device enable. The driver
  loads without GPU or GSP errors.
- It reproduces on a second cold boot and a second card.

## Reverse-engineered specs

While doing research, I reverse engineered a good chunk of the GB202: the boot
chain, the rate-control registers, the firmware formats, the debug interfaces.
These specs are that material, cleaned up.

| Spec | What's in it |
|---|---|
| [Boot chain](specs/01_boot-chain.md) | From reset to GSP-RM: the security processor, boot ROM, first-stage firmware, host boot descriptors, suspend/resume |
| [Privilege and rate control](specs/02_privilege-and-rate-control.md) | The three privilege levels, the permission mask, the FEAT and fuse banks, how a 3-bit selector becomes an SM issue rate |
| [Register map](specs/03_register-map.md) | Every register block I measured, with stock values and a cross-part comparison |
| [Firmware formats](specs/04_firmware-formats.md) | The FMC container and signature format, the boot image, the GSP-RM image layout and address model, its module map |
| [FMC parsers](specs/09_fmc-parsers.md) | The FMC's checks on the host boot inputs, the signature section layout, and the pointer rules |
| [vBIOS and devinit](specs/05_vbios-and-devinit.md) | The 2 MiB flash map, PCI image chain, info table, microcode table, and how the init tables are authenticated |
| [GSP RISC-V and PRISCV](specs/06_gsp-riscv-and-priscv.md) | The GSP's register blocks, the debug engine, its command set, and the 14.4 MB code window |
| [Memory and host access](specs/07_memory-and-host-access.md) | The card's memory windows, the protected firmware region, framebuffer heaps, and the sentinel fills that mark refusals |
| [Errors and logging](specs/08_errors-and-logging.md) | The boot error codes, driver status codes, sentinels, and the GSP log format and decoder |

Most of this was measured on the two cards. Where a value came from a public
header or is carried over from Ada/Ampere, the spec says so.

## Tools

Everything I used is here, minus NVIDIA's firmware. These are research tools;
expect rough edges. Each directory has a README with build and run steps.

| Tool | What it does | Needs | Read / write / hang |
|---|---|---|---|
| [Register access](tools/register-access/) | Userspace client for the driver's register-op ioctl: reads and writes the FEAT and fuse banks, streams firmware memory, polls the lock | live card, root | read/write |
| [Direct probe](tools/direct-probe/) | Direct reads through the card's memory window, with no driver involvement: read-only register maps and streams | live card, root | read; can hang + reboot |
| [Issue-rate probe](tools/issue-rate-probe/) | Register-resident tensor issue-rate benchmark; validates every output cell and records clocks and power | live 5090, CUDA 13 | read/write |
| [vBIOS tools](tools/vbios-tools/) | Dumps the flash window and parses the image chain, info table, microcode table, and init tables | live card or a local dump | read |
| [GSP-RM tools](tools/gsp-rm-tools/) | Ghidra helpers for the GSP-RM image (the ~18.5 MB plaintext region of the 72.8 MB file), a raw reference scanner, the module splitter, and the GSP log decoder | your own extracted firmware | offline |
| [FMC tools](tools/fmc-tools/) | Extracts the FMC and boot images, verifies signatures, and runs the 16! key search | your own driver package | offline |
| [Driver harness](tools/driver-harness/) | Instrumented-driver harness: boot-input and suspend/resume tests, FEAT samplers, context dumps, debug-engine tools | an exact 595.91.07 driver source tree | read/write; can hang + reboot |
| [Boot tests](tools/boot-tests/) | Registry-key boot experiments: withholding boot regions and the host-driven FMC bootstrap | live card, root | read/write; can hang + reboot |

No NVIDIA firmware, driver binary, or decompiled GSP-RM tree is in this repo. The
tools that need images expect you to extract them from your own driver package.

## Scope, license, contributing

This is a research log. There is no working exploit or unlock in it. I am not
affiliated with NVIDIA.

The text is CC BY 4.0. Tool source is MIT, except `tools/issue-rate-probe/` and
`tools/fmc-tools/`, which are GPL-2.0-only. See [LICENSE](LICENSE).

The PRO 6000 reference dump is in [the
assessment](experiments/08_assessment-and-cross-checks.md#0810-an-rtx-pro-6000-reference-dump).
A cold-boot sample from one card would still help with the boot variance; a
second card is already in the dump.

Corrections are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Point me at an
experiment record or a command that reproduces the problem.
