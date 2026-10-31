#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# fmc_oracle.sh - vary exactly one host-built COT field and capture the FMC's
# answer.  Part of the BF16/FMC parser phase.
#
# Usage:
#   sudo ./fmc_oracle.sh <field> [value]
#
#   field 0   stock; clears any override
#         1   frtsVidmemSize              (default 0x80000 = half)
#         2   frtsVidmemOffset            (default 0)
#         3   gspBootArgsSysmemOffset     (default 0)
#         4   gspFmcSysmemOffset          (default 0)
#         5   hash384[0] ^= value         (default 1; signature-check control)
#         6   self-signed COT key + signature (value unused; key-anchor test)
#
# The value is a C integer literal (decimal or 0x...).
#
# One run = set the two BF16_COT_* defines in kern_fsp_gh100.c, incremental
# rebuild, load the instrumented 595.91.07 modules, capture dmesg, restore the
# stock DKMS driver in dump_ctx.sh's exit trap.  No context dumps and no CUDA
# probe are performed (EXITMAX=0, MAXDUMPS=0, GLOBALMAX=0, --no-trigger).
#
# Safety: no register or firmware writes; the only change is the value the
# host puts in its own COT message.  A refused boot is recoverable by the
# stock-driver restore; a hung ioctl may require a reboot.
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
HARNESS="$TOOL_DIR/dump_ctx.sh"

case "${1:-}" in
    0|1|2|3|4|5|6) VARY="$1" ;;
    *)
        echo "usage: sudo $0 <0|1|2|3|4|5|6> [value]" >&2
        exit 2
        ;;
esac

VALUE="${2:-}"
if [ -z "$VALUE" ]; then
    case "$VARY" in
        0) VALUE=0 ;;
        1) VALUE=0x80000 ;;
        2|3|4) VALUE=0x0 ;;
        5) VALUE=0x1 ;;
        6) VALUE=0 ;;
    esac
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
[ -x "$HARNESS" ] || { echo "missing $HARNESS" >&2; exit 1; }

sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY $VARY/" "$SRC" \
    || { echo "could not set BF16_COT_VARY" >&2; exit 1; }
sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE ${VALUE}ULL/" "$SRC" \
    || { echo "could not set BF16_COT_VALUE" >&2; exit 1; }

# Clear the WprMeta override so this run varies only a COT field.
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
if [ -f "$GSP_SRC" ]; then
    sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 0/" "$GSP_SRC" \
        || { echo "could not clear BF16_WPR_VARY" >&2; exit 1; }
    sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0ULL/" "$GSP_SRC" \
        || { echo "could not clear BF16_WPR_VALUE" >&2; exit 1; }
fi

# Clear the SRMeta override too: an SR value left armed by a hung suspend must
# not ride along into a COT run.
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
if [ -f "$SR_SRC" ]; then
    sed -i -E "s/^#define BF16_SR_VARY .*/#define BF16_SR_VARY 0/" "$SR_SRC" \
        || { echo "could not clear BF16_SR_VARY" >&2; exit 1; }
    sed -i -E "s/^#define BF16_SR_VALUE .*/#define BF16_SR_VALUE 0ULL/" "$SR_SRC" \
        || { echo "could not clear BF16_SR_VALUE" >&2; exit 1; }
fi

echo "== BF16 FMC oracle: field=$VARY value=$VALUE"
grep -n "^#define BF16_COT_" "$SRC"
echo

env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 \
    "$HARNESS" --no-trigger
rc=$?

OUT=$(ls -dt "$TOOL_DIR"/runs/ctxdump_* 2>/dev/null | head -1)
if [ -n "${OUT:-}" ] && [ -f "$OUT/dmesg.txt" ]; then
    echo
    echo "== oracle lines from $OUT"
    grep -E "BF16: COT|BF16: WprMeta|BF16: FMC boot|Fatal GSP-FMC|RmInitAdapter|Xid|NVRM: GPU[0-9]" \
        "$OUT/dmesg.txt" | tail -40
    echo
    echo "== run dir: $OUT"
fi

exit "$rc"
