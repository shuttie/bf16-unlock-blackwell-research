# Peer BAR read

## At a glance

- **What it does.** Aims one GPU's copy engine at another GPU's BAR apertures
  and compares the result with the host read of the same window. It answers
  what a second bus master gets from the protected framebuffer.
- **Access.** Read-only with respect to VRAM. Root is required: the BAR
  resource files are `0600`. The only register write is the BAR0 PRAMIN
  window base, which is saved and restored around every target. A wedged card
  needs a reboot.
- **Requirements.** Two GPUs on one host, CUDA 13 with the driver API, kernel
  headers, and a `595.91.07` open-module tree with
  [`peer-bar-iomem.patch`](peer-bar-iomem.patch) applied. Without the patch
  the stock driver refuses every I/O-memory import over a GPU BAR.

**The short version.**

- The host maps a window through sysfs, reads it, registers it with CUDA as
  I/O memory, and copies it to the second GPU. That copy is a PCIe read by
  the second GPU's copy engine.
- The target is either the static BAR1 window (client framebuffer) or the
  movable BAR0 PRAMIN window, which can be aimed at any framebuffer offset.
- A nonzero pattern in a CUDA allocation is the control. It proves the path
  and the address math before any protected offset is read.
- Every comparison reports the first differing byte and how many 256-byte
  blocks carry a matching first dword.

**In this file.**

