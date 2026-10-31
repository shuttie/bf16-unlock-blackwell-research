# The firmware and vBIOS corpus

## Summary

**The idea.**

- The [3090](https://github.com/Zagitta/gpu-unlock) and
  [4090](https://github.com/JustAResearcher/gpu-unlock-ada) unlocks started with a
  signed boot image and a leaked test key. Blackwell removes that path, so I read
  the images the driver ships: `nvidia.ko`, the GSP-RM `.fwimage` (the GPU's main
  firmware), the FMC (first-stage mutable firmware) and bootloader, and the board
  vBIOS (the PCI option ROM).
- Most of the work is offline. The live register read and the vBIOS dumps need a
  card and root.

**What it found.**

- **What ships:** GB202
  [ships prod and debug GspRmBoot and FMC images](#071-pl3-components-in-the-driver-package);
  there is
  [no FSP (security processor) or BootROM image](#072-no-fsp-or-bootrom-image-ships),
  and no GB202 SEC2 image.
- **The plaintext corpus:** the
  [vBIOS](#073-the-vbios-has-no-feat-address) and
  [full PROM](#079-the-full-prom-has-no-feat-table) carry no FEAT (rate-control
  register bank) address or selector constant. The
  [host driver](#077-the-host-driver-has-no-rate-writer) has no rate writer, the
  [GR (graphics engine) control table](#076-the-rate-getter-has-no-hidden-setter)
  has no hidden setter, and the
  [readout decoder](#078-the-decoder-is-installed-by-the-hal) is HAL-installed.
- **The FMC container:** the
  [format and signature](#074-fmc-container-format-and-signature) are verified
  with two public keys. The body is code, data, and a manifest.
- **The key searches:** the
  [GA100 test-key family](#075-the-ga100-test-key-does-not-fit) does not open
  GB202, and the
  [full 16! permutation search](#0710-the-fmc-key-search-comes-back-negative) is
  negative under five modes.

**What it did not find.**

- No plaintext FEAT address or selector constant in the
  [vBIOS](#073-the-vbios-has-no-feat-address) or
  [PROM](#079-the-full-prom-has-no-feat-table), and no
  [rate writer](#077-the-host-driver-has-no-rate-writer) in the driver.
- No [FSP or BootROM image](#072-no-fsp-or-bootrom-image-ships).
- No [hidden GR SET control](#076-the-rate-getter-has-no-hidden-setter).
- No [FMC key from the MD5-IV permutation family](#0710-the-fmc-key-search-comes-back-negative).

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 07.1 | [PL3 components in the driver package](#071-pl3-components-in-the-driver-package) | Only prod/debug images ship |
| 07.2 | [No FSP or BootROM image ships](#072-no-fsp-or-bootrom-image-ships) | No ROM image found |
| 07.3 | [The vBIOS has no FEAT address](#073-the-vbios-has-no-feat-address) | No FEAT address in vBIOS |
| 07.4 | [FMC container format and signature](#074-fmc-container-format-and-signature) | Two public keys verify |
| 07.5 | [The GA100 test key does not fit](#075-the-ga100-test-key-does-not-fit) | Test-key family ruled out |
| 07.6 | [The rate getter has no hidden setter](#076-the-rate-getter-has-no-hidden-setter) | Getter is a boot cache |
| 07.7 | [The host driver has no rate writer](#077-the-host-driver-has-no-rate-writer) | No writer in `nvidia.ko` |
| 07.8 | [The decoder is installed by the HAL](#078-the-decoder-is-installed-by-the-hal) | Decoder is not dead code |
| 07.9 | [The full PROM has no FEAT table](#079-the-full-prom-has-no-feat-table) | No FEAT address in PROM |
| 07.10 | [The FMC key search comes back negative](#0710-the-fmc-key-search-comes-back-negative) | Permutation search negative |

## 07.1 PL3 components in the driver package

**Question.** Which PL3 components are obtainable from the driver package?

**Why.**

- The 3090/4090 unlocks started with a signed SEC2 (security coprocessor) boot
  image at PL3 (the boot-firmware privilege level). If Blackwell ships one, it is
  the first thing to inspect.
- What it would give: an exploitable PL3 image, or a closed component inventory.

**Method.**

- Tools: `readelf`; an entropy/string script; the FMC ELF wrapper.
- Target: the installed 595.91.07 `nvidia.ko` and `fmc.bin`; offline.
- Steps:
  - `readelf -sW nvidia.ko` for `ksec2BinArchive*`,
    `kgspBinArchiveGspRmBoot_*`, `kgspBinArchiveGspRmFmc*`, and
    `kgspBinArchiveConcatenatedFMC*`.
  - Map symbols to file offsets: section 20 is `.rodata` at `0x434558`; file
    offset is `0x434558 + st_value`.
  - Compute Shannon entropy, printable-string counts, and prod/debug byte
    deltas.
  - Parse the FMC wrapper with `readelf -SW fmc.bin`.
  - Check the open GB100 HAL: `ConcatenatedFMC` is selected only under
    confidential compute;
    [the boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md)
    resolve this SKU to the ordinary path.
- Args used:
```bash
readelf -sW nvidia.ko | grep -E 'ksec2BinArchive|kgspBinArchiveGspRmBoot|kgspBinArchiveGspRmFmc|kgspBinArchiveConcatenatedFMC'
readelf -SW fmc.bin
```
- Entropy script:
```python
import collections, math
d = open('nvidia.ko','rb').read()
sec = 0x434558
for name, off, size in (
    ('GspRmBoot PROD', 0x4d6a58, 0x47000),
    ('GspRmBoot DBG',  0x51da78, 0x47000),
    ('FMC PROD',       0x15b040, 0x46248),
    ('FMC DEBUG',      0x25cf28, 0x46248),
):
    b = d[sec+off:sec+off+size]
    c = collections.Counter(b); n = len(b)
    h = -sum(v/n*math.log2(v/n) for v in c.values())
    print(f"{name}: entropy={h:.3f} head={b[:8].hex()}")
```

**Observed data.**

```text
GspRmBoot PROD: size=290816 entropy=7.983 head=840e559669372140
GspRmBoot DBG:  size=290816 entropy=7.980 head=0000000000000000
FMC PROD:       size=287304 entropy=7.999 head=0304480000620400
FMC DEBUG:      size=287304 entropy=7.999 head=0304480000620400
FMC prod/debug differing bytes: 99.57%
GspRmBoot prod/debug differing bytes: 98.37%

readelf -SW fmc.bin
[2] hash       0x30
[3] signature  0x60
[4] publickey  0x61
[5] image      0x30a48
```

**Result.**

- **Answer:** GB202 ships prod and debug GspRmBoot and FMC images; only TU102
  (303 B) and AD10X (6,233 B) SEC2 images exist.
- **What we learned:**
  - All bodies are ≥7.98 bits/byte; FMC prod/debug differ in 99.6% of bytes,
    GspRmBoot in 98.4%.
  - The FMC wrapper sections are `hash` (0x30), `signature` (0x60), `publickey`
    (0x61), and `image` (0x30a48).
  - There is no GB202 SEC2 image.
- **Related:**
  - The [FMC container](#074-fmc-container-format-and-signature) analysis covers
    the signed wrapper.
  - The [missing ROM inventory](#072-no-fsp-or-bootrom-image-ships) covers
    FSP/BootROM.
  - The [boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md)
    resolve the SKU path.

## 07.2 No FSP or BootROM image ships

**Question.** Can the FSP (security processor) or GSP BootROM (the GPU's
immutable boot ROM) image be obtained from the host?

**Why.**

- The FSP and GSP BootROM run from immutable ROM at PL3. A host-readable copy
  would expose the first-stage code.
- What it would give: the ROM image or a closed route.

**Method.**

- Tools: a filesystem inventory, `nvidia-debugdump`, `/dev/nvdebug`, and the PCI
  ROM BAR.
- Target: the installed firmware tree and the live card; root for the ROM BAR.
- Steps:
  - List `/lib/firmware/nvidia/gb202/gsp/`.
  - Search `/lib/firmware` for FSP or BootROM names.
  - Audit `nvidia-debugdump --help` and its strings.
  - Check for `/dev/nvdebug` and `/sys/bus/pci/devices/<bdf>/rom`.
- Args used:
```bash
ls -la /lib/firmware/nvidia/gb202/gsp/
find /lib/firmware -iname '*fsp*' -o -iname '*bootrom*'
nvidia-debugdump --help
```

**Observed data.**

```text
$ ls -la /lib/firmware/nvidia/gb202/gsp/
bootloader-570.144.bin.zst
fmc-570.144.bin.zst
gsp-570.144.bin.zst -> ../../ga102/gsp/gsp-570.144.bin.zst

$ find /lib/firmware -iname '*fsp*' -o -iname '*bootrom*'
(no output)
```

The installed package here is 570.144; 595.91.07 has the same three entries
(`bootloader`, `fmc`, and the `gsp` symlink).

**Result.**

- **Answer:** no FSP or BootROM image exists in any package; no documented host
  read path exists.
- **What we learned:**
  - Obtainable: the board vBIOS, the encrypted FMC, the plaintext GSP-RM.
  - The ROM BAR read stopped at `0x27A00`;
    [the full PROM scan](#079-the-full-prom-has-no-feat-table) supersedes it with
    the full aperture.
  - This proves no host-readable image ships, not that the ROMs are absent from
    the die.
- **Related:**
  - The [vBIOS dump](#073-the-vbios-has-no-feat-address) covers the image that
    does ship.
  - The [full PROM scan](#079-the-full-prom-has-no-feat-table) covers the rest of
    the aperture.

## 07.3 The vBIOS has no FEAT address

**Question.** What is in the board vBIOS, and does it carry a plaintext rate
constant or a FEAT (rate-control register bank) address?

**Why.**

- If the vBIOS init tables name the FEAT block, a modified vBIOS or devinit path
  could write the selector.
- What it would give: a plaintext address or a closed surface.

**Method.**

- Tools: [vBIOS tools](../tools/vbios-tools/): `vbios_probe`, `vbios_read`,
  `parse_flash.py`, `bit_tokens.py`, `devinit_scan.py`; Ghidra for the x86 option
  ROM.
- Target: `41:00.0`, root; read-only.
- Steps:
  - Set and clear the PCI ROM BAR enable bit at config `0x30`.
  - Dump the PROM aperture at BAR0 `0x300000`–`0x400000`; the image starts at
    `0x338000`.
  - Parse the image chain, the BIOS information table (BIT), the microcode table,
    and descriptors.
  - Scan for FEAT/FUSE constants and x86 MMIO stores; diff the two cards.
- Args used:
```bash
sudo tools/vbios-tools/vbios_probe 0000:41:00.0 300000 100000
sudo tools/vbios-tools/vbios_read 0000:41:00.0 flash_41.bin
python3 tools/vbios-tools/parse_flash.py flash_41.bin
python3 tools/vbios-tools/devinit_scan.py flash_41.bin
cmp -l flash_41.bin flash_c1.bin | wc -l
```

**Observed data.**

```text
== flash1m_41.bin: 1048576 bytes, entropy=6.26
  BIT @0xdf0 image base @0x0 adjust(EFI correction)=0x18000
    image @0x0 size=0xfa00
    image @0xfa00 size=0x18000
    image @0x27a00 size=0xfa00
  BIT: header=12 stride=6 tokens=20
  ucode table: ver=1 hsize=6 esize=6 entries=35
    entry 5  app=0x07 tgt=0x06 enc=1 body=0x6fdf0..0x8fff0
    entry 22 app=0x18 tgt=0x01 invalid hdr=0xbadf1100
    entry 23 app=0x19 tgt=0x01 enc=1 body=0x90040..0xb1b40
    entry 24 app=0x15 tgt=0x01 enc=1 body=0xb1c80..0xb7780
    entry 32 app=0x23 tgt=0x0e enc=1 body=0xb780c..0xd5a0c
    entry 34 app=0x24 tgt=0x0f invalid hdr=0xbadf1100
  FEAT address literals: none
  devinit opcodes with an address in 0x823800-0x8238ff: none
```

`cmp -l flash_41.bin flash_c1.bin | wc -l` returns `1375`. The PciAt
decompilation index has 85 functions.

**Result.**

- **Answer:** four real microcode images (`0x07`, `0x19`, `0x15`, `0x23`) and
  two placeholders (`0x18`, `0x24`); all real bodies are encrypted; there are no
  FEAT/FUSE constants; 1,375 bytes differ between cards.
- **What we learned:**
  - No FWSEC app IDs.
  - No FEAT address literals; no devinit opcode in `0x823800`–`0x8238ff`.
  - [The boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md)
    correct the census and body offsets.
  - This is the 1 MiB image, not the 2 MiB aperture; the
    [full PROM scan](#079-the-full-prom-has-no-feat-table) covers the rest.
- **Related:**
  - The [full PROM scan](#079-the-full-prom-has-no-feat-table) covers the 2 MiB
    aperture.
  - The [boot-input experiments](../experiments/05_fmc-fsp-boot-inputs.md)
    correct the microcode census.

## 07.4 FMC container format and signature

**Question.** What is the FMC container format, and what does the signature cover?

**Why.**

- The FMC runs at PL3. A parseable container and a verifiable signature are the
  boundary for a custom FMC.
- What it would give: the signed region and the key model, or a closed
  authentication path.

**Method.**

- Tools: a scan for the container magic, a header parser, DER/SPKI (public-key
  encoding), and OpenSSL; the [FMC tools](../tools/fmc-tools/) README has the
  container layout and OpenSSL commands.
- Target: the 595.91.07 `nvidia.ko` and the extracted FMC containers; offline.
- Steps:
  - Scan for `03 04 48 00`; each container is `0x48 + u32@+4` bytes.
  - Split the `0xF8` bytes before the container as
    `publickey[97] || pad[7] || signature[96] || hash[48]`.
  - DER-encode the key as SPKI (`ecPublicKey` + `secp384r1`) and the signature
    as `SEQUENCE{INTEGER r, INTEGER s}`.
  - Verify with OpenSSL.
- DER encoding:
```python
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

key = open('c04_pkey.bin','rb').read()   # 97-byte uncompressed point
pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP384R1(), key)
open('pub.der','wb').write(pub.public_bytes(
    serialization.Encoding.DER,
    serialization.PublicFormat.SubjectPublicKeyInfo))

def der_int(x):
    b = x.to_bytes((x.bit_length() + 7)//8 or 1, 'big')
    if b[0] & 0x80:
        b = b'\x00' + b
    return b'\x02' + bytes([len(b)]) + b

sig = open('c04_sig.bin','rb').read()    # r || s, 48 bytes each
body = der_int(int.from_bytes(sig[:48],'big')) + der_int(int.from_bytes(sig[48:],'big'))
open('sig.der','wb').write(b'\x30' + bytes([len(body)]) + body)
```
- Args used:
```bash
openssl pkey -pubin -inform DER -in pub.der -out pub.pem
openssl dgst -sha384 -verify pub.pem -signature sig.der c04.bin
openssl pkeyutl -verify -pubin -inkey pub.pem -in hash.bin -sigfile sig.der \
  -pkeyopt digest:sha384
```

**Observed data.**

```text
c04 header: 03 04 48 00 00 62 04 00 ... 00 70 03 00 ... 00 e8 00 00 04 01 ...
c09 header: identical
body 0x46200 = code 0x37000 + data 0xE800 + 0xA00
openssl dgst -sha384 -verify c09_pub.pem -signature c09_sig.der c09.bin
Verified OK
openssl pkeyutl -verify ... -pkeyopt digest:sha384
Signature Verified Successfully
```

**Result.**

- **Answer:** for all 14 samples, `body = code + data + 0xA00`. The `hash` is
  SHA-384 over the whole container, header included; the signature is `r || s`.
  Two public keys verify.
- **What we learned:**
  - Production and debug keys verify different containers. Seven containers
    have a valid hash but no inline key block.
  - Body entropy is 7.999; ≤1 repeated 16-byte block per image; the prod/debug
    XOR zero count is 1,154 in 287,232 (chance rate).
  - A valid signature proves NVIDIA signed the container; it says nothing about
    the body plaintext or the encryption key.
- **Related:**
  - The [FMC key search](#0710-the-fmc-key-search-comes-back-negative) uses the
    c09 and c11 containers.
  - The [PL3 component inventory](#071-pl3-components-in-the-driver-package)
    covers the container sizes.

## 07.5 The GA100 test key does not fit

**Question.** Does the GA100 AES-128-ECB debug test key, a permutation of the MD5
initialization vector (MD5-IV), open the GB202 debug FMC?

**Why.**

- The leaked test key opened GA100 debug images. If it also opens GB202, the FMC
  is decryptable.
- What it would give: the FMC key, or closure of the test-key family.

**Method.**

- Tools: a byte scan for the 16-byte known-answer test (KAT), a repeated-block
  count, and the candidate search in [FMC tools](../tools/fmc-tools/).
- Target: all FMC containers, the ELF-wrapped FMC, the linux-firmware boot
  loader, the 1 MiB vBIOS dump, and `nvidia.ko`; offline.
- Steps:
  - Scan for
    `AES-ECB(key37, 0×16) = 717d1494eaca317ff106195258b38377`.
  - Count repeated 16-byte blocks (ECB structure); the four vBIOS microcode
    bodies at descriptor `+0x50`, 8 KiB each.
  - Test 132,240 structured candidates derived from the MD5 IV with
    `pycryptodome`: word and byte orders, rotations, nibble swaps, ShiftRows
    permutations, key-schedule words, XOR/add constants, key-index variants.
- Args used:
```bash
python3 tools/fmc-tools/key37_search.py
python3 tools/fmc-tools/key37_search2.py
```

**Observed data.**

```text
KAT: AES-128-ECB(key37, 0^16) = 717d1494eaca317ff106195258b38377
fingerprint hits: 0 in all 13 containers, nvidia.ko, flash_41.bin, flash_c1.bin
```

The 132,240-candidate search found no match. Hashcat cannot express "each of the
16 known bytes exactly once" (16¹⁶ ≈ 1.8 × 10¹⁹ vs 16! ≈ 2.09 × 10¹³). The [full
16! search](#0710-the-fmc-key-search-comes-back-negative) has two-GPU runs of
about 1,900 s per container.

**Result.**

- **Answer:** 0 fingerprint hits; no candidate matches.
- **What we learned:**
  - ≤1 repeated block per FMC; vBIOS bodies are 512/512 distinct.
  - The ECB/zero-padding shape is ruled out. The same key in CBC, CTR, XTS, or a
    compressed-then-ECB body is not.
  - The [full 16! search](#0710-the-fmc-key-search-comes-back-negative).
- **Related:**
  - The [full permutation search](#0710-the-fmc-key-search-comes-back-negative)
    covers the remaining modes.
  - The [FMC container](#074-fmc-container-format-and-signature) supplies the
    c09 and c11 samples.

## 07.6 The rate getter has no hidden setter

**Question.** Does the driver's rate getter reflect `FEAT_READOUT_1`, and does the
GR control table hide a setter?

**Why.**

- A live getter or a hidden SET would be a software path to the rate. A cached
  getter and a complete table close both.
- What it would give: a live selector path, or proof the getter is a boot-time
  cache.

**Method.**

- Tools: [register access](../tools/register-access/) `ratev2` and `throttle` on
  a live card; Ghidra 12.2 for the table and decoder.
- Target: `41:00.0`, root for the live reads; offline for the decompile.
- Steps:
  - Decode every 32-byte record in `0x20801200`–`0x208012ff` as
    `{ctrlId, paramSize}`.
  - Compare with the public GR control list in
    [firmware formats](../specs/04_firmware-formats.md).
  - Search the fused sub-offsets as call arguments.
  - Decompile the decoder and its installer.
- Args used:
```bash
sudo tools/register-access/regops 1 0000:41:00.0 ratev2
sudo tools/register-access/regops 1 0000:41:00.0 throttle
"$GHIDRA_HOME/support/analyzeHeadless" project gsp_full \
  -process gsp_fwimage.bin -noanalysis \
  -scriptPath tools/gsp-rm-tools \
  -postScript DecompileAt.java out.c 0x15ffae8 0 300
```

**Observed data.**

```text
ratev2 status = 0 (0) listSize=10
  FMLA16=0  FMLA32=3  FFMA=0  IMLA0=0
  IMLA1=3   IMLA2=3   IMLA3=0  IMLA4=3
  FP16=0    FP32=0
throttle status = 0 (0) listSize=1
  [0] MASK=0 (no CREDIT entries)
44 control IDs in the table, 44 public IDs in the control list, exact match.
```

```c
pcVar3 = *(code **)(*(long *)(param_1 + 0x1d70) + 0x100);
(*pcVar3)(param_1, *(long *)(param_1 + 0x1d70), 0x3818, &local_40, 0,0,0, pcVar3);
param_3[5] = (byte)(local_40 >> 0xd) & 7;
...
param_3[2] = local_3c[0];   /* DP, second call through object +0xc38 */
```

The installer selects the decoder with `0x3e0 >> variant & 1`: variants 5–9 get
`FUN_ram_015ff1dc` (`0x9668`); every other variant gets `FUN_ram_015ffae8`
(`0x3818`). The static scan of `FUN_ram_015ffae8` fills the nine bytes from
`0x3818`; stock `0x00c36180` decodes to `fmla32=3`.

**Result.**

- **Answer:** the getter is a copy-out of `KGRAPHICS_STATIC_INFO`, populated at GR
  init. The GR table has no hidden SET.
- **What we learned:**
  - `0x2080123e` is `GR_TEST_CTXSW_ERROR_LOGS`; the internal static-info entries
    `0x20800b03` and `0x20800b05` are GET-only.
  - The installer selects the decoder with `0x3e0 >> variant & 1`: variants 5–9
    use `0x9668`; every other variant uses `0x3818`.
  - Stock `0x00c36180` decodes to `fmla32=3`.
  - The getter is a boot-time cache, not a live hardware read.
- **Related:**
  - The [decoder installation](#078-the-decoder-is-installed-by-the-hal) covers
    the live caller.
  - The [registry and static audit](../experiments/02_registry-and-static-audit.md)
    covers the driver knobs.

## 07.7 The host driver has no rate writer

**Question.** Does the host driver contain a rate writer?

**Why.**

- If `nvidia.ko` writes the rate registers, a driver knob could change the rate.
- What it would give: a host-side writer, or proof the driver only reads.

**Method.**

- Tools: `nm`, `size`, a 32/64-bit constant scan on `nvidia.ko`, and a diff of
  the matching open kernel modules (`$NVIDIA_SRC`).
- Target: the installed 595.91.07 `nvidia.ko`; offline.
- Steps:
  - `nm -g --defined-only nvidia.ko` for the GB202 vGPU functions.
  - Trace the generated HAL dispatch table: GB202 → `kgspResetHw_GB100`,
    `kgspSetupGspFmcArgs_GH100`, `kgspBootstrap_GH100`.
  - Trace the vGPU call site; it runs only when
    `bVgpuGspPluginOffloadEnabled`.
  - History: the GB202 HAL file was introduced in `580.65.06` (2025-08-04).
  - Scan the tree for every rate literal; enumerate `NV_FUSE_ZB_*` uses:
    `0x3814` (error-correcting code, ECC), `0x74c`, and the ucode version. All
    are reads.
  - Diff `570.153.02..595.91.07` for the GR init file and the GR control header:
    V2 and throttle GETs were added; no SET.
- Args used:
```bash
nm -g --defined-only nvidia.ko | grep kgspVgpu
git -C "$NVIDIA_SRC" diff 570.153.02..595.91.07 -- \
  src/nvidia/src/kernel/graphics/kernel_graphics.c \
  src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gr.h
```

**Observed data.**

```text
000000000024fd20 T kgspVgpuFwHeapSize_GB202
000000000024fda0 T kgspVgpuNumVgpuPartitions_GB202
text 13258932  data 236502  bss 282320
constant scan:
0x823804 0
0x823818 0
0x82381c 0
0x823820 0
0x8207d8 0
0x504204 0
```

The GB202 HAL file is 63 lines and two functions; it is vGPU-only and does not
override reset or COT.

**Result.**

- **Answer:** the host driver contains no rate writer; `nvidia.ko` has no literal
  reference to the six rate registers.
- **What we learned:**
  - The GB202 HAL file is 63 lines and two functions; it is vGPU-only and does
    not override reset or the chain-of-trust (COT) path.
  - A literal scan misses computed offsets (`base + 0x3818`); the
    [decoder installation](#078-the-decoder-is-installed-by-the-hal) is the
    correction.
- **Related:**
  - The [decoder installation](#078-the-decoder-is-installed-by-the-hal) covers
    the computed offset.
  - The [rate getter](#076-the-rate-getter-has-no-hidden-setter) covers the
    host-side view.

## 07.8 The decoder is installed by the HAL

**Question.** Is the FEAT decoder installed through the per-chip HAL table, or is
it dead code?

**Why.**

- If the decoder is dead, the rate getter may not be the real readout path. If it
  is installed, the static model is valid.
- What it would give: proof the decoder is live and a lead to its caller.

**Method.**

- Tools: a raw reference scan over `gsp_fwimage.bin` and Ghidra 12.2;
  [GSP-RM tools](../tools/gsp-rm-tools/).
- Target: the extracted GSP-RM `.fwimage`; offline.
- Steps:
  - Decode every 2-byte-aligned word and test `JAL`, `AUIPC+ADDI`,
    `AUIPC+JALR`, `LUI+ADDI` with correct sign extension, plus raw u32/u64 and
    table forms.
  - Disassemble and decompile survivors.
- Args used:
```bash
python3 tools/gsp-rm-tools/refscan.py gsp_fwimage.bin 0x015ffae8
```

**Observed data.**

```text
015c1c4a8: auipc a4, 0xff9e3      ; a4 = pc - 0x61d000 = 0x015ff4a8
015c1c4ac: addi  a4, a4, 0x640    ; a4 = 0x015ffae8
015c1c4b0: sd    a4, -0x3e0(a5)   ; *(void**)(obj + 0xC20) = FUN_ram_015ffae8

0x01c1c4a8  auipc+addi -> 0x015ffae8
0x01c1db74  auipc+addi -> 0x015ffae8
0x01c1dcf0  auipc+addi -> 0x015ffae8
0x01c1ddda  auipc+addi -> 0x015ffae8
0x01c1e40c  auipc+addi -> 0x015ffae8
```

The five sites are inside `FUN_ram_01c1c374` (`0x21fc` bytes), each storing into
`obj+0xC20`. The initializer fills `obj+0xB78…0xDE8` from `desc+0x10`: family
`(>>5)`, variant `(&0x1f)`. The object is `0x3E40` bytes, built by
`FUN_ram_01acd340` (`0x527c`), which calls the initializer at `0x1acde76`.

| Variant (`desc[0x10] & 0x1f`) | `obj+0xC20` | Register source |
|---|---|---|
| not in `{5..9}` | `FUN_ram_015ffae8` | fuse `0x3818` via `gpu+0x1D70 → +0x100` |
| in `{5..9}` | `FUN_ram_015ff1dc` | register `0x9668` via `obj+0xF20 → +0x28` |

**Result.**

- **Answer:** the decoder is materialized at five sites and installed in the HAL
  object; it is not dead code.
- **What we learned:**
  - Five stores into `obj+0xC20`; the object is `0x3E40` bytes, built by
    `FUN_ram_01acd340`; the initializer fills `obj+0xB78…0xDE8` from `desc+0x10`.
  - Variants 5–9 use `0x9668`; every other variant uses `0x3818`.
  - `FUN_ram_01acd340` has no static references, so the instantiation path
    remains open.
- **Related:**
  - The [rate getter](#076-the-rate-getter-has-no-hidden-setter) covers the
    decoder's output.
  - The [host driver](#077-the-host-driver-has-no-rate-writer) covers the
    computed-offset gap.
- **Open question:** who calls `obj+0xC20` is not proven. The five
  materializations show the decoder is installed; they do not identify the
  caller.

## 07.9 The full PROM has no FEAT table

**Question.** Does the full 2 MiB PROM aperture contain a FEAT/`SS0`/`SS1` constant
(the rate-override bank and its selector words) or a plaintext devinit table that
names the FEAT block?

**Why.**

- The 1 MiB vBIOS dump may have missed the upper region. The full aperture is the
  last place a plaintext table could name FEAT.
- What it would give: a plaintext address or closure of the vBIOS route.

**Method.**

- Tools: [vBIOS tools](../tools/vbios-tools/): `prom_read_raw`, `bit_tokens.py`,
  `devinit_scan.py`.
- Target: `41:00.0`, root; read-only.
- Steps:
  - Dump the 2 MiB aperture read-only.
  - Parse the image chain, BIT, and microcode table.
  - Scan for FEAT/`SS0`/`SS1` constants and devinit opcodes.
  - Diff the two cards' heads.
- Args used:
```bash
sudo tools/vbios-tools/prom_read_raw 0000:41:00.0 prom_full_41.bin
python3 tools/vbios-tools/bit_tokens.py prom_full_41.bin
python3 tools/vbios-tools/devinit_scan.py prom_full_41.bin
```

**Observed data.**

```text
== prom_full_41.bin: 2097152 bytes (0x200000), entropy=5.32
  BIT @0x38df0  image base @0x38000  adjust(EFI correction)=0x18000
    image @0x38000 size=0xfa00
    image @0x47a00 size=0x18000
    image @0x5fa00 size=0xfa00
    image @0x6f400 size=0x0 last=1
  BIT: tokens=20
  ucode table: entries=35
    app 0x07/tgt 0x06, app 0x19/tgt 0x01, app 0x15/tgt 0x01, app 0x23/tgt 0x0e
    placeholders: app 0x18/tgt 0x01, app 0x24/tgt 0x0f (hdr=0xbadf1100)
  FEAT literals: none
  sentinel 0xbadf1100: 241883 occurrences
```

The `0x38000` head differs by 790 bytes between the cards: 228,586 of 229,376
identical (99.66%). `devinit_scan.py` finds no devinit opcode whose address lands
in `0x823800`–`0x8238ff`; the only register-address list is a 72-entry FUSE/strap
table at `0x638E5` (`0x820800`–`0x8221A4`).

**Result.**

- **Answer:** no FEAT address in any plaintext table or script.
- **What we learned:**
  - Aperture map: `0x00000`–`0x38000` head (`NVFW` at `+0x1000`, 218 KiB
    encrypted blob, plaintext board metadata); `0x38000`–`0x138000` the vBIOS
    image; `0x138000`–`0x200000` the `0xBADF1100` sentinel.
  - The `0x38000` head differs by 790 bytes; 228,586 of 229,376 identical
    (99.66%).
  - The only register-address list is a 72-entry FUSE/strap table at `0x638E5`
    (`0x820800`–`0x8221A4`).
  - The 218 KiB head blob is encrypted; the scan covers the aperture, not the
    encrypted microcode.
- **Related:**
  - The [1 MiB vBIOS dump](#073-the-vbios-has-no-feat-address) covers the lower
    image.
  - The [boot-input devinit experiments](../experiments/05_fmc-fsp-boot-inputs.md)
    cover the corrected microcode census.

## 07.10 The FMC key search comes back negative

**Question.** Does the GB202 FMC decrypt under the MD5-IV permutation family, and
does the body layout allow a code-first key?

**Why.**

- The previous FMC 16! oracle accepted a key only if its first decrypted block
  was a container or compression magic. If the encrypted body starts with code, a
  correct key could have been discarded, and "family exhausted" would not be
  established.
- What it would give: the FMC key, or exhaustion of the permutation family.

**Method.**

- Tools: the [container extractor](#074-fmc-container-format-and-signature); the
  parcel-table builder,
  CUDA search, two-GPU runner, and verifier in
  [FMC tools](../tools/fmc-tools/).
- Target: the GB202 c09/c11 FMC containers and the GSP-RM code segment; two 5090s.
- **Layout.** Extract c04 (prod) and c09 (debug) FMC containers and the
  `GspRmBoot_GB202` prod/debug images from `nvidia.ko` (`.rodata` at `0x434558`;
  GspRmBoot at `0x4d6a58`/`0x51da78`; FMC at `0x15b040`/`0x25cf28`). Parse the
  container header (`codeSize` at `+0x0C`, `dataSize` at `+0x14`) and the
  GspRmBoot `WprMeta` (host boot descriptor) geometry (manifest 0, data `0xA00`,
  code `0xF200`, size `0x47000`). Compare region by region for both pairs.
- **Oracle.** `build_riscv_logp.py` extracts the loaded GSP-RM code segment (the
  ELF at file `0x18F000`, `p_vaddr 0x01000000`, `0xDCD000` bytes; the largest of
  the 11 embedded ELF64 headers) and builds a 16-bit parcel histogram: 7,233,536
  parcels, entropy 11.588 bits, `p = (count+1)/(n+65536)`, quantized to
  `round(2*log2 p)`. `key37_cuda.cu --fmc-riscv` Stage 1 decrypts block 0 in the
  ECB/CBC-zero and CTR-zero hypotheses and sums eight table entries; Stage 2
  decrypts 8 blocks for Stage-1 survivors and scores the ECB and CBC-zero
  streams (mode 0) or the CTR stream with counter = block index (mode 1). The
  compact AES kernel uses 12,872 B shared, 118 registers, 2 blocks/SM, so the
  64 KB table stays in L1.
- **Calibration and controls.** Build a synthetic container whose code component
  is the real GSP-RM entry code, encrypt it under the rank-0 key (`POOL` in
  order), and check that the oracle recovers exactly that key. Re-score the
  12,260 legacy c09/c11 first-block hits with the parcel model.
- **Runs.** Five hypotheses per key: ECB (0), CBC-zero (1), CBC with the
  container header as IV (3), CTR start 0 (2), and CTR start 1 (4). CBC IV
  affects only block 0, so the two CBC variants share one stream; CTR start 1
  costs one extra encrypt. A true CBC key can hit both CBC modes as an expected
  pair; the genuine IV is the higher-scoring one. Hit modes: 0/1/3 decrypt, 2/4
  CTR. `fmc_riscv_verify.py` knows modes 3 and 4 and walks the whole code
  component as RV32/64 instructions.
- Args used:
```bash
nvcc -O3 -arch=sm_120 -U_GNU_SOURCE \
  -o key37_cuda tools/fmc-tools/key37_cuda.cu
python3 tools/fmc-tools/build_riscv_logp.py \
  --fw gsp_fwimage.bin --out riscv_logp_q.bin
python3 tools/fmc-tools/riscv_oracle_selftest.py \
  --bin key37_cuda --blocks 8
tools/fmc-tools/run_fmc_riscv_2gpu.sh c09.bin out_c09
tools/fmc-tools/run_fmc_riscv_2gpu.sh c11.bin out_c11 c09.bin
python3 tools/fmc-tools/fmc_riscv_verify.py \
  --hits out_c09/fmc_hits.txt --container c09.bin
python3 tools/fmc-tools/fmc_riscv_verify.py \
  --hits out_c11/fmc_hits.txt --container c11.bin
```

**Observed data.**

**Layout.**

```text
prod  header body/code/data 0x46200 0x37000 0xe800 algebra 0x46200
  code prefix match True
  data region match True
  manifest match True
debug header body/code/data 0x46200 0x37000 0xe800 algebra 0x46200
  code prefix match True
  data region match True
  manifest match True
c11   body 0x30500 code 0x25400 data 0xa700 algebra 0x30500
```

| Region | Comparison | Prod | Debug |
|---|---|---|---|
| FMC `body[0 : codeSize]` | GspRmBoot `[0xA00+dataSize : ...]` | identical prefix (`0x37000`) | identical prefix (`0x37000`) |
| FMC `body[codeSize : codeSize+dataSize]` | GspRmBoot `[0xA00 : 0xA00+dataSize]` | identical (`0xE800`) | identical (`0xE800`) |
| FMC `body[codeSize+dataSize : ]` | GspRmBoot `[0 : 0xA00]` | identical (`0xA00`) | identical (`0xA00`) |

**Oracle calibration (19,481 GSP-RM function starts).**

```text
Stage 1 t1=-256 (3.8 sigma): 97.0% overall, 99.3% on clean code
Stage 2 8 blocks t2=-2102 (9 sigma): 99.92% of clean code
exact-DP staged random tail: 1.2e-14 per hypothesis
GSP-RM entry block score: -185 Q
```

**Controls.**

```text
rank-0 synthetic: rank 0 score -1533
  recovered in ECB (0), CBC-zero (1), CTR-zero (2); verifier accepts all
same key, random plaintext: hits=0
full-code walk: synthetic 0.046% invalid; random key 8.8% invalid
legacy re-score: c09 median -297 Q (min -323, max -246)
                 c11 median -297 Q (min -325, max -248)
                 random mean -296.4 Q (sigma 10.6)
                 above t1: 5/6,115 (c09), 2/6,145 (c11)
```

**Runs.**

```text
c09 three-mode: 1375 s wall, 7.61 G keys/s per 5090, 0 hits
c09 five-mode: 1902 s, 5.50 G keys/s per 5090, 0 valid
c11 five-mode: 1907 s, 5.50 G keys/s per 5090, 0 valid
```

| Container | Hit | Rank | Score | Verifier |
|---|---|---|---:|---|
| c09 | mode 4 (CTR start 1) | 13,567,028,728,510 | -2097 | reject |
| c11 | mode 0 (ECB) | 5,123,222,474,751 | -2089 | reject |
| c11 | mode 4 (CTR start 1) | 14,469,189,879,912 | -2094 | reject |

**Result.**

- **Answer:** the body is `[code][data][manifest 0xA00]`; the first body block is
  code. The MD5-IV permutation family does not decrypt the c09 or c11 FMC under
  ECB, CBC-zero/header-IV, or CTR start 0/1.
- **What we learned:**
  - The FMC code is a prefix of the GspRmBoot code, and the manifest is the
    GspRmBoot manifest. The data and manifest ciphertexts are identical although
    their absolute offsets differ, so there is no cross-component chaining: the
    mode is ECB or a per-component reset. The first body block is code; under
    CTR its plaintext is `E(K,0) XOR C0`.
  - The staged oracle has a false-positive rate of about 0.5 records per
    hypothesis over the whole 16! search, with 99.92% clean-code recall.
  - The controls recover the correct key in all three modes; random plaintext is
    rejected. Every legacy hit is a random-magic false positive.
  - The first full-code run exposed two Stage-2 bugs: CBC must XOR with the
    previous ciphertext block, and the CTR counter word is the block index
    (big-endian word 3), not a byte-swapped value. Both were fixed and the
    controls re-run.
  - The hit counts match the exact-DP expectation (about 2.5 per container across
    five hypotheses). The KAT, FF, and last-round-key statuses are
    `KAT_NEGATIVE`, `FF_NEGATIVE`, and `RK_NEGATIVE`. The IV-permutation avenue
    is exhausted for the FMC under all tested modes.
- **Related:**
  - The [FMC container](#074-fmc-container-format-and-signature) supplies the
    c09 and c11 samples.
  - The [GA100 test-key search](#075-the-ga100-test-key-does-not-fit) covers the
    structured candidates.
- **Open question:** the remaining options are a different key derivation,
  family, or source; the intermediate round keys 1–9 (about 1.9 h); or hardware.
