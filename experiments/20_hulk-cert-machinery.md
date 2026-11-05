# The HULK certificate machinery

## Summary

**The idea.**

- The vendor's own unlock mechanism — signed certificates that execute
  register overrides — was measured on GA100 by the public record: HULK
  certificates in a flash license region, targeting
  `FUSE_FEATURE_OVERRIDE` (`0x823800`), the GA100 ancestor of the GB202 FEAT
  bank. Nothing in this record said whether the machinery survived into
  Blackwell.
- I censused the GB202 GSP-RM plaintext for the certificate vocabulary
  (HULK, HLK, BCRT, ULF, UPR, FWSECLIC) across the 570, 595, and 615
  images, and checked the local vBIOS dumps for the flash-side structures.

**What it found.**

- The machinery is alive on GB202 and named: the 595 RM carries a 63-string
  HULK/BCRT cluster — certificate parsing (`CERT20`, `CERT21`, `BCRT2X_VDPA`
  with named buffer-size and entry checks), InfoROM sourcing
  (`UL_GLOB`, `HLK` objects), device matching (`STRICT_ID_DEVID/ECID`),
  a fused signature scheme (`3AES` against `GPU_FUSE`), and an executor that
  runs certificate opcodes on SEC2 with register read-back verification
  ([20.1](#201-the-certificate-cluster-in-the-rm-plaintext)).
- The cluster is identical in 570 and absent from the 615 image, matching
  the string-removal boundary ([20.1](#201-the-certificate-cluster-in-the-rm-plaintext)).
- The GB202 vBIOS carries no certificate structures, so the cert source on
  Blackwell is the InfoROM, a flash region outside every dump this project
  has taken ([20.2](#202-the-vbios-is-not-the-source)).

**What it did not find.**

- No certificate bytes, no parser code walked, no InfoROM dump. The strings
  name the path; the handlers sit unread in the FWSEC-LIC code region.

## Experiments

| ID | Experiment | Result |
|---|---|---|
| 20.1 | [The certificate cluster in the RM plaintext](#201-the-certificate-cluster-in-the-rm-plaintext) | 63 strings, 570 = 595, 615 = 0 |
| 20.2 | [The vBIOS is not the source](#202-the-vbios-is-not-the-source) | No LU/HLK structures in any dump |

## 20.1 The certificate cluster in the RM plaintext

**Question.** Does the GB202 RM firmware carry the GA100 certificate
machinery, and what does it name?

**Why.**

- The GA100 public record ([comparison
  gist](https://gist.github.com/nvlight/fc7479629b0ace094873e58ba7d75eb2))
  maps the vendor unlock as HULK certificates: a flash license region with a
  `LU` header and `LIC`/`ULF`/`UPR`/`HLK` slots, certificates signed with a
  shared secret, admission that fails only at signature verification
  (`0x006D`), and production certificates in the wild that target
  `FUSE_FEATURE_OVERRIDE` with `STRICT_ID_MATCH=NO`.
- If the mechanism survives on GB202, it is the vendor's own override path —
  a parser surface and an authorization question, in the readable plaintext
  quarter.

**Method.**

- Offline. Byte-substring counts over the 570, 595, and 615 GSP-RM images
  and the 615 ucode container for `HULK`, `HLK`, `BCRT`, `ULF`, `UPR`,
  `UL_GLOB`, `FWSECLIC`; full-string extraction of every cluster member in
  the 595 image. Working scripts in `analysis-tmp/c38/work/`.

**Observed data.**

```text
                          570      595      615
HULK                      25       25       0
BCRT2X                    5        5        0
UL_GLOB                   1        1        0
FWSECLIC                  128      128      0

595 cluster, selected (first offsets 0xef466e..0xef555d, inside rm.elf):
  NV_FWSECLIC_ERR_CODE_CMD_VBIOS_VERIFY_HULK_INIT_FAIL
  NV_FWSECLIC_ERR_CODE_CERT_HULK_INFOROM_NOT_FOUND
  NV_FWSECLIC_ERR_CODE_CERT_HULK_INFOROM_UL_GLOB_NOT_FOUND
  NV_FWSECLIC_ERR_CODE_CERT_HULK_INFOROM_HLK_OBJ_NOT_VALID
  NV_FWSECLIC_ERR_CODE_CERT_HULK_DEVID_MISMATCH
  NV_FWSECLIC_ERR_CODE_CERT_HULK_NO_ID_MATCH_FOUND
  NV_FWSECLIC_ERR_CODE_CERT_HULK_STRICT_ID_DEVID_MISMATCH
  NV_FWSECLIC_ERR_CODE_CERT_HULK_STRICT_ID_ECID_MISMATCH
  NV_FWSECLIC_ERR_CODE_CERT_HULK_DATA_BUFFER_TOO_SMALL
  NV_FWSECLIC_ERR_CODE_CERT_HULK_OPCODE_UNDEFINED
  NV_FWSECLIC_ERR_CODE_CERT_HULK_REG_READ_BACK_VERIFY_MISMATCH
  NV_FWSECLIC_ERR_CODE_CERT_HULK_REG_RMW_RBV_READ_BACK_VERIFY_MISMATCH
  NV_FWSECLIC_ERR_CODE_CERT_HULK_UCODE_NOT_EXECUTING_ON_SEC2
  NV_FWSECLIC_ERR_CODE_VERIFY_ENG_HULK_3AES_SIG_MISMATCH_WITH_GPU_FUSE
  NV_FWSECLIC_ERR_CODE_VERIFY_ENG_HULK_NO_3AES_SIG
  NV_FWSECLIC_ERR_CODE_VERIFY_LICENSE_UGPU_SIG_INVALID
  NV_FWSECLIC_ERR_CODE_UGPU_PROCESSING_FAILED_INVALID_ULF_OBJECT
  NV_FWSECLIC_ERR_CODE_UGPU_PROCESSING_FAILED_INVALID_UPR_OBJECT
  NV_FWSECLIC_ERR_CODE_CERT20_VDPA_CERT_INTBLK_MISMATCH
  NV_FWSECLIC_ERR_CODE_CERT21_CERT_VERSION_UNEXPECTED
  NV_FWSECLIC_ERR_CODE_BCRT2X_VDPA_INTBLK_BUFFER_SIZE_OVERFLOW
  NV_FWSECLIC_ERR_CODE_BCRT2X_VDPA_INTBLK_ENTRIES_NUMBER_OVERLIMIT
  NV_FWSECLIC_ERR_CODE_BCRT2X_VDPA_INTBLK_ENTRIES_INVALID_ENTRY_TYPE
  NV_FWSECLIC_ERR_CODE_BCRT2X_VDPA_UNEXPECTED_MAJOR_TYPE
  NV_FWSECLIC_ERR_CODE_BCRT2X_VDPA_UNEXPECTED_PCI_CODE_TYPE
  NV_FWSECLIC_ERR_CODE_CERT_HULK_ACR_BIN_LOADED
  NV_FWSECLIC_ERR_CODE_CERT_HULK_SCRUBBER_BIN_NOT_COMPLETED_ON_VPR_SKU
  NV_FWSECLIC_ERR_CODE_CERT_HULK_UDE_NOT_COMPLETED_ON_NON_VPR_SKU
```

**Result.**

- **Answer:** the HULK machinery is alive on GB202 and string-mapped. The
  error names describe a full chain: certificates sourced from InfoROM
  `UL_GLOB`/`HLK` objects, parsed as `CERT20`/`CERT21` through the
  `BCRT2X_VDPA` reader with explicit buffer and entry checks, matched to the
  device by DEVID and ECID with a strict mode, signed with a `3AES` scheme
  checked against GPU fuses, and executed as opcodes on SEC2 that perform
  register read-modify-write with read-back verification.
- **What we learned:**
  - The vendor's override vehicle on GB202 is a certificate-executed
    register-write engine — the ancestor of the Redfish `HardwareUnlock`
    token, and the GA100 record's `FUSE_FEATURE_OVERRIDE` target is the same
    address family as the FEAT bank (`0x8238xx`).
  - The signature is fused (`3AES` against `GPU_FUSE`), so a leaked
    production certificate signed for another device fails ECID matching
    unless `STRICT_ID` is off — the GA100 leaked certs carried
    `STRICT_ID_MATCH=NO`, and the strict-mode strings exist here.
  - The `BCRT2X_VDPA` reader has named bounds checks; a parser whose checks
    are named is a parser whose checks can be read, and the handlers sit in
    the readable quarter (the FWSEC-LIC code region).
- **Related:** the [HULK certificate path](../IDEAS.md#hulk-certificate-path)
  lead carries the next runs; [the string
  removal](17_cross-version-corpus-diff.md#173-the-secure-boot-strings-vanish-in-615)
  explains the 615 zero.

## 20.2 The vBIOS is not the source

**Question.** Do the local GB202 flash dumps carry the license-region
structures the GA100 record found in vBIOS?

**Why.**

- On GA100 the certificate region is a vBIOS flash area (`LU` header, slot
  table, `HLK` slot). If GB202 kept that, the 1 MiB dumps already in hand
  would contain it.

**Method.**

- Offline. Substring counts over every flash dump in the working tree:
  `rombar_41/c1`, `flash_41/c1`, `flash1m_41/c1`, `prom_full_41/c1`.

**Observed data.**

```text
7 dumps x {HULK, BCRT, HLK, 00 LU 00}: 0 hits
the 1 MiB image above 0xF7B18 is sentinel fill (the DEVINIT bounds, exp 18)
```

**Result.**

- **Answer:** no license region exists in the GB202 vBIOS. The certificate
  source named by the strings is the InfoROM — a separate flash region none
  of the current dumps cover.
- **What we learned:** a 5090 InfoROM dump is a new, cheap read target, and
  the `UL_GLOB`/`HLK` slot contents on a stock card are the base state of
  the whole path.
- **Related:** the InfoROM dump joins the lead's Try list.
