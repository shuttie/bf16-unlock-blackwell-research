#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# boot_tamper_run.sh - corrupt one ciphertext byte of the host-supplied
# GspRmBoot image before the FMC parses it in HS.
#
# The COT binds only the FMC container (E62: 0x33).  The bootloader image that
# the FMC reads from sysmem (WprMeta.sysmemAddrOfBootloader, 0x47000 bytes) has
# never been tampered.  Everything else stays stock: COT hash, signature
# buffer, WprMeta.  A rejection is therefore attributable to the image's own
# integrity check; a clean boot means a corrupted ciphertext reaches the HS
# parser.
#
# Usage:  sudo ./boot_tamper_run.sh [offset_hex] [xor]
# Env:    OFF=0x0 XOR=0x01
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
KFSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/kern_fsp.c"
HARNESS="$TOOL_DIR/dump_ctx.sh"

OFF="${1:-${OFF:-0x0}}"
XOR="${2:-${XOR:-0x01}}"

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)" >&2; exit 1; }
for f in "$GSP_SRC" "$FSP_SRC" "$KFSP_SRC" "$HARNESS"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

set_def() {  # file name value
    local f="$1" n="$2" v="$3"
    grep -qE "^#define $n[[:space:]]" "$f" \
        || { echo "define $n not found in $f" >&2; return 1; }
    sed -i -E "s/^#define $n[[:space:]]+.*/#define $n $v/" "$f"
}

reset_all() {
    set_def "$GSP_SRC" BF16_BOOT_TAMPER 0
    set_def "$GSP_SRC" BF16_BOOT_OFF 0x0
    set_def "$GSP_SRC" BF16_BOOT_XOR 0x01
    set_def "$GSP_SRC" BF16_WPR_VARY 0
    set_def "$GSP_SRC" BF16_WPR_VALUE 0ULL
    set_def "$FSP_SRC" BF16_ICD_HALT 0
    set_def "$FSP_SRC" BF16_ICD_TRACE 0
    set_def "$FSP_SRC" BF16_COT_VARY 0
    set_def "$FSP_SRC" BF16_COT_VALUE 0ULL
    set_def "$FSP_SRC" BF16_FMCDUMP 0
    set_def "$KFSP_SRC" BF16_FMCDUMP 0
    [ -f "$SR_SRC" ] && set_def "$SR_SRC" BF16_SR_VARY 0
    return 0
}
trap reset_all EXIT

reset_all
set_def "$GSP_SRC" BF16_BOOT_TAMPER 1
set_def "$GSP_SRC" BF16_BOOT_OFF "$OFF"
set_def "$GSP_SRC" BF16_BOOT_XOR "$XOR"

echo "== bootloader tamper armed: off=$OFF xor=$XOR"
grep -nE "^#define BF16_(BOOT_TAMPER|BOOT_OFF|BOOT_XOR|WPR_VARY)" "$GSP_SRC"

env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 "$HARNESS" --no-trigger
rc=$?

OUT=$(ls -dt "$TOOL_DIR"/runs/ctxdump_* 2>/dev/null | head -1)
echo
if [ -n "${OUT:-}" ] && [ -f "$OUT/dmesg.txt" ]; then
    echo "== result from $OUT"
    grep -E "BF16: BOOTTAMPER|Fatal GSP-FMC|GSCI fwWprLayoutOffset|RmInitAdapter failed|Xid" \
        "$OUT/dmesg.txt" | head -20
else
    echo "== no run directory; check dmesg"
fi
echo
echo "== run dir: ${OUT:-none}"

exit "$rc"
