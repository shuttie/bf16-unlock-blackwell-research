# Registry keys and static audit

Recorded 2026-10-25 and 2026-10-26. Evidence is inline; the records need only the
tools and the local inputs named below.

## Reproducing this group

**Hardware.** 2× RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07, Linux
7.0.0-38-generic, CUDA 13. `deviceId 1` is `41:00.0`; `deviceId 0` is `c1:00.0`.

**Tools.** [Register access](../tools/register-access/) for the live BAR0 reads,
[Issue-rate probe](../tools/issue-rate-probe/) for the tensor rate,
[Boot tests](../tools/boot-tests/) for the registry boot matrix,
[GSP-RM tools](../tools/gsp-rm-tools/) for the static scans, and
[Driver harness](../tools/driver-harness/) for the rate sweep. The live tools need
root; the probe also needs the card UUID.

**Inputs.** `gsp_ga10x.bin` and `nvidia.ko` 595.91.07 from your driver package, and
the 595.91.07 host-driver source. None of these ship in this repo. Decompile the
GSP-RM with [GSP-RM tools](../tools/gsp-rm-tools/).

**Boot state and cost.** Live tests need the stock driver loaded and no open
`/dev/nvidia*` handles. Each registry test is one module reload. `frts-vid` and
`gspfmc` can wedge the GSP; budget one reboot per failed variant. Static scans are
offline and free.

**Terms.**
- **GSP-RM:** the main GPU firmware, running at PL2. See
  [the boot chain](../specs/01_boot-chain.md).
- **FEAT bank:** the register block holding speed-selector overrides. See
  [the register map](../specs/03_register-map.md).
- **PLM:** a per-block read/write permission mask. See
  [the rate-control spec](../specs/02_privilege-and-rate-control.md).
- **`SS0`/`SS1`:** the two SM speed-selector override words. See
  [the rate-control spec](../specs/02_privilege-and-rate-control.md).
- **`.fwimage`:** the plaintext GSP-RM section inside `gsp_ga10x.bin`.
- **`auipc`:** a RISC-V PC-relative address instruction; string and code references
  are often `auipc` + `addi`.
- **`NVreg_RegistryDwords`:** the driver module parameter carrying `key=value`
  pairs into the RM registry.
- **`nvidia.ko`:** the host driver module at 595.91.07.

## E01 · Static register audit and registry-key closure

