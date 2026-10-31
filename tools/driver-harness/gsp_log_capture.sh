#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Capture the raw GSP-RM libos log rings with the instrumented 595.91.07 modules.
#
# The instrumented kernel_gsp.c dumps pKernelGsp->rmLibosLogMem[idx] to
# runs/gsplog/ when the driver frees the log structures (module unload).
#
# Usage:
#   sudo ./gsp_log_capture.sh
#
# The script always tries to restore the stock DKMS modules.  If the unload or
# reload wedges, a reboot is the reliable recovery.
set -u

TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
MODDIR="$TREE/kernel-open"
OUT="${OUT:-$TOOL_DIR/runs/gsplog}"
MODS="nvidia_drm nvidia_modeset nvidia_uvm nvidia"
LOG="$OUT/capture_$(date +%Y%m%d_%H%M%S).log"
RESTORED=0

say() { echo "$@" | tee -a "$LOG"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo $0" >&2
    exit 1
fi

mkdir -p "$OUT" || exit 1
chmod 777 "$OUT" 2>/dev/null || true
rm -f "$OUT"/gsp_log_*.bin
: > "$LOG"

for m in nvidia.ko nvidia-modeset.ko nvidia-uvm.ko; do
    [ -f "$MODDIR/$m" ] || { say "missing $MODDIR/$m (build it first)"; exit 1; }
done

unload() {
    local m
    for m in $MODS; do
        if lsmod | awk '{print $1}' | grep -qx "$m"; then
            timeout 45 rmmod "$m" 2>&1 | tee -a "$LOG" || return 1
        fi
    done
    return 0
}

restore() {
    [ "$RESTORED" -eq 1 ] && return 0
    RESTORED=1
    say "== restoring stock modules"
    pkill -9 -x nvidia-smi 2>/dev/null || true
    unload || true
    timeout 90 modprobe nvidia 2>&1 | tee -a "$LOG" || true
    timeout 90 modprobe nvidia_uvm 2>&1 | tee -a "$LOG" || true
    timeout 90 modprobe nvidia_drm modeset=1 2>&1 | tee -a "$LOG" || true
    systemctl start nvidia-persistenced 2>/dev/null || true
    timeout -s KILL 20 nvidia-smi -L 2>&1 | tee -a "$LOG"
}

trap 'restore' EXIT INT TERM

say "== GSP log capture $(date -Is)"
say "== tree: $TREE"
say "== out:  $OUT"
say "== stock modules:"
lsmod | grep -E '^nvidia' | tee -a "$LOG"

dmesg > "$OUT/dmesg_before.txt" 2>/dev/null || true
pkill -9 -x nvidia-smi 2>/dev/null || true
systemctl stop nvidia-persistenced 2>/dev/null || true

if ! unload; then
    say "== stock unload failed; nothing captured, reboot if the driver is wedged"
    exit 1
fi
if lsmod | grep -qE '^nvidia'; then
    say "== an nvidia module is still loaded; aborting"
    exit 1
fi

dmesg -C 2>/dev/null || true
say "== loading instrumented nvidia.ko (modeset/uvm are not needed for GSP logs)"
# A rejected FMC boot can leave an insmod stuck; a killed insmod still lets the
# trap restore stock, but a reboot may be required.
timeout -s KILL 180 insmod "$MODDIR/nvidia.ko" 2>&1 | tee -a "$LOG" || {
    say "== insmod nvidia failed"; exit 1;
}

say "== waiting for GPUs"
for i in $(seq 1 30); do
    if timeout -s KILL 10 nvidia-smi -L >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
timeout -s KILL 20 nvidia-smi -L 2>&1 | tee -a "$LOG"

# A few RM queries beyond boot.  No CUDA context is needed: the boot and GR-init
# records are already in the rings, and this avoids depending on the probe's
# cubin hash/UUID arguments.
say "== a few RM queries"
timeout -s KILL 20 nvidia-smi -q -d CLOCK 2>&1 | tail -5 | tee -a "$LOG" || true
dmesg -T > "$OUT/dmesg_loaded.txt" 2>/dev/null || true

say "== unloading instrumented modules (this writes the rings)"
for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if lsmod | awk '{print $1}' | grep -qx "$m"; then
        timeout 60 rmmod "$m" 2>&1 | tee -a "$LOG" || true
    fi
done

dmesg -T > "$OUT/dmesg_unload.txt" 2>/dev/null || true
say "== dmesg GSPLOG lines"
dmesg -T 2>/dev/null | grep 'BF16: GSPLOG' | tee -a "$LOG" || true

chmod 644 "$OUT"/gsp_log_*.bin 2>/dev/null || true
say "== captured files"
ls -l "$OUT"/gsp_log_*.bin 2>&1 | tee -a "$LOG" || true

restore
say "== done"
