#!/bin/bash
# run_reload_test.sh -- load the instrumented 595.91.07 modules and run the
# peer BAR1 read twice: once with the stock I/O-memory gate, once with the
# BF16PeerBarIoMem bypass.
#
# Read-only with respect to VRAM: the only writes are the ones CUDA already
# does (an allocation on gpu0 for the magic control). The kernel-side change
# is a registry-gated skip of osCheckGpuBarsOverlapAddrRange.
#
# Usage: sudo ./run_reload_test.sh
# Recovery: if a reload fails, reboot. The DKMS stock module is restored on a
# clean exit.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS="$DIR/runs"
mkdir -p "$RUNS"
OUT="$RUNS/reload_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/run.log"
exec > >(tee -a "$LOG") 2>&1

MODDIR="${MODDIR:?set MODDIR to the built 595.91.07 kernel-open tree}"
GPU0_BDF="${GPU0_BDF:-0000:41:00.0}"
GPU1_BDF="${GPU1_BDF:-0000:c1:00.0}"
BAR1_0="/sys/bus/pci/devices/$GPU0_BDF/resource1"
BIN="$DIR/peer_read"
REG_BASE="RMDisableFeatureDisablement=1;EnableResizableBar=1;RMForceStaticBar1=1;RMForceP2PType=1;RMPcieP2PType=1;ForceP2P=0x11"
MODS="nvidia_drm nvidia_modeset nvidia_uvm nvidia"

say() { echo "$@"; }
die() { say "FATAL: $*"; say "== recovery: reboot is the reliable exit"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -x "$BIN" ] || die "missing $BIN"
[ -f "$MODDIR/nvidia.ko" ] || die "missing $MODDIR/nvidia.ko"

say "== peer BAR1 read (instrumented driver) $(date -Is)"

unload() {
    pkill -9 -x nvidia-smi 2>/dev/null || true
    systemctl stop ollama 2>/dev/null || true
    systemctl stop nvidia-persistenced 2>/dev/null || true
    sleep 1
    local m
    for m in $MODS; do
        if lsmod | awk '{print $1}' | grep -qx "$m"; then
            timeout 30 rmmod "$m" || return 1
        fi
    done
    ! lsmod | grep -qE '^nvidia'
}

load_driver() {
    local extra="${1:-}"
    dmesg -C >/dev/null 2>&1 || true
    timeout -s KILL 180 insmod "$MODDIR/nvidia.ko" NVreg_RegistryDwords="$REG_BASE$extra" \
        || return 1
    timeout -s KILL 60 insmod "$MODDIR/nvidia-modeset.ko" 2>/dev/null || true
    timeout -s KILL 60 insmod "$MODDIR/nvidia-uvm.ko" 2>/dev/null || true
    timeout -s KILL 60 insmod "$MODDIR/nvidia-drm.ko" modeset=1 2>/dev/null || true
    # GSP boot, the WPR layout print, then the static BAR1 mapping (printed
    # later, from kbusInitBar1).
    for i in $(seq 1 40); do
        sleep 1
        if dmesg | grep -q "BF16: BAR1MAP"; then
            break
        fi
    done
    sleep 2
    return 0
}

restore_stock() {
    say "-- restoring stock DKMS modules"
    unload || { say "WARN: unload failed; reboot required"; return 1; }
    timeout 120 modprobe nvidia || return 1
    timeout 60 modprobe nvidia_uvm 2>/dev/null || true
    timeout 60 modprobe nvidia_drm modeset=1 2>/dev/null || true
    sleep 5
    nvidia-smi -L || true
}

# Derive target windows from the driver's own boot print. Returns a string of
# --win arguments on stdout.
BAR1_START=0; BAR1_SIZE=0
NW=""; FRTS=""; WPRS=""; BOOTBIN=""

