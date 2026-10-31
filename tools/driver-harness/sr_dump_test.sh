#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# sr_dump_test.sh - dump the SR suspend image before HS restores it.
#
# The suspend path builds a radix3 over the firmware state region in unprotected
# sysmem; HS saves into it at suspend and restores from it at resume.  This run
# hooks the resume FMC setup (bootMode == SR_RESUME) and writes that saved
# region to srdump/sr_<instance>.bin, scanning it for FEAT/selector words.
#
# Files are written to disk (not tmpfs), so they survive a hung resume and a
# reboot.  The run clears all oracle defines and forces BF16_SRDUMP=1.
#
# Usage: sudo ./sr_dump_test.sh
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
DIR="$TOOL_DIR"
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
DUMPDIR="$TOOL_DIR/runs/srdump"
OUT="$TOOL_DIR/runs/sr_dump_$(date +%Y%m%d_%H%M%S)"
PM_TEST_SAVED=""

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$GSP_SRC" ] && [ -f "$FSP_SRC" ] && [ -f "$SR_SRC" ] \
    || { echo "missing tree sources" >&2; exit 1; }

mkdir -p "$OUT" "$DUMPDIR"
rm -f "$DUMPDIR"/sr_*.bin
say() { echo "$@" | tee -a "$OUT/run.log"; }

reset_pm_test() {
    if [ -n "$PM_TEST_SAVED" ]; then
        echo "$PM_TEST_SAVED" > /sys/power/pm_test 2>/dev/null || true
        PM_TEST_SAVED=""
    fi
}
trap 'reset_pm_test' EXIT INT TERM

say "== SR dump test $(date -Is)"

# Stock behaviour except the dump.
sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 0/" "$GSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0ULL/" "$GSP_SRC" || exit 1
sed -i -E "s/^#define BF16_SR_VARY .*/#define BF16_SR_VARY 0/" "$SR_SRC" || exit 1
sed -i -E "s/^#define BF16_SR_VALUE .*/#define BF16_SR_VALUE 0ULL/" "$SR_SRC" || exit 1
sed -i -E "s/^#define BF16_SRDUMP .*/#define BF16_SRDUMP 1/" "$GSP_SRC" || exit 1

say "== defines:"
grep -hnE "^#define BF16_(COT|WPR|SR)_(VARY|VALUE)|^#define BF16_SRDUMP" \
    "$FSP_SRC" "$GSP_SRC" "$SR_SRC" | tee -a "$OUT/run.log"

say "== building"
(cd "$TREE" && timeout 1800 make modules -j"$(nproc)") | tee -a "$OUT/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { say "ERROR: build failed"; exit 1; }
say "== build ok"

"$DIR/load_patched.sh" 2>&1 | tee -a "$OUT/load.log"
load_rc=${PIPESTATUS[0]}

PM_TEST_SAVED="$(cat /sys/power/pm_test)"
dmesg -C 2>/dev/null || true
say "== pm_test=devices suspend/resume cycle"
echo devices > /sys/power/pm_test
timeout 240 sh -c 'echo mem > /sys/power/state'
susp_rc=$?
reset_pm_test
say "== suspend test rc=$susp_rc"

dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
say "== dump lines:"
grep -E "BF16: SRDUMP|BF16: SRMeta|BF16: FMC boot params" "$OUT/dmesg.txt" \
    | tail -30 | tee -a "$OUT/run.log"

# Keep whatever was written, even if the resume failed part-way.
if ls "$DUMPDIR"/sr_*.bin >/dev/null 2>&1; then
    say "== dump files:"
    ls -l "$DUMPDIR"/sr_*.bin | tee -a "$OUT/run.log"
    mv "$DUMPDIR"/sr_*.bin "$OUT"/ 2>/dev/null || true
    # The kernel writes them 0600; make them readable for offline analysis.
    chmod 644 "$OUT"/sr_*.bin 2>/dev/null || true
else
    say "== no dump files were written"
fi

say "== nvidia-smi:"
timeout -s KILL 20 nvidia-smi -L 2>&1 | tee -a "$OUT/run.log"

"$DIR/load_patched.sh" --restore 2>&1 | tee -a "$OUT/restore.log" || true
say "== done rc(load=$load_rc susp=$susp_rc)"
say "== out: $OUT / $DUMPDIR"
