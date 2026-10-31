# Direct probe

Read-only BAR0 register maps and streams, with no RM or GSP call. `hw_probe`
opens `/sys/bus/pci/devices/<bdf>/resource0`, maps the 16 MiB BAR0 window, and
reads dwords at explicit offsets. It writes only pointer/control registers, and
saves and restores each one.

This is the tool behind the FECS, FSP, SEC2, and EMEM maps in the register-map
spec. It is deliberately dumb: no driver ioctl, no GSP RPC, no parsing layer.

## Layout

| File | What it is |
|---|---|
| `hw_probe.c` | The direct BAR0 reader; one static binary, libc only |
| `run_step1_2.sh` | FECS/FEAT reads, FSP EMEM, CMS2, and block maps |
| `run_step3.sh` | FSP/SEC2 streams and the FECS PLM write/read/restore tests |
| `run_step4_fsp_emem.sh` | FSP core EMEM pair plus wide PFSP EMEM maps |

## Build

```bash
gcc -O2 -Wall -o hw_probe hw_probe.c
```

The `run_step` scripts also call the register-access client:

```bash
cd ../register-access
gcc -O2 -Wall -o regops regops.c
```

`REG` defaults to `../register-access/regops`; override it if the client lives
elsewhere.

## Modes

All offsets are BAR0 byte offsets. `read` and `falcon` pass their count through
`strtoul(..., 0)`, so use `0x` for hex. The `dump`/`bar` commands inside the
scripts are the register-access client's commands; that client treats its count
argument as hex.

| Mode | What it does |
|---|---|
| `read <off> <count>` | Read `count` dwords from `<off>` |
| `fecs` | Map `0x409000`–`0x409fff` and print the labelled FECS registers |
| `falcon <base> <count>` | Map a block, e.g. `0x8f0000 0x400` or `0x840000 0x800` |
| `fspemem <count> <origfile>` | Walk the PFSP EMEM channels at `0x8f2ac0`; saves and restores each `EMEMC` |
| `cms2 <start> <count> <origfile>` | Walk the CMS2 indirect-read window at `0x8aa374`; saves and restores the address |
| `stream <ctrlo> <datao> <count> <origfile> <label>` | Arm a control/data pair and stream `count` words; saves and restores the control |
| `restore <origfile>` | Replay saved pointer/control values |

`hw_probe` writes only pointer/control registers: `PFSP_EMEMC(i)`, `CMS2_ADDR`,
and the caller-supplied `stream` control. Each is saved before the first write
and restored. The scripts also call the register-access client; `run_step3.sh`
uses its `wrr` mode to issue write/read/restore batches against the FECS PLMs and
`0x409800`.

## Run

```bash
sudo BDF=0000:41:00.0 GPU=1 OUTDIR=./runs ./run_step1_2.sh
sudo BDF=0000:41:00.0 GPU=1 OUTDIR=./runs ./run_step3.sh
sudo BDF=0000:41:00.0 GPU=1 BDF0=0000:c1:00.0 GPU0=0 OUTDIR=./runs ./run_step4_fsp_emem.sh
```

`BDF` and `GPU` select the card; `GPU` is the register-access `deviceId`, where
`1` is `41:00.0` and `0` is `c1:00.0` on the two-card rig. `OUTDIR` defaults to
`./runs`; each run gets a timestamped subdirectory with `run.log`, dmesg
snapshots, the raw maps, and `orig_regs.txt`.

The scripts check the card first with a benign `PMC_BOOT_0` read and abort if the
GSP control status is not zero. `run_step3` only proceeds with the FECS writes if
each previous write restored cleanly.

## `orig_regs.txt`

The file is append-only and is replayed by `hw_probe restore`:

```text
FSPEMEM <channel> <hex-ememc>
CMS2 <hex-address>
CTRL <hex-offset> <hex-value>
```

The `CTRL` lines come from the `stream` mode; `fspemem` and `cms2` write the other
two. Keep the file with the run; it is the only record of the values that were
restored.

## Inputs and outputs

Inputs: a live card, root, and a built `regops` client. No firmware or dumps are
needed.

Outputs per run:

- `run.log` — full console transcript
- `00_dmesg_before.txt`, `90_dmesg_after.txt` — kernel log around the run
- the raw map files (`10_*`, `20_*`, `30_*`, …)
- `orig_regs.txt` — saved pointer/control values
- `99_restore.txt` — replay readback

## Example output

