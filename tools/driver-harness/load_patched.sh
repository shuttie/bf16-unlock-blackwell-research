#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Phase 2b: load the instrumented 595.91.07 open modules and capture the BF16 logs.
# The patched module only adds NV_PRINTF lines; it changes no behavior.
#
# Usage:
#   sudo ./load_patched.sh            # unload stock, insmod the instrumented modules
#   sudo ./load_patched.sh --restore  # unload and restore the stock DKMS modules
#
# Recovery: if rmmod/insmod fails, a reboot is the reliable exit.  The installed
# DKMS modules are untouched.
set -u
MODDIR="${MODDIR:?set MODDIR to the kernel-open tree at 595.91.07}"
OUTDIR="${OUTDIR:-$TOOL_DIR/runs}"
OUT="$OUTDIR/load_patched_$(date +%Y%m%d_%H%M%S).txt"
MODS="nvidia_drm nvidia_modeset nvidia_uvm nvidia"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi
mkdir -p "$OUTDIR"
say() { echo "$@" | tee -a "$OUT"; }

unload() {
    local m
    for m in $MODS; do
        if lsmod | awk '{print $1}' | grep -qx "$m"; then
            timeout 30 rmmod "$m" 2>&1 | tee -a "$OUT" || return 1
        fi
    done
    return 0
}

restore() {
    say "== restoring stock modules"
    pkill -9 -x nvidia-smi 2>/dev/null || true
    if ! unload; then
        say "== unload failed; reboot is the reliable recovery"
        return 1
    fi
    timeout 90 modprobe nvidia 2>&1 | tee -a "$OUT" || return 1
    timeout 90 modprobe nvidia_uvm 2>&1 | tee -a "$OUT" || true
    timeout 90 modprobe nvidia_drm modeset=1 2>&1 | tee -a "$OUT" || true
    systemctl start nvidia-persistenced 2>/dev/null || true
    timeout -s KILL 15 nvidia-smi -L 2>&1 | tee -a "$OUT"
    say "== stock driver restored"
}

if [ "${1:-}" = "--restore" ]; then
    restore
    exit $?
fi

say "== Phase 2b instrumented load $(date -Is)"
say "== module dir: $MODDIR"
say "== pre-load modules:"
lsmod | grep -E "^nvidia" | tee -a "$OUT"
say "== pre-load dmesg tail:"
dmesg -T | tail -40 | tee -a "$OUT"

pkill -9 -x nvidia-smi 2>/dev/null || true
systemctl stop nvidia-persistenced 2>/dev/null || true

if ! unload; then
    say "== unload failed; reboot before continuing"
    exit 1
fi
if lsmod | grep -qE "^nvidia"; then
    say "== an nvidia module is still loaded; aborting"
    exit 1
fi

dmesg -C
say "== loading instrumented modules"
# Timeouts matter: a rejected FMC boot can leave nvidia-drm in an unkillable
# init path.  A killed insmod still lets the caller capture the oracle and
# restore the stock driver (a reboot may still be required).
timeout -s KILL 180 insmod "$MODDIR/nvidia.ko" 2>&1 | tee -a "$OUT" || { say "== insmod nvidia failed or timed out"; exit 1; }
timeout -s KILL 60 insmod "$MODDIR/nvidia-modeset.ko" 2>&1 | tee -a "$OUT" || true
timeout -s KILL 60 insmod "$MODDIR/nvidia-uvm.ko" 2>&1 | tee -a "$OUT" || true
if [ "${SKIP_DRM:-0}" != "1" ]; then
    timeout -s KILL 60 insmod "$MODDIR/nvidia-drm.ko" modeset=1 2>&1 | tee -a "$OUT" || true
else
    say "== SKIP_DRM=1: not loading nvidia-drm"
fi

sleep 20
say "== GPUs:"
timeout -s KILL 15 nvidia-smi -L 2>&1 | tee -a "$OUT"
say "== BF16/GSP lines:"
dmesg -T | grep -E "BF16:|Fatal GSP|Xid|NVRM: GPU|GSP" | tee -a "$OUT"
DMESG="$OUTDIR/dmesg_$(date +%Y%m%d_%H%M%S).txt"
dmesg -T > "$DMESG"
say "== full dmesg: $DMESG"
say "== restore with: sudo $0 --restore"
