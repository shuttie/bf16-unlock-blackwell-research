#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# sr_resume_test.sh - stage 1 of the SR-resume work: instrumentation only.
#
# Loads the instrumented 595.91.07 modules, forces a device-level suspend/resume
# test cycle (pm_test=devices, so the machine stays up), captures the SR
# instrumentation and restores the stock driver.
#
# The useful lines are:
#   BF16: SRMeta magic=0x8a3bb9e6c6c39d93 ... size=... radix3Addr=...
#   BF16: SRMeta inputs frts{off=... size=...} nonWpr{off=... size=...}
#   BF16: FMC boot params: bootMode=1 ...     (1 = KGSP_BOOT_MODE_SR_RESUME)
#
# No behavior change: all four oracle defines are forced to 0 first.
#
# Usage: sudo ./sr_resume_test.sh
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
DIR="$TOOL_DIR"
GSP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
OUT="$TOOL_DIR/runs/sr_resume_$(date +%Y%m%d_%H%M%S)"
PM_TEST_SAVED=""

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$GSP_SRC" ] && [ -f "$FSP_SRC" ] || { echo "missing tree sources" >&2; exit 1; }
[ -x "$DIR/load_patched.sh" ] || { echo "missing $DIR/load_patched.sh" >&2; exit 1; }

mkdir -p "$OUT"
say() { echo "$@" | tee -a "$OUT/run.log"; }

reset_pm_test() {
    if [ -n "$PM_TEST_SAVED" ]; then
        echo "$PM_TEST_SAVED" > /sys/power/pm_test 2>/dev/null || true
        PM_TEST_SAVED=""
    fi
}
trap 'reset_pm_test' EXIT INT TERM

say "== SR stage 1 (instrumentation only) $(date -Is)"

# 1. Stock behaviour: clear every oracle override.
sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 0/" "$GSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0ULL/" "$GSP_SRC" || exit 1
say "== defines:"
grep -hnE "^#define BF16_(COT|WPR)_(VARY|VALUE)" "$FSP_SRC" "$GSP_SRC" | tee -a "$OUT/run.log"

# 2. Build.
say "== building"
(cd "$TREE" && timeout 1800 make modules -j"$(nproc)") | tee -a "$OUT/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { say "ERROR: build failed"; exit 1; }
say "== build ok"

# 3. Load the instrumented modules.
"$DIR/load_patched.sh" 2>&1 | tee -a "$OUT/load.log"
load_rc=${PIPESTATUS[0]}

# 4. Device-level suspend/resume test cycle.
say "== current pm_test: $(cat /sys/power/pm_test)"
PM_TEST_SAVED="$(cat /sys/power/pm_test)"
dmesg -C 2>/dev/null || true
echo "== triggering pm_test=devices suspend/resume" | tee -a "$OUT/run.log"
echo devices > /sys/power/pm_test
timeout 180 sh -c 'echo mem > /sys/power/state'
susp_rc=$?
reset_pm_test
say "== suspend test rc=$susp_rc"

# 5. Capture and summarise.
dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
say "== SR lines:"
grep -E "BF16: SRMeta|BF16: FMC boot params|BF16: GSCI|RmInitAdapter|WPR2|Xid|suspend|resume" \
    "$OUT/dmesg.txt" | tail -40 | tee -a "$OUT/run.log"
say "== nvidia-smi:"
timeout -s KILL 20 nvidia-smi -L 2>&1 | tee -a "$OUT/run.log"

# 6. Restore stock regardless.
"$DIR/load_patched.sh" --restore 2>&1 | tee -a "$OUT/restore.log" || true
say "== done rc(load=$load_rc susp=$susp_rc)"
say "== out: $OUT"
