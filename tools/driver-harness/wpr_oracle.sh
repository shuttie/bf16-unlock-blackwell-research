#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# wpr_oracle.sh - vary exactly one host-filled GspFwWprMeta field and capture
# the FMC's answer.  Part of the BF16/FMC parser phase.
#
# Usage:
#   sudo ./wpr_oracle.sh <field> [value]
#
#   field 0  stock; clears any override
#         1  magic              (default 0xdeadbeefdeadbeef; plumbing control)
#         2  revision           (default 2; stock is 1)
#         3  verified           (default 0xa0a0a0a0a0a0a0a0)
#         4  fbSize             (default 0)
#         5  frtsSize           (default 0x200000)
#         6  gspFwHeapSize      (default 0)
#         7  nonWprHeapSize     (default 0)
#      8..16  bootloader description, signature, and radix3 sizes/addresses
#        17  signature address + delta   (value required)
#        18  radix3 address + delta      (value required)
#
# The value is a C integer literal (decimal or 0x...).
#
# The host fills this 256-byte structure and the FMC reads it from sysmem at
# gspRmDescOffset, so every field here is host-controlled parser input.  Each
# run clears the COT override so exactly one field changes.  One run = set the
# two BF16_WPR_* defines, incremental rebuild, load the instrumented 595.91.07
# modules, capture dmesg, restore the stock DKMS driver in dump_ctx.sh's trap.
#
# Safety: no register or firmware writes; the only change is what the host
# puts in its own WprMeta structure.
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
HARNESS="$TOOL_DIR/dump_ctx.sh"

case "${1:-}" in
    0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18) VARY="$1" ;;
    *)
        echo "usage: sudo $0 <0..18> [value]" >&2
        echo "  8 sizeOfBootloader  9 sysmemAddrOfBootloader" >&2
        echo " 10 bootloaderCodeOffset 11 DataOffset 12 ManifestOffset" >&2
        echo " 13 sysmemAddrOfSignature 14 sizeOfSignature" >&2
        echo " 15 sysmemAddrOfRadix3Elf 16 sizeOfRadix3Elf" >&2
        echo " 17 signature address + delta 18 radix3 address + delta" >&2
        exit 2
        ;;
esac

VALUE="${2:-}"
if [ -z "$VALUE" ]; then
    case "$VARY" in
        0) VALUE=0 ;;
        1) VALUE=0xdeadbeefdeadbeef ;;
        2) VALUE=0x2 ;;
        3) VALUE=0xa0a0a0a0a0a0a0a0 ;;
        5) VALUE=0x200000 ;;
        8) VALUE=0x47001 ;;                # stock size + 1
        9) VALUE=0x0 ;;                    # invalid bootloader address
        10|11|12) VALUE=0xffffffff ;;      # wild in-image offsets
        13) VALUE=0x0 ;;                   # invalid signature address
        14) VALUE=0x100000 ;;              # oversized signature
        15) VALUE=0x0 ;;                   # invalid ELF address
        16) VALUE=0x100000 ;;              # oversized ELF
        17|18)
            echo "field $VARY needs an explicit delta" >&2
            exit 2 ;;
        *) VALUE=0 ;;
    esac
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ -f "$GSP_SRC" ] || { echo "missing $GSP_SRC" >&2; exit 1; }
[ -f "$FSP_SRC" ] || { echo "missing $FSP_SRC" >&2; exit 1; }
[ -x "$HARNESS" ] || { echo "missing $HARNESS" >&2; exit 1; }

# Clear the COT override so this run varies only a WprMeta field.
sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$FSP_SRC" \
    || { echo "could not clear BF16_COT_VARY" >&2; exit 1; }
sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$FSP_SRC" \
    || { echo "could not clear BF16_COT_VALUE" >&2; exit 1; }

sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY $VARY/" "$GSP_SRC" \
    || { echo "could not set BF16_WPR_VARY" >&2; exit 1; }
sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE ${VALUE}ULL/" "$GSP_SRC" \
    || { echo "could not set BF16_WPR_VALUE" >&2; exit 1; }

# Clear the SRMeta override too: an SR value left armed by a hung suspend must
# not ride along into a WprMeta run.
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
if [ -f "$SR_SRC" ]; then
    sed -i -E "s/^#define BF16_SR_VARY .*/#define BF16_SR_VARY 0/" "$SR_SRC" \
        || { echo "could not clear BF16_SR_VARY" >&2; exit 1; }
    sed -i -E "s/^#define BF16_SR_VALUE .*/#define BF16_SR_VALUE 0ULL/" "$SR_SRC" \
        || { echo "could not clear BF16_SR_VALUE" >&2; exit 1; }
fi

echo "== BF16 WprMeta oracle: field=$VARY value=$VALUE"
grep -n "^#define BF16_COT_" "$FSP_SRC"
grep -n "^#define BF16_WPR_" "$GSP_SRC"
echo

env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 \
    "$HARNESS" --no-trigger
rc=$?

OUT=$(ls -dt "$TOOL_DIR"/runs/ctxdump_* 2>/dev/null | head -1)
if [ -n "${OUT:-}" ] && [ -f "$OUT/dmesg.txt" ]; then
    echo
    echo "== oracle lines from $OUT"
    grep -E "BF16: WPR VARY|BF16: WprMeta|BF16: COT|Fatal GSP-FMC|RmInitAdapter|Xid|NVRM: GPU[0-9]|FSP response" \
        "$OUT/dmesg.txt" | tail -40
    echo
    echo "== run dir: $OUT"
fi

exit "$rc"
