#!/bin/bash
#
# sig_oracle.sh - edit the host-supplied 4 KB GSP-RM signature buffer
# (.fwsignature_gb20x) before the FMC parses it, then capture the reply.
#
# The buffer is copied into unprotected sysmem by _kgspCreateSignatureMemdesc
# and its address reaches the FMC through WprMeta.sysmemAddrOfSignature.  The
# header is plaintext:
#
#   0x00 u32 magic/version   stock 0x00020001
#   0x04 u32 size            stock 0x000008c8
#   0x08 u32 count           stock 0x0000000c
#   0x0c u32 reserved        stock 0x00000101
#   0x10 u32 stride          stock 0x00000200
#   0x14 ... 384-byte blocks, high entropy
#
# Usage:
#   sudo ./sig_oracle.sh stock
#   sudo ./sig_oracle.sh xor  <off> [xor]           # buf[off] ^= xor
#   sudo ./sig_oracle.sh poke <off> <width> <value> # width 1, 2 or 4
#
# Env:
#   TREE   driver source checkout (default /home/shutty/open-gpu-kernel-modules)
#   BDF    target GPU (default 0000:41:00.0)
#   ROOT   repository root (default: three levels above this script)
#
# One run = set the BF16_SIG_* defines, incremental rebuild, load the
# instrumented 595.91.07 modules, capture dmesg, restore the stock DKMS driver.
# No register or firmware writes; the only change is the host's own buffer.
#
set -u

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:-/home/shutty/open-gpu-kernel-modules}"
BDF="${BDF:-0000:41:00.0}"
DH="$TOOL_DIR"
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
KFSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/kern_fsp.c"
HARNESS="$DH/dump_ctx.sh"

usage() {
    sed -n '2,32p' "$0"
}

DRY=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY=1
    shift
fi

MODE="${1:-}"
case "$MODE" in
    stock)
        MT=0; OFF=0x0; XOR=0x01; VAL=0; WIDTH=1 ;;
    xor)
        MT=1; OFF="${2:?xor needs an offset}"; XOR="${3:-0x01}"; VAL=0; WIDTH=1 ;;
    poke)
        MT=2; OFF="${2:?poke needs an offset}"
        WIDTH="${3:?poke needs a width (1, 2 or 4)}"
        VAL="${4:?poke needs a value}"; XOR=0x00 ;;
    *)
        usage; exit 2 ;;
esac

if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo $0 ...)" >&2
    exit 1
fi
for f in "$GSP_SRC" "$FSP_SRC" "$SR_SRC" "$KFSP_SRC" "$HARNESS"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

set_def() {  # file name value
    local f="$1" n="$2" v="$3"
    grep -qE "^#define $n[[:space:]]" "$f" || return 0
    sed -i -E "s/^#define $n[[:space:]]+.*/#define $n $v/" "$f"
}

# Exactly one oracle armed.  Everything else is returned to stock.
clear_all() {
    set_def "$GSP_SRC" BF16_WPR_VARY 0
    set_def "$GSP_SRC" BF16_WPR_VALUE 0ULL
    set_def "$GSP_SRC" BF16_BOOT_TAMPER 0
    set_def "$GSP_SRC" BF16_BOOT_OFF 0x0
    set_def "$GSP_SRC" BF16_BOOT_XOR 0x01
    set_def "$GSP_SRC" BF16_SIG_TAMPER 0
    set_def "$GSP_SRC" BF16_SIG_OFF 0x0
    set_def "$GSP_SRC" BF16_SIG_XOR 0x01
    set_def "$GSP_SRC" BF16_SIG_VALUE 0ULL
    set_def "$GSP_SRC" BF16_SIG_WIDTH 1
    set_def "$FSP_SRC" BF16_COT_VARY 0
    set_def "$FSP_SRC" BF16_COT_VALUE 0ULL
    set_def "$FSP_SRC" BF16_FMCDUMP 0
    set_def "$FSP_SRC" BF16_ICD_HALT 0
    set_def "$FSP_SRC" BF16_ICD_TRACE 0
    set_def "$KFSP_SRC" BF16_FMCDUMP 0
    set_def "$SR_SRC" BF16_SR_VARY 0
    set_def "$SR_SRC" BF16_SR_VALUE 0ULL
}

clear_all
set_def "$GSP_SRC" BF16_SIG_TAMPER "$MT"
set_def "$GSP_SRC" BF16_SIG_OFF "$OFF"
set_def "$GSP_SRC" BF16_SIG_XOR "$XOR"
set_def "$GSP_SRC" BF16_SIG_VALUE "$VAL"
set_def "$GSP_SRC" BF16_SIG_WIDTH "$WIDTH"

echo "== BF16 signature oracle: mode=$MODE off=$OFF width=$WIDTH value=$VAL xor=$XOR"
grep -nE "^#define BF16_(SIG|WPR|BOOT)_" "$GSP_SRC"
grep -nE "^#define BF16_COT_" "$FSP_SRC"
echo

if [ "$DRY" -eq 1 ]; then
    echo "== dry run: defines applied, build not started"
    exit 0
fi

export TREE BDF ROOT
env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 "$HARNESS" --no-trigger
rc=$?

OUT=$(ls -dt "$DH"/runs/ctxdump_* 2>/dev/null | head -1)
if [ -n "${OUT:-}" ] && [ -f "$OUT/dmesg.txt" ]; then
    echo
    echo "== oracle lines from $OUT"
    grep -E "BF16: SIGTAMPER|BF16: WprMeta|Fatal GSP-FMC|FSP response|RmInitAdapter|Xid" \
        "$OUT/dmesg.txt" | tail -30
    echo "== run dir: $OUT"
fi

exit "$rc"
