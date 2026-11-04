# Crypto compare

## At a glance

- **What it does.** Offline ciphertext compares over the firmware corpus:
  extracts `rm.bindata.bin` from a GSP-RM image, joins two blobs on identical
  aligned 16-byte blocks, finds duplicated runs inside one blob, localizes
  differing bytes between two dumps, and converts generated driver bindata C
  arrays to binary.
- **Access.** Offline. No GPU, no root, no network.
- **Inputs.** Your own driver files and dumps: GSP-RM `.fwimage` files, vBIOS
  dumps, generated bindata `.c` files from the open kernel modules.
- **Outputs.** Printed statistics and optional extracted binaries. No firmware
  ships here.

**The short version.**

- The [crypto-model compare](../../experiments/16_crypto-model-compare.md) used
  these five operations to establish that the corpus keys are
  [not device-bound](../../experiments/16_crypto-model-compare.md#161-the-encrypted-vbios-is-card-independent)
  and [version-stable](../../experiments/16_crypto-model-compare.md#162-the-bindata-key-is-version-stable).
- The join counts blocks that are byte-identical at any relative offset, so a
  match means both files carry the same ciphertext, not the same layout.
- The self-join skips uniform blocks (all-zero blocks match themselves
  everywhere and say nothing).

**In this file.**

- [Layout](#layout)
- [Run](#run)
- [Inputs and outputs](#inputs-and-outputs)
- [Access](#access)
- [Limits](#limits)
- [Related](#related)
- [License](#license)

## Layout

| File | Purpose |
|---|---|
| `crypto-compare.py` | All five subcommands, standard library only |

## Run

```bash
python3 crypto-compare.py bindata gsp_fwimage.bin --out bindata.bin
python3 crypto-compare.py join bindata_570.bin bindata_595.bin
python3 crypto-compare.py selfjoin bindata_595.bin
python3 crypto-compare.py diff flash1m_41.bin flash1m_c1.bin \
  --region 0xb780c,0xd5a0c,ucode_app23
python3 crypto-compare.py carray g_bindata_...FmcGfwProdSigned_GB202.c \
  --outdir fmc615
```

`--min-run` (default `0x4000` for `join`, `0x1000` for `selfjoin`) sets the
smallest reported run; `--region` labels diff ranges against a `LO,HI,NAME`
map; `--top` caps the printed run list.

## Inputs and outputs

- `bindata` reads a GSP-RM `.fwimage`, parses the libos manifest, and writes
  the `rm.bindata.bin` extent.
- `join`/`selfjoin` print matched-block counts, the percentage of the first
  file covered, and the largest runs with their offsets.
- `diff` prints differing-byte counts, merged ranges, and per-region totals.
- `carray` prints each array's size and SHA-256 prefix and writes the binaries.

## Access

Read-only. Nothing writes a GPU register, and nothing needs a card.

## Limits

- The join aligns to 16-byte blocks, so a shared ciphertext stored at a
  non-multiple-of-16 shift is missed. The measured corpus shifts are
  multiples of 16.
- The manifest parser expects the module-name layout of driver 570.144 and
  595.91.07 images; a restructured manifest needs new offsets.
- `bindata` on 615-series images reports the shrunken in-image extent only;
  the engine ucode moved to the separate `ucodes` container there
  ([the 615 corpus](../../experiments/16_crypto-model-compare.md#166-the-615-corpus-splits-and-resigns-the-fmc)).

## Related

- [FMC tools](../fmc-tools/) search keys; this tool compares ciphertext.
- [GSP-RM tools](../gsp-rm-tools/) decompile the plaintext image.

## License

MIT.