bar1_geom() {
    local out="$1"
    local fbstart fbval gpu_idx line ap gsci ws wl
    fbstart=$(sed -n '2p' "/sys/bus/pci/devices/$GPU0_BDF/resource" | awk '{print $1}')
    fbval=$(( fbstart ))

    line=$(grep "BF16: BAR1MAP" "$out/dmesg.load" | while read -r l; do
        pf=$(echo "$l" | sed -n 's/.*physFb=0x\([0-9a-f]*\).*/\1/p')
        [ -n "$pf" ] && [ $(( 0x$pf )) -eq $fbval ] && { echo "$l"; break; }
    done)
    [ -n "$line" ] || line=$(grep "BF16: BAR1MAP" "$out/dmesg.load" | head -1)
    if [ -z "$line" ]; then
        say "-- no BF16 BAR1MAP print; cannot place windows" >&2
        return
    fi
    gpu_idx=$(echo "$line" | sed -n 's/.*gpu=\([0-9]*\).*/\1/p')
    BAR1_START=$(( 0x$(echo "$line" | sed -n 's/.* start=0x\([0-9a-f]*\).*/\1/p') ))
    BAR1_SIZE=$(( 0x$(echo "$line" | sed -n 's/.* size=0x\([0-9a-f]*\).*/\1/p') ))
    ap=$(echo "$line" | sed -n 's/.* aperture=0x\([0-9a-f]*\).*/\1/p')
    say "-- BAR1MAP gpu=$gpu_idx start=0x$(printf %x "$BAR1_START") size=0x$(printf %x "$BAR1_SIZE") aperture=$ap (fb=$fbstart)"

    # WPR layout: WPRLAYOUT prints before the GSP publishes the fields, so it
    # is all zeros. Use the GSCI line, which carries this boot's values, plus
    # the stock constants (non-WPR heap 3 MiB, bootloader 0x47000).
    NW=""; FRTS=""; WPRS=""; BOOTBIN=""
    gsci=$(dmesg | grep -o 'BF16: GSCI fwWprLayoutOffset nonWprHeap=0x[0-9a-f]* frts=0x[0-9a-f]*' | tail -1)
    if [ -n "$gsci" ]; then
        NW=$(( 0x$(echo "$gsci" | sed -n 's/.*nonWprHeap=0x\([0-9a-f]*\).*/\1/p') ))
        FRTS=$(( 0x$(echo "$gsci" | sed -n 's/.*frts=0x\([0-9a-f]*\).*/\1/p') ))
        WPRS=$(( NW + 0x300000 ))
        BOOTBIN=$(( FRTS - 0x47000 ))
    fi
    wl=$(grep "BF16: WPRLAYOUT gpu=${gpu_idx:-0}" "$out/dmesg.load" | head -1)
    ws=$(echo "$wl" | sed -n 's/.* wprStart=0x\([0-9a-f]*\).*/\1/p')
    [ -n "$ws" ] && [ "$ws" != "0" ] && WPRS=$(( 0x$ws ))
    say "-- WPR: nw=0x$(printf %x "${NW:-0}") wprStart=0x$(printf %x "${WPRS:-0}") bootbin=0x$(printf %x "${BOOTBIN:-0}") frts=0x$(printf %x "${FRTS:-0}")"
}

# The static mapping puts FB offset 0 at BAR1 aperture offset start, so a BAR1
# (resource) offset for FB offset F is start + F. PRAMIN windows take the FB
# offset directly.
make_wins() {
    local args="" name fb x
    for pair in "nw:$NW" "wprstart:$WPRS" "bootbin:$BOOTBIN" "frts:$FRTS"; do
        name="${pair%%:*}"
        [ -n "${pair#*:}" ] && [ "${pair#*:}" != "0" ] || continue
        fb=$(( ${pair#*:} ))
        if [ $(( fb + 0x10000 )) -le $(( BAR1_SIZE )) ]; then
            x=$(( BAR1_START + fb ))
            args="$args --win $name:$x:0x10000"
        else
            say "-- $name fb=0x$(printf %x "$fb") outside static BAR1 [0,0x$(printf %x "$BAR1_SIZE"))" >&2
        fi
    done
    # The same FB offsets through the movable BAR0 PRAMIN window, at several
    # sizes and offsets to find the transfer granularity a peer read gets.
    if [ -n "$WPRS" ]; then
        args="$args --pramin prwpr1k:$WPRS:0x400"
        args="$args --pramin prwpr4k:$WPRS:0x1000"
        args="$args --pramin prwpr64k:$WPRS:0x10000"
        args="$args --pramin prwprp1:$(( WPRS + 0x400 )):0x400"
        args="$args --pramin prwprp4:$(( WPRS + 0x1000 )):0x1000"
        args="$args --pramin prwprp64:$(( WPRS + 0x10000 )):0x1000"
    fi
    [ -n "$BOOTBIN" ] && args="$args --pramin prboot:$BOOTBIN:0x1000"
    [ -n "$FRTS" ] && args="$args --pramin prfrts:$FRTS:0x1000"
    echo "$args"
}

run_phase() {
    local tag="$1" extra="$2"
    say "== phase $tag: registry keys '$extra'"
    unload || die "unload failed before phase $tag"
    load_driver "$extra" || die "insmod failed in phase $tag"
    dmesg > "$OUT/dmesg.load" 2>&1
    nvidia-smi -L || die "no GPUs after load"
    nvidia-smi topo -p2p r 2>&1 | head -6

    local wins
    bar1_geom "$OUT"
    wins=$(make_wins)

    say "-- harness ($tag) args: $wins"
    "$BIN" --gpu0 "$GPU0_BDF" --gpu1 "$GPU1_BDF" --magic \
           --bar1-start "$BAR1_START" \
           --probe map0:0:0x10000 --probe maptop:0x7ffff0000:0x10000 \
           --scan "$BAR1_0" 268435456 $wins | tee "$OUT/peer_$tag.log"

    dmesg > "$OUT/dmesg.$tag" 2>&1
    grep -E "BF16: osCheckGpuBars|osCheckGpuBarsOverlap|Xid|GPU requires reset" \
        "$OUT/dmesg.$tag" | tail -10
    nvidia-smi -L 2>&1 | tee "$OUT/smi.$tag"
}

# ---------------------------------------------------------------------------
lsmod | grep -E '^nvidia' || true
modinfo -F filename nvidia 2>&1 || true
nvidia-smi -L || true

run_phase stock_gate ""
run_phase bypass ";BF16PeerBarIoMem=1"

restore_stock
say "== ollama left stopped (per user)"
say "== done; logs in $OUT"
