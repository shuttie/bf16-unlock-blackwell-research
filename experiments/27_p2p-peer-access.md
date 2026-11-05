# PCIe peer-to-peer on the bench pair

## Summary

**The idea.**

- The second-bus-master lead asks whether a peer GPU's copy engine takes the
  same enforcement path as the host's BAR1 route ([the FB
  route](05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)). The read needs P2P on
  a consumer pair, which the earlier patched-driver route did not deliver on
  this bench.
- I enabled P2P with registry keys only, then checked which gates the stock
  595 driver and GSP actually enforce.

**What it found.**

- P2P is live on the bench pair on the stock 595.91.07 driver. `nvidia-smi
  topo -p2p` reports OK for reads and writes, `cuDeviceCanAccessPeer` is 1 in
  both directions, and 256 MiB `cuMemcpyPeer` copies verify byte-for-byte
  ([the bench pair is live](#271-peer-to-peer-is-live-on-the-bench-pair)).
- The working enabler is a six-key registry set. The stock pair reports CNS
  without it; the host force keys are what flip the status ([the six-key
  result](#271-peer-to-peer-is-live-on-the-bench-pair)).
- The stock host gate is not the CPU. EPYC Zen 2 maps to the Ryzen class, so
  the read check passes. The GSP capability result keeps the host from
  reaching the BAR1 fallback; `ForceP2P=0x11` overrides it. Static BAR1 is
  required for the BAR1 mapping, and the auto check cannot fit a 32 GiB frame
  buffer into a 32 GiB BAR1 ([the host gates](#272-the-gates-behind-cns)).
- The 595 GSP still parses `RMDisableFeatureDisablement` and the feature gate
  still bypasses on it, but the 590-era ebreak guards are not present as flag
  readers in the decompiled image. The key's firmware effect is narrower than
  the 590 write-up ([the GSP gate](#272-the-gates-behind-cns)).
- NCCL's single-thread grouped launch deadlocks in `ncclGroupEnd` on this host;
  one thread per GPU works. This is a harness issue, not a P2P issue
  ([the NCCL result](#273-nccl-on-the-new-path)).
- The static BAR1 window maps the client frame buffer only,
  `[0, 0x7d6e00000)`, and stops below the WPR. There is no BAR1 offset that
  reaches the protected region ([the window
  geometry](#274-the-static-bar1-window-stops-below-the-wpr)).
- A second GPU's copy engine can be aimed at the WPR through the movable BAR0
  window. It gets the same `0xbad0ac00` fill the host gets, with no VRAM bytes
  ([the peer read](#275-a-peer-engine-gets-the-wpr-fill)).
- The stock driver refuses to import any GPU BAR as I/O memory, as root, even
  for the read-only peer route. The experiment needs the instrumented module
  and a registry key ([the gate](#275-a-peer-engine-gets-the-wpr-fill)).

**What it did not find.**

- Which of the six keys is strictly necessary. The full set works; it was not
  peeled back.
- Whether a peer *write* into the WPR is treated the same. Only reads were
  measured.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 27.1 | [Peer-to-peer is live on the bench pair](#271-peer-to-peer-is-live-on-the-bench-pair) | Six keys, OK both ways |
| 27.2 | [The gates behind the CNS status](#272-the-gates-behind-cns) | Host force keys, narrower GSP |
| 27.3 | [NCCL on the new path](#273-nccl-on-the-new-path) | Thread-per-GPU works |
| 27.4 | [Static BAR1 window stops below the WPR](#274-the-static-bar1-window-stops-below-the-wpr) | No BAR1 offset reaches it |
| 27.5 | [A peer engine gets the WPR fill](#275-a-peer-engine-gets-the-wpr-fill) | Fill, no data |

## 27.1 Peer-to-peer is live on the bench pair

**Question.** Does the bench pair expose PCIe peer-to-peer on the stock
595.91.07 driver?

**Why.**

- The WPR peer read needs a second bus master, and the earlier patched-driver
  route required rebuilding the module.
- A registry-only enabler keeps the driver version the rest of the work uses.

**Method.**

- Installed a `modprobe.d` drop-in and reloaded the stock module.
- Queried `nvidia-smi topo -p2p r` and `w`, then ran a driver-API peer test:
  `cuDeviceCanAccessPeer`, `cuCtxEnablePeerAccess`, a 256 MiB `cuMemcpyPeer`,
  and a byte comparison of the destination.

Args used:
`RMDisableFeatureDisablement=1;EnableResizableBar=1;RMForceStaticBar1=1;RMForceP2PType=1;RMPcieP2PType=1;ForceP2P=0x11`

**Observed data.**

- `topo -p2p r` and `w`: OK in both directions.
- `cuDeviceCanAccessPeer`: 1 in both directions.
- 256 MiB peer copies verify in both directions; about 27.6 GB/s one way,
  near the PCIe 4.0 x16 line rate. No Xid or AER entries.
- The same pair reported CNS in both directions before the drop-in was
  installed.

**Result.**

**Answer.** Yes, with the six-key set.

**What we learned.** `ForceP2P=0x11` is the host-side lever that makes the
status OK. The firmware key alone does not flip it.

**Related.** [The FB route](05_fmc-fsp-boot-inputs.md#0525-fb-route-shut),
[the reset window](01_software-register-writes.md#016-the-post-reset-window-closes-before-gsp-rm).

## 27.2 The gates behind CNS

**Question.** Why does a stock GeForce pair report CNS, and which of the keys
change which gate?

**Why.**

- The enabler mixes a firmware key from the 590 write-up with host keys. If the
  host is the only gate, the firmware key may be unnecessary.
- The answer decides whether the enabler is stable across driver updates.

**Method.**

- Read the 595.91.07 host driver's P2P capability path.
- Read the 595.91.07 GSP decompile for the `RMDisableFeatureDisablement`
  parser and its consumers.

**Observed data.**

- The host BAR1 read check allows a peer read when the GPUs share a switch or
  the CPU is Ryzen or Xeon SPR. EPYC Zen 2 maps to Ryzen, so the CPU check
  passes.
- The host only reaches the BAR1 fallback when the GSP capability result has
  at least one OK. On a GeForce SKU it does not, so the stock result is CNS.
  `ForceP2P=0x11` overrides the status before that check.
- The BAR1 mapping requires static BAR1. The auto check compares the full
  frame-buffer address space with BAR1; on a 32 GiB card with a 32 GiB BAR1 it
  cannot fit, and the forced path uses the smaller client frame buffer.
- The 595 GSP parser still stores `RMDisableFeatureDisablement` at
  config+`0x545a`, and the feature gate still returns zero when it is set. In
  the decompiled image only the feature-gate function reads it; the 590-era
  ebreak guard sites are not present as flag readers.

**Result.**

**Answer.** The host force keys are the working path. The firmware key is
still parsed, but the 590 write-up's guard mechanism does not carry over.

**What we learned.** The enabler is a host-driver override with a firmware key
of uncertain value, not a firmware unlock.

**Related.** [The write gate](../specs/03_register-map.md#write-gate), [the
registry audit](02_registry-and-static-audit.md#023-speed-select-keys-are-live-code-paths).

## 27.3 NCCL on the new path

**Question.** Does NCCL use the new path, and does the grouped single-process
launch work?

**Why.**

- LLM inference uses NCCL for tensor-parallel collectives. A raw copy test is
  not enough.

**Method.**

- Two-GPU all-reduce, P2P enabled versus `NCCL_P2P_DISABLE=1`, one thread per
  GPU.

**Observed data.**

- 64 KiB: 23.5 µs/op with P2P, 36.7 µs over shared memory.
- 512 MiB: 23.8 GB/s with P2P, 6.4 GB/s over shared memory.
- The single-thread `ncclCommInitAll` grouped launch hangs in `ncclGroupEnd`;
  `strace` shows a busy `accept()` loop. One thread per GPU completes and
  verifies.

**Result.**

**Answer.** NCCL uses P2P and benefits at both sizes. The grouped
single-process launch is not usable on this host.

**What we learned.** The harness must use one thread per GPU. Real inference
deployments use one process per GPU, so the grouped path is not the one that
matters.

**Related.** [The enablement](#271-peer-to-peer-is-live-on-the-bench-pair).

## 27.4 The static BAR1 window stops below the WPR

**Question.** Does the static BAR1 aperture cover the WPR, so that a peer read
can be pointed at "the WPR's BAR1 offset"?

**Why.**

- [The enablement](#271-peer-to-peer-is-live-on-the-bench-pair) made P2P live;
  the next step was a peer read of the protected region.
- [The FB route](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)
  used the BAR0 PRAMIN window because BAR1 does not exist during the boot. The
  post-boot static BAR1 window is the P2P data aperture, so its geometry
  decides whether the plan is possible at all.
- If the window is one-to-one with FB over the whole card, the WPR has a BAR1
  offset and the peer read is a one-line change.

**Method.**

- Instrumented `595.91.07`: `kbusEnableStaticBar1Mapping_TU102` prints the
  window's FB start, size, aperture size, and bus address.
- The WPR layout comes from the GSP's
  [GSCI layout](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut) plus the stock
  constants (3 MiB non-WPR heap, `0x47000` bootloader).
- Read 64 KiB at both ends of the 32 GiB aperture and scanned the whole window
  for the [`0xbad0ac00` fill](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads).
- Filled a 4 MiB CUDA allocation with a nonzero pattern and located it through
  BAR1 to confirm the window is one-to-one with client FB.

Args used:

```text
BF16PeerBarIoMem unset; six-key P2P enabler; instrumented module loaded with insmod
```

**Observed data.**

```text
BF16: BAR1MAP gpu=1 physFb=0x28800000000 start=0x0 size=0x7d6e00000 aperture=0x800000000
BF16: GSCI fwWprLayoutOffset nonWprHeap=0x7e72e0000 frts=0x7f42c0000
```

- With `nonWprHeap=0x7e72e0000`, the WPR base is `0x7e75e0000`, the boot slot
  `0x7f4279000`, and FRTS `0x7f42c0000`. All three are above the window's
  `size` of `0x7d6e00000`.
- The 64 KiB probes at offsets 0 and `0x7ffff0000` read zero. The scan over the
  32 GiB aperture (127 of 128 chunks; one chunk boundary is refused by the
  kernel) found no fill.
- The pattern allocation appeared at BAR1 offset `0x1fc00000`, and a 64 KiB
  peer copy from that offset verified byte-for-byte. The window is one-to-one
  with client FB below `size`.

**Result.**

**Answer:** no. The static window maps client FB `[0, 0x7d6e00000)` and the WPR
starts above it. No BAR1 offset reaches the protected region.

**What we learned.**

- The WPR is reached through the movable BAR0 PRAMIN window, not BAR1. The
  window base register `NV_XAL_EP_ZB_BAR0_WINDOW` sits at BAR0 offset
  `0x10fd40` and holds the FB offset in 64 KiB units; the data window is 1 MiB
  at BAR0 `0x700000`–`0x7fffff`.
- The [BAR1 spec](../specs/07_memory-and-host-access.md#bar0-and-bar1) needed a
  correction: with the static mapping deployed, BAR1 offsets are FB offsets
  over the client window. The earlier zeros were a boot-time VAS artifact, not
  a general rule.

**Related.** [The FB route](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut),
[the peer read](#275-a-peer-engine-gets-the-wpr-fill),
[BAR0 and BAR1](../specs/07_memory-and-host-access.md#bar0-and-bar1).

## 27.5 A peer engine gets the WPR fill

**Question.** When the second GPU's copy engine reads the WPR through the
movable BAR0 window, does it get data or the host's access-denied fill?

**Why.**

- Every measured drop so far arrived through the host port or the RM. A peer
  copy engine is a different bus master, and the gate's requester model was
  inferred, not measured.
- [The FB route](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut)
  closed the host route to the decrypted boot image. A peer route would be a
  read primitive with no code execution.
- The test is read-only, so it needs no wedge budget.

**Method.**

- The stock `595.91.07` refuses to import a GPU BAR as I/O memory:
  `osCheckGpuBarsOverlapAddrRange` rejects any range overlapping FB or a GPU
  BAR, as root, to avoid the BAR1 P2P deadlock (bug 1571948). Both the FB range
  (`overlaps with FB or GPU BAR2`) and the BAR0 range (`overlaps with GPU
  BAR0`) are refused.
- Ran on the instrumented module with a registry key, `BF16PeerBarIoMem=1`,
  that skips that check. The default module keeps the stock behavior; the
  bypass prints one line to dmesg.
- For each target: write the PRAMIN window base (FB offset `>> 16`) through
  BAR0 `0x10fd40`, read the window from the host, register the same BAR0 range
  with CUDA as I/O memory on the second GPU, and copy it to that GPU with its
  copy engine.
- Controls: the same path aimed at a CUDA allocation filled with a nonzero
  pattern, at 1 KiB, 4 KiB, and 64 KiB, and at `+0x400`, `+0x1000`, and
  `+0x10000`; the static BAR1 path at 4 KiB and 64 KiB.
- Targets: WPR base, `+0x400`, `+0x1000`, `+0x10000`, the boot slot, and FRTS.
- Tool: [peer-bar-read](../tools/peer-bar-read/README.md).

Args used:

```text
BF16PeerBarIoMem=1;RMDisableFeatureDisablement=1;EnableResizableBar=1;RMForceStaticBar1=1;RMForceP2PType=1;RMPcieP2PType=1;ForceP2P=0x11
```

**Observed data.**

- The stock gate refused both registrations; with the key the same calls
  succeed. The import path stopped accepting a fifth registration in one
  process, so the PRAMIN range is registered once and the window base is moved
  between reads.
- Pattern control through the BAR0 window: every size and offset copied
  byte-for-byte, including 64 KiB at 2.4 GB/s. The BAR1 control matched at
  4 KiB and 64 KiB.

```text
compare:prammagic1k    -> same
compare:prammagic4k    -> same
compare:prammagic64k   -> same
compare:prammagicp64   -> same
```

- Every WPR target: the host read is the fill throughout. The peer read has the
  fill in the first dword of each 256-byte block and zero in the rest. At
  64 KiB, all 256 blocks carry a matching first dword; no other byte matches.

```text
DATA prwpr1k      nz=768  entropy=2.0000 head=00acd0ba00acd0ba00acd0ba00acd0ba
DATA prwpr1k.peer nz=12   entropy=0.1106 head=00acd0ba000000000000000000000000
RESULT blocks4:prwpr1k -> 4/4 first-dword matches
RESULT blocks4:prwpr64k -> 256/256 first-dword matches
```

The same window, registration, and copy path returned the full pattern for the
control; only the target FB address differs.

**Result.**

**Answer:** no data. A peer engine gets the same fill the host gets.

**What we learned.**

- The WPR protection is enforced on the target side, not on the host port. The
  requester model is not "host hardwired".
- The second-bus-master class is closed as a read oracle. There is no peer
  route to the WPR contents.
- The 256-byte fill structure belongs to the protected read path, not to the
  transfer. The control through the same path returned every byte.
- The route needs a patched driver because the stock RM refuses GPU-BAR I/O
  imports. That is a policy bypass, not a hardware unlock.

**Open question.** Why a peer read of the protected range returns only the
first dword of each 256-byte block, while the host read of the same window
returns the full fill, is not explained by an experiment yet. The pattern is
per block and stable across sizes; the control rules out the transfer path.

**Related.** [The static window](#274-the-static-bar1-window-stops-below-the-wpr),
[the FB route](../experiments/05_fmc-fsp-boot-inputs.md#0525-fb-route-shut),
[the write gate](../specs/03_register-map.md#write-gate).
