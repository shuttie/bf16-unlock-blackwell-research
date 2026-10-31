#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# wpr_verified_patch_test.sh - decisive test for WprMeta.verified.
#
# Installs the patched GSP-RM image that the FMC normally rejects with 0xaff
# (D.20: FUN_ram_015ffae8 entry replaced by `ret`), with the host preset
# verified = 0xa0a0a0a0a0a0a0a0 in GspFwWprMeta.  If the FMC still rejects it,
# the flag does not gate image verification.  If the GSP-RM comes up, the flag
# is a signature bypass.
#
# Recovery note: a rejected patched image can leave WPR2 up, in which case the
# GPUs do not come back until a reboot.  The original firmware is restored
# before the stock driver is restored, so that reboot is clean.
#
# Usage: sudo ./wpr_verified_patch_test.sh
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
DIR="$TOOL_DIR"
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
FW=/lib/firmware/nvidia/595.91.07/gsp_ga10x.bin
ORIG="$DIR/gsp_ga10x.bin.orig"
PATCHED="$DIR/gsp_ga10x.bin.patched"
OUT="$TOOL_DIR/runs/wpr_verified_patch_$(date +%Y%m%d_%H%M%S)"
FW_INSTALLED=0

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$ORIG" ] && [ -f "$PATCHED" ] || { echo "missing image copies in $DIR" >&2; exit 1; }
[ -f "$GSP_SRC" ] && [ -f "$FSP_SRC" ] || { echo "missing tree sources" >&2; exit 1; }

mkdir -p "$OUT"
say() { echo "$@" | tee -a "$OUT/run.log"; }

restore_fw() {
    if [ "$FW_INSTALLED" -eq 1 ]; then
        cp "$ORIG" "$FW"
        sync
        say "== original firmware restored: $(sha256sum "$FW" | awk '{print $1}')"
        FW_INSTALLED=0
    fi
}

reset_defines() {
    sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$FSP_SRC" 2>/dev/null || true
    sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$FSP_SRC" 2>/dev/null || true
    sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 0/" "$GSP_SRC" 2>/dev/null || true
    sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0ULL/" "$GSP_SRC" 2>/dev/null || true
}

cleanup() {
    restore_fw
    reset_defines
}
trap cleanup EXIT INT TERM

say "== WprMeta verified + patched GSP-RM test $(date -Is)"
say "== original sha256: $(sha256sum "$ORIG" | awk '{print $1}')"
say "== patched  sha256: $(sha256sum "$PATCHED" | awk '{print $1}')"

# 1. One-field oracle: verified = 0xa0a0a0a0a0a0a0a0, COT stock.
sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 3/" "$GSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0xa0a0a0a0a0a0a0a0ULL/" "$GSP_SRC" || exit 1
say "== defines:"
grep -n "^#define BF16_COT_" "$FSP_SRC" | tee -a "$OUT/run.log"
grep -n "^#define BF16_WPR_" "$GSP_SRC" | tee -a "$OUT/run.log"

# 2. Incremental build.
say "== building"
(cd "$TREE" && timeout 1800 make modules -j"$(nproc)") | tee -a "$OUT/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { say "ERROR: build failed"; exit 1; }
say "== build ok"

# 3. Install the patched image, then load the instrumented modules.
cp "$PATCHED" "$FW" && sync
FW_INSTALLED=1
say "== installed patched firmware: $(sha256sum "$FW" | awk '{print $1}')"

"$DIR/load_patched.sh" 2>&1 | tee -a "$OUT/load.log"
rc=${PIPESTATUS[0]}

# 4. Restore the original image immediately, then the stock driver.
restore_fw
"$DIR/load_patched.sh" --restore 2>&1 | tee -a "$OUT/restore.log" || true

# 5. Capture and summarise.
dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
say "== oracle lines:"
grep -E "BF16: WPR VARY|BF16: WprMeta|BF16: COT|Fatal GSP-FMC|FSP response|RmInitAdapter|WPR2|Xid|GSCI|0xaff" \
    "$OUT/dmesg.txt" | tail -40 | tee -a "$OUT/run.log"
say "== test rc=$rc"
say "== if no devices are listed, reboot (firmware is already restored): sudo systemctl reboot -f"
say "== out: $OUT"
exit "$rc"
