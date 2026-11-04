# Corpus diff

## At a glance

- **What it does.** Splits GSP-RM firmware images into their libos manifest
  modules, compares modules and strings across driver versions, and censuses
  FMC container headers.
- **Access.** Offline. No GPU, no root, no network.
- **Inputs.** Your own GSP-RM `.fwimage` / `gsp.bin` files and FMC containers
  from driver packages. No firmware ships here.
- **Outputs.** Printed module tables, string deltas, and header tables. No
  files are written.

**The short version.**

- The libos manifest lists each module as a NUL-terminated name padded to 8
  bytes, then `flags, reserved, align, offset, size, count, entryptr` as u64
  words. Short names such as `rm.elf` shift every field by 8 against a
  16-byte name slot, so fields are read from the padded name end.
- The [cross-version corpus
  diff](../../experiments/17_cross-version-corpus-diff.md) used the split to
  date the module set per branch and to find the secure-boot string families
  that vanish from the 615 image.
- The header census extends [the container
  census](../../experiments/16_crypto-model-compare.md#165-the-container-census-names-the-chips-and-the-keys)
  across versions: one table for magic, sizes, flags, and tail bytes.

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
| `corpus_diff.py` | Module split, cross-version compare, header census |

## Run

```bash
python3 -I corpus_diff.py split gsp_fwimage.bin
python3 -I corpus_diff.py compare gsp570_fwimage.bin gsp_fwimage.bin 570 595
python3 -I corpus_diff.py headers 570-lf=fmc570.bin 615-prod=fmc615.bin
```

`split` prints one row per manifest module: file offset, size, SHA-256 prefix,
zero-byte fraction. `compare` prints per-module size and hash changes, then
string deltas filtered to a security namespace (`UDE`, `DEVINIT`, `WPR`, `PLM`,
`FUSE`, `SEC2`, signature and key terms). `headers` takes `label=path` pairs
and prints the FMC container header fields plus a body-layout check.

## Inputs and outputs

- `split` needs a libos-container GSP-RM image with a manifest within 32 KiB
  below the first ELF. The manifest base is solved from the first
  `kernel_*` module offset.
- `compare` also derives the manifest of the second image; modules present in
  only one image are listed, and byte-identical modules are skipped in the
  string pass.
- `headers` needs whole FMC containers (the `0x48`-byte header included).

## Access

Read-only. Nothing writes a GPU register, and nothing needs a card.

## Limits

- The manifest parser covers the name-slot layout of 570.144, 595.91.07, and
  615.78.08 images. A restructured manifest needs new offsets.
- The string delta over an encrypted module (`rm.bindata.bin`) is ciphertext
  noise; read it only for plaintext modules.
- The security namespace is a fixed keyword list, not a parser.

## Related

- [Crypto compare](../crypto-compare/) joins ciphertext across versions; this
  tool diffs the plaintext layers.
- [GSP-RM tools](../gsp-rm-tools/) decompile one image.

## License

MIT.
