# The FECS doorbell and the GR context image

## Summary

**The idea.**

- FECS/GPCCS is the GR (graphics engine) front-end and context-switch microcode;
  the [rate-control spec](../specs/02_privilege-and-rate-control.md) puts the
  speed selector at the end of that path.
- The two host-reachable surfaces are the FECS command doorbell and the GR context
  buffers [GSP-RM](../specs/01_boot-chain.md) initializes.
- I mapped the FECS, [FSP](../specs/01_boot-chain.md) (reset-time security
  processor), and [SEC2](../specs/01_boot-chain.md) (security coprocessor) register
  windows, decoded the plaintext FECS command protocol, and dumped the GR context
  images from both cards, looking for a rate selector.
- What it would give: a writable rate path outside the FEAT bank, or proof the GR
  path carries no selector.

**What it found.**

- The FECS, FSP, and SEC2 windows are readable; FECS
  [PLM](../specs/02_privilege-and-rate-control.md) writes
  [drop while the `0x409800` doorbell holds](#031-live-fecs-fsp-and-sec2-probes).
- The plaintext FECS command list has
  [no command that writes FEAT, SS0, or SS1](#032-the-fecs-command-protocol-statically)
  ([register map](../specs/03_register-map.md)).
- The host
  [builds context descriptors, not the image](#033-the-fecs-context-path-and-the-host-gr-structures);
  GSP-RM initializes it.
- The full 3.6 MB GR context image has
  [no known rate constant](#038-the-full-context-image-and-the-0x88888888-false-positive);
  `0x88888888` is fill, not the Ada payload.
- The two cards' images
  [differ in 618 words, none selector-shaped](#039-comparing-the-gr-context-across-both-cards).

**What it did not find.**

- No rate selector or writable rate field in the
  [FECS command surface](#032-the-fecs-command-protocol-statically) or the
  [GR context image](#038-the-full-context-image-and-the-0x88888888-false-positive).
- No
  [host-built context image](#033-the-fecs-context-path-and-the-host-gr-structures)
  to inject a selector into.
- No
  [card-dependent selector field](#039-comparing-the-gr-context-across-both-cards).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 03.1 | [Live FECS, FSP, and SEC2 probes](#031-live-fecs-fsp-and-sec2-probes) | PLM gated; doorbell writable |
| 03.2 | [The FECS command protocol, statically](#032-the-fecs-command-protocol-statically) | No rate command found |
| 03.3 | [The FECS context path and host structures](#033-the-fecs-context-path-and-the-host-gr-structures) | Host builds descriptors only |
| 03.4 | [First live GR context-buffer dump](#034-first-live-gr-context-buffer-dump) | No known constant found |
| 03.5 | [The post-use patch buffer differential](#035-the-post-use-patch-buffer-differential) | Changes are address overrides |
| 03.6 | [The main window at 0x4000 is zero](#036-the-main-window-at-0x4000-is-zero) | Window is a save area |
| 03.7 | [Global buffers and the file-dump transport](#037-global-buffers-and-the-switch-to-file-dumps) | File dumps fix transport |
| 03.8 | [Full context image and the false positive](#038-the-full-context-image-and-the-0x88888888-false-positive) | No rate constant in image |
| 03.9 | [Comparing the GR context across both cards](#039-comparing-the-gr-context-across-both-cards) | No card-dependent selector field |

## 03.1 Live FECS, FSP, and SEC2 probes

**Question.** Do the FECS, FSP, or SEC2 register windows expose a host-writable
rate or command surface?

**Why.**

- FECS is the GR (graphics engine) front-end and context-switch microcode; a
  command doorbell there could be a rate lever.
- The FSP and SEC2 windows might expose a writable control surface that bypasses
  the [FEAT bank](../specs/03_register-map.md).
- What it would give: a writable rate register outside the FEAT bank, or proof
  those windows are read-only or gated.

**Method.**

- Tools: `hw_probe` from [Direct probe](../tools/direct-probe/) for direct BAR0
  reads; `regops` from [Register access](../tools/register-access/) for reads and
  read-modify-write batches through GSP-RM.
- Target: `41:00.0` (`deviceId 1`), root.
- Steps:
  - Map the FECS, FSP, PMU, and SEC2 blocks read-only.
  - Try four write/read/restore batches through GSP-RM.
- Args used:
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
| `0x409660` | `0xfffffbef` | PLM: read all / write levels 1–3 |
| `0x409688` | `0xffffffcf` | PLM: read all / write levels 2–3 |
| `0x409438` | `0xffffffef` | PLM: read all / write levels 1–3 |
| `0x4096d0` | `0xffffffff` | read/write all |
| `0x409638` | `5` | implemented |
| `0x409800` | `1` | GSP-RM-writable doorbell/status |
| `0x409b00` / `0x409b04` | `0x007e0f0a` | DP/companion readout |
| `0x409500` | `0` | command data |
| `0x409504` | `0xbadf5545` | command ID, read-blocked |

The [PLM](../specs/02_privilege-and-rate-control.md) write returns success and
does not change the register:

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

Key FSP and SEC2 values:

| Offset | Value | Meaning |
|---|---|---|
| `0x8f0a58` / `0x8f0a5c` | `0x6624b970` / `3` | core status/config |
| `0x8f0a90` | `0xffffff8f` | core PLM: read all / write PL3 only |
| `0x8f0ac0` / `0x8f0ac4` | `0x5536c785` / `0x6fd593dc` | ch0 control/data |
| `0x8f0ac8` / `0x8f0acc` | `0xc79705f3` / `0x8f7a6cc2` | ch1 |
| `0x8f0ad0` / `0x8f0ad4` | `0x5792ea26` / `0xf7cd4b7b` | ch2 |
| `0x8f0ad8` / `0x8f0adc` | `0xc1c4c375` / `0x21fa03ab` | ch3 |
| `0x8f0ab0`–`0x8f0abc` | `e81dc861 98216d8b 803e5471 9e870bdf` | unidentified constant |
| `0x8401c0` / `0x8401c4` | DMEM port; `AINCR` advances; first 8 KB zero | SEC2 |
| `0x840180` / `0x840184` | host `0xbadf5720`, GSP-RM `0xbadf5723` | SEC2 IMEM blocked |
| `0x8403c4` | `0x00000b0f` | SEC2 PLM: read all / write none |

**Result.**

- **Answer:** the FECS, FSP, and SEC2 blocks are readable. All four FECS PLM
  writes were dropped; the `0x409800` doorbell held its write. The FSP core PLM is
  PL3-only, SEC2 IMEM is blocked, and SEC2 DMEM is empty.
- **What we learned:**
  - The FECS block is 1,024 dwords; 789 are sentinels. Implemented registers start
    around `0x409400`.
  - FECS PLM writes return success and leave the register unchanged. The
    `0x409800` doorbell accepts a host write.
  - The FSP core PLM at `0x8f0a90` is `0xffffff8f`, write PL3 only.
  - SEC2 IMEM is blocked (host `0xbadf5720`, GSP-RM `0xbadf5723`); SEC2 DMEM is
    empty; SEC2 PLM at `0x8403c4` is `0x00000b0f`, write none.
  - No new Xid after the probes.
- **Related:**
  - The [FECS command protocol](#032-the-fecs-command-protocol-statically) maps
    what the doorbell carries.
  - The [HS/SEC2 memory experiments](../experiments/04_hs-sec2-fsp-memory.md)
    cover the SEC2 windows in more detail.
  - The [register map](../specs/03_register-map.md) has the FECS, FSP, and SEC2
    block maps.

## 03.2 The FECS command protocol, statically

**Question.** Does the FECS command protocol contain a command that sets the rate
selector?

**Why.**

- If a host-reachable FECS command writes the rate, the doorbell is a lever that
  does not touch the FEAT bank directly.
- The handler is in encrypted FECS/GPCCS microcode; the caller code is plaintext.
- What it would give: a command ID to test, or proof the plaintext surface has no
  rate setter.

**Method.**

- Tools: `DecompileAt.java` and `DisasmRange.java` from
  [GSP-RM tools](../tools/gsp-rm-tools/) against the extracted GSP-RM image in a
  Ghidra 12.2 project loaded at `0x01000000`.
- Steps:
  - Decompile the sender `FUN_ram_015e2724` and the waiter `FUN_ram_015cc798`.
  - Correlate their HAL (per-chip method table) relative offsets with the
    measured FECS map.
  - List the plaintext call-site command IDs.
- Args used:
```bash
python3 tools/gsp-rm-tools/refscan.py <gsp-rm-image> 0x015e2724 0x015cc798
# then DecompileAt.java at 0x015e2724 and 0x015cc798 in Ghidra
```

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
init and context commands. None writes the
[FEAT bank](../specs/03_register-map.md) selectors or `SS0`/`SS1`.

**Result.**

- **Answer:** the host-reachable FECS surface is a command doorbell plus a context
  buffer loader. No command ID in the plaintext call-site list sets the rate.
- **What we learned:**
  - The sender writes data to `0x9500`, the command ID to `0x9504`
    (`cmd & 0xfff`), and a payload to `0x9800 + 4*param`.
  - The waiter reads status at `(param_3 + 0x2600) * 4`.
  - The caller sends `0x30` first, then waits.
  - The command-ID set is the plaintext call-site list, not a decoded ucode
    command table.
- **Related:**
  - The [measured FECS map](#031-live-fecs-fsp-and-sec2-probes) pins the absolute
    offsets.
  - The [context path](#033-the-fecs-context-path-and-the-host-gr-structures) is
    the other half of the GR setup.
- **Open question:** the encrypted FECS/GPCCS handler's command table is not
  decoded, so a hidden command ID cannot be ruled out from the plaintext alone.

## 03.3 The FECS context path and the host GR structures

**Question.** Does the host GR context path carry a rate selector, or does the
host build the initialized context image?

**Why.**

- If the host builds the image, it could inject a selector before GSP-RM sees it.
- If the host only builds descriptors, the initialized image comes from GSP-RM and
  the selector would have to be in firmware state.
- What it would give: a host-side selector field, or proof the host only describes
  buffers.

**Method.**

- Tools: `refscan.py` and `DecompileAt.java` from
  [GSP-RM tools](../tools/gsp-rm-tools/), plus the exact 595.91.07 host source
  tree.
- Steps:
  - Scan every 2-byte offset for `JAL`, `AUIPC+ADDI`, `LUI+ADDI`, and raw 32/64-bit
    values with correct 20-bit sign extension.
  - Decompile the survivors.
  - Review the host context-buffer structures.
- Args used:
```bash
python3 tools/gsp-rm-tools/refscan.py <gsp-rm-image> 0x0162cc10 0x0162cda8
# then DecompileAt.java on the reported sites
```

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

The context descriptor is 0x20 bytes: `+0x00` memdesc (memory descriptor),
`+0x08` 64-bit GPU address, `+0x10` size (29 bits) plus flags (3 bits), `+0x18`
state, `+0x1c` flag.
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

**Result.**

- **Answer:** the host builds descriptors; GSP-RM initializes the image. There is
  no rate, selector, or enable field in the host structures or the command
  payloads.
- **What we learned:**
  - The two context functions are materialized four times inside
    `FUN_ram_01c1c374` and installed at `obj+0xD00`; the caller is
    `FUN_ram_0184499c`.
  - The context descriptor is 0x20 bytes; `GR_GLOBALCTX_BUFFERS` and
    `NV2080_CTRL_GR_CTX_BUFFER_INFO` carry handles, GPU addresses, and sizes.
  - The only `portMemCopy` calls are the UUID copy and the sort swap.
  - The rate state is a separate read-only cache and is never inserted into a
    context buffer.
- **Related:**
  - The [measured FECS map](#031-live-fecs-fsp-and-sec2-probes) correlates with the
    static offsets.
  - The [first live dump](#034-first-live-gr-context-buffer-dump) tests the image
    GSP-RM builds.

## 03.4 First live GR context-buffer dump

**Question.** Does the initialized GR context image contain a rate selector?

**Why.**

- The host only builds descriptors; GSP-RM builds the image. A selector could sit
  in the initialized buffer.
- The context image is the only place GSP-RM could encode a per-context selector;
  the first 4 KB is the obvious place to start.
- What it would give: a selector offset to target, or proof the first dump has no
  known rate constant.

**Method.**

- Tools: [Driver harness](../tools/driver-harness/) applies
  `bf16_ctxdump.patch` to the exact 595.91.07 tree, builds it, loads it, and
  restores stock. [Issue-rate probe](../tools/issue-rate-probe/) runs the tensor
  workload.
- Target: root; `41:00.0`.
- Steps:
  - Apply the context-dump patch, build and load the instrumented driver.
  - Run the probe with `--iters 1 --reps 1`, capture dmesg, and restore stock.
  - Parse the dumps.
- Args used:
```bash
sudo tools/driver-harness/dump_ctx.sh
# BDF=0000:41:00.0 EXITMAX=2 GLOBALMAX=6
python3 tools/driver-harness/parse_ctxdump.py
```

**Observed data.** GPU0 booted and produced four dumps; GPU1 failed with
`_kgspBootGspRm: unexpected WPR2 already up` (WPR2 is the second write-protected
region, [boot chain](../specs/01_boot-chain.md)) and
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

**Result.**

- **Answer:** no known rate constant in the first 4 KB of either buffer. The patch
  buffer is an address/value override list, not a selector.
- **What we learned:**
  - GPU1 failed with WPR2 already up; the probe targeted GPU1 and never ran.
  - GPU0 produced four driver-init dumps: two `0x377000` main buffers and two
    `0x9000` patch buffers.
  - The patch values are context defaults, not rate constants.
- **Related:**
  - The [full image dump](#038-the-full-context-image-and-the-0x88888888-false-positive)
    covers the whole buffer.
  - The [cross-card comparison](#039-comparing-the-gr-context-across-both-cards)
    compares the two cards.

## 03.5 The post-use patch buffer differential

**Question.** Does the patch buffer change after use in a way that reveals a
selector?

**Why.**

- The patch buffer is an address/value override list. A rate entry that appears
  after use could point at the selector.
- The driver-init and free-time buffers can be diffed without decoding the whole
  image.
- What it would give: a post-use address/value entry tied to the rate, or proof
  the changes are global-buffer overrides.

**Method.**

- Tools: post-use hooks on `kgrctxUnmapMainCtxBuffer` and
  `kgrctxFreePatchBuffer`, with `BF16_CTXDUMP_CREATE=0`.
- Target: GPU0 (`c1:00.0`), root.
- Steps: dump the patch buffer at driver-init and at free, then diff the
  `{address, value}` entries.
- Args used:
```bash
sudo tools/driver-harness/dump_ctx.sh
# BF16_CTXDUMP_CREATE=0 EXITMAX=2, GPU0
```

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

**Result.**

- **Answer:** the changed slots are global-buffer address overrides, not selectors.
- **What we learned:**
  - Both buffers have 287 entries; 10 values differ; no address differs.
  - The main-exit dump lost its header to the dmesg ring; the patch-exit dump is
    complete.
- **Related:**
  - The [full image dump](#038-the-full-context-image-and-the-0x88888888-false-positive)
    captures the complete files.

## 03.6 The main window at `0x4000` is zero

**Question.** Does the main context window at `0x4000` contain the initialized
selectors?

**Why.**

- The [first dump](#034-first-live-gr-context-buffer-dump) showed only 10 nonzero
  bytes in the first 4 KB of the main buffer. The `0x4000` window is the next
  candidate.
- What it would give: selector offsets in the main window, or proof the window is
  a per-channel save area.

**Method.**

- Tool: bounded 8 KB window at `BF16_CTXDUMP_MAIN_OFFSET=0x4000`,
  `BF16_CTXDUMP_BYTES=8192`.
- Target: GPU0 (`c1:00.0`), root.
- Steps: dump the bounded main window for the uninitialized and compute contexts.
- Args used:
```bash
sudo tools/driver-harness/dump_ctx.sh
# BF16_CTXDUMP_MAIN_OFFSET=0x4000 BF16_CTXDUMP_BYTES=8192
```

**Observed data.** Both windows are zero; the patch-exit buffer matches
[the post-use differential](#035-the-post-use-patch-buffer-differential):

```text
main-exit seq=1 size=3633152 dumped=24576 nonzero=0
main-exit seq=2 size=3633152 dumped=24576 nonzero=0
patch-exit seq=2 size=36864  dumped=8192  nonzero=1336
```

**Result.**

- **Answer:** the main buffer is a per-channel save area, not the initialized
  image.
- **What we learned:**
  - Both bounded main windows are zero.
  - The patch-exit buffer still holds the 1,336 nonzero bytes seen in the
    differential.
- **Related:**
  - The [patch differential](#035-the-post-use-patch-buffer-differential) explains the
    patch-exit list.
  - The [full image dump](#038-the-full-context-image-and-the-0x88888888-false-positive)
    scans the whole buffer.

## 03.7 Global buffers and the switch to file dumps

**Question.** Do the global context buffers contain the image, and is the dmesg
transport losing them?

**Why.**

- The global buffers are the remaining mapped regions outside the main and patch
  buffers.
- The dmesg ring overwrote earlier buffers, so the transport itself was a
  problem.
- What it would give: a complete image transport, or proof the global buffers are
  zero or irrelevant.

**Method.**

- Tool: the file-dump transport in the instrumented driver writes each mapped
  buffer to a file with a 4 MB cap.
- Target: GPU0 (`c1:00.0`), root.
- Steps: dump all global buffers; switch from dmesg hex to direct files when the
  ring overwrites them; parse the files.
- Args used:
```bash
sudo tools/driver-harness/dump_ctx.sh
# GLOBALMAX=6
python3 tools/driver-harness/parse_ctxfiles.py
```

**Observed data.** Only `global seq=8` (`UNRESTRICTED_PRIV_ACCESS_MAP`) survived;
the first six global buffers were already gone:

```text
global seq=8   size=?     dumped=8192  nonzero=0
main-exit seq=1 size=3633152 dumped=24576 nonzero=0
patch-exit seq=1 size=36864 dumped=8192 nonzero=8192
main-exit seq=2 size=3633152 dumped=24576 nonzero=0
patch-exit seq=2 size=36864 dumped=8192 nonzero=1336
```

**Result.**

- **Answer:** the file-dump transport fixes the lost-buffer problem. This run is
  not a measurement of the missing globals.
- **What we learned:**
  - Only `global seq=8` survived; the first six global buffers were gone.
  - The main buffers are zero in this run; the patch-exit buffers carry the same
    poison and 287-entry list.
- **Related:**
  - The [full image dump](#038-the-full-context-image-and-the-0x88888888-false-positive)
    captures all seven files.

## 03.8 The full context image and the `0x88888888` false positive

**Question.** Does the full context image contain a rate constant or the Ada `SS0`
payload?

**Why.**

- The full 3.6 MB image is the last place a selector could hide after the window
  probes.
- An earlier scan labeled aligned `0x88888888` runs as the
  [4090 unlock](https://github.com/JustAResearcher/gpu-unlock-ada) payload, so the
  label needed a check.
- What it would give: the selector offset, or proof the image has no known rate
  constant.

**Method.**

- Tool: full-file dump, GPU0; parser
  `tools/driver-harness/parse_ctxfiles.py`.
- Steps: dump every mapped main, patch, and global buffer to a file; scan for the
  known rate constants.
- Args used:
```bash
sudo tools/driver-harness/dump_ctx.sh
# EXITMAX=2 GLOBALMAX=6, GPU0
python3 tools/driver-harness/parse_ctxfiles.py
```

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

**Result.**

- **Answer:** no known rate constant in the full 3.6 MB image. `0x88888888` is a
  fill pattern, not the Ada payload.
- **What we learned:**
  - The main image has zero occurrences of `0x00c36180`, `0xfffffb8f`,
    `0x00504204`, and either stock `SS0` word.
  - `0x88888888` occurs 1,076 times aligned and 157 times in 16-byte runs, so it
    is a fill pattern.
  - The two patch buffers are all poison at driver-init and a 287-entry list at
    compute time.
  - The first six global buffers were not captured; `global_0_8` is the
    `UNRESTRICTED_PRIV_ACCESS_MAP`.
- **Related:**
  - The [first dump](#034-first-live-gr-context-buffer-dump) covers the first 4 KB.
  - The [cross-card comparison](#039-comparing-the-gr-context-across-both-cards) checks whether
    any of this is card-dependent.

## 03.9 Comparing the GR context across both cards

**Question.** Is there a card-dependent selector field in the GR context image?

**Why.**

- A capped card and a full-rate card might differ in the image even when each
  image has no known constant.
- A field that differs by card and looks selector-shaped would be a target.
- What it would give: a card-dependent field to target, or proof the difference is
  not rate-shaped.

**Method.**

- Tools: a cold power cycle to clear GPU1's WPR2 state (the second write-protected
  region, [boot chain](../specs/01_boot-chain.md)); one `dump_ctx.sh` run with
  `BDF=0000:41:00.0`, `EXITMAX=2`, `GLOBALMAX=6`; the cross-card analyzer in
  [Driver harness](../tools/driver-harness/).
- Steps: capture the first driver-init main images on both cards in one boot,
  before the CUDA probe, and diff them word by word.
- Args used:
```bash
sudo tools/driver-harness/dump_ctx.sh
# BDF=0000:41:00.0 EXITMAX=2 GLOBALMAX=6
# then run the cross-card analyzer
```

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
[FEAT](../specs/03_register-map.md) vector, and neither image contains a known
rate constant (`0x00c36180`,
`0xfffffb8f`, `0x00504204`, or either stock `SS0` word). `0x88888888` appears
1,000 times at identical offsets in both images; `UNRESTRICTED_PRIV_ACCESS_MAP` is
byte-identical to the previous boot.

**Result.**

- **Answer:** no card-dependent selector-shaped or rate-shaped field in the GR
  context image.
- **What we learned:**
  - 618 of 908,288 words differ (0.068%); 235 pages contain a difference.
  - The 427 diffs in `0x1d0000`–`0x330000` are a 4-bit index at `[30:27]` in a
    `~0x3b00`-stride array.
  - The 191 diffs in `0x4000`–`0x1d0000` are 52-byte-stride table words plus
    per-boot random values.
  - No diff decodes to the FEAT vector, and neither image contains a known rate
    constant.
  - `0x88888888` appears 1,000 times at identical offsets in both images;
    `UNRESTRICTED_PRIV_ACCESS_MAP` is byte-identical to the previous boot.
  - The images are first driver-init contexts, not compute contexts; a shared
    capped-card constant would not show up in a cross-card diff.
- **Related:**
  - The [full image scan](#038-the-full-context-image-and-the-0x88888888-false-positive)
    establishes the constant counts on one card.
