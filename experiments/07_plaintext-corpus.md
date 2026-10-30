# Firmware and vBIOS corpus

Static and saved-dump work on the images that ship with the driver: the host
driver, the GSP-RM firmware, the FMC and boot loader, and the board vBIOS.
[E13](#e13--the-computed-feat-readout-path-and-the-control-table-audit) also does
one live register read. No firmware or dump is redistributed.
Recorded 2026-10-25 to 2026-10-29 on driver 595.91.07.

## Hardware, tools, inputs

**Hardware.** 2× RTX 5090 (GB202, `10de:2b85`), driver and GSP-RM 595.91.07,
Linux. Offline work needs no GPU.
[E13](#e13--the-computed-feat-readout-path-and-the-control-table-audit) and the
vBIOS dumps in [E04](#e04--the-vbios-dump-and-analysis) /
[E47](#e47--the-full-vbios-aperture) need a live card and root.

**Tools.** [GSP-RM tools](../tools/gsp-rm-tools/),
[FMC tools](../tools/fmc-tools/), [vBIOS tools](../tools/vbios-tools/),
[Driver harness](../tools/driver-harness/), and
[Register access](../tools/register-access/).
[E05](#e05--fmc-container-and-signature-analysis) needs `cryptography`;
[E06](#e06--the-ga100-test-key-route-tested) needs `pycryptodome`;
[E13](#e13--the-computed-feat-readout-path-and-the-control-table-audit),
[E16](#e16--host-driver-source-audit), and
[E17](#e17--the-decoder-is-a-table-installed-hal-method) need Ghidra 12.2
(`$GHIDRA_HOME`) and a matching open kernel-modules checkout (`$NVIDIA_SRC`).

**Inputs.** Extract these from the installed 595.91.07 package; none are in this
repo:

- `nvidia.ko`: the package's `.ko.zst`, decompressed with `zstd -d`; 21,085,101 B.
- `gsp_fwimage.bin`: the `.fwimage` section of `gsp_ga10x.bin`; 72,830,976 B.
- `fmc.bin` and `bootloader.bin`: `/lib/firmware/nvidia/gb202/gsp/`, or the driver
  bindata.
- `flash_41.bin`, `flash_c1.bin`: 1 MiB vBIOS dumps from BAR0 + `0x338000`.
- `prom_full_41.bin`, `prom_full_c1.bin`: 2 MiB PROM apertures.

**Boot state and cost.** Offline work takes minutes. The live register read and
the vBIOS dumps take seconds and need root. Nothing flashes or writes firmware.
Offsets are tied to 595.91.07; a different package moves them.

**Terms.** The [boot chain](../specs/01_boot-chain.md) and
[privilege and rate control](../specs/02_privilege-and-rate-control.md) specs have
the full model.

| Term | Meaning |
|---|---|
| GSP-RM | The GPU's main firmware; runs at PL2 (Light Secure). |
| FMC | First-stage mutable firmware; signed and encrypted; runs at PL3 (Heavy Secure). |
| COT | Chain-of-trust boot message the host sends to the FMC. |
| WprMeta | Host-built boot descriptor consumed by the FMC. |
| FEAT bank | Register block holding speed-selector overrides. |
| `SS0` / `SS1` | The two SM speed-selector override words. |
| PLM | Per-block read/write permission mask. |
| GR | The graphics and compute engine. |
| FECS / GPCCS | GR front-end and context-switch microcode. |
| KAT | Known-answer test. |
| MD5-IV | The MD5 initialization vector; the GA100 test key is a permutation of its 16 bytes. |
| SPKI / DER | Public-key encoding used for the P-384 signature. |
| BIT | BIOS information table in the vBIOS. |
| PciAt / FwSec / ERoT / NVFW | The x86 option ROM, signed firmware images, external root of trust, and NVIDIA firmware marker. |

## E02 · PL3 component inventory

*2026-10-25 · Revision 2b · status: static*

**Question.** Which PL3 components are obtainable from the driver package?

**Instrument.** `readelf`, an entropy/string script over `nvidia.ko`, and the FMC
ELF wrapper.

**Method.**

1. `readelf -sW nvidia.ko` for `ksec2BinArchive*`, `kgspBinArchiveGspRmBoot_*`,
   `kgspBinArchiveGspRmFmc*`, and `kgspBinArchiveConcatenatedFMC*`.
2. Map symbols to file offsets: section 20 is `.rodata` at `0x434558`; file offset
   is `0x434558 + st_value`.
3. Compute Shannon entropy, printable-string counts, and prod/debug byte deltas.
4. Parse the FMC wrapper with `readelf -SW fmc.bin`.
5. Check the open GB100 HAL: `ConcatenatedFMC` is selected only under confidential
   compute; [E28](../experiments/05_fmc-fsp-boot-inputs.md) resolves this SKU to
   the ordinary path.

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

**Result.** Only TU102 (303 B) and AD10X (6,233 B) SEC2 images exist; GB202 ships
prod and debug GspRmBoot and FMC. All bodies are ≥7.98 bits/byte; FMC prod vs
debug differ in 99.6% of bytes, GspRmBoot in 98.4%.

**Reproduce.**

1. Decompress `nvidia.ko`; confirm 21,085,101 B.
2. Run the entropy script below with `.rodata` base `0x434558`.
3. `readelf -SW fmc.bin`; expect the four sections and `image` = `0x30a48`.

```bash
python3 - <<'EOF'
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
EOF
```

**Limits.** Offsets belong to this package. Entropy shows the bodies are opaque;
it does not identify the cipher.

## E03 · Boot-chain availability research

*2026-10-25 · Revision 3 · status: static; no ROM obtained*

**Question.** Can the FSP or GSP BootROM image be obtained from the host?

**Instrument.** A filesystem inventory, `nvidia-debugdump`, `/dev/nvdebug`, and the
PCI ROM BAR.

**Method.** List the installed GB202 firmware directory; search the firmware tree
for FSP/BootROM names; audit `nvidia-debugdump --help` and its strings; check for
`/dev/nvdebug` and `/sys/bus/pci/devices/<bdf>/rom`.

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

**Result.** No FSP or BootROM image exists in any package; no documented host read
path exists. Obtainable: the board vBIOS, the encrypted FMC, the plaintext GSP-RM.
The ROM BAR read stops at `0x27A00`;
[E04](#e04--the-vbios-dump-and-analysis) supersedes it with the full aperture.

**Reproduce.**

1. List `/lib/firmware/nvidia/gb202/gsp/`.
2. Search `/lib/firmware` for an FSP or BootROM image.
3. Check `nvidia-debugdump --help` and `/dev/nvdebug`; neither exposes a ROM.

**Limits.** Proves no host-readable FSP/BootROM image ships; not that the ROMs are
absent from the die.

## E04 · The vBIOS dump and analysis

*2026-10-25 · Revision 4 · status: static*

**Question.** What is in the board vBIOS, and does it carry a plaintext rate
constant or a FEAT address?

**Instrument.** [vBIOS tools](../tools/vbios-tools/): `vbios_probe`, `vbios_read`,
`parse_flash.py`, `bit_tokens.py`, and `devinit_scan.py`; Ghidra for the x86 option
ROM.

**Method.** Read-only. Set and clear the PCI ROM BAR enable bit at config `0x30`.
Dump the PROM aperture at BAR0 `0x300000`–`0x400000`; the image starts at
`0x338000`. Parse the image chain, BIT, microcode table, and descriptors; scan for
FEAT/FUSE constants and x86 MMIO stores; diff the two cards.

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

**Result.** Four real microcode images (`0x07`, `0x19`, `0x15`, `0x23`) and two
placeholders (`0x18`, `0x24`); all real bodies encrypted; no FWSEC app IDs; no
FEAT/FUSE constants; 1,375 bytes differ between cards.
[E66](../experiments/05_fmc-fsp-boot-inputs.md) corrects the census and body
offsets.

**Reproduce.**

1. `sudo ../tools/vbios-tools/vbios_probe 0000:41:00.0 300000 100000`.
2. `sudo ../tools/vbios-tools/vbios_read 0000:41:00.0 flash_41.bin`.
3. `python3 ../tools/vbios-tools/parse_flash.py flash_41.bin`.
4. `python3 ../tools/vbios-tools/devinit_scan.py flash_41.bin`; expect no FEAT
   address and no devinit opcode in `0x823800`–`0x8238ff`.
5. Diff the two cards; expect 1,375 differing bytes.

**Limits.** This is the 1 MiB image, not the 2 MiB aperture
([E47](#e47--the-full-vbios-aperture)). The microcode bodies are encrypted; the
scan sees descriptors and plaintext tails.

## E05 · FMC container and signature analysis

*2026-10-25 · Revision 5 · status: static*

**Question.** What is the FMC container format, and what does the signature cover?

**Instrument.** A scan for the container magic, a header parser, DER/SPKI encoding,
and OpenSSL.

**Method.** Scan the 595.91.07 `nvidia.ko` for `03 04 48 00`; each container is
`0x48 + u32@+4` bytes. For signed images, split the `0xF8` bytes before the
container as `publickey[97] || pad[7] || signature[96] || hash[48]`. DER-encode the
key as SPKI (`ecPublicKey` + `secp384r1`) and the signature as
`SEQUENCE{INTEGER r, INTEGER s}`.

**Observed data.**

```text
c04 header: 03 04 48 00 00 62 04 00 ... 00 70 03 00 ... 00 e8 00 00 04 01 ...
c09 header: identical
keys: c04 04 8b f1 18 bb eb 9c 0f 5e a6 d4 a4
      c09 04 d3 0b d5 4b 30 cc 2c 1f 03 b5 44
body 0x46200 = code 0x37000 + data 0xE800 + 0xA00
openssl dgst -sha384 -verify c09_pub.pem -signature c09_sig.der c09.bin
Verified OK
openssl pkeyutl -verify ... -pkeyopt digest:sha384
Signature Verified Successfully
```

**Result.** For all 14 samples `body = code + data + 0xA00`. `hash` is SHA-384 over
the whole container, header included; the signature is `r || s`. Two keys verify:
production `04 8bf118bb…` (c00, c01, c04, c06) and debug `04 d30bd54b…` (c09, c11).
The other seven containers have a valid hash but no inline key block. Body entropy
7.999; ≤1 repeated 16-byte block per image; prod/debug XOR zero count 1,154 in
287,232 (chance rate).

**Reproduce.**

1. Extract `nvidia.ko` and scan for `03 04 48 00`; each container is
   `0x48 + u32@+4` bytes.
2. Split the `0xF8` prefix into `publickey[97] || pad[7] || signature[96] ||
   hash[48]`. Encode the key and signature with `cryptography`:

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

3. `openssl pkey -pubin -inform DER -in pub.der -out pub.pem`.
4. `openssl dgst -sha384 -verify pub.pem -signature sig.der c04.bin`; expect
   `Verified OK`.
5. `openssl pkeyutl -verify -pubin -inkey pub.pem -in hash.bin -sigfile sig.der
   -pkeyopt digest:sha384`; expect `Signature Verified Successfully`.

**Limits.** A valid signature proves NVIDIA signed the container; it says nothing
about the body plaintext or the encryption key.

## E06 · The GA100 test-key route, tested

*2026-10-25 · Revision 6 · status: CLOSED-STATIC*

**Hypothesis.** The GA100 AES-128-ECB debug test key (key #37, a permutation of the
MD5-IV bytes) also opens the GB202 debug FMC.

**Instrument.** A byte scan for the 16-byte KAT, a repeated-block count, and the
candidate search in [FMC tools](../tools/fmc-tools/).

**Method.**

1. Scan all FMC containers, the ELF-wrapped FMC, the linux-firmware boot loader,
   the 1 MiB vBIOS dump, and `nvidia.ko` for
   `AES-ECB(key37, 0×16) = 717d1494eaca317ff106195258b38377`.
2. Count repeated 16-byte blocks (ECB structure); the four vBIOS microcode bodies
   at descriptor `+0x50`, 8 KiB each.
3. Test 132,240 structured candidates derived from the MD5 IV with `pycryptodome`
   AES-ECB: word and byte orders, rotations, nibble swaps, ShiftRows permutations,
   key-schedule words, XOR/add constants, key-index variants.

**Observed data.**

```text
KAT: AES-128-ECB(key37, 0^16) = 717d1494eaca317ff106195258b38377
fingerprint hits: 0 in all 13 containers, nvidia.ko, flash_41.bin, flash_c1.bin
```

The 132,240-candidate search found no match. Hashcat cannot express "each of the
16 known bytes exactly once" (16¹⁶ ≈ 1.8 × 10¹⁹ vs 16! ≈ 2.09 × 10¹³). The full
permutation is ~1–3 h on two 5090s with the factoradic kernel in
[E73](#e73--fmc-body-layout-and-the-risc-v-validity-key-oracle).

**Result.** 0 fingerprint hits; ≤1 repeated block per FMC; vBIOS bodies 512/512
distinct; no key candidate matches.

**Reproduce.**

1. `pip install pycryptodome`.
2. Run `python3 ../tools/fmc-tools/key37_search.py` and
   `../tools/fmc-tools/key37_search2.py`; expect `no match among ... candidates`.
3. Scan every container and the driver/vBIOS dumps for the 16-byte KAT; expect
   zero hits.

**Limits.** Rules out the ECB/zero-padding shape for the test-key family. It does
not rule out the same key in CBC/CTR/XTS, or a compressed-then-ECB body.

## E13 · The computed FEAT readout path and the control-table audit

*2026-10-25 · Revision 13 · status: decoder found; audit corrected by
[E17](#e17--the-decoder-is-a-table-installed-hal-method)*

**Question.** Does the driver's rate getter reflect `FEAT_READOUT_1`, and does the
GR control table hide a setter?

**Instrument.** [Register access](../tools/register-access/) `ratev2` and
`throttle` on a live card, plus Ghidra 12.2 for the table and decoder.

**Method.** Decode every 32-byte record in `0x20801200`–`0x208012ff` as
`{ctrlId, paramSize}` and compare with the public GR control list in
[firmware formats](../specs/04_firmware-formats.md). Search the fused sub-offsets as
call arguments; decompile the decoder and its installer.

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

**Result.** `0x2080123e` is `GR_TEST_CTXSW_ERROR_LOGS`; the internal static-info
entries `0x20800b03` and `0x20800b05` are GET-only. The table has no hidden SET.
The getter is a copy-out of `KGRAPHICS_STATIC_INFO`, populated at GR init.

**Reproduce.**

1. `sudo ../tools/register-access/regops 1 0000:41:00.0 ratev2`; expect the
   10-entry list above.
2. `sudo ../tools/register-access/regops 1 0000:41:00.0 throttle`; expect one
   `MASK=0` entry.
3. Decompile the decoder and installer with the Ghidra wrapper in
   [GSP-RM tools](../tools/gsp-rm-tools/):

```bash
"$GHIDRA_HOME/support/analyzeHeadless" project gsp_full \
  -process gsp_fwimage.bin -noanalysis \
  -scriptPath ../tools/gsp-rm-tools \
  -postScript DecompileAt.java out.c 0x15ffae8 0 300
```

Expect the `0x3818` read and the `param_3[5]` extraction.

**Limits.** The getter is a boot-time cache, not a live hardware read. The
decoder's live caller is unproven; [E17](#e17--the-decoder-is-a-table-installed-hal-method)
covers that.

## E16 · Host-driver source audit

*2026-10-25 · Revision 14 · status: CLOSED-STATIC*

**Question.** Does the host driver contain a rate writer?

**Instrument.** `nm`, `size`, a 32/64-bit constant scan on `nvidia.ko`, and a diff
of the matching open kernel modules (`$NVIDIA_SRC`).

**Method.**

1. `nm -g --defined-only nvidia.ko` for the GB202 vGPU functions.
2. Trace the generated HAL dispatch table: GB202 → `kgspResetHw_GB100`,
   `kgspSetupGspFmcArgs_GH100`, `kgspBootstrap_GH100`.
3. Trace the vGPU call site; it runs only when `bVgpuGspPluginOffloadEnabled`.
4. History: the GB202 HAL file was introduced in `580.65.06` (2025-08-04).
5. Scan the tree for every rate literal; enumerate `NV_FUSE_ZB_*` uses: `0x3814`
   (ECC), `0x74c`, and the ucode version. All are reads.
6. Diff `570.153.02..595.91.07` for the GR init file and the GR control header: V2
   and throttle GETs were added; no SET.

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

**Result.** The host driver contains no rate writer; `nvidia.ko` has no literal
reference to the six rate registers.

**Reproduce.**

1. `zstd -d nvidia.ko.zst`; confirm 21,085,101 B.
2. `nm -g --defined-only nvidia.ko | grep kgspVgpu`; expect the two symbols.
3. Scan for each little-endian constant; expect zero.
4. With `$NVIDIA_SRC` at 595.91.07:

```bash
git -C "$NVIDIA_SRC" diff 570.153.02..595.91.07 -- \
  src/nvidia/src/kernel/graphics/kernel_graphics.c \
  src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gr.h
```

Expect the V2 and throttle GET additions and no SET.

**Limits.** A literal scan misses computed offsets (`base + 0x3818`), which is the
[E17](#e17--the-decoder-is-a-table-installed-hal-method) correction.

## E17 · The decoder is a table-installed HAL method

*2026-10-25 · Revision 15 · status: corrected static model*

**Hypothesis.** The FEAT decoder is installed through the per-chip HAL table and is
not dead code.

**Instrument.** A raw reference scan over `gsp_fwimage.bin` and Ghidra 12.2.

**Method.** Decode every 2-byte-aligned word and test `JAL`, `AUIPC+ADDI`,
`AUIPC+JALR`, `LUI+ADDI` with correct sign extension, plus raw u32/u64 and table
forms. Disassemble and decompile survivors with
[GSP-RM tools](../tools/gsp-rm-tools/).

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

**Result.** The decoder is materialized at five sites and installed in the HAL
object; it is not dead code. `FUN_ram_01acd340` has no static references, so the
instantiation path remains open.

**Reproduce.**

1. `python3 ../tools/gsp-rm-tools/refscan.py gsp_fwimage.bin 0x015ffae8`; expect
   the five hits above.
2. Disassemble around each hit with `DisasmRange.java`; expect `auipc/addi/sd`.
3. Decompile `FUN_ram_01c1c374` and `FUN_ram_01acd340`; check the five stores and
   the `0x3E40` object.

**Limits.** The materializations prove the decoder is installed; they do not prove
who calls `obj+0xC20`.

## E47 · The full vBIOS aperture

*2026-10-26 · Revision 46 · status: static corpus closed*

**Question.** Does the full 2 MiB PROM aperture contain a FEAT/`SS0`/`SS1` constant
or a plaintext devinit table that names the FEAT block?

**Instrument.** [vBIOS tools](../tools/vbios-tools/): `prom_read_raw`,
`bit_tokens.py`, and `devinit_scan.py`.

**Method.** Dump the 2 MiB aperture read-only; parse the image chain, BIT, and
microcode table; scan for FEAT/`SS0`/`SS1` constants and devinit opcodes; diff the
two cards' heads.

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

**Result.** Aperture map: `0x00000`–`0x38000` head (`NVFW` at `+0x1000`, 218 KiB
encrypted blob, plaintext board metadata); `0x38000`–`0x138000` the vBIOS image;
`0x138000`–`0x200000` the `0xBADF1100` sentinel. No FEAT address in any plaintext
table or script.

**Reproduce.**

1. `sudo ../tools/vbios-tools/prom_read_raw 0000:41:00.0 prom_full_41.bin`
   (defaults to the 2 MiB aperture).
2. `python3 ../tools/vbios-tools/bit_tokens.py prom_full_41.bin`.
3. `python3 ../tools/vbios-tools/devinit_scan.py prom_full_41.bin`; expect zero
   FEAT addresses and zero devinit opcodes in `0x823800`–`0x8238ff`.
4. Compare the two cards' heads; expect 790 differing bytes.

**Limits.** The 218 KiB head blob is encrypted; the scan covers the aperture, not
the encrypted microcode.

## E73 · FMC body layout and the RISC-V-validity key oracle

*2026-10-28 · status: layout CLOSED-MEASURED; oracle built and self-tested;
c09/c11 16! passes complete and negative under five hypotheses (2026-10-29)*

**Hypothesis.** The previous FMC 16! oracle accepted a key only if its first
decrypted block was a container or compression magic. If the encrypted body starts
with code, a correct key could have been discarded, and "family exhausted" would
not be established.

**Instrument.** The container extractor from [E05](#e05--fmc-container-and-signature-analysis),
the parcel-table builder and CUDA search in
[Driver harness](../tools/driver-harness/), and the two-GPU runner in
[FMC tools](../tools/fmc-tools/).

### Layout

**Method.** Extract the GB202 FMC containers (c04 prod, c09 debug) and the
`GspRmBoot_GB202` prod/debug images from `nvidia.ko` (`.rodata` at `0x434558`;
GspRmBoot at `0x4d6a58`/`0x51da78`; FMC at `0x15b040`/`0x25cf28`). Parse the
container header (`codeSize` at `+0x0C`, `dataSize` at `+0x14`) and the GspRmBoot
`WprMeta` geometry (manifest 0, data `0xA00`, code `0xF200`, size `0x47000`), then
compare region by region for both pairs.

**Observed data.**

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

**Result.** The body is `[code][data][manifest 0xA00]`; the manifest is the
GspRmBoot manifest; the FMC code is a prefix of the GspRmBoot code. The data and
manifest ciphertexts are identical although their absolute offsets differ between
the two images, so there is no cross-component chaining: the mode is ECB or a
per-component reset. The first body block is code; under CTR its plaintext is
`E(K,0) XOR C0`.

### Oracle

**Method.** `build_riscv_logp.py` extracts the loaded GSP-RM code segment (the ELF
at file `0x18F000`, `p_vaddr 0x01000000`, `0xDCD000` bytes; the largest of the 11
embedded ELF64 headers) and builds a 16-bit parcel histogram: 7,233,536 parcels,
entropy 11.588 bits, `p = (count+1)/(n+65536)`, quantized to `round(2*log2 p)`.
`key37_cuda.cu --fmc-riscv` Stage 1 decrypts block 0 in the ECB/CBC-zero and
CTR-zero hypotheses and sums eight table entries; Stage 2 decrypts 8 blocks for
Stage-1 survivors and scores the ECB and CBC-zero streams (mode 0) or the CTR
stream with counter = block index (mode 1). The compact AES kernel uses 12,872 B
shared, 118 registers, 2 blocks/SM, so the 64 KB table stays in L1.

**Observed data — calibration (19,481 GSP-RM function starts).**

```text
Stage 1 t1=-256 (3.8 sigma): 97.0% overall, 99.3% on clean code
Stage 2 8 blocks t2=-2102 (9 sigma): 99.92% of clean code
exact-DP staged random tail: 1.2e-14 per hypothesis
GSP-RM entry block score: -185 Q
```

**Result.** The staged false-positive rate is about 0.5 records per hypothesis over
the whole 16! search, with 99.92% clean-code recall. Modes tested: ECB,
CBC-zero, CTR-zero.

### Calibration and controls

**Method.** Build a synthetic container whose code component is the real GSP-RM
entry code, encrypt it under the rank-0 key (`POOL` in order), and check that the
oracle recovers exactly that key. Re-score the 12,260 legacy c09/c11 first-block
hits with the parcel model.

**Observed data.**

```text
rank-0 synthetic: key 01102332455467768998abbacddceffe rank 0 score -1533
  recovered in ECB (0), CBC-zero (1), CTR-zero (2); verifier accepts all
same key, random plaintext: hits=0
full-code walk: synthetic 0.046% invalid; random key 8.8% invalid
legacy re-score: c09 median -297 Q (min -323, max -246)
                 c11 median -297 Q (min -325, max -248)
                 random mean -296.4 Q (sigma 10.6)
                 above t1: 5/6,115 (c09), 2/6,145 (c11)
```

**Result.** The controls recover the correct key in all three modes; random
plaintext is rejected. Every legacy hit is a random-magic false positive. The
first full-code run exposed two Stage-2 bugs that the one-block path could not see:
CBC must XOR with the previous ciphertext block, and the CTR counter word is the
block index (big-endian word 3), not a byte-swapped value. Both were fixed and the
controls re-run.

### Runs

**Method.** Five hypotheses per key: ECB (0), CBC-zero (1), CBC with the container
header as IV (3), CTR start 0 (2), and CTR start 1 (4). CBC IV affects only block
0, so the two CBC variants share one stream; CTR start 1 costs one extra encrypt.
A true CBC key can hit both CBC modes as an expected pair; the genuine IV is the
higher-scoring one. Hit modes: 0/1/3 decrypt, 2/4 CTR. `fmc_riscv_verify.py`
knows modes 3 and 4 and walks the whole code component as RV32/64 instructions.

**Observed data.**

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

**Result.** The counts match the exact-DP expectation (~2.5 per container across
five hypotheses). The debug GB202 (c09) and 0x30500 (c11) FMCs are not decrypted
by any MD5-IV permutation under ECB, per-component CBC with a zero or header IV,
or CTR with counter start 0 or 1. The earlier three-mode c09 run was 0 hits; the
KAT, FF, and last-round-key statuses are `KAT_NEGATIVE`, `FF_NEGATIVE`, and
`RK_NEGATIVE`. The IV-permutation avenue is exhausted for the FMC under all tested
modes. Remaining options are a different key derivation, family, or source (the
intermediate round keys 1–9 are the only literal remainder, ~1.9 h), or hardware.

**Reproduce.**

1. Build the search binary:

```bash
nvcc -O3 -arch=sm_120 -U_GNU_SOURCE \
  -o key37_cuda ../tools/driver-harness/key37_cuda.cu
```

2. Build the parcel table:

```bash
python3 ../tools/driver-harness/build_riscv_logp.py \
  --fw gsp_fwimage.bin --out riscv_logp_q.bin
```

3. Run the end-to-end control:

```bash
python3 ../tools/driver-harness/riscv_oracle_selftest.py \
  --bin key37_cuda --blocks 8
```

4. Extract the c09 and c11 containers from `nvidia.ko` with the
   [E05](#e05--fmc-container-and-signature-analysis) recipe; save them as
   `c09.bin` and `c11.bin`.

5. Run the two-GPU search:

```bash
../tools/fmc-tools/run_fmc_riscv_2gpu.sh c09.bin out_c09
../tools/fmc-tools/run_fmc_riscv_2gpu.sh c11.bin out_c11 c09.bin
```

6. Merge the hit files and run `../tools/driver-harness/fmc_riscv_verify.py` on
   each container. Expect 0 valid bodies; chance hits are rejected at ~8.6–8.9%
   invalid instructions.

**Limits.** The search covers the MD5-IV permutation family under ECB,
CBC-zero/header-IV, and CTR start 0/1. It is not a general key search.
