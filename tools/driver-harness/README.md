# Driver harness

## At a glance

- **What it is.** Instrumented `595.91.07` driver patches and oracle scripts for
  the RTX 5090 research. Research tools, not a supported installer. Every script
  restores the stock DKMS modules on a clean exit; a wedged run may need a
  reboot.
- **Access.** Read/write. Failed boot-input runs can leave the card wedged and
  need a reboot or cold power cycle.
- **Requirements.** An exact `NVIDIA open kernel modules` checkout at
  `595.91.07`, the stock DKMS modules as the recovery path, Secure Boot disabled
  or the built modules signed, CUDA 13 headers for `cuda_ctx.c`, and
  `cryptography` for `gen_cot_key.py`.
- **No firmware ships.** The scripts expect a local driver/firmware package.

**The short version.**

- The harness adds read-only printk and buffer-dump hooks to the open kernel
  modules, varies one host-built boot field at a time (COT, `WprMeta`,
  `SRMeta`), and drives the PRISCV debug engine and FB window.
- Boot-input oracles return structured FSP/FMC errors; the code table is in
  [the error spec](../../specs/08_errors-and-logging.md#boot-error-codes).
- FEAT/PLM scripts sample the rate bank before and after boot and bracket the
  post-FLR window.
- Suspend/resume scripts capture `SRMeta` and the saved state; a bad field hangs
  with no host log.
- An ICD `STOP` halts GSP-RM, and a BAR1 read can wedge the GPU.

**In this file.**

- [Requirements](#requirements)
- [Layout](#layout)
- [Environment](#environment)
- [Setup and restore](#setup-and-restore)
- [Boot-input oracles](#boot-input-oracles)
- [FEAT and PLM](#feat-and-plm)
- [Suspend/resume](#suspendresume)
- [PRISCV ICD](#priscv-icd)
- [Context and FB](#context-and-fb)
- [GSP logs](#gsp-logs)
- [COT test key](#cot-test-key)
- [Inputs and outputs](#inputs-and-outputs)
- [Access and hazards](#access-and-hazards)
- [Observed output](#observed-output)
- [Related](#related)
- [License](#license)

## Requirements

- Linux, root, `gcc`, Python 3, `bash`.
- An `NVIDIA open kernel modules` checkout at tag `595.91.07`.
- The stock `nvidia` DKMS modules installed as the recovery path.
- Secure Boot disabled, or the built modules signed for the running kernel.
- CUDA 13 headers only for `cuda_ctx.c`.
- `cryptography` only for `gen_cot_key.py`.

Terms: the [COT](../../specs/01_boot-chain.md#cot-v2) is the chain-of-trust boot
message; [`WprMeta`](../../specs/01_boot-chain.md#wprmeta) and
[`SRMeta`](../../specs/01_boot-chain.md#suspendresume) are the 256-byte host
descriptors; [WPR2](../../specs/01_boot-chain.md#terms) is the
write-protected firmware reservation; the
[PLM](../../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm)
is the per-block privilege mask. The linked specs define each in full.

## Layout

| Group | Files |
|---|---|
| Loader | `load_patched.sh` |
| Boot inputs | `fmc_oracle.sh`, `wpr_oracle.sh`, `wpr_verified_patch_test.sh`, `run_gsp_patch_test.sh`, `bootbuf_dump.sh`, `boot_tamper_run.sh`, `fmc_buffer_probe.sh` |
| FEAT / PLM | `feat_preboot.sh`, `feat_preboot_flr.sh`, `featbank_writer_probe.sh`, `plm_window_race.sh`, `regkey_rate_sweep.sh` |
| Suspend/resume | `sr_resume_test.sh`, `sr_oracle.sh`, `sr_dump_test.sh` |
| PRISCV ICD | `icd_cmd.c`, `icd_rdm.c`, `icd_dump.c`, `icd_halt_probe.c`, `icd_bootimg_probe.c`, plus `icd_*probe.sh`, `icd_scan.sh`, `icd_trace_run.sh`, `icd_halt_run.sh` |
| Context | `dump_ctx.sh`, `parse_ctxdump.py`, `parse_ctxfiles.py`, `analyze_crosscard.py`, `cuda_ctx.c`, `gprobe_with_ctx.sh` |
| Logs / FB | `gsp_log_capture.sh`, `fb_capture.sh`, `fb_peek.py`, `fbread_analyze.py`, `icd_trace_analyze.py` |
| Patches | `bf16_ctxdump.patch`, `bf16_boot_instr.patch`, `bf16_fsp_eventfix.patch` |
| COT test key | `gen_cot_key.py` |

## Environment

| Variable | Meaning |
|---|---|
| `TOOL_DIR` | Set by each script to its own directory. |
| `ROOT` | Repository root; defaults three levels above `TOOL_DIR`. |
| `TREE` | Path to the `NVIDIA open kernel modules` checkout at `595.91.07`. |
| `MODDIR` | `$TREE/kernel-open`; used by `load_patched.sh`. |
| `BDF` | Target PCI address; required by the register and ICD scripts. |
| `GPU` | RM device index; `1` for `41:00.0`, `0` for `c1:00.0` by default. |
| `DEVID` | Device id used by the ICD wrapper scripts. |
| `OUTDIR` / `OUT` | Output root; defaults to `runs/` under this directory. |
| `REF_CONT` | Reference FMC container for `fmc_buffer_probe.sh`. |
| `UUID` | Target card UUID for `gprobe_with_ctx.sh`. |

Example:

```bash
export TREE=/path/to/nvidia-open-kernel-source
export MODDIR="$TREE/kernel-open"
export BDF=0000:41:00.0
export GPU=1
```

## Setup and restore

1. Check out tag `595.91.07` in your `NVIDIA open kernel modules` tree.
2. Build the instrumented modules:

   ```bash
   cd "$TREE"
   make clean
   make modules -j"$(nproc)"
   ```

3. Load them with the stock driver unloaded:

   ```bash
   sudo ./load_patched.sh
   ```

4. Run one oracle, capture its output, then restore:

   ```bash
   sudo ./load_patched.sh --restore
   ```

The scripts that build or load the instrumented tree (`dump_ctx.sh`,
`bootbuf_dump.sh`, `feat_preboot_flr.sh`, `fb_capture.sh`,
`gsp_log_capture.sh`) apply their patch, build, load, run and restore in one
command. They leave the tree changed, so `make clean` before the next patch.

Cold and warm boots matter. A cold power cycle clears
[WPR2](../../specs/01_boot-chain.md#failure-modes); a warm reboot may leave it
armed after an authentication failure. Assume one reboot per failed run, and use
a cold power cycle if WPR2 survives.

## Boot-input oracles

| Script | What it varies |
|---|---|
| `fmc_oracle.sh <0..6> [value]` | [COT](../../specs/01_boot-chain.md#cot-v2) field: size, offset, boot-args pointer, FMC pointer, hash flip, self-signed key |
| `wpr_oracle.sh <0..18> [value]` | [`WprMeta`](../../specs/01_boot-chain.md#wprmeta): every field, the bootloader description, and the signature and radix3 address deltas |
| `sig_oracle.sh <stock\|xor\|poke> ...` | Edits the GSP-RM signature buffer: `xor <off> [xor]` or `poke <off> <width> <value>` |
| `wpr_verified_patch_test.sh` | Patched GSP-RM image plus preset `verified` |
| `run_gsp_patch_test.sh` | One-instruction GSP-RM patch, rejected by the FMC |
| `bootbuf_dump.sh` | Dumps the host `GspRmBoot` buffer pre-COT and post-boot |
| `boot_tamper_run.sh [off] [xor]` | Flips one ciphertext byte of `GspRmBoot` |
| `fmc_buffer_probe.sh dump` | Reads the host FMC container at copy, postsend and release |
| `fmc_buffer_probe.sh tamper <1\|2\|3>` | Flips a body byte, body-size field or header magic; the observed refusal is [`0x33`](../../specs/08_errors-and-logging.md#boot-error-codes) |

Fields 0 clear any override and leave the boot stock. Values are C integer
literals. Every failure leaves a `dmesg` line with a `Fatal GSP-FMC Error` code;
the code table is in [the error
spec](../../specs/08_errors-and-logging.md#boot-error-codes).

## FEAT and PLM

| Script | What it does |
|---|---|
| `feat_preboot.sh` | Samples the [FEAT bank](../../specs/03_register-map.md#feat-bank) before the COT and after GSP-RM in one boot |
| `feat_preboot_flr.sh [bdf]` | Brackets the [PLM](../../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) re-lock across an FLR and the first open |
| `featbank_writer_probe.sh selftest\|snapshot\|watch\|flr\|boot-install\|boot-collect\|boot-status\|boot-uninstall` | Read-only bank sampler; the boot units sample before the driver binds |
| `plm_window_race.sh measure\|benign\|payload [bdf]` | Measures the [post-FLR L2 window](../../specs/02_privilege-and-rate-control.md#privilege-levels-and-the-plm) and optionally races a write |
| `regkey_rate_sweep.sh [--dry-run\|--only <name>\|--restore]` | One registry key per stock-driver reload |

`featbank_writer_probe.sh boot-install` installs systemd units that sample
before `systemd-udev-trigger`; power the machine fully off and on between
samples, then run `boot-collect`.

## Suspend/resume

| Script | What it does |
|---|---|
| `sr_resume_test.sh` | Forces `pm_test=devices` and captures the stock [`SRMeta`](../../specs/01_boot-chain.md#suspendresume) |
| `sr_oracle.sh <0..6> [value]` | Varies [`SRMeta`](../../specs/01_boot-chain.md#suspendresume) magic, revision, size, radix3 pointer, flags, or a radix3 address delta |
| `sr_dump_test.sh` | Dumps the suspend state through the host-built radix3 |

The trigger is:

```bash
echo devices > /sys/power/pm_test
echo mem > /sys/power/state
```

A bad `SRMeta` field hangs the resume with no host log. The oracle writes
`phase_loaded`, `phase_pre_suspend`, and `phase_post_resume` in its run
directory; a hang leaves the first two and no post-resume marker. Use
netconsole as well when a serial or network console is available.

## PRISCV ICD

Build the C tools first:

```bash
gcc -O2 -o icd_cmd icd_cmd.c
gcc -O2 -o icd_rdm icd_rdm.c
gcc -O2 -o icd_dump icd_dump.c
gcc -O2 -o icd_halt_probe icd_halt_probe.c
gcc -O2 -o icd_bootimg_probe icd_bootimg_probe.c
```

Usage:

```text
icd_cmd <bdf> <cmd_hex> [base_hex] [poll_ms]
icd_rdm <bdf> <addr_hex> <size 1|2|4|8> [base_hex] [poll_ms]
icd_dump <bdf> <addr_hex> <len_hex> <outfile>
icd_halt_probe <bdf>
icd_bootimg_probe <bdf> [dumpfile]
```

`icd_halt_probe` and `icd_bootimg_probe` issue
[`STOP`](../../specs/06_gsp-riscv-and-priscv.md#icd-command-engine); the GSP
halts and the card needs a reboot. `icd_cmd` and `icd_rdm` only latch addresses
and issue one command.

The wrapper scripts add sweeps and boot-window traces:
`icd_probe2.sh`, `icd_rstat_probe.sh`, `icd_rdm_probe.sh`, `icd_map_probe.sh`,
`icd_scan.sh`, `icd_fsp_probe.sh`, `icd_fsp_probe2.sh`, `icd_trace_run.sh`,
`icd_halt_run.sh`.

## Context and FB

Build [the issue-rate probe](../issue-rate-probe/) first; `dump_ctx.sh` uses its
cubin and runner. The script applies `bf16_ctxdump.patch`, builds, loads, runs
the probe, parses the dumps and restores stock. The kernel writes each mapped
context buffer to `/dev/shm/bf16_ctxdump_*.bin`; the script copies them into
`runs/`. `bf16_ctxdump.patch` is the only source of that path.

```bash
sudo ./dump_ctx.sh
python3 -I ./parse_ctxfiles.py runs/ctxdump_<stamp>
python3 -I ./analyze_crosscard.py runs/ctxdump_<stamp>
```

`fb_capture.sh` reads FB through the BAR0 PRAMIN window after GSP-RM is up.
`fb_peek.py` reads through BAR1; it is read-only but a
[BAR1 read](../../specs/07_memory-and-host-access.md#bar0-and-bar1) can wedge
the GSP. The BAR0 window is the working path; the WPR range returns the
[access-denied fill](../../specs/07_memory-and-host-access.md#host-fb-reads-and-the-wpr).

## GSP logs

`gsp_log_capture.sh` loads the instrumented modules, triggers a few RM queries,
unloads to fire the log hook, and writes the raw rings to `runs/gsplog/`. The
decoder lives in [GSP-RM tools](../gsp-rm-tools/). Message text and severity
need the logging metadata file; the function-level trace does not. See
[the GSP log ring
format](../../specs/08_errors-and-logging.md#gsp-log-ring-format) and
[what the decoder
recovers](../../specs/08_errors-and-logging.md#what-the-decoder-recovers).

## COT test key

`gen_cot_key.py` generates a throwaway P-384 key pair for the key-anchor test.
It writes the private key next to the script. Never commit it.

```bash
python3 -I ./gen_cot_key.py --hash c04_hash.bin
```

## Inputs and outputs

Inputs are local-only:

- the exact `595.91.07` source tree;
- the driver/firmware package for `gsp_ga10x.bin` and the FMC/bootloader files;
- the FMC reference container for `REF_CONT`;
- `c04_hash.bin` for the COT test key.

Outputs go to `runs/` under this directory. The context dump is the exception:
the kernel writes it to `/dev/shm/bf16_ctxdump_*.bin`, and `dump_ctx.sh` copies
it into the run directory. Kernel logs go to `dmesg` or the journal.

## Access and hazards

Most scripts read and write. Treat every run as one that may need a reboot:

- A refused COT hash, key or container leaves
  [WPR2](../../specs/01_boot-chain.md#failure-modes) armed; retries fail until a
  reboot or cold power cycle.
- A [`gspFwHeapSize`](../../specs/01_boot-chain.md#wprmeta) below GSP-RM's
  minimum applies the layout and then wedges.
- A bad [`SRMeta`](../../specs/01_boot-chain.md#suspendresume) field hangs the
  resume with no host log.
- [`STOP`](../../specs/06_gsp-riscv-and-priscv.md#icd-command-engine) through the
  ICD halts GSP-RM; the card needs a reset.
- A [BAR1 read](../../specs/07_memory-and-host-access.md#bar0-and-bar1) can
  wedge the GSP; use the BAR0 PRAMIN window where possible.
- Do not page-scan the [BAR0 flash
  aperture](../../specs/07_memory-and-host-access.md#bar0-and-bar1) while the
  driver owns the card.

## Observed output

Stock COT size mismatch:

```text
FSP response reported error. Task ID: 0x1 Command type: 0x14 Error code: 0xd9
```

Bad `WprMeta` magic:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x827, additional info=0x0
```

Suspend/resume descriptor:

```text
BF16: SRMeta magic=0x8a3bb9e6c6c39d93 rev=2 size=0xcde0000 flags=0x0 radix3Addr=0x148c00000
```

Post-FLR PLM window:

```text
samples=1042 first=0x80842bcf last=0xfffffb8f
window opens at t=0 ms (plm=0x80842bcf)
re-lock at t=1156 ms (+1156 ms after open)
```

ICD halt read:

```text
RPC                  0xffffffff93002ebc
RDM 0x01400000/8     0x96be52c70693b9e7
```

GSP log decode counts:

```text
RM task 3:     98 records, 96 resolved
INIT task 2:   42 records, 41 resolved
KERNEL task 1: 26 records, 0 resolved
```

WPR read through the BAR0 window:

```text
[frts - 0x50000, frts): 245760 nonzero, entropy 2.0000, head 00acd0ba 00acd0ba
```

## Related

- Experiments:
  - [the PL2 write test](../../experiments/01_software-register-writes.md#012-speed-register-write-from-gsp-is-dropped)
    and [the post-FLR window](../../experiments/01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm)
  - [the GR context dumps](../../experiments/03_fecs-and-gr-context.md#034-first-live-gr-context-buffer-dump)
  - [the live ICD](../../experiments/04_hs-sec2-fsp-memory.md#044-priscv-icd-is-a-live-debug-port)
  - [the boot-input baseline](../../experiments/05_fmc-fsp-boot-inputs.md#053-boot-input-baseline-and-the-ordinary-fmc-path)
  - [the host-driven SR cycle](../../experiments/06_sr-resume.md#061-the-suspend-and-resume-cycle-is-host-driven)
  - [the same-boot two-card probe](../../experiments/08_assessment-and-cross-checks.md#083-same-boot-two-card-issue-rate-probe)
- Specs: [boot chain](../../specs/01_boot-chain.md#at-a-glance),
  [WPR and FRTS layout](../../specs/07_memory-and-host-access.md#wpr-and-frts-layout),
  [boot error codes](../../specs/08_errors-and-logging.md#boot-error-codes).
- Sibling tools: [register access](../register-access/),
  [FMC tools](../fmc-tools/), [boot tests](../boot-tests/).

## License

MIT.
