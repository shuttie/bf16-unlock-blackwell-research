#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# feat_preboot.sh - determine whether the FEAT / SM-rate bank is written by
# firmware at all, by sampling it twice in one boot:
#
#   pre-FMC   in kgspSetupGspFmcArgs_GH100, cold boot.  The FSP has executed
#             (it starts out of reset) but the FMC has not been sent the COT and
#             GSP-RM does not exist yet.
#   post-boot in _kgspSetFwWprLayoutOffset, after GET_GSP_STATIC_INFO, i.e.
#             GSP-RM is up and running.
#
# If PLM / READOUT_1 / SS0 / SS1 are identical at both points, no GSP/FMC code
# wrote them: the values are hardware or FSP products, and the "who writes the
# rate block" question is closed.  If they differ, the difference is the window
# in which a firmware writer exists - and the only code in that window is HS.
#
# Read-only: the instrumentation only reads 10 BAR0 dwords.  The harness builds
# and loads the instrumented 595.91.07 modules, captures dmesg, and restores the
# stock DKMS driver in its exit trap.
#
# Usage:  sudo ./feat_preboot.sh
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
GH100="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
KGSP="$TREE/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
COT_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
HARNESS="$TOOL_DIR/dump_ctx.sh"

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
for f in "$GH100" "$KGSP" "$HARNESS"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -x "$HARNESS" ] || { echo "$HARNESS is not executable" >&2; exit 1; }

set_feat() {  # file value
    sed -i -E "s/^#define BF16_FEAT_PREBOOT .*/#define BF16_FEAT_PREBOOT $2/" "$1" \
        || { echo "could not set BF16_FEAT_PREBOOT in $1" >&2; exit 1; }
}

# This run must vary nothing else.
if [ -f "$COT_SRC" ]; then
    sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$COT_SRC"
    sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$COT_SRC"
fi
sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 0/" "$GH100"
sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0ULL/" "$GH100"
if [ -f "$SR_SRC" ]; then
    sed -i -E "s/^#define BF16_SR_VARY .*/#define BF16_SR_VARY 0/" "$SR_SRC"
    sed -i -E "s/^#define BF16_SR_VALUE .*/#define BF16_SR_VALUE 0ULL/" "$SR_SRC"
fi

# Never leave the read armed in the source tree, even if the run hangs.
cleanup() { set_feat "$GH100" 0; set_feat "$KGSP" 0; }
trap cleanup EXIT

set_feat "$GH100" 1
set_feat "$KGSP" 1
echo "== FEAT pre/post-boot sampling enabled"
grep -n 'define BF16_FEAT_PREBOOT' "$GH100" "$KGSP"

env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 "$HARNESS" --no-trigger
rc=$?

OUT=$(ls -dt "$TOOL_DIR"/runs/ctxdump_* 2>/dev/null | head -1)
if [ -n "${OUT:-}" ] && [ -f "$OUT/dmesg.txt" ]; then
    echo
    echo "== FEAT samples from $OUT"
    grep -E 'BF16: FEAT|BF16: FMC boot|BF16: GSCI|Fatal GSP-FMC|RmInitAdapter|Xid' \
        "$OUT/dmesg.txt" | tail -30
    echo
    echo "== run dir: $OUT"
else
    echo "== no run directory found; check dmesg manually" >&2
fi

exit "$rc"