*2026-10-25 · Revision 2 · status: CLOSED-STATIC (register audit); superseded by
[E50](#e50--registry-key-reachability-re-tested) for the registry-key closure*

**Hypothesis.** No plaintext component references a FEAT/FUSE rate register, and the
registry speed-select keys are dead.

**Instrument.** Offline: a 32/64-bit literal scan over the `.fwimage`, a constant
grep over the 69 decompiled modules, a string and pointer scan, a scan of the
decompressed 595.91.07 `nvidia.ko`, and a control-table decode. Tools:
[GSP-RM tools](../tools/gsp-rm-tools/).

**Method.**

1. Extract `.fwimage` from `gsp_ga10x.bin`: section at file offset `0x40`,
   72,830,976 B, base `0x01000000`.
2. Scan for each FEAT/FUSE offset as 32- and 64-bit little-endian, plus a histogram
   of every aligned dword in `0x00800000`–`0x008fffff` (1,735 distinct values,
   mostly data-table false positives).
3. Scan every `0x8xxxxx` constant in the 69 decompiled modules; 151 distinct values
   in the aperture; the `0x00823800`–`0x0082382f` window is empty.
4. Query the decompiled string index with reference counts, then search raw bytes
   for `regOpCount`, `regOps`, `hChannelTarget`, `ExecRegOps`, `permission to
   access register`, `osIsAdministrator` (all absent).
5. Pointer scan for 4- and 8-byte absolute pointers to the registry strings.
6. Decompress `nvidia.ko.zst` and repeat the constant and string scans.
7. Decode the 32-byte ctrl-table entries
   `{ctrlId | paramSize<<32, classPtr, handlerPtr, flags}` at `0x01d16xxx`; confirm
   `0x20800a34` → `0x48` and `0x20800122` → `0x30`.
8. Decompile targeted handlers with `DecompileAt.java` from
   [GSP-RM tools](../tools/gsp-rm-tools/).

**Observed data.** The six target offsets count zero in both widths:

```text
0x00823804 0
0x00823818 0
0x0082381c 0
0x00823820 0
0x008207d8 0
0x00504204 0
```

The module scan finds 151 distinct `0x8xxxxx` constants, none in
`0x00823800`–`0x0082382f`. The ctrl table has 44 IDs; the public GR control header
has 44; the sets match.

**Result.** Zero literal references in the `.fwimage`, `nvidia.ko`, and the
decompiled modules. The registry keys `RMOverrideSmSpeedSelect` and `_1` had zero
code references and no absolute pointer, so this pass concluded they were not
forwarded. That registry-key conclusion is superseded by
[E50](#e50--registry-key-reachability-re-tested): the reference scan missed the
sign-extended `auipc` materializations, and the forwarding argument was wrong. The
ctrl-table entries are reliable; the Ghidra-recovered handler bodies were not used
as evidence.

**Reproduce.**

1. Locate and dump `.fwimage`:

   ```bash
   readelf -SW gsp_ga10x.bin
   objcopy --dump-section .fwimage=gsp_fwimage.bin gsp_ga10x.bin
   ```

2. Run the literal scan:

   ```bash
   python3 - <<'EOF'
   import struct
   d = open('gsp_fwimage.bin','rb').read()
   for t in (0x00823804,0x00823818,0x0082381c,0x00823820,0x008207d8,0x00504204):
       n = d.count(struct.pack('<I', t)) + d.count(struct.pack('<Q', t))
       print(f"{t:#010x} {n}")
   EOF
   ```

3. Decompress the host driver and repeat the scans:

   ```bash
   zstd -d nvidia.ko.zst -o nvidia.ko
   ```

4. In the directory of the 69 decompiled `mod_*.c` files, count the distinct
   aperture constants:

   ```bash
   grep -rhoE '0x8[0-9a-f]{5}\b' mod_*.c | sort -u | wc -l
   ```

   Expect 151.

5. Decompile a ctrl-table handler with
   [GSP-RM tools](../tools/gsp-rm-tools/):

   ```bash
   JAVA_HOME=<jdk> GHIDRA_HEADLESS_MAXMEM=16G \
     <ghidra>/support/analyzeHeadless <project> gsp_fwimage.bin -noanalysis \
     -scriptPath tools/gsp-rm-tools -postScript DecompileAt.java out.c 0x1acd340 0 300
   ```

   Expect the 44/44 ID match and no FEAT address in `0x823800`–`0x8238ff`.

6. Expect zero hits for every target offset. A nonzero hit is a lead, not a
   conclusion; check the address model first.

**Limits.** A literal scan cannot see computed offsets (`base + 0x3818`); that blind
spot is what [E13](../experiments/07_plaintext-corpus.md) and
[E17](../experiments/07_plaintext-corpus.md) corrected. The registry-key negative is
superseded by [E50](#e50--registry-key-reachability-re-tested).

## E11 · Host-driven boot path and the registry experiments

*2026-10-25 · Revision 11 · status: LIVE (input surface) / CLOSED-MEASURED (bootstrap)*

**Hypothesis.** Registry keys that alter the boot inputs change what secure
firmware receives, and a refused variant returns a structured error.

**Instrument.** [Boot tests](../tools/boot-tests/) (`gsp_bootpath_tests.sh`, bash,
root). Each test unloads `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, and `nvidia`;
reloads with one `NVreg_RegistryDwords=...` on the modprobe command line; waits 15 s;
captures the dmesg delta before any health check; then restores the stock driver.

**Method.**

- Keys tested: `RmDisableFspFuseErrorCheck=1`, `RmDisableCotCmd=0x1` (FRTS sysmem),
  `RmDisableCotCmd=0x4` (FRTS vidmem), `RmDisableCotCmd=0x10` (GSPFMC).
- No `/etc/modprobe.d` change. Values are parsed by `os_strtoul(value, NULL, 0)`;
  entries are separated by `;`.
- Run `--dry-run` first, then one `--only` variant, then `--restore`.

**Observed data.**

```text
fusecheck  RmDisableFspFuseErrorCheck=1
  healthy=yes
  FSP's fuse error detection status check during boot is disabled using the regkey.

frts-sys   RmDisableCotCmd=0x1
  healthy=yes
frts-vid   RmDisableCotCmd=0x4
  healthy=no (0/2)
  Fatal GSP-FMC Error: version=0x1, partition=0x1, error code=0x83d, additional info=0x0
  Max GSP-RM boot attempts exceeded: 4/4
```

```text
kgspResetHw_GB100: Timed out waiting for GSP reset PLM to be lowered
Possible bad register read: addr: 0x1103c0, regvalue: 0xbadf5720
kgspResetHw_GH100: Timed out waiting for GSP falcon reset to assert
Call timed out [NV_ERR_TIMEOUT] (0x00000065) ... _kgspBootstrapGspFmc_GH100 ... kernel_gsp_gh100.c:980
```

**Result.** Withholding the vidmem FRTS region yields the structured FMC report
`0x83d` on both cards. The GSPFMC path deadlocks on the reset PLM: the host cannot
lower the level-0 enables in `0x1103c4`, so it cannot reset the GSP it needs to boot.
In that state the host reads `0xBADF5720` on `0x1103c0`.

Two failure modes shaped the harness. A SIGTERM-stopped `nvidia-smi` pins the module
(`rmmod` reports "in use"); use `timeout -s KILL` and `pkill -9 -x nvidia-smi`. The
GSPFMC failure leaves an ioctl blocked even on SIGKILL; only a reboot exits.

**Reproduce.**

1. Stock driver loaded; no open `/dev/nvidia*` handles.
2. `sudo tools/boot-tests/gsp_bootpath_tests.sh --dry-run` (plan only).
3. `sudo tools/boot-tests/gsp_bootpath_tests.sh --only fusecheck` (control; should
   boot).
4. `sudo tools/boot-tests/gsp_bootpath_tests.sh --only frts-vid`; expect `0x83d` on
   both cards and a reboot before the next variant.
5. `sudo tools/boot-tests/gsp_bootpath_tests.sh --only gspfmc`; expect the
   reset-PLM timeout and a blocked ioctl. Run it last.
6. `sudo tools/boot-tests/gsp_bootpath_tests.sh --restore` after each test.

**Limits.** The `0x83d` code shows the FMC consumes the FRTS location; it does not
show a write primitive. The reset-PLM deadlock is a boot-path property, not a gate
on the FMC.

## E50 · Registry-key reachability, re-tested

*2026-10-26 · status: CLOSED-STATIC (keys are live)*

**Hypothesis.** The [E01](#e01--static-register-audit-and-registry-key-closure)
closure is wrong: it used the same reference negative later withdrawn in
[E13](../experiments/07_plaintext-corpus.md) →
[E17](../experiments/07_plaintext-corpus.md), and its forwarding argument was
untested.

**Instrument.** [GSP-RM tools](../tools/gsp-rm-tools/): `refscan.py` with correct
`auipc` sign extension and `DisasmRange.java`; the 595.91.07 host-driver source for
the option parser. Offline.

**Method.**

1. Scan every 2-byte offset of the 72,830,976-byte `.fwimage` for `JAL`,
   `AUIPC+ADDI`, `AUIPC+JALR`, and `LUI+ADDI`, with the 20-bit `auipc` immediate
   sign-extended.
2. Disassemble the two sites and resolve the callee.
3. Read the host option parser and confirm unknown keys are forwarded.

**Observed data.** The corrected scan prints both materializations:

```text
0x015cf1be  auipc+addi -> 0x01f3a958
0x015cf1ea  auipc+addi -> 0x01f3a970
```

The parse block from `FUN_ram_015ce3e8`:

```c
iVar17 = FUN_ram_011cfb2c(param_1, s_RMOverrideSmSpeedSelect_ram_01f3a958, &uStack_80);
if (iVar17 == 0) {
  *(undefined1 *)(param_2 + 0xe45) = 1;
  *(uint *)(param_2 + 0xea8) = CONCAT22(uStack_7e, uStack_80);
}
iVar17 = FUN_ram_011cfb2c(param_1, s_RMOverrideSmSpeedSelect1_ram_01f3a970, &uStack_80);
if (iVar17 == 0) {
  *(undefined1 *)(param_2 + 0xe46) = 1;
  *(uint *)(param_2 + 0xeac) = CONCAT22(uStack_7e, uStack_80);
}
```

The host option parser forwards every unknown key:

```c
data = os_strtoul(value, NULL, 0);

for (i = 0; (entry = &nv_parms[i])->name != NULL; i++) {
    if (os_string_compare(entry->name, name) == 0)
        break;
}

if (!entry->name)
    rm_write_registry_dword(sp, NULL, name, data);
else
    *entry->data = data;
```

The driver binary contains zero occurrences of `RMDisableFeatureDisablement`, yet
that key works; unknown keys are forwarded by construction.

**Result.** Both strings are materialized in 595.91.07 and parsed as registry keys.
The callee is `FUN_ram_011cfb2c`, the same registry-read primitive used for
`ForceP2P`. On success the parser stores:

| Key | Presence | Value |
|---|---|---|
| `RMOverrideSmSpeedSelect` | config+`0xE45` = 1 | config+`0xEA8` = parsed dword |
| `RMOverrideSmSpeedSelect1` | config+`0xE46` = 1 | config+`0xEAC` = parsed dword |

The forwarding argument is false: every unrecognized `key=value` is written into the
RM registry. The keys are live code paths. The consumer was not resolved in this
pass; a later static pass resolved it: `0x015cf1be` is an interior address of
`FUN_ram_015ce3e8`, and `config+0xEA8/0xEAC` are read by `FUN_ram_0216d680` and
`FUN_ram_0217f718`, reduced to booleans, and written to a GR context/ucode
descriptor; EA8 is gated by `config+0xEA4`
([E58](../experiments/08_assessment-and-cross-checks.md)).

**Reproduce.**

1. Run the corrected reference scan:

   ```bash
   python3 tools/gsp-rm-tools/refscan.py gsp_fwimage.bin 0x01f3a958 0x01f3a970
   ```

   Expect the two `auipc+addi` lines.

2. Disassemble `0x15cf1a0` with `DisasmRange.java` and resolve the callee.

3. Check the host option parser: unknown keys reach `rm_write_registry_dword`.

4. Expected result: both keys parsed into `config+0xEA8/0xEAC`.

**Limits.** This proves the keys are live code paths, not that they reach the rate.
[E51](#e51--registry-key-hardware-sweep) measures the effect;
[E58](../experiments/08_assessment-and-cross-checks.md) resolves the consumer to
boolean GR descriptor fields, not MMIO.

## E51 · Registry-key hardware sweep

*2026-10-26 · status: CLOSED-MEASURED (inert)*

**Hypothesis.** If the parsed value reaches a rate writer, the issue rate or the
FEAT bank changes.

**Instrument.** [Driver harness](../tools/driver-harness/)
(`regkey_rate_sweep.sh`, bash, root): one stock-driver reload per variant, the
[Issue-rate probe](../tools/issue-rate-probe/) on both cards, and a direct BAR0 read
of `0x823800`–`0x823824` before and after.

**Method.** Four variants: `RMOverrideSmSpeedSelect=0x88888888`,
`RMOverrideSmSpeedSelect=0`, `RMDisableFeatureDisablement=1`, and both keys
(`0x88888888` / `0x8`). One reload per variant; probe both cards; read the bank
before and after; restore the stock driver.

**Observed data.** Best rates per mode, from the run logs:

| Variant | Card | FP16/MHz | f16_f32 TF/s | bf16_f32 TF/s | tf32 TF/s | u4_s32 TOPS | Bank |
|---|---|---:|---:|---:|---:|---:|---|
| baseline ([E49](../experiments/08_assessment-and-cross-checks.md)) | `41:00.0` | 0.07789 | 226.65 | 226.64 | 113.34 | 595.96 | stock |
| baseline ([E49](../experiments/08_assessment-and-cross-checks.md)) | `c1:00.0` | 0.07771 | 229.65 | 229.62 | 114.83 | 604.55 | stock |
| `speed88` | `41:00.0` | 0.07821 | 226.42 | 225.83 | 112.94 | 591.23 | identical |
| `speed88` | `c1:00.0` | 0.07760 | 229.30 | 228.97 | 114.53 | 599.91 | identical |
| `speed0` | `41:00.0` | 0.07792 | 226.13 | 225.83 | 112.93 | 590.22 | identical |
| `speed0` | `c1:00.0` | 0.07755 | 229.16 | 229.08 | 114.53 | 603.46 | identical |
| `featdis` | `41:00.0` | 0.07782 | 225.83 | 225.85 | 112.93 | 594.38 | identical |
| `featdis` | `c1:00.0` | 0.07764 | 229.42 | 229.03 | 114.53 | 599.79 | identical |
| `speedboth` | `41:00.0` | 0.07782 | 225.84 | 225.81 | 112.93 | 597.44 | identical |
| `speedboth` | `c1:00.0` | 0.07792 | 229.10 | 229.04 | 114.54 | 599.59 | identical |

The FEAT bank is byte-identical before and after. For `speed88` on `41:00.0`:

```text
--- FEAT bank before probe
  0x00823804 = 0xfffffb8f
  0x00823818 = 0x00c36180
  0x0082381c = 0x21240001
  0x00823820 = 0x00000002
--- FEAT bank after probe
  0x00823804 = 0xfffffb8f
  0x00823818 = 0x00c36180
  0x0082381c = 0x21240001
  0x00823820 = 0x00000002
```

The per-clock FP16 values span 0.07755–0.07821 TF/s/MHz across all variants; the
other modes are within about 1% on each card. `READOUT_1`, `SS0`, `SS1`, the PLM,
and the static words at `0x823824/28/2c` (`FEAT_OVR_ROW_REMAP`, `FEAT_READOUT_2`,
`FEAT_OVR_ECC_2`) are unchanged
([E56](../experiments/08_assessment-and-cross-checks.md)). No Xid, no GSP error.

**Result.** The keys are parsed and stored, but neither the rate nor the bank moves.
All four modes stay at the baseline within run noise.

**Reproduce.**

1. `sudo tools/driver-harness/regkey_rate_sweep.sh --only speed88`
2. `sudo tools/driver-harness/regkey_rate_sweep.sh --only speed0`
3. `sudo tools/driver-harness/regkey_rate_sweep.sh --only featdis`
4. `sudo tools/driver-harness/regkey_rate_sweep.sh --only speedboth`
5. Add `--bdf 0000:c1:00.0` to fill the second card for one variant.
6. Expect the bank identical before and after, and the rates within run noise.
   Restore the stock driver; one reboot per failed variant.

**Limits.** The keys are parsed, but the rate is unchanged. A null result here would
not by itself prove the key is dead; [E50](#e50--registry-key-reachability-re-tested)
shows the code path is live.

## E52 · The SKU feature-disable machinery in 595.91.07

*2026-10-26 · status: CLOSED-STATIC (display-only; no compute gate)*

**Hypothesis.** The `RMDisableFeatureDisablement` SKU bypass may gate the full-rate
tensor path the way it gates P2P on consumer parts.

**Instrument.** Offline decompilation of `gsp_fwimage.bin`: `FUN_ram_015be840` (the
checker), `FUN_ram_011ac464` (the registry parser), and the 10-entry table at
`0x01d7ad48`. Tools: [GSP-RM tools](../tools/gsp-rm-tools/).

**Method.** Map the 595.91.07 equivalents of the earlier 590.48.01 layout: the
platform flag, the bypass byte, the checker, and the feature table. Trace the call
sites and enumerate the `ebreak` guards.

**Observed data.**

| Object | 595.91.07 | 590.48.01 |
|---|---|---|
| platform flag `is_geforce` | config+`0x4e58` | config+`0x4dd4` |
| bypass byte | config+`0x545a` | config+`0x53ca` |
| checker | `FUN_ram_015be840` (`0x148`) | `FUN_01418060` |
| feature table | `0x01d7ad48`, 10 × 24 B | same shape |

The checker walks the 10-entry, `0x18`-byte table and returns the bit selected by the
platform mask (excerpt):

```c
piVar5 = &DAT_ram_01d7ad48;
do {
  iVar3 = *piVar5;
  piVar5 = piVar5 + 6;
  if (iVar3 == param_2) {
    uVar4 = *(uint *)(&DAT_ram_01d7ad50 + lVar7) &
            uVar2 >> ((long)*(int *)(&DAT_ram_01d7ad4c + lVar7) & 0x1fU);
    if ((long)(int)uVar4 != 0) return (long)(int)uVar4;
    cVar1 = *(char *)(param_1 + 0x545a);
    goto joined_r0x015be902;
  }
  uVar6 = (ulong)((int)uVar6 + 1);
} while (uVar6 != 10);
...
if (cVar1 == '\0') {
  if ((&DAT_ram_00004e58)[param_1] != '\0') {
    return (ulong)(param_2 == 5);
  }
}
return 0;
```

The registry-parser call sites pass ids `5`, `1`, and `9` next to `RMEnableIMP` and
`RMSkipSnoozeFrames`:

```c
iVar5 = FUN_ram_011cfb2c(param_1, s_RMEnableIMP_ram_01ef7738, local_1ac);
...
iVar5 = FUN_ram_015be840(param_1, 5);
...
iVar5 = FUN_ram_015be840(param_1, 1);
...
iVar5 = FUN_ram_015be840(param_1, 9);
```

**Result.** `is_geforce` is set by a PCI-device-ID → detector → switch inside the
registry parser, not from a fuse. The checker's only GeForce special case is feature
id 5 (IMP/HDMI/display); the table entries are byte-identical to 590.48.01 and
contain no compute, tensor, or SM-rate feature. The feature-5 call sites sit next to
`RMEnableIMP` and `RMSkipSnoozeFrames`. In 595 the nine inline bypass → `ebreak`
guards of 590 are gone; the bypass byte is read only by the parser and two checkers.
A second, separate checker (`FUN_ram_015be324`) uses different tables and ids
(`6, 7, 0x11, 0x13, 0x1d`) and is unrelated.

The p2p-style SKU bypass cannot reach a compute rate. One residual: the devinit
branches in `gr_fecs` that test platform bytes (`+0x4e56`, `+0x4e59`) are not
conditioned on the bypass byte and look like assert/devinit paths.

**Reproduce.**

1. Decompile `FUN_ram_015be840` and `FUN_ram_011ac464` from the 595.91.07 image with
   [GSP-RM tools](../tools/gsp-rm-tools/).
2. Dump the 10 × `0x18` table at `0x01d7ad48` and compare it with the 590.48.01
   column above.
3. Trace the `FUN_ram_015be840(..., 5)` call sites; expect the display/IMP path.
4. Expected result: no feature id used for compute or SM rate.

**Limits.** Static only. The residual devinit branches in `gr_fecs` that test
`+0x4e56`/`+0x4e59` are not conditioned on the bypass byte.
