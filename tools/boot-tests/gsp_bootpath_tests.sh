#!/bin/bash
# Direction D: GSP boot-path registry experiments on GB202.
#
# Each test unloads the NVIDIA modules, reloads nvidia with a single
# NVreg_RegistryDwords value, records what the GSP boot path did, then restores
# a stock driver before the next test.  Nothing is persisted: the parameter is
# passed at modprobe time only, so a plain `modprobe nvidia` is always clean.
#
# Keys and semantics (driver 595.91.07):
#   RmDisableCotCmd              bitfield
#     FRTS_SYSMEM  bits 1:0      mask 0x03
#     FRTS_VIDMEM  bits 3:2      mask 0x0c
#     GSPFMC       bits 5:4      mask 0x30  -> host-side FMC bootstrap
#   RmDisableFspFuseErrorCheck   == 1 disables the FSP fuse-error check
#   RmDisableFsp                 only honoured when IS_EMULATION(pGpu)
#
# Oracle: the FMC reports structured errors, printed as
#   "Fatal GSP-FMC Error: version=.., partition=.., error code=.., additional info=.."
#
# Usage:
#   sudo ./gsp_bootpath_tests.sh               # run every test
#   sudo ./gsp_bootpath_tests.sh --dry-run     # print the plan, touch nothing
#   sudo ./gsp_bootpath_tests.sh --only gspfmc # run one test by name
#   sudo ./gsp_bootpath_tests.sh --restore     # just unload and reload stock
#
# Recovery: if the driver will not come back, reboot.  No configuration file
# is modified, so a stock boot is unaffected.  The keys are module-wide: the
# script acts on every NVIDIA GPU in the machine, so there is no BDF argument.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
OUTDIR="${OUTDIR:-$DIR}"
OUT="$OUTDIR/bootpath_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p "$OUTDIR"

# name|modprobe parameter|what we expect
TESTS=(
    "fusecheck|RmDisableFspFuseErrorCheck=1|control: should boot, logs the fuse-check message"
    "frts-sys|RmDisableCotCmd=0x1|FRTS sysmem location disabled  [boots, measured]"
    "frts-vid|RmDisableCotCmd=0x4|FRTS vidmem disabled  [fatal 0x83d, measured]"
    "frts-both|RmDisableCotCmd=0xf|both FRTS locations disabled"
    "gspfmc|RmDisableCotCmd=0x10|host-driven FMC bootstrap instead of FSP"
    "all-cot|RmDisableCotCmd=0x3f|all three COT commands disabled"
    "disablefsp|RmDisableFsp=1|negative control: emulation-only, expect no effect"
)

DRY_RUN=0
RESTORE_ONLY=0
ONLY=""
ARGS="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --restore) RESTORE_ONLY=1 ;;
        --only)    shift; ONLY="${1:-}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { echo "$@" | tee -a "$OUT"; }
