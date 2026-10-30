# FECS and GR context

Research record from October 2026. The evidence below is self-contained; the tool
and spec links point into this docs tree.

## Reproducing this group

**Hardware.** 2× RTX 5090 (GB202, `10de:2b85`), 575 W, Linux, CUDA 13, driver and
GSP-RM 595.91.07. `41:00.0` is `deviceId 1` (`/dev/nvidia1`); `c1:00.0` is
`deviceId 0` (`/dev/nvidia0`). The records use GPU0 for `c1:00.0` and GPU1 for
`41:00.0`; most experiments target `41:00.0`.

**Tools.** [Register access](../tools/register-access/) for the RM
`GPU_EXEC_REG_OPS` path, [Direct probe](../tools/direct-probe/) for raw BAR0 reads,
[Driver harness](../tools/driver-harness/) for the context-dump patch and scripts,
[Issue-rate probe](../tools/issue-rate-probe/) for the tensor rate, and
[GSP-RM tools](../tools/gsp-rm-tools/) for Ghidra and reference scans. Build and
run steps are in each tool README.

**Inputs.** A live card, root, and the exact 595.91.07 driver source tree for the
context dumps. [E19](#e19--the-fecs-command-protocol-statically) and
[E20](#e20--the-fecs-context-path-and-the-host-gr-structures) need the GSP-RM
image extracted from the installed 595.91.07 driver package and a Ghidra 12.2
project loaded at base `0x01000000`. No firmware is shipped here.

**Boot state and cost.** Start from a clean boot: no Xid, both GSPs at 595.91.07.
The context dumps replace the stock driver with an instrumented build and restore
the DKMS modules afterwards. A failed boot can leave WPR2 up and needs a reboot.
Do not page-scan BAR0 while the driver owns the card.

**Terms.** FECS/GPCCS: the GR front-end and context-switch microcode
([rate control](../specs/02_privilege-and-rate-control.md)). GR context: the
per-channel state buffer the host describes and GSP-RM initializes. HAL: the
per-chip method table the plaintext GSP-RM calls. PLM: per-block read/write
permission mask ([register map](../specs/03_register-map.md)). `SS0`/`SS1`:
speed-selector override words. WPR2: the write-protected firmware region
([boot chain](../specs/01_boot-chain.md)). `ctxdump`: the context-dump harness;
`memdesc`: the RM memory descriptor.

## E18 · Live FECS/FSP/SEC2 probes

*2026-10-25 · Revision 16 · status: LIVE (doorbell) / CLOSED (everything else)*

**Hypothesis.** The FECS/GR, FSP, and SEC2 register windows may expose a
host-writable rate or command surface.

**Instrument.** `hw_probe` from [Direct probe](../tools/direct-probe/) does direct
BAR0 reads; `regops` from [Register access](../tools/register-access/) issues
reads and read-modify-write batches through the GSP. Both run as root on
`41:00.0` (`deviceId 1`). The read-only step drivers live in the direct-probe tool.

**Method.** Map the FECS, FSP, PMU, and SEC2 blocks read-only, then try four
write/read/restore batches through the GSP.

```bash
sudo tools/register-access/regops 1 0000:41:00.0 dump 409660 8
sudo tools/direct-probe/hw_probe fecs
sudo tools/direct-probe/hw_probe fspemem 100 baseline.txt
sudo tools/direct-probe/hw_probe falcon 8f0000 400
sudo tools/direct-probe/hw_probe falcon 840000 800
sudo tools/register-access/regops 1 0000:41:00.0 wrr 409688 ffffffff ffffffcf
sudo tools/register-access/regops 1 0000:41:00.0 wrr 409800 0 1
```

`baseline.txt` is the register snapshot the probe uses to restore the block.

**Observed data.** The FECS block is 1,024 dwords; 789 are sentinels. The values
that matter:

| Offset | Value | Meaning |
|---|---|---|
| `0x409660` | `0xfffffbef` | PLM: read all / write L1–L3 |
| `0x409688` | `0xffffffcf` | PLM: read all / write L2–L3 |
| `0x409438` | `0xffffffef` | PLM: read all / write L1–L3 |
| `0x4096d0` | `0xffffffff` | read/write all |
| `0x409638` | `5` | implemented |
| `0x409800` | `1` | GSP-writable doorbell/status |
| `0x409b00` / `0x409b04` | `0x007e0f0a` | DP/companion readout |
| `0x409500` | `0` | command data |
| `0x409504` | `0xbadf5545` | command ID, read-blocked |

The PLM write returns success and does not change the register:

```text
WRITE    off=0x00409660 status=0 SUCCESS value=0xffffffff (write)
READBACK off=0x00409660 status=0 SUCCESS value=0xfffffbef
WRITE    off=0x00409660 status=0 SUCCESS value=0xfffffbef (write)
READBACK off=0x00409660 status=0 SUCCESS value=0xfffffbef
```

Equivalent batches at `0x409688`, `0x409438`, and `0x4096d0` returned success and
left `0xffffffcf`, `0xffffffef`, and `0xffffffff` unchanged.

The doorbell at `0x409800` holds its write:

```text
WRITE    off=0x00409800 status=0 SUCCESS value=0x00000000 (write)
READBACK off=0x00409800 status=0 SUCCESS value=0x00000000
WRITE    off=0x00409800 status=0 SUCCESS value=0x00000001 (write)
READBACK off=0x00409800 status=0 SUCCESS value=0x00000001
```

Implemented registers start around `0x409400`; the first 1 KB is sentinels:

```text
00409000 badf5040
00409004 badf5040
...
00409400 00000190
00409404 00002003
0040940c 000007ff
00409438 ffffffef
00409500 00000000
```

The FSP core block reads `0xbadf5620`; the PMU guess at `0x10a000` is all
`0xbadf5040`; the SEC2 block is mixed:

```text
008f0000 badf5620
008f0004 badf5620
...
0010a000 badf5040
...
00840000 00000000
0084000c ffac6c20
00840018 1f180000
00840020 badf5720
```

Key FSP/SEC2 values, replacing the old appendix pointers:

| Offset | Value | Meaning |
|---|---|---|
| `0x8f0a58` / `0x8f0a5c` | `0x6624b970` / `3` | core status/config |
| `0x8f0a90` | `0xffffff8f` | core PLM: read all / write L3 only |
| `0x8f0ac0` / `0x8f0ac4` | `0x5536c785` / `0x6fd593dc` | ch0 control/data |
| `0x8f0ac8` / `0x8f0acc` | `0xc79705f3` / `0x8f7a6cc2` | ch1 |
| `0x8f0ad0` / `0x8f0ad4` | `0x5792ea26` / `0xf7cd4b7b` | ch2 |
| `0x8f0ad8` / `0x8f0adc` | `0xc1c4c375` / `0x21fa03ab` | ch3 |
| `0x8f0ab0`–`0x8f0abc` | `e81dc861 98216d8b 803e5471 9e870bdf` | unidentified constant |
| `0x8401c0` / `0x8401c4` | DMEM port; `AINCR` advances; first 8 KB zero | SEC2 |
| `0x840180` / `0x840184` | host `0xbadf5720`, GSP `0xbadf5723` | SEC2 IMEM blocked |
| `0x8403c4` | `0x00000b0f` | SEC2 PLM: read all / write none |

**Result.** The FECS/GR, FSP, and SEC2 blocks are readable. All four FECS PLM
writes were dropped; the `0x409800` doorbell held its write. The FSP core PLM is
L3-only, SEC2 IMEM is blocked, and SEC2 DMEM is empty. No new Xid.

**Reproduce.**
1. Build [Register access](../tools/register-access/) and
   [Direct probe](../tools/direct-probe/) per their READMEs.
2. Run the read-only commands above as root on `41:00.0`.
3. Run the two `wrr` batches; expect the PLM readback unchanged and `0x409800` to
   hold. Restore the original values.
4. The direct-probe harness writes a timestamped run directory with the maps and
   dmesg; keep it with the record.

**Limits.** This maps the FECS/FSP/SEC2 windows and shows the PLM writes drop. It
does not show what the FECS command handler does; that code is encrypted
([E19](#e19--the-fecs-command-protocol-statically)).

## E19 · The FECS command protocol, statically

*2026-10-25 · Revision 17 · status: mapped; not a host lever*

**Hypothesis.** The FECS command protocol may contain a command that sets the rate
selector.

**Instrument.** `DecompileAt.java` and `DisasmRange.java` from
[GSP-RM tools](../tools/gsp-rm-tools/) against the extracted GSP-RM image in a
Ghidra 12.2 project loaded at `0x01000000`.

**Method.** Decompile the sender `FUN_ram_015e2724` and the waiter
`FUN_ram_015cc798`; correlate their HAL-relative offsets with the measured FECS
map.

**Observed data.** The sender writes command data to `0x9500`, the command ID to
`0x9504` (`cmd & 0xfff`), and an optional payload to `0x9800 + 4*param`:

```c
/* FUN_ram_015e2724 */
(**(code **)(**(long **)(param_2 + 0xf20) + 0x40))(*(long **)(param_2 + 0xf20),0x9500,param_4);
...
(**(code **)(**(long **)(param_2 + 0xf20) + 0x40))
          (*(long **)(param_2 + 0xf20),0x9504,param_3 & 0xfff);
```

The waiter polls the status slot:

```c
/* FUN_ram_015cc798 */
(**(code **)(**(long **)(param_2 + 0xf20) + 0x28))
    (*(long **)(param_2 + 0xf20),(long)((param_3 + 0x2600) * 4));
```

The caller sends command `0x30` first, then waits:

```c
/* FUN_ram_0184499c */
FUN_ram_015e2724(param_1, lVar5, 0x30, 1, 0, 0);
...
iVar4 = FUN_ram_015cc798(param_1, lVar5, 0, &local_84, 1, 0, 5, 0, 0);
```

The measured absolute registers are `0x409500` (data), `0x409504` (command ID),
and `0x409800` (status/payload). The plaintext call-site command IDs are:

```text
0x01 0x03 0x04 0x09 0x0c 0x0d 0x0e 0x0f 0x1a 0x21 0x24 0x2c 0x2d
0x2e 0x2f 0x30 0x31 0x32 0x3a 0x71 0x72 0x75 0x76 0x7d 0x7e 0xb7
```

`0x21/0x3fffffff` is a boot feature command; `0x30/0x31/0x32/0x75/0x76` are GR
init/context commands. None writes the FEAT selectors or `SS0`/`SS1`.

**Result.** The host-reachable FECS surface is a command doorbell plus a context
buffer loader. The command handler is in the encrypted FECS/GPCCS microcode. No
command ID in the plaintext call-site list sets the rate.

**Reproduce.**
1. Extract the GSP-RM image from your installed 595.91.07 driver package; the
   extraction command is in [GSP-RM tools](../tools/gsp-rm-tools/).
2. Import the image into Ghidra 12.2 at base `0x01000000`.
3. Run `DecompileAt.java` for `0x015e2724` and `0x015cc798`; expect the
   `0x9500`/`0x9504` writes and the `(param_3 + 0x2600) * 4` status read.
4. Check the command IDs against the list above; none references the FEAT bank.

**Limits.** Static only; the handler is encrypted. The command-ID list is the
plaintext call-site set, not a decoded ucode command table.

## E20 · The FECS context path and the host GR structures

*2026-10-26 · Revision 18 · status: CLOSED-STATIC (no rate field)*

**Hypothesis.** The host GR context path may carry a rate selector, or the host may
build the initialized context image.

**Instrument.** `refscan.py` and `DecompileAt.java` from
[GSP-RM tools](../tools/gsp-rm-tools/), plus the 595.91.07 host source tree.

**Method.** Scan every 2-byte offset for `JAL`, `AUIPC+ADDI`, `LUI+ADDI`, and raw
32/64-bit values with correct 20-bit sign extension. Decompile the survivors.
Review the host context-buffer structures.

**Observed data.** The two context functions are materialized four times inside
`FUN_ram_01c1c374` and installed at `obj+0xD00`; the caller is
`FUN_ram_0184499c`:

```c
/* FUN_ram_0184499c */
FUN_ram_015e2724(param_1, lVar5, 0x30, 1, 0, 0);
...
iVar4 = (**(code **)(lVar5 + 0xd00))
            (param_1,lVar5,local_80 >> 0xc,lVar8,plVar3, ...);
```

The installed functions are:

```text
/* ram:0162cc10  FUN_ram_0162cc10  size=0x198 */
/* ram:0162cda8  FUN_ram_0162cda8  size=0x280 */
```

The context descriptor is 0x20 bytes: `+0x00` memdesc, `+0x08` 64-bit GPU
address, `+0x10` size (29 bits) plus flags (3 bits), `+0x18` state, `+0x1c` flag.
The host structures are descriptors, not the image:

- `GR_GLOBALCTX_BUFFERS` is an array of memory descriptors.
- `NV2080_CTRL_GR_CTX_BUFFER_INFO` carries handles, GPU addresses, and sizes.
- `kgrctxPrepareInitializeCtxBuffer_IMPL` fills `gpuPhysAddr`, `size`, `physAttr`,
  `bufferId`, `bInitialize`, and `bNonmapped`.
- `kgrctxFillCtxBufferInfo_IMPL` and `kgrctxMarkCtxBufferInitialized_IMPL` manage
  the list.

The only `portMemCopy` calls in the context path are the UUID copy and the sort
swap:

```text
portMemCopy(pUuidBuffer, uuidBufferSize, pUuid, uuidLength);
portMemCopy(&tmp, sizeof(tmp), &pCtxBufferInfo[j], sizeof(tmp));
portMemCopy(&pCtxBufferInfo[j], sizeof(tmp), &pCtxBufferInfo[j + 1], sizeof(tmp));
portMemCopy(&pCtxBufferInfo[j + 1], sizeof(tmp), &tmp, sizeof(tmp));
```

**Result.** The host builds descriptors; GSP-RM initializes the image. There is no
rate, selector, or enable field in the host structures or the command payloads.
The rate state is a separate read-only cache and is never inserted into a context
buffer.

**Reproduce.**
1. `python3 tools/gsp-rm-tools/refscan.py <gsp-rm-image> 0x0162cc10 0x0162cda8`.
2. Decompile the reported sites; expect the four materializations inside
   `FUN_ram_01c1c374` and the slots at `obj+0xD00`.
3. In the 595.91.07 source tree, inspect the context-buffer functions; expect only
   the UUID copy and the sort swap.

**Limits.** Static. It shows the host builds descriptors, not the initialized
image; [E22](#e22--first-live-gr-context-buffer-dump) through
[E27](#e27--cross-card-context-comparison) test the image itself.

## E22 · First live GR context-buffer dump

*2026-10-26 · Revision 20 · status: partial*

**Hypothesis.** The initialized GR context image may contain a rate selector.

**Instrument.** [Driver harness](../tools/driver-harness/) applies
`bf16_ctxdump.patch` to the exact 595.91.07 tree, builds it, loads it, and restores
stock. [Issue-rate probe](../tools/issue-rate-probe/) runs the tensor workload.
Root; target `41:00.0`.

**Method.** Apply the context-dump patch, build and load the instrumented driver,
run the probe with `--iters 1 --reps 1`, capture dmesg, and restore stock.

**Observed data.** GPU0 booted and produced four dumps; GPU1 failed with
`_kgspBootGspRm: unexpected WPR2 already up` and
`RmInitAdapter failed! (0x62:0x40:2168)`. The probe targeted GPU1 and never ran, so
the dumps are GPU0 driver-init contexts.

| Dump | Tag | Size | Phys | First 4 KB |
|---|---|---:|---|---|
| 1 | main | `0x377000` | `0x7e0b79000` | zero |
| 2 | patch | `0x9000` | `0x7e0f00000` | all `0xaddeadde` |
| 3 | main | `0x377000` | `0x7e0b92000` | 10 nonzero bytes; first word `0x02400000` |
| 4 | patch | `0x9000` | `0x7e0a47000` | `0x8f8` bytes initialized, 287 entries |

The patch buffer parses as `{address, value}` clusters; values are context defaults
(`0x00120000` 88×, `0x40260000` 44×, `0x00400000` 41×). No 4 KB window contains a
known rate constant.

**Result.** No known rate constant in the first 4 KB of either buffer. The patch
buffer is an address/value override list, not a selector.

**Reproduce.**
1. Apply `tools/driver-harness/bf16_ctxdump.patch` to the exact 595.91.07 tree;
   `make clean && make modules -j`.
2. Unload the stock `nvidia` modules, load the instrumented ones, and keep the
   stock DKMS modules as recovery.
3. `sudo tools/driver-harness/dump_ctx.sh` with
   `BDF=0000:41:00.0 EXITMAX=2 GLOBALMAX=6`.
4. Expect four dumps; GPU1 may fail with WPR2 up. Parse with
   `tools/driver-harness/parse_ctxdump.py`.
5. Restore the stock driver.

**Limits.** Only 4 KB per dump; GPU0 driver-init context; GPU1 did not run. The
full image is [E26](#e26--the-full-context-image-and-the-0x88888888-false-positive).

## E23 · Post-use patch buffer differential

*2026-10-26 · Revision 21 · status: negative for rate*

**Hypothesis.** The patch buffer may change after use in a way that reveals a
selector.

**Instrument.** Post-use hooks on `kgrctxUnmapMainCtxBuffer` and
`kgrctxFreePatchBuffer`, with `BF16_CTXDUMP_CREATE=0`, GPU0.

**Method.** Dump the patch buffer at driver-init and at free, then diff the
`{address, value}` entries.

**Observed data.** Both buffers have 287 entries; exactly 10 values differ and no
address differs:

| Address | Driver-init | Post-use |
|---|---:|---:|
| `0x0c804000` | `0x00422001` | `0x00280602` |
| `0x04104200` | `0x00422001` | `0x00280602` |
| `0x04804000` | `0xa0002001` | `0x303e0602` |
| `0x240e4200` | `0xa0002001` | `0x303e0602` |
| `0x10084200` | `0x00401280` | `0x002e2080` |
| `0x48404200` | `0x00401210` | `0x002e2010` |
| `0x2c444200` | `0x00401210` | `0x002e2010` |
| `0x00464200` | `0x00401200` | `0x002e2000` |
| `0x70804000` | `0x00442001` | `0x00320602` |
| `0x34104200` | `0x00442001` | `0x00320602` |

The first changed entry:

```text
0c804000 00280602 10804000 00d80780 04104200 00280602 08104200 00000000
```

**Result.** The changed slots are global-buffer address overrides, not selectors.
The main-exit dump lost its header to the dmesg ring; the patch-exit dump is
complete.

**Reproduce.**
1. Build and load the instrumented driver with the post-use hooks.
2. `sudo tools/driver-harness/dump_ctx.sh` with `BF16_CTXDUMP_CREATE=0`,
   `EXITMAX=2`, GPU0.
3. Diff the driver-init and post-use patch buffers; expect 287 entries, 10 value
   changes, 0 address changes.

**Limits.** One context pair; the main-exit dump lost its header; the changed
slots are address overrides.

## E24 · The main window at `0x4000` is zero

*2026-10-26 · Revision 22 · status: negative*

**Hypothesis.** The main context window at `0x4000` may contain the initialized
selectors.

**Instrument.** Bounded 8 KB window at `BF16_CTXDUMP_MAIN_OFFSET=0x4000`,
`BF16_CTXDUMP_BYTES=8192`, GPU0.

**Method.** Dump the bounded main window for the uninitialized and compute
contexts.

**Observed data.** Both windows are zero; the patch-exit buffer matches
[E23](#e23--post-use-patch-buffer-differential):

```text
main-exit seq=1 size=3633152 dumped=24576 nonzero=0
main-exit seq=2 size=3633152 dumped=24576 nonzero=0
patch-exit seq=2 size=36864  dumped=8192  nonzero=1336
```

**Result.** The main buffer is a per-channel save area, not the initialized image.

**Reproduce.**
1. `sudo tools/driver-harness/dump_ctx.sh` with
   `BF16_CTXDUMP_MAIN_OFFSET=0x4000` and `BF16_CTXDUMP_BYTES=8192`.
2. Expect zero in both main dumps; the patch-exit list should match
   [E23](#e23--post-use-patch-buffer-differential).

**Limits.** 8 KB window, not the whole image; the main buffer is a per-channel
save area.

## E25 · Global buffers and the switch to file dumps

*2026-10-26 · Revision 23 · status: transport fix*

**Hypothesis.** The global context buffers may contain the image, and the dmesg
transport may be losing them.

**Instrument.** The file-dump transport in the instrumented driver writes each
mapped buffer to a file with a 4 MB cap.

**Method.** Dump all global buffers; switch from dmesg hex to direct files when the
ring overwrites them.

**Observed data.** Only `global seq=8` (`UNRESTRICTED_PRIV_ACCESS_MAP`) survived;
the first six global buffers were already gone:

```text
global seq=8   size=?     dumped=8192  nonzero=0
main-exit seq=1 size=3633152 dumped=24576 nonzero=0
patch-exit seq=1 size=36864 dumped=8192 nonzero=8192
main-exit seq=2 size=3633152 dumped=24576 nonzero=0
patch-exit seq=2 size=36864 dumped=8192 nonzero=1336
```

**Result.** The file-dump transport fixes the lost-buffer problem. This run is not
a measurement of the missing globals;
[E26](#e26--the-full-context-image-and-the-0x88888888-false-positive) captures all
seven files.

**Reproduce.**
1. Build the tree with the file-dump hooks; load it.
2. `sudo tools/driver-harness/dump_ctx.sh` with `GLOBALMAX=6`.
3. Parse the files with `tools/driver-harness/parse_ctxfiles.py`.

**Limits.** Transport fix only; the first six globals are missing from this run.

## E26 · The full context image and the `0x88888888` false positive

*2026-10-26 · Revision 24 · status: negative*

**Hypothesis.** The full context image may contain a rate constant or the Ada
`SS0` payload.

**Instrument.** Full-file dump, GPU0; parser
`tools/driver-harness/parse_ctxfiles.py`.

**Method.** Dump every mapped main, patch, and global buffer to a file and scan it
for the known rate constants.

**Observed data.** File sizes and nonzero counts:

| File | Size | Nonzero | Notes |
|---|---:|---:|---|
| `main-exit_0_1` | 3,633,152 | 311,213 | driver-init |
| `main-exit_0_2` | 3,633,152 | 180,373 | compute |
| `patch-exit_0_1` | 36,864 | 36,864 | all poison |
| `patch-exit_0_2` | 36,864 | 1,336 | 287-entry list |
| `global_0_6` | 65,536 | 0 | `FECS_EVENT` |
| `global_0_7` | 524,288 | 0 | `PRIV_ACCESS_MAP` |
| `global_0_8` | 524,288 | 15,063 | `UNRESTRICTED_PRIV_ACCESS_MAP` |

The main image contains **0** occurrences of `0x00c36180`, `0xfffffb8f`,
`0x00504204`, and either stock `SS0` word. `0x88888888` occurs 1,076 times aligned
and 157 times in sixteen-byte runs.

**Result.** No known rate constant in the full 3.6 MB image. `0x88888888` is a fill
pattern, not the Ada payload; the earlier `ADA_SS0_PAYLOAD` label was a false
positive.

**Reproduce.**
1. `sudo tools/driver-harness/dump_ctx.sh` with `EXITMAX=2`, `GLOBALMAX=6`, GPU0.
2. Parse with `tools/driver-harness/parse_ctxfiles.py`.
3. Scan for the rate constants; expect zero. Count `0x88888888`; expect 1,076
   aligned occurrences.

**Limits.** GPU0 only; the first six global buffers were not captured; the image
is still a driver-init context.

## E27 · Cross-card context comparison

*2026-10-26 · Revision 26 · status: CLOSED-MEASURED*

**Hypothesis.** A card-dependent selector field may differ between the two cards.

**Instrument.** Cold power cycle to clear GPU1's WPR2 state; one
`dump_ctx.sh` run with `BDF=0000:41:00.0`, `EXITMAX=2`, `GLOBALMAX=6`; the
cross-card analyzer in [Driver harness](../tools/driver-harness/).

**Method.** Capture the first driver-init main images on both cards in one boot,
before the CUDA probe, and diff them word by word.

**Observed data.**

| Metric | Value |
|---|---:|
| Words compared | 908,288 |
| Differing words | 618 (0.068%) |
| Pages with a difference | 235 |
| Diffs below `0x4000` | 0 |
| Diffs `0x4000`–`0x1d0000` | 191 |
| Diffs `0x1d0000`–`0x330000` | 427 |
| Diffs above `0x330000` | 0 |

The first `0x4000` and last ~`0x47000` bytes are identical. The 427 diffs are a
4-bit index field at `[30:27]` in a `~0x3b00`-stride record array; the 191 are
52-byte-stride table words plus per-boot random values. No diff decodes to the
FEAT vector, and neither image contains a known rate constant (`0x00c36180`,
`0xfffffb8f`, `0x00504204`, or either stock `SS0` word). `0x88888888` appears
1,000 times at identical offsets in both images; `UNRESTRICTED_PRIV_ACCESS_MAP` is
byte-identical to the previous boot.

**Result.** No card-dependent selector-shaped or rate-shaped field in the GR
context image.

**Reproduce.**
1. Cold power cycle to clear WPR2.
2. `sudo tools/driver-harness/dump_ctx.sh` with `BDF=0000:41:00.0`,
   `EXITMAX=2`, `GLOBALMAX=6`.
3. Run the cross-card analyzer; expect 618 differing words of 908,288 and no
   FEAT-shaped field.

**Limits.** The images are first driver-init contexts, not compute contexts; a
shared capped-card constant would not show up in a cross-card diff.
