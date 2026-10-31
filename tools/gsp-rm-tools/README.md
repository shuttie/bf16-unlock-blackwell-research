# GSP-RM tools

Ghidra 12.2 helpers, a raw reference scanner, a module splitter, and an offline
decoder for the GSP-RM log rings. Everything works on the plaintext `gsp_ga10x.bin`
image, so none of it needs the GPU to be running.

## Layout

| File | Purpose |
|---|---|
| `DecompileAt.java` | Create a function and decompile it, optionally following callees |
| `DisasmAt.java`, `DisasmRange.java`, `DisasmRanges.java` | Disassemble a function or an address range |
| `FuncAt.java`, `Refs.java`, `Blocks.java`, `PrevInsns.java`, `Fwd.java`, `Back.java` | Navigation helpers for references, blocks, and nearby instructions |
| `DecompileAll.java`, `ParallelDecompileAll.java` | Bulk decompilation |
| `ghidra.sh` | Serialized read-only `analyzeHeadless` wrapper |
| `refscan.py` | Raw-byte reference scan for RISC-V `JAL`, `AUIPC+ADDI`, `LUI+ADDI`, and literals |
| `module_split.py`, `module_split_v2.py` | Seed and Louvain split of the decompiled dump into module files |
| `annotate_strings.py`, `community_probe.py` | String annotation and community diagnostics |
| `build_id_table.py` | Build the log metadata-ID table |
| `build_init_strings.py` | Recover exact text for the early log writer |
| `gsp_log_decode.py` | Parse raw log rings and join them to functions |
| `selftest.py` | Synthetic round-trip tests for the decoder |
| `init_strings.csv`, `id_table_summary.json` | Recovered text and the last table summary |

## Inputs

You need three local inputs. None of them are shipped here.

1. `gsp_ga10x.bin` from your driver package. The `.fwimage` section is at file
   offset `0x40` and is `72,830,976` bytes.
2. A decompiled C dump of that image, produced by Ghidra at base `0x01000000`.
   `DecompileAll.java` writes it.
3. A module directory from `module_split_v2.py`. The ID table builder uses it for
   module names.

Set them once:

```bash
export FWIMAGE=/path/to/gsp_fwimage.bin
export DECOMPILED=/path/to/gsp_decompiled.c
export MODULES=/path/to/modules_v2
```

## Ghidra setup

Install Ghidra 12.2 and Java 25. Import `gsp_fwimage.bin` at base `0x01000000`
into a project named `gsp_full`, with the program name `gsp_fwimage.bin`.
`ghidra.sh` expects:

```bash
export GHIDRA_HOME=/path/to/ghidra_12.2_PUBLIC
export PROJ=/path/to/project        # default: ./project
export SCRIPTS=$(pwd)               # default: this directory
```

Examples:

```bash
./ghidra.sh DisasmRange.java 0x15ffae8,8
./ghidra.sh DecompileAt.java out.c 0x15ffae8,0x15ff1dc 1 120
./ghidra.sh Refs.java 0x015ffae8
```

The wrapper runs `-noanalysis -readOnly`, serializes access with `flock`, and
sets `GHIDRA_HEADLESS_MAXMEM` to `8G` by default.

## Reference scanner

`refscan.py` scans every 2-byte offset, handles RVC boundaries, and sign-extends
the `auipc` immediate correctly.

```bash
python3 -I refscan.py "$FWIMAGE" 0x01f3a958 0x01f3a970
```

Expected output for the two registry strings:

```text
0x015cf1be  auipc+addi -> 0x01f3a958
0x015cf1ea  auipc+addi -> 0x01f3a970
```

The same scan is used to find the five materializations of the FEAT decoder and
the indirect-call slot loads. Raw literals and `lui+addi` forms are included;
do not conclude "unreferenced" from a Ghidra reference list alone.

## Module splitter

```bash
python3 -I module_split_v2.py \
  --input "$DECOMPILED" --image "$FWIMAGE" --outdir "$MODULES" \
  --resolution 3.0
```

It needs `networkx`. The result is one C file per module plus an index and a
summary. On the 595.91.07 image the split covers `22,941` functions in `69`
modules; `feat_rate` is empty, which is itself a useful negative result.

`module_split.py` is the earlier, simpler splitter and takes explicit
`--input`/`--outdir` arguments.

## Log decoder

