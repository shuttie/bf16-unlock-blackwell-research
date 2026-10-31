#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# p2p-style registry-key sweep against the SM issue rate.
#
# Hypothesis: the half-rate FP32-accumulate path is GeForce product
# segmentation, and the GSP-RM's SKU feature-disable machinery (the same table
# rtx-p2p bypasses with RMDisableFeatureDisablement) may gate it the way it
# gates P2P on consumer parts.  Each variant is one stock-driver reload with a
# single NVreg_RegistryDwords value; the sm120 issue-rate probe measures both
# cards and the FEAT bank is read directly.
#
# Nothing is persisted: the value is passed on the modprobe command line only.
# Every run ends by restoring the stock driver.  If a variant wedges the
# driver, reboot and run with --restore.
#
# Background: the earlier research concluded these keys were "dead" because
# nvidia.ko does not contain the strings.  That reasoning is wrong:
# rm_parse_option_string() (osapi.c:3352) forwards every unrecognized
# key=value to rm_write_registry_dword(), and the RM registry reaches GSP-RM.
# The host binary does not contain "RMDisableFeatureDisablement" either, yet
# that key works on this driver family.
#
# Usage:
#   sudo ./regkey_rate_sweep.sh              # baseline + all variants
#   sudo ./regkey_rate_sweep.sh --dry-run    # print the plan, touch nothing
#   sudo ./regkey_rate_sweep.sh --only featdis
#   sudo ./regkey_rate_sweep.sh --restore    # unload + reload stock only
#
# Output: runs/regkey_<timestamp>/  (summary.txt, per-variant logs, dmesg)

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
RUNNER="$TOOL_DIR/../issue-rate-probe/tensor_modes_driver_runner.py"
CUBIN="$TOOL_DIR/../issue-rate-probe/tensor_modes_issue_sm120.cubin"
HASH=099aecf487705caacb24500ef36d41175bdfb650e00bafd57db6caaa17c1cde8
REGOPS="$TOOL_DIR/../register-access/regops"
POWER="${EXPECT_POWER_LIMIT:-575}"
OUT="$TOOL_DIR/runs/regkey_$(date +%Y%m%d_%H%M%S)"

# name | RegistryDwords value | note
TESTS=(
    "baseline||stock control"
    "featdis|RMDisableFeatureDisablement=1|rtx-p2p SKU feature-gate bypass"
    "quadro|RmEmulationQuadro=1|Quadro/workstation SKU emulation"
    "both|RMDisableFeatureDisablement=1;RmEmulationQuadro=1|both SKU flags"
    "speed0|RMOverrideSmSpeedSelect=0|legacy CMP key, value 0"
    "speed88|RMOverrideSmSpeedSelect=0x88888888|legacy key, Ada override payload"
    "speed1_0|RMOverrideSmSpeedSelect1=0|second legacy key"
    "speedboth|RMOverrideSmSpeedSelect=0x88888888;RMOverrideSmSpeedSelect1=0x8|Ada SS0/SS1 payload pair"
    "speedboth0|RMOverrideSmSpeedSelect=0;RMOverrideSmSpeedSelect1=0|both keys zero"
)

DRY_RUN=0
RESTORE_ONLY=0
ONLY=""
ONLY_BDF=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --restore) RESTORE_ONLY=1 ;;
        --only)    shift; ONLY="${1:-}" ;;
        --bdf)     shift; ONLY_BDF="${1:-}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