have_mod() { lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

if [ "$DRY_RUN" -eq 1 ]; then
    echo "plan ($OUT):  args=[$ARGS]"
    for t in "${TESTS[@]}"; do
        IFS='|' read -r name param note <<<"$t"
        if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi
        printf "  %-12s  NVreg_RegistryDwords=\"%s\"\n                %s\n" "$name" "$param" "$note"
    done
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

# ---------- driver control (defined before use: --restore needs them) -------
unload_driver() {
    local m
    for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        if have_mod "$m"; then
            timeout 30 rmmod "$m" 2>>"$OUT" || return 1
        fi
    done
    return 0
}

load_driver() {
    local param="${1:-}"
    if [ -n "$param" ]; then
        timeout 90 modprobe nvidia NVreg_RegistryDwords="$param"
    else
        timeout 90 modprobe nvidia
    fi
}

# SIGKILL on timeout: a stuck nvidia-smi left in T state holds the device node
# and pins the module, which is what blocked rmmod in the 18:07 run
health() { timeout -s KILL 15 nvidia-smi -L 2>/dev/null | grep -c '^GPU'; }

kill_strays() { pkill -9 -x nvidia-smi 2>/dev/null || true; }

BASELINE_GPUS="${BASELINE_GPUS:-2}"
RESTORE_FAILED=0

restore_stock() {
    say ""
    say "== restoring stock driver"
    kill_strays
    if ! unload_driver; then
        say "== could not unload the driver"
        RESTORE_FAILED=1
        return 1
    fi
    if ! load_driver ""; then
        say "== modprobe of the stock driver failed"
        RESTORE_FAILED=1
        return 1
    fi
    local n
    n=$(health)
    say "== after restore: $n GPU(s) visible"
    if [ "$n" -ne "$BASELINE_GPUS" ]; then
        RESTORE_FAILED=1
        say "== RESTORE FAILED: modules will not bring the GPUs back. Reboot."
        return 1
    fi
    return 0
}

if [ "$RESTORE_ONLY" -eq 1 ]; then
    {
        echo "== restore-only run $(date -Is)  args=[$ARGS]"
    } | tee "$OUT"
    unload_driver; load_driver ""
    n=$(health)
    say "== $n GPU(s) visible"
    say "== log: $OUT"
    [ "$n" -eq 2 ] || { say "== still not healthy: reboot"; exit 1; }
    exit 0
fi

# ---------- preflight -------------------------------------------------------
{
    echo "== GSP boot-path registry tests $(date -Is)"
    echo "== args: [$ARGS]"
    echo "== driver: $(cat /sys/module/nvidia/version 2>/dev/null)  kernel: $(uname -r)"
    echo "== current NVreg_RegistryDwords: $(cat /sys/module/nvidia/parameters/NVreg_RegistryDwords 2>/dev/null || echo '<unreadable>')"
} | tee "$OUT"

if ! have_mod nvidia; then
    say "nvidia module is not loaded -- nothing to test"
    exit 1
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    procs=$(timeout 20 nvidia-smi --query-compute-apps=pid,process_name \
                --format=csv,noheader 2>/dev/null)
    if [ -n "$procs" ]; then
        say "compute processes are using the GPU -- stop them first:"
        say "$procs"
        exit 1
    fi
fi

PERSISTED_RUNNING=0
if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
    PERSISTED_RUNNING=1
    say "== stopping nvidia-persistenced for the duration"
    systemctl stop nvidia-persistenced
fi

BASELINE_GPUS=$(health)
say "== baseline: $BASELINE_GPUS GPU(s) visible"
if [ "$BASELINE_GPUS" -eq 0 ]; then
    say "== no GPUs visible at baseline -- run --restore or reboot first"
    exit 1
fi

cleanup() {
    kill_strays
    if [ "$RESTORE_FAILED" -eq 0 ]; then
        restore_stock || true
    fi
    # never hand the device back to persistenced while the driver is broken:
    # it holds /dev/nvidia* and would pin the module
    if [ "$PERSISTED_RUNNING" -eq 1 ] && [ "$RESTORE_FAILED" -eq 0 ]; then
        systemctl start nvidia-persistenced 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------- run -------------------------------------------------------------
SUMMARY="$DIR/.summary.$$"
: >"$SUMMARY"

for t in "${TESTS[@]}"; do
    IFS='|' read -r name param note <<<"$t"
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi

    say ""
    say "=================================================================="
    say "---- $name   NVreg_RegistryDwords=\"$param\""
    say "     $note"

    if ! unload_driver; then
        say "---- FAILED to unload the driver; stopping"
        RESTORE_FAILED=1
        echo "$name|unload-failed" >>"$SUMMARY"
        break
    fi

    mark=$(dmesg 2>/dev/null | wc -l)
    if load_driver "$param"; then rc=0; else rc=$?; fi
    sleep 15                      # long enough for the target-mask wait to time out
    delta=$(dmesg 2>/dev/null | tail -n +$((mark + 1)))   # capture BEFORE any hang

    n=$(health)
    kill_strays
    if [ "$n" -eq "$BASELINE_GPUS" ]; then healthy=yes; else healthy="no ($n/$BASELINE_GPUS)"; fi

    via_fsp=$(grep -c "Starting to boot GSP via FSP" <<<"$delta")
    fmc_err=$(grep -o "Fatal GSP-FMC Error:[^\"]*" <<<"$delta" | head -1)
    fmc_n=$(grep -c "Fatal GSP-FMC Error" <<<"$delta")
    rep_err=$(grep -o "GSP-FMC reported an error[^0-9]*0x[0-9a-fA-F]*" <<<"$delta" | head -1)
    mbox=$(grep -o "NV_PGSP_FALCON_MAILBOX0 = 0x[0-9a-fA-F]*" <<<"$delta" | tail -1)
    tmo=$(grep -c "Timeout waiting" <<<"$delta")
    xids=$(grep -c "Xid" <<<"$delta")

    say "     modprobe rc=$rc  healthy=$healthy"
    say "     booted via FSP: $via_fsp   'Timeout waiting': $tmo   Xid lines: $xids"
    [ "$fmc_n" -gt 0 ] && say "     FMC error reports: $fmc_n"
    [ -n "$fmc_err" ]  && say "     $fmc_err"
    [ -n "$rep_err" ]  && say "     $rep_err"
    [ -n "$mbox" ]     && say "     $mbox"

    if [ -n "$delta" ]; then
        say "     ---- kernel log (deduplicated) ----"
        grep -iE "NVRM|GSP|FMC|COT|FRTS|FSP|Xid" <<<"$delta" \
            | sed -E 's/^\[[ 0-9.]+\] //' | awk '!seen[$0]++' \
            | sed 's/^/     | /' | tee -a "$OUT" >/dev/null
    fi

    # when the GPU does not come back, the boot trace IS the result: keep all of it
    if [ "$healthy" != "yes" ] && [ -n "$delta" ]; then
        say "     ---- full kernel log for this test ----"
        sed -E 's/^\[[ 0-9.]+\] //' <<<"$delta" | awk '!seen[$0]++' \
            | sed 's/^/     ~ /' | tee -a "$OUT" >/dev/null
    fi

    echo "$name|rc=$rc|healthy=$healthy|via_fsp=$via_fsp|fmc_errors=$fmc_n|timeout=$tmo|xid=$xids|${fmc_err:-none}" >>"$SUMMARY"

    # always leave a clean driver behind, and carry on: a failed boot has
    # proven recoverable by reloading without the key
    if ! restore_stock; then
        say "---- restore failed; stopping (reboot required)"
        break
    fi
done

# ---------- summary ---------------------------------------------------------
say ""
say "================ summary ================"
while IFS='|' read -r line; do
    say "  $line"
done <"$SUMMARY"
rm -f "$SUMMARY"

say ""
say "== log: $OUT"
