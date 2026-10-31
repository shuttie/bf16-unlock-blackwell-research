#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# sr_oracle.sh - vary exactly one host-built GspFwSRMeta field and exercise the
# SR-resume path with a device-level suspend/resume test cycle.
#
# Usage:
#   sudo ./sr_oracle.sh <field> [value]
#
#   field 0  stock; clears any override
#         1  magic                    (stock 0x8a3bb9e6c6c39d93; default wrong
#                                     value 0xdeadbeefdeadbeef)
#         2  revision                 (stock 2; default 3)
#         3  sizeOfSuspendResumeData  (default 0x66f0000 = half stock)
#         4  sysmemAddrOfSuspendResumeData    (value required; radix3 pointer)
#         5  flags                            (default 1)
#         6  radix3 address + delta           (value required)
#
# The host builds this structure in kgspPrepareSuspendResumeData_TU102 and the
# FMC is handed it instead of the WprMeta on resume (bootMode=1), so each field
# is host-controlled input to secure ucode.  The field override is applied after
# the radix3 is built, so a size change deliberately leaves the page table at
# the stock size.
#
# The run clears the COT and WprMeta overrides so exactly one field varies, then
# builds, loads the instrumented modules, forces a pm_test=devices suspend/resume
# cycle (the machine stays up), captures dmesg and restores the stock driver.
#
# Safety: no register or firmware writes.  A malformed SRMeta can fail the
# resume; recovery is a reboot, and the stock driver is restored at the end.
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
export MODDIR="${MODDIR:-$TREE/kernel-open}"
DIR="$TOOL_DIR"
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
HOP_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
OUT="$TOOL_DIR/runs/sr_oracle_$(date +%Y%m%d_%H%M%S)"
PM_TEST_SAVED=""

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
        1) VALUE=0xdeadbeefdeadbeef ;;
        2) VALUE=0x3 ;;
        3) VALUE=0x66f0000 ;;
        5) VALUE=0x1 ;;
        4)
            echo "field 4 (radix3 sysmem address) needs an explicit value" >&2
            exit 2
            ;;
        6)
            echo "field 6 (radix3 address delta) needs an explicit value" >&2
            exit 2
            ;;
    esac
fi

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$SR_SRC" ] && [ -f "$HOP_SRC" ] && [ -f "$FSP_SRC" ] \
    || { echo "missing tree sources" >&2; exit 1; }
[ -f "$MODDIR/nvidia.ko" ] \
    || { echo "missing $MODDIR/nvidia.ko (build the tree first)" >&2; exit 1; }

mkdir -p "$OUT"
say() { echo "$@" | tee -a "$OUT/run.log"; }

reset_pm_test() {
    if [ -n "$PM_TEST_SAVED" ]; then
        echo "$PM_TEST_SAVED" > /sys/power/pm_test 2>/dev/null || true
        PM_TEST_SAVED=""
    fi
}
trap 'reset_pm_test' EXIT INT TERM

# Exactly one field: clear the other two oracles.
sed -i -E "s/^#define BF16_COT_VARY .*/#define BF16_COT_VARY 0/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_COT_VALUE .*/#define BF16_COT_VALUE 0ULL/" "$FSP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VARY .*/#define BF16_WPR_VARY 0/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_WPR_VALUE .*/#define BF16_WPR_VALUE 0ULL/" "$HOP_SRC" || exit 1
# A stale cold-boot flip would fail the load before the suspend test starts.
sed -i -E "s/^#define BF16_SIG_TAMPER .*/#define BF16_SIG_TAMPER 0/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_SIG_OFF .*/#define BF16_SIG_OFF 0x0/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_SIG_XOR .*/#define BF16_SIG_XOR 0x01/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_SIG_VALUE .*/#define BF16_SIG_VALUE 0/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_SIG_WIDTH .*/#define BF16_SIG_WIDTH 1/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_BOOT_TAMPER .*/#define BF16_BOOT_TAMPER 0/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_BOOT_OFF .*/#define BF16_BOOT_OFF 0x0/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_BOOT_XOR .*/#define BF16_BOOT_XOR 0x01/" "$HOP_SRC" || exit 1
sed -i -E "s/^#define BF16_SR_VARY .*/#define BF16_SR_VARY $VARY/" "$SR_SRC" || exit 1
sed -i -E "s/^#define BF16_SR_VALUE .*/#define BF16_SR_VALUE ${VALUE}ULL/" "$SR_SRC" || exit 1

say "== BF16 SR oracle: field=$VARY value=$VALUE"
grep -hnE "^#define BF16_(COT|WPR|SR)_(VARY|VALUE)" "$FSP_SRC" "$HOP_SRC" "$SR_SRC" | tee -a "$OUT/run.log"

say "== building"
(cd "$TREE" && timeout 1800 make modules -j"$(nproc)") | tee -a "$OUT/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { say "ERROR: build failed"; exit 1; }
say "== build ok"

"$DIR/load_patched.sh" 2>&1 | tee -a "$OUT/load.log"
load_rc=${PIPESTATUS[0]}
if [ "$load_rc" -ne 0 ]; then
    say "ERROR: instrumented load failed (rc=$load_rc); restoring stock"
    "$DIR/load_patched.sh" --restore 2>&1 | tee -a "$OUT/restore.log" || true
    exit 1
fi
say "== loaded"
date -Is > "$OUT/phase_loaded"
# Keep the load-time log: the ring buffer is cleared before the cycle, and a
# hung resume never gets to write dmesg.txt.
dmesg -T > "$OUT/dmesg_load.txt" 2>/dev/null || true

PM_TEST_SAVED="$(cat /sys/power/pm_test)"
dmesg -C 2>/dev/null || true
say "== pm_test=devices suspend/resume cycle"
echo devices > /sys/power/pm_test
# Disk marker: survives a failed resume.  A hang leaves this file and no
# phase_post_resume, which distinguishes "never resumed" from "restore failed".
date -Is > "$OUT/phase_pre_suspend"
timeout 180 sh -c 'echo mem > /sys/power/state'
susp_rc=$?
date -Is > "$OUT/phase_post_resume"
reset_pm_test
say "== suspend test rc=$susp_rc"

dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
say "== oracle lines:"
grep -E "BF16: SR VARY|BF16: SRMeta|BF16: SRDUMP|BF16: FMC boot params|Fatal|RmInitAdapter|WPR2|Xid|resume" \
    "$OUT/dmesg.txt" | tail -40 | tee -a "$OUT/run.log"
say "== nvidia-smi:"
timeout -s KILL 20 nvidia-smi -L 2>&1 | tee -a "$OUT/run.log"

"$DIR/load_patched.sh" --restore 2>&1 | tee -a "$OUT/restore.log" || true
say "== done rc(load=$load_rc susp=$susp_rc)"
say "== out: $OUT"