FECS map, from `hw_probe fecs`:

```text
0x00409660 0xfffffbef  FECS 0x409660 (feature)
0x00409688 0xffffffcf  FECS PLM?
0x00409800 0x00000001  FECS 0x409800
0x00409b00 0x007e0f0a  FECS 0x409b00 (DP path?)
0x00409b04 0x007e0f0a  FECS 0x409b04
```

The full `0x409000`–`0x409fff` range is sparse: 789 of 1024 dwords read
`0xBADF5040` on the stock card. The `0x409800` write lands because it sits in the
fully open `0x4096d0` block; the FECS PLMs do not.

FSP block, from `hw_probe falcon 0x8f0000 0x400`:

```text
0x008f0a58 0x6624b970
0x008f0a5c 0x00000003
0x008f0a90 0xffffff8f
0x008f0ab0 0xe81dc861
0x008f0ab4 0x98216d8b
0x008f0ab8 0x803e5471
0x008f0abc 0x9e870bdf
0x008f0ac0 0x5536c785
0x008f0ac4 0x6fd593dc
0x008f0ac8 0xc79705f3
0x008f0acc 0x8f7a6cc2
0x008f0ad0 0x5792ea26
0x008f0ad4 0xf7cd4b7b
0x008f0ad8 0xc1c4c375
0x008f0adc 0x21fa03ab
```

The `0x8f0a90` word is the FSP core's PLM (`0xffffff8f`, write L3 only). The four
`0x8f0ac0`–`0x8f0adc` channel pairs are the FSP core EMEM channels. The 16-byte
`0x8f0ab0` constant is unidentified.

SEC2 block, from `hw_probe falcon 0x840000 0x800`:

```text
0x00840180 0xbadf5720   (host view; the GSP sees 0xbadf5723)
0x008401c0 0x02000040
0x008401c4 0x00000000
0x008403c4 0x00000b0f
0x00840ac0 0x02000040
0x00840ac4 0x00000000
```

The DMEM port at `0x8401c0` is real but the first 8 KB read zero; the IMEM port
is blocked; the PLM at `0x8403c4` is `0x00000b0f` (read all, write none).

CMS2, from `hw_probe cms2 0 0x2000 orig_regs.txt`, reports
`nonzero=448/8192`. The 448 nonzero dwords are a repeating 128-dword block; the
address register is restored at the end.

PFSP EMEM at `0x8f2ac0` is master-dependent. On the host, channels 4–7 read
`0xBADF5720` and channels 1–3 read zero or `0xdead5ed0`; from the GSP, channels
1/2/4/6/7 read `0xBADF5723` and channels 3/5 read zero or `0xdead5ed0`. Channel 0
is the MCTP/NVDM transport and moves with RM traffic.

## Access and hazards

- Reads are safe in the blocks above. `hw_probe` writes only pointer/control
  registers and restores them; `run_step3.sh` also issues FECS PLM and `0x409800`
  write/read/restore batches through the register-access client.
- Do not page-scan BAR0 `0x300000`–`0x400000` while the driver owns the card. In
  this project that scan coincided with a GSP crash and a required reboot. The
  scripts do not touch that aperture.
- A failed restore or a write to the wrong block can wedge the GSP. Reboot before
  retrying; do not stack experiments on a card whose control status is nonzero.
- The scripts abort on the first unhealthy control status; do not bypass that
  check.

## Related

- Experiments: [E18](../../experiments/03_fecs-and-gr-context.md),
  [E21](../../experiments/04_hs-sec2-fsp-memory.md),
  [E63](../../experiments/04_hs-sec2-fsp-memory.md),
  [E67](../../experiments/04_hs-sec2-fsp-memory.md),
  [E68](../../experiments/04_hs-sec2-fsp-memory.md).
- Specs: [register map](../../specs/03_register-map.md),
  [memory and host access](../../specs/07_memory-and-host-access.md).
- Sibling tool: [register access](../../tools/register-access/).

## Limits

The direct view is master-dependent. The same offset can read a value to the
host and a sentinel to the GSP, or the reverse. Read `0xBADFxxxx` as a PRI error
code, not as data: `0xBADF5040` is unimplemented, `0xBADF5720`/`0xBADF5723` are
blocked to the host/GSP, and `0xBADF5620` is present but inaccessible. The tool
does not decode those codes; the error spec does. It also does not distinguish
an empty EMEM channel from a channel whose pointer the firmware chose not to
move.
