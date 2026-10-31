# Boot tests

Registry-key boot-path experiments for GB202. Each run reloads the NVIDIA driver
with one `NVreg_RegistryDwords` value, records what the GSP boot path did, and
restores the stock driver before the next variant. Nothing is persisted: the key
is passed on the modprobe command line only.

## What it does

The script exercises three controls:

- `RmDisableCotCmd` is a bitfield: FRTS sysmem in bits 1:0 (`0x1`), FRTS vidmem
  in bits 3:2 (`0x4`), and the host-driven FMC bootstrap (GSPFMC) in bits 5:4
  (`0x10`).
- `RmDisableFspFuseErrorCheck=1` disables the FSP fuse-error check.
- `RmDisableFsp=1` is honoured only in emulation, so it is a negative control.

The FMC answers with a structured report:

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x83d, additional info=0x0
```

## Layout

- `gsp_bootpath_tests.sh` — the harness.

## Build

No build step. Check the script with `bash -n gsp_bootpath_tests.sh`; it is
already executable.

## Run

```bash
sudo ./gsp_bootpath_tests.sh --dry-run          # print the plan, touch nothing
sudo ./gsp_bootpath_tests.sh --only frts-vid    # one variant
sudo ./gsp_bootpath_tests.sh --restore          # unload and reload stock
```

Environment:

- `BASELINE_GPUS` — expected visible GPU count; default `2`.
- `OUTDIR` — where the run log is written; default is the script directory.

The harness unloads `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, and `nvidia`,
captures the dmesg delta before any health check, and restores the stock driver
in an `EXIT` trap.

## Inputs

A live GB202 card, root, the stock driver loaded, and no compute processes using
the GPU. The keys are module-wide, so the script acts on every NVIDIA GPU in the
machine; there is no BDF argument.

## Outputs

`$OUTDIR/bootpath_<timestamp>.txt` contains the per-test kernel log and a summary
line of the form:

```text
frts-vid|rc=0|healthy=no (0/2)|via_fsp=0|fmc_errors=4|timeout=0|xid=0|Fatal GSP-FMC Error: ... 0x83d
```

Representative results from the measured runs:

- FRTS vidmem withheld (`RmDisableCotCmd=0x4`):

```text
Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x83d, additional info=0x0
Max GSP-RM boot attempts exceeded: 4/4
```

- GSPFMC path (`RmDisableCotCmd=0x10`):

```text
kgspResetHw_GB100: Timed out waiting for GSP reset PLM to be lowered
```

  In that state the host cannot read `0x1103c0`: it returns `0xBADF5720`, while
  the GSP sees `0x00000200`.

- FRTS sysmem withheld (`RmDisableCotCmd=0x1`) boots normally.

- A failed restore or a retry after a wedge can report:

```text
_kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
RmInitAdapter failed! (0x62:0x40:2168)
```

## Hazards

The GSPFMC failure leaves an ioctl blocked forever: `nvidia-smi` sticks in
`nvidia_unlocked_ioctl`, `rmmod` blocks on the open fd, and only a reboot exits.
Treat that variant as one-shot.

A `nvidia-smi` stopped with SIGTERM stays in `T` state, holds `/dev/nvidia*`, and
pins the module. The harness uses `timeout -s KILL` and `pkill -9 -x nvidia-smi`
for that reason.

If the driver does not come back after a variant, reboot. A warm reboot may not
clear WPR2; use a cold power cycle if it does not.

## Access

Read/write. The script reloads drivers and changes boot-path inputs; it can hang
the card and require a reboot.

## Related

- [Registry and static audit](../../experiments/02_registry-and-static-audit.md) — E11 measured these variants.
- [Boot chain](../../specs/01_boot-chain.md) — COT and WprMeta fields.
- [Errors and logging](../../specs/08_errors-and-logging.md) — the error codes above.
- [Driver harness](../driver-harness/) — the instrumented-driver oracles.
