# Registry keys and the static register audit

## Summary

**The idea.**

- The [4090](https://github.com/JustAResearcher/gpu-unlock-ada) and
  [3090](https://github.com/Zagitta/gpu-unlock) unlocks need a write to the
  [FEAT rate bank](../specs/03_register-map.md). Before building an exploit, I
  checked whether the host driver's registry keys already expose a
  speed-selector override.
- The candidates were `RMOverrideSmSpeedSelect`, `RMOverrideSmSpeedSelect1`, and
  `RMDisableFeatureDisablement`.
- I also scanned every plaintext component for a reference to the FEAT and
  [FUSE](../specs/03_register-map.md#fuse-and-otp) rate registers.

**What it found.**

- The plaintext components contain
  [no reference to the six target rate
  registers](#021-static-scan-finds-no-rate-register-reference).
- The two speed-select keys are
  [live firmware code paths](#023-speed-select-keys-are-live-code-paths), parsed
  into config fields.
- On hardware the keys are
  [inert on the rate and the FEAT bank](#024-speed-select-keys-are-inert-on-hardware).
- The SKU bypass is
  [display-only](#025-the-sku-bypass-is-display-only), not a compute gate.
- Boot-input keys can
  [change what the FMC receives](#022-boot-input-keys-change-what-the-fmc-receives)
  and return structured errors.

**What it did not find.**

- A registry key that
  [writes the FEAT bank or moves the issue
  rate](#024-speed-select-keys-are-inert-on-hardware).
- A plaintext reference to a rate register. The literal scan found none, and
  [the computed-offset hunt](../experiments/07_plaintext-corpus.md) found only a
  readout path, not a writer.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 02.1 | [Static scan finds no rate-register reference](#021-static-scan-finds-no-rate-register-reference) | Zero register references |
| 02.2 | [Boot-input keys change what the FMC receives](#022-boot-input-keys-change-what-the-fmc-receives) | Structured boot errors |
| 02.3 | [Speed-select keys are live code paths](#023-speed-select-keys-are-live-code-paths) | Keys are live |
| 02.4 | [Speed-select keys are inert on hardware](#024-speed-select-keys-are-inert-on-hardware) | No rate change |
| 02.5 | [The SKU bypass is display-only](#025-the-sku-bypass-is-display-only) | No compute gate |

## 02.1 Static scan finds no rate-register reference

**Question.** Does any plaintext component reference a FEAT or FUSE rate register,
and are the registry speed-select keys dead?

**Why.**

- The 3090/4090 unlock writes FEAT bank words. A firmware or driver reference
  would be a shortcut to the same write.
- The two `RMOverrideSmSpeedSelect` keys looked like candidate overrides.
- What it would give: a reachable register writer in the plaintext surface, or
  proof that the surface has none.

**Method.**

- Tools: [GSP-RM tools](../tools/gsp-rm-tools/) for the `.fwimage` and
  decompiled-module scans; `zstd` for the host driver.
- Target: `gsp_ga10x.bin` 595.91.07 and the 69 decompiled GSP-RM (the GPU's
  main firmware) modules.
- Steps:
  - Extract `.fwimage`, the plaintext GSP-RM section, from `gsp_ga10x.bin`:
    section at file offset `0x40`, 72,830,976 B, base `0x01000000`.
  - Scan for each FEAT/FUSE offset as 32- and 64-bit little-endian, then
    histogram every aligned dword in `0x00800000`–`0x008fffff`.
  - Scan every `0x8xxxxx` constant in the 69 modules and check the
    [`0x00823800`–`0x0082382f`](../specs/03_register-map.md#feat-bank) window.
  - Query the decompiled string index with reference counts, then search raw
    bytes for `regOpCount`, `regOps`, `hChannelTarget`, `ExecRegOps`, and
    `permission to access register`.
  - Pointer-scan for 4- and 8-byte absolute pointers to the registry strings.
  - Decompress `nvidia.ko.zst`, the host driver module, and repeat the constant
    and string scans.
  - Decode the 32-byte ctrl-table entries at `0x01d16xxx`; confirm
    `0x20800a34` maps to `0x48` and `0x20800122` to `0x30`.
  - Decompile targeted handlers with `DecompileAt.java`; the recovered bodies
    were not used as evidence.
- Args used:
```bash
readelf -SW gsp_ga10x.bin
objcopy --dump-section .fwimage=gsp_fwimage.bin gsp_ga10x.bin
python3 - <<'EOF'
import struct
d = open('gsp_fwimage.bin','rb').read()
for t in (0x00823804,0x00823818,0x0082381c,0x00823820,0x008207d8,0x00504204):
    n = d.count(struct.pack('<I', t)) + d.count(struct.pack('<Q', t))
    print(f"{t:#010x} {n}")
EOF
zstd -d nvidia.ko.zst -o nvidia.ko
grep -rhoE '0x8[0-9a-f]{5}\b' mod_*.c | sort -u | wc -l
```

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
`0x00823800`–`0x0082382f`. The ctrl table has 44 IDs; the public GR control
header has 44; the sets match.

**Result.**

- **Answer:** no. Zero literal references in the `.fwimage`, `nvidia.ko`, and the
  decompiled modules.
- **What we learned:**
  - The literal scan is sound for literal constants.
  - Its registry-key conclusion was wrong: `RMOverrideSmSpeedSelect` and `_1`
    showed zero references here because the scan missed sign-extended `auipc`
    materializations. [The corrected scan](#023-speed-select-keys-are-live-code-paths)
    finds both keys.
  - The ctrl-table entries are reliable; the Ghidra-recovered handler bodies were
    not used as evidence.
  - A literal scan cannot see computed offsets such as
    [`base + 0x3818`](../specs/03_register-map.md#readout-decode). [The
    computed-offset hunt](../experiments/07_plaintext-corpus.md) covers that
    blind spot.
- **Related:**
  - The [corrected reference scan](#023-speed-select-keys-are-live-code-paths)
    finds the two keys.
  - The [computed FEAT readout
    path](../experiments/07_plaintext-corpus.md) is the non-literal scan this one
    could not cover.

## 02.2 Boot-input keys change what the FMC receives

**Question.** Do registry keys that alter the boot inputs change what secure
firmware receives, and does a refused variant return a structured error?

**Why.**

- The registry is a live host-to-secure-firmware input surface.
- If a key can withhold or move boot regions, it may expose a parser or a PL3
  path.
- What it would give: a structured oracle on the boot chain, or a wedge that
  names the failing stage.

**Method.**

- Tools: [Boot tests](../tools/boot-tests/) `gsp_bootpath_tests.sh`, bash, root.
- Target: both cards, stock driver loaded, no open `/dev/nvidia*` handles.
- Steps:
  - Unload `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, and `nvidia`.
  - Reload with one `NVreg_RegistryDwords=...`, the module parameter carrying
    `key=value` pairs into the RM registry.
  - Wait 15 s, capture the dmesg delta before any health check, then restore the
    stock driver.
  - Keys tested: `RmDisableFspFuseErrorCheck=1`, `RmDisableCotCmd=0x1` (the
    FRTS firmware runtime state in sysmem), `RmDisableCotCmd=0x4` (FRTS in
    vidmem), `RmDisableCotCmd=0x10` (GSPFMC, the host-driven FMC bootstrap).
    FSP is the security processor that runs first out of reset; COT is the
    chain-of-trust message the host sends it.
  - No `/etc/modprobe.d` change. Values are parsed with
    `os_strtoul(value, NULL, 0)`; entries are separated by `;`.
- Args used:
```bash
sudo tools/boot-tests/gsp_bootpath_tests.sh --dry-run
sudo tools/boot-tests/gsp_bootpath_tests.sh --only fusecheck
sudo tools/boot-tests/gsp_bootpath_tests.sh --only frts-vid
sudo tools/boot-tests/gsp_bootpath_tests.sh --only gspfmc
sudo tools/boot-tests/gsp_bootpath_tests.sh --restore
```

**Observed data.** From the run logs:

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

**Result.**

- **Answer:** yes. Withholding the vidmem FRTS region yields the structured
  report [`0x83d`](../specs/08_errors-and-logging.md#boot-error-codes) from the
  first-stage mutable GPU firmware (FMC) on both cards. The GSPFMC path deadlocks
  on the reset [PLM](../specs/02_privilege-and-rate-control.md).
- **What we learned:**
  - The host cannot lower the level-0 enables in
    [`0x1103c4`](../specs/06_gsp-riscv-and-priscv.md#falcon-block), so it cannot
    reset the GSP it needs to boot. In that state the host reads
    [`0xBADF5720`](../specs/08_errors-and-logging.md#data-sentinels-and-bad-reads)
    on [`0x1103c0`](../specs/06_gsp-riscv-and-priscv.md#falcon-block).
  - The `0x83d` code shows the FMC consumes the FRTS location; it does not show
    a write primitive.
  - The reset-PLM deadlock is a boot-path property, not a gate on the FMC.
  - Harness caveat: a SIGTERM-stopped `nvidia-smi` pins the module (`rmmod`
    reports "in use"). Use `timeout -s KILL` and `pkill -9 -x nvidia-smi`.
- **Related:**
  - The [boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md) use
    the same host-built descriptors and error codes.
  - The [boot-chain spec](../specs/01_boot-chain.md) covers the FSP, COT, and FMC
    stages.

## 02.3 Speed-select keys are live code paths

**Question.** Are the `RMOverrideSmSpeedSelect` keys actually forwarded and parsed
by the firmware?

**Why.**

- The [first static
  scan](#021-static-scan-finds-no-rate-register-reference) called them dead. A
  miss in a reference scan is weak evidence.
- If live, they are a supported host-to-firmware override path.
- What it would give: a registry-driven rate override, or a dead end with a
  named consumer.

**Method.**

- Tools: [GSP-RM tools](../tools/gsp-rm-tools/) `refscan.py` and
  `DisasmRange.java`; the 595.91.07 host-driver source for the option parser.
- Target: the 72,830,976-byte `.fwimage`, offline.
- Steps:
  - Scan every 2-byte offset for `JAL`, `AUIPC+ADDI`, `AUIPC+JALR`, and
    `LUI+ADDI`, with the 20-bit `auipc` immediate sign-extended. `auipc` is a
    RISC-V PC-relative address instruction; string references often appear as
    `auipc` + `addi`.
  - Disassemble the two sites and resolve the callee.
  - Read the host option parser and confirm unknown keys are forwarded.
- Args used:
```bash
python3 tools/gsp-rm-tools/refscan.py gsp_fwimage.bin 0x01f3a958 0x01f3a970
```

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

**Result.**

- **Answer:** yes. Both strings are materialized in 595.91.07 and parsed as
  registry keys. The callee is `FUN_ram_011cfb2c`, the same registry-read
  primitive used for `ForceP2P`.
- **What we learned:**
  - On success the parser stores `RMOverrideSmSpeedSelect` as config+`0xE45` = 1
    and config+`0xEA8` = the parsed dword; `_1` sets config+`0xE46` and
    config+`0xEAC`.
  - Every unrecognized `key=value` is written into the RM registry, so the
    earlier forwarding argument was false.
  - The consumer was not resolved in this pass. A later static pass resolved it:
    `0x015cf1be` is an interior address of `FUN_ram_015ce3e8`, and
    config+`0xEA8`/`0xEAC` are read by `FUN_ram_0216d680` and `FUN_ram_0217f718`,
    reduced to booleans, and written to a GR context/ucode descriptor; `EA8` is
    gated by config+`0xEA4`
    ([the cross-check](../experiments/08_assessment-and-cross-checks.md)).
- **Related:**
  - The [hardware sweep](#024-speed-select-keys-are-inert-on-hardware) measures
    the effect.
  - The [consumer
    resolution](../experiments/08_assessment-and-cross-checks.md) maps the
    config fields to GR descriptor booleans.

## 02.4 Speed-select keys are inert on hardware

**Question.** Do the parsed speed-select values reach the rate or the FEAT bank?

**Why.**

- The keys are [live code
  paths](#023-speed-select-keys-are-live-code-paths), so the only remaining
  question is effect.
- A rate change would be a supported override. No change closes the registry
  route.
- What it would give: a rate lever, or proof the keys are inert.

**Method.**

- Tools: [Driver harness](../tools/driver-harness/) `regkey_rate_sweep.sh`, the
  [issue-rate probe](../tools/issue-rate-probe/) on both cards, and a direct
  BAR0 read of [`0x823800`–`0x823824`](../specs/03_register-map.md#feat-bank)
  before and after.
- Target: both cards, one stock-driver reload per variant.
- Variants: `RMOverrideSmSpeedSelect=0x88888888`,
  `RMOverrideSmSpeedSelect=0`, `RMDisableFeatureDisablement=1`, and both keys
  ([`0x88888888` / `0x8`](../specs/02_privilege-and-rate-control.md#selector-encoding)).
- Steps: reload, probe both cards, read the bank before and after, restore the
  stock driver.
- Args used:
```bash
sudo tools/driver-harness/regkey_rate_sweep.sh --only speed88
sudo tools/driver-harness/regkey_rate_sweep.sh --only speed0
sudo tools/driver-harness/regkey_rate_sweep.sh --only featdis
sudo tools/driver-harness/regkey_rate_sweep.sh --only speedboth
```

**Observed data.** Best rates per mode, from the run logs:

| Variant | Card | FP16/MHz | f16_f32 TF/s | bf16_f32 TF/s | tf32 TF/s | u4_s32 TOPS | Bank |
|---|---|---:|---:|---:|---:|---:|---|
| baseline ([same-boot probe](../experiments/08_assessment-and-cross-checks.md)) | `41:00.0` | 0.07789 | 226.65 | 226.64 | 113.34 | 595.96 | stock |
| baseline ([same-boot probe](../experiments/08_assessment-and-cross-checks.md)) | `c1:00.0` | 0.07771 | 229.65 | 229.62 | 114.83 | 604.55 | stock |
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
other modes are within about 1% on each card.
[`READOUT_1`](../specs/03_register-map.md#readout-decode),
[`SS0`](../specs/03_register-map.md#ss0-and-ss1),
[`SS1`](../specs/03_register-map.md#ss0-and-ss1), the
[PLM](../specs/02_privilege-and-rate-control.md), and the static words at
`0x823824/28/2c`
([`FEAT_OVR_ROW_REMAP`, `FEAT_READOUT_2`, `FEAT_OVR_ECC_2`](../specs/03_register-map.md#other-feat-words))
are unchanged
([the cross-part corpus](../experiments/08_assessment-and-cross-checks.md)). No
Xid, no GSP error.

**Result.**

- **Answer:** no. The keys are parsed and stored, but neither the rate nor the
  bank moves.
- **What we learned:**
  - All four modes stay at the baseline within run noise.
  - The FEAT bank is byte-identical before and after, with no Xid or GSP error.
  - A null result here would not by itself prove the key dead. The [code path is
    live](#023-speed-select-keys-are-live-code-paths).
- **Related:**
  - The [live-code-path
    result](#023-speed-select-keys-are-live-code-paths) explains why a null
    sweep is meaningful.
  - The [consumer
    resolution](../experiments/08_assessment-and-cross-checks.md) shows the
    fields become GR descriptor booleans, not MMIO writes.

## 02.5 The SKU bypass is display-only

**Question.** Does `RMDisableFeatureDisablement` gate the full-rate tensor path
the way it gates P2P on consumer parts?

**Why.**

- The SKU bypass is a known consumer-part lever on other features.
- If it gates compute, it would be a supported path to the full-rate tensor mode.
- What it would give: a compute gate through the feature-disable machinery, or
  proof it is display-only.

**Method.**

- Tools: [GSP-RM tools](../tools/gsp-rm-tools/) for the 595.91.07 decompilation.
- Target: `FUN_ram_015be840` (the checker), `FUN_ram_011ac464` (the registry
  parser), and the 10-entry table at `0x01d7ad48`.
- Steps:
  - Map the 595.91.07 equivalents of the earlier 590.48.01 layout: the platform
    flag, the bypass byte, the checker, and the feature table.
  - Trace the call sites and enumerate the `ebreak` (RISC-V breakpoint) guards.
- Args used:
```text
Ghidra: FUN_ram_015be840, FUN_ram_011ac464
table:  0x01d7ad48, 10 x 0x18 bytes
```

**Observed data.**

| Object | 595.91.07 | 590.48.01 |
|---|---|---|
| platform flag `is_geforce` | config+`0x4e58` | config+`0x4dd4` |
| bypass byte | config+`0x545a` | config+`0x53ca` |
| checker | `FUN_ram_015be840` (`0x148`) | `FUN_01418060` |
| feature table | `0x01d7ad48`, 10 × 24 B | same shape |

The checker walks the 10-entry, `0x18`-byte table and returns the bit selected by
the platform mask (excerpt):

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

The registry-parser call sites pass ids `5`, `1`, and `9` next to `RMEnableIMP`
and `RMSkipSnoozeFrames`:

```c
iVar5 = FUN_ram_011cfb2c(param_1, s_RMEnableIMP_ram_01ef7738, local_1ac);
...
iVar5 = FUN_ram_015be840(param_1, 5);
...
iVar5 = FUN_ram_015be840(param_1, 1);
...
iVar5 = FUN_ram_015be840(param_1, 9);
```

**Result.**

- **Answer:** no. The bypass is display-only.
- **What we learned:**
  - `is_geforce` is set by a PCI-device-ID detector and switch inside the
    registry parser, not from a fuse.
  - The checker's only GeForce special case is feature id 5
    (IMP/HDMI/display). The table entries are byte-identical to 590.48.01 and
    contain no compute, tensor, or SM-rate feature.
  - The feature-5 call sites sit next to `RMEnableIMP` and `RMSkipSnoozeFrames`.
  - In 595 the nine inline bypass-to-`ebreak` guards of 590 are gone; the bypass
    byte is read only by the parser and two checkers.
  - A second checker (`FUN_ram_015be324`) uses different tables and ids (`6, 7,
    0x11, 0x13, 0x1d`) and is unrelated.
  - The p2p-style SKU bypass cannot reach a compute rate.
- **Related:**
  - The [boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md) cover
    the PL3 and devinit surface.
  - The [register map](../specs/03_register-map.md) has the FEAT and FUSE words.
- **Open question:** the residual `gr_fecs` devinit branches that test platform
  bytes `+0x4e56` and `+0x4e59` are not conditioned on the bypass byte. They look
  like assert/devinit paths, and no experiment has covered them.