- [What it does](#what-it-does)
- [Layout](#layout)
- [Build](#build)
- [Driver patch](#driver-patch)
- [Modes](#modes)
- [Run](#run)
- [Outputs](#outputs)
- [Example output](#example-output)
- [Access and hazards](#access-and-hazards)
- [Related](#related)
- [Limits](#limits)

## What it does

The 5090's framebuffer is reachable from the host through two apertures: the
static BAR1 window, which maps the client frame buffer one-to-one, and the
BAR0 PRAMIN window, whose base is a register ([BAR0 and
BAR1](../../specs/07_memory-and-host-access.md#bar0-and-bar1)). This tool
issues the same read from a peer GPU instead.

For each window it does three things in order: read it from the CPU, register
the same physical range with the CUDA driver as I/O memory
(`CU_MEMHOSTREGISTER_IOMEMORY`), and copy it into the second GPU with that
GPU's copy engine. The source address of that DMA is the first GPU's BAR bus
address, so the read crosses PCIe.

The protected WPR returns the [`0xbad0ac00`
fill](../../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads) to the
host. The tool measures whether a peer requester gets the fill or the
contents ([the peer
read](../../experiments/27_p2p-peer-access.md#275-a-peer-engine-gets-the-wpr-fill)).

## Layout

| File | What it is |
|---|---|
| `peer_read.c` | Harness: P2P control, BAR1 scan, magic control, BAR0 window targeting, peer copies |
| `Makefile` | Builds `peer_read` against `libcuda` |
| `run-peer-read.sh` | Root run against the loaded driver; no reload |
| `run-reload-test.sh` | Loads the instrumented modules, runs the stock and bypass phases, restores the stock modules |
| `peer-bar-iomem.patch` | Registry-gated driver change: bypass the GPU-BAR I/O-memory check and print the static BAR1 geometry at `kbusEnableStaticBar1Mapping` |

## Build

```bash
make
```

`CUDA_INC` and `CUDA_LIB` override the header and `libcuda` paths.

## Driver patch

The stock driver rejects any I/O-memory import that overlaps framebuffer or a
GPU BAR. `osCheckGpuBarsOverlapAddrRange` returns `NV_ERR_INVALID_ADDRESS`
even for root, to avoid the BAR1 P2P deadlock (bug 1571948). The patch adds a
registry key, `BF16PeerBarIoMem`, that skips the check only when it is set.
The address is still validated by the rest of the import path.

The second hunk prints the static BAR1 window:

```text
BF16: BAR1MAP gpu=1 physFb=0x28800000000 start=0x0 size=0x7d6e00000 aperture=0x800000000 busAddr=0x28800000000
```

`start` is the BAR1 aperture offset of FB offset 0, `size` is the window
length, and `physFb + start + F` is the bus address of framebuffer offset
`F`. The five registry keys that enable P2P on the bench pair are in the
[P2P enablement](../../experiments/27_p2p-peer-access.md#271-peer-to-peer-is-live-on-the-bench-pair).

```bash
cd <open-module tree>
patch -p1 < peer-bar-iomem.patch
make modules -j$(nproc)
```

`run-reload-test.sh` loads the built modules with `MODDIR=<tree>/kernel-open`
and restores the stock DKMS modules at the end.

## Modes

| Option | What it does |
|---|---|
| `--gpu0 BDF` / `--gpu1 BDF` | The two devices, default `0000:41:00.0` and `0000:c1:00.0` |
| `--scan PATH [chunk]` | Chunked scan of a BAR resource for the `0xbad0ac00` fill |
| `--magic` | Allocate a patterned buffer on gpu0, locate it through BAR1, use it as a target |
| `--bar1-start N` | BAR1 aperture offset of FB offset 0 (from `BF16: BAR1MAP`); needed to derive FB offsets from BAR1 offsets |
| `--win name:off:len` | Target a BAR1 window of gpu0 at resource offset `off` |
| `--probe name:off:len` | Map and host-read only, no CUDA registration |
| `--pramin name:fb:len` | Move the BAR0 PRAMIN window to FB offset `fb`, then host-read and peer-read it |
| `--control PATH OFF LEN` | I/O-memory control on a non-GPU BAR |
| `--mb N` | Size of the `cuMemcpyPeer` positive control, default 32 |

The PRAMIN range is registered once and reused across bases. The driver stops
accepting overlapping I/O-memory imports after a few registrations, so a
single registration is also the practical limit.

## Run

```bash
sudo ./run-peer-read.sh
```

Targets the stock driver and reports the refusal when the driver is not
patched. To run the full experiment including the peer read of the WPR:

```bash
sudo MODDIR=<open-module tree>/kernel-open ./run-reload-test.sh
```

The script runs two phases: the stock gate (key unset, expects the refusal)
and the bypass (`BF16PeerBarIoMem=1`). It derives windows from the driver's
`BF16: BAR1MAP` and `BF16: GSCI` boot lines and from the stock layout
constants (3 MiB non-WPR heap, `0x47000` bootloader), then restores the stock
modules.

## Outputs

One `RESULT` line per step, `DATA` lines with size, nonzero bytes, entropy,
and head bytes, and `RESULT compare` with the first differing byte. The
scripts tee everything into `runs/<timestamp>/`.

## Example output

```text
-- target magic64k off=0x1fc00000 len=0x10000
RESULT peer:magic64k            sync -> ok time=0.027 ms rate=2.45 GB/s
RESULT compare:magic64k             -> same
-- pramin prwpr1k fb=0x7e75e0000 len=0x400 reg=1
DATA prwpr1k                  size=0x400 nz=768 entropy=2.0000 head=00acd0ba...
RESULT compare:prwpr1k              -> DIFFER first=0x5 host=ac peer=00
RESULT blocks4:prwpr1k            -> 4/4 first-dword matches
```

## Access and hazards

- Root is required for the BAR resource mmaps and the window register.
- The PRAMIN window base write is restored around every target. Do not run
  while another process is using the first GPU for real work; the window is
  shared with the driver's own PRAMIN path.
- Reads only. The WPR read returns the fill, but a wrong register write can
  wedge the GSP, and recovery is a reboot.
- `--scan` reads the whole 32 GiB aperture in 256 MiB chunks. One chunk
  boundary is refused by the kernel; the tool reports the failure and
  continues.

## Related

- [Peer-to-peer is live on the bench pair](../../experiments/27_p2p-peer-access.md#271-peer-to-peer-is-live-on-the-bench-pair)
- [The static BAR1 window stops below the WPR](../../experiments/27_p2p-peer-access.md#274-the-static-bar1-window-stops-below-the-wpr)
- [A peer engine gets the WPR fill](../../experiments/27_p2p-peer-access.md#275-a-peer-engine-gets-the-wpr-fill)
- [BAR0 and BAR1](../../specs/07_memory-and-host-access.md#bar0-and-bar1)

## Limits

- The register offsets (`0x10fd40` window base, `0x700000` data window) are
  GB202 values. Another part needs its own `NV_XAL_BASE_ADDRESS` and
  `NV_XAL_EP_ZB_BAR0_WINDOW`.
- The stock driver cannot run the peer half at all; the measurement needs the
  patched module. Results obtained that way describe the hardware, not a stock
  system's behavior.
- Only reads are implemented. A peer write needs a different measurement.