have_mod() { lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
kill_strays() { pkill -9 -x nvidia-smi 2>/dev/null || true; }
health() { timeout -s KILL 15 nvidia-smi -L 2>/dev/null | grep -c '^GPU'; }

unload_driver() {
    local m
    for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        if have_mod "$m"; then
            timeout 30 rmmod "$m" 2>>"$OUT/error.log" || return 1
        fi
    done
    return 0
}

load_driver() {
    local param="${1:-}"
    if [ -n "$param" ]; then
        timeout 120 modprobe nvidia NVreg_RegistryDwords="$param"
    else
        timeout 120 modprobe nvidia
    fi
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo "plan ($OUT)"
    echo "  probe: $CUBIN"
    for t in "${TESTS[@]}"; do
        IFS='|' read -r name param note <<<"$t"
        if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi
        printf "  %-10s NVreg_RegistryDwords=\"%s\"\n             %s\n" "$name" "$param" "$note"
    done
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root" >&2
    exit 1
fi

mkdir -p "$OUT" || exit 1

restore_stock() {
    echo "== restoring stock driver" | tee -a "$OUT/summary.txt"
    kill_strays
    unload_driver || { echo "== unload failed; reboot" | tee -a "$OUT/summary.txt"; return 1; }
    load_driver "" || { echo "== modprobe failed; reboot" | tee -a "$OUT/summary.txt"; return 1; }
    local n; n=$(health)
    echo "== after restore: $n GPU(s)" | tee -a "$OUT/summary.txt"
    [ "$n" -ge 1 ] || return 1
    return 0
}

if [ "$RESTORE_ONLY" -eq 1 ]; then
    restore_stock
    exit $?
fi

# ---- preflight ------------------------------------------------------------
PERSISTED=0
if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
    PERSISTED=1
    systemctl stop nvidia-persistenced
fi

BASELINE=$(health)
echo "== preflight: $BASELINE GPU(s), driver $(cat /sys/module/nvidia/version 2>/dev/null)" | tee "$OUT/summary.txt"
if [ "$BASELINE" -lt 1 ]; then
    echo "== no GPUs at baseline; run --restore or reboot" | tee -a "$OUT/summary.txt"
    exit 1
fi

procs=$(timeout 20 nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null)
if [ -n "$procs" ]; then
    echo "== compute processes active; stop them first:" | tee -a "$OUT/summary.txt"
    echo "$procs" | tee -a "$OUT/summary.txt"
    exit 1
fi

trap 'restore_stock || true; [ "$PERSISTED" -eq 1 ] && systemctl start nvidia-persistenced 2>/dev/null; echo "== results: $OUT"' EXIT

# BDF -> probe UUID and RM device index (Device Minor)
bdf_uuid() {
    nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader 2>/dev/null |
        awk -F', ' -v bdf="$1" '
            { b=tolower($2); sub(/^00000000:/,"",b); sub(/^0000:/,"",b);
              want=tolower(bdf); sub(/^0000:/,"",want);
              if (b == want) { print $1; exit } }'
}
bdf_index() {
    sed -n 's/^Device Minor: *//p' "/proc/driver/nvidia/gpus/$1/information" 2>/dev/null | head -1
}

run_probe() {
    local bdf="$1" uuid="$2" log="$3"
    local i; i=$(bdf_index "$bdf")
    {
        echo "--- $bdf ($uuid) deviceIndex=$i"
        echo "--- FEAT bank before probe (host BAR0)"
        "$REGOPS" "$i" "$bdf" bar 823800 10 2>&1
        echo "--- probe"
        ( cd "$TOOL_DIR/../issue-rate-probe" && CUDA_VISIBLE_DEVICES="$uuid" timeout 240 \
            python3 "$RUNNER" "$CUBIN" --sha256 "$HASH" --expect-uuid "$uuid" \
            --expect-power-limit "$POWER" --iters 20000 --reps 3 ) 2>&1
        echo "--- FEAT bank after probe"
        "$REGOPS" "$i" "$bdf" bar 823800 10 2>&1
    } >"$log" 2>&1
}

# ---- sweep ----------------------------------------------------------------
for t in "${TESTS[@]}"; do
    IFS='|' read -r name param note <<<"$t"
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi

    echo | tee -a "$OUT/summary.txt"
    echo "===== $name: \"$param\" ($note)" | tee -a "$OUT/summary.txt"

    unload_driver || { echo "unload failed" | tee -a "$OUT/summary.txt"; exit 1; }
    if ! load_driver "$param"; then
        echo "modprobe failed" | tee -a "$OUT/summary.txt"
        restore_stock || true
        exit 1
    fi
    sleep 5
    n=$(health)
    echo "GPUs after load: $n" | tee -a "$OUT/summary.txt"
    dmesg -T | tail -n 400 >"$OUT/$name.dmesg.txt"

    if [ "$n" -lt 1 ]; then
        echo "no GPUs visible; skipping probe" | tee -a "$OUT/summary.txt"
        restore_stock || true
        continue
    fi

    for bdf in ${BDFS:-0000:41:00.0 0000:c1:00.0}; do
        if [ -n "$ONLY_BDF" ] && [ "$(echo "$bdf" | tr 'A-F' 'a-f')" != "$(echo "$ONLY_BDF" | tr 'A-F' 'a-f')" ]; then
            continue
        fi
        uuid=$(bdf_uuid "$bdf")
        if [ -z "$uuid" ]; then
            echo "$bdf: not present" | tee -a "$OUT/summary.txt"
            continue
        fi
        run_probe "$bdf" "$uuid" "$OUT/${name}_${bdf//[:.]/_}.log"
        grep -E '"mode"|tflops|tops|"best"|clock_mhz|error|Traceback' "$OUT/${name}_${bdf//[:.]/_}.log" \
            | head -20 | tee -a "$OUT/summary.txt"
    done

    restore_stock || { echo "restore failed; reboot" | tee -a "$OUT/summary.txt"; exit 1; }
done

echo | tee -a "$OUT/summary.txt"
echo "== done: $OUT" | tee -a "$OUT/summary.txt"