GSP-RM writes per-task log rings into host-allocated cached sysmem. The decoder
recovers a function-level trace without `gsp_log_ga10x.bin`, the logging ELF
that NVIDIA does not ship.

### Record format

```text
ring[0]      total 64-bit words ever written; monotonic
ring[1..L]   ring data, L = buffer_size/8 - 1

record       [arg0][arg1]...[arg(N-2)][meta][timestamp]
meta         47:0  metadata VA - per-task base
             55:48 N, total 64-bit entries (2..22)
             63:56 libos task id
```

The metadata word is second-to-last. `N = argumentCount + 2`.

### Task bases

| Task | ID | Base | Note |
|---|---:|---:|---|
| KERNEL | 1 | unknown | captured IDs are not referenced in `.fwimage` |
| INIT | 2 | `0x20183000` | writer `FUN_ram_011849a6` |
| RM | 3 | `0x2018f000` | writer `FUN_ram_01b9e86e` |
| INTR | 4 | `0x2018f000` | |
| ROOT | 8 | `0x2018f000` | partial |
| RMON | 9 | `0x2018f000` | partial |

### Build the ID table

```bash
python3 -I build_id_table.py \
  --decompiled "$DECOMPILED" --image "$FWIMAGE" --modules "$MODULES" \
  --out id_table.csv --summary id_table_summary.json
```

Expected: `63,612` rows, `30,568` decompiled call sites plus `33,044` raw-scan
IDs; `58,736` distinct RM IDs, `184` INIT, `75` early. The big `id_table.csv` is
generated, not committed. `selftest.py` needs it:

```bash
python3 -I selftest.py
```

### Decode

```bash
python3 -I gsp_log_decode.py --manifest run/manifest.json --stats
python3 -I gsp_log_decode.py --manifest run/manifest.json --merge --time-unit ms
python3 -I gsp_log_decode.py --manifest run/manifest.json \
  --filter-module gr_fecs --format jsonl
```

Example text output:

```text
# buffer 2: gsp_log_gpu0_2_rm.bin gpu=0 hint=RM size=65536B capacity=8191 put=0x1a2c records=57 wrapped=True
[     +0.000000 ms] t=3 RM      id=0x203b9b10 n_args=2  FUN_ram_0119bc28 [rm_core]  args=[0x1, 0x20000000]
[     +0.041216 ms] t=3 RM      id=0x203b9b28 n_args=0  FUN_ram_0119bc28 [rm_core]  args=[]
[     +0.041700 ms] t=2 INIT    id=0x201795c0 n_args=1  FUN_ram_01179d2e [logging_debug]  args=[0x5]  text="handleWdtEvent(27): Failed to reset SK watchdog, rc=%x"
```

A live capture of both cards produced `173` records per card with identical
`(task, ID, argc)` sequences; `141/173` resolve to a function. The decoder
cannot recover RM/INIT format strings, source lines, or severity without the
logging metadata; the early writer's `31` literal fallbacks are recovered exactly
by `build_init_strings.py`.

### Capture

The ring buffers are ordinary sysmem. Use the instrumented driver in
[the driver harness](../../tools/driver-harness/) to dump them at unload, then point the
decoder at the manifest. The manifest format is:

```json
{
  "gpu": 0,
  "buffers": [
    {"path": "gsp_log_gpu0_0_init.bin", "task": "init", "size": 65536},
    {"path": "gsp_log_gpu0_1_intr.bin", "task": "intr", "size": 65536},
    {"path": "gsp_log_gpu0_2_rm.bin",   "task": "rm",   "size": 65536}
  ]
}
```

## Access

Offline. No GPU, no kernel module, no register access. Everything reads local
files and writes local generated tables.

## Related

- [FECS and GR context experiments](../../experiments/03_fecs-and-gr-context.md)
- [HS / SEC2 / FSP memory experiments](../../experiments/04_hs-sec2-fsp-memory.md)
- [Firmware and vBIOS corpus](../../experiments/07_plaintext-corpus.md)
- [Assessment and cross-checks](../../experiments/08_assessment-and-cross-checks.md)
- [Firmware formats](../../specs/04_firmware-formats.md)
- [Errors and logging](../../specs/08_errors-and-logging.md)
- [Driver harness](../../tools/driver-harness/)
- [FMC tools](../../tools/fmc-tools/)
