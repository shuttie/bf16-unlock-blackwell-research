#!/bin/bash
# run_peer_read.sh -- root harness for the peer BAR1 read (experiment 27.4).
#
# Maps the first GPU's BAR1 through sysfs, then asks the second GPU's copy
# engine to DMA-read the same offsets. Read-only: no register or firmware
# writes. The only mutating step is CUDA context setup.
#
# Usage:
#   sudo ./run_peer_read.sh            # stock driver, auto-locate the WPR
#   sudo ./run_peer_read.sh --wins "name:off:len ..."   # explicit targets
#
# The WPR offsets are taken from the instrumented driver's boot log when
# present ("BF16: GSCI fwWprLayoutOffset ..."), else located by scanning BAR1
# for the 0xbad0ac00 fill.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS="$DIR/runs"
mkdir -p "$RUNS"
OUT="$RUNS/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/run.log"
exec > >(tee -a "$LOG") 2>&1

GPU0_BDF="${GPU0_BDF:-0000:41:00.0}"
GPU1_BDF="${GPU1_BDF:-0000:c1:00.0}"
BAR1_0="/sys/bus/pci/devices/$GPU0_BDF/resource1"
BIN="$DIR/peer_read"
WINS_OPT=""
if [ "${1:-}" = "--wins" ]; then
    WINS_OPT="${2:?--wins needs a spec}"
fi

say() { echo "$@"; }

say "== peer BAR1 read $(date -Is) pid=$$ uid=$(id -u)"
if [ "$(id -u)" -ne 0 ]; then
    say "ERROR: must run as root (BAR1 resource files are 0600 yet accept mmap)"
    exit 1
fi
[ -x "$BIN" ] || { say "ERROR: $BIN missing; build with make"; exit 1; }
[ -r "$BAR1_0" ] || { say "ERROR: $BAR1_0 not readable"; exit 1; }

say "-- pre-state"
nvidia-smi -L 2>&1 | tee "$OUT/nvidia-smi-L.pre"
nvidia-smi topo -p2p r 2>&1
nvidia-smi topo -p2p w 2>&1
lsmod | grep -E '^nvidia' || true
modinfo -F filename nvidia 2>&1
dmesg | tail -40 > "$OUT/dmesg.pre" 2>&1

# A non-NVIDIA device memory BAR: positive control for IOMEMORY registration.
# Without it a failure on the GPU BAR cannot be told apart from "this driver
# does not register I/O memory at all".
control=""
for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] && continue
    for n in 0 1 2 3 4 5; do
        f="$d/resource$n"
        [ -r "$f" ] || continue
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        [ "$sz" -ge 4096 ] || continue
        [ "$sz" -le 16777216 ] || continue
        flags=$(sed -n "$((n + 1))p" "$d/resource" 2>/dev/null | awk '{print $3}')
        [ -n "$flags" ] || continue
        # IORESOURCE_MEM = 0x200
        [ $(( flags & 0x200 )) -ne 0 ] || continue
        control="$f"
        break 2
    done
done
say "-- I/O memory control BAR: ${control:-none found}"

ctl_args=()
[ -n "$control" ] && ctl_args=(--control "$control" 0 0x10000)

# Locate the WPR: prefer the instrumented driver's published layout.
gsci=$(dmesg | grep -o 'BF16: GSCI fwWprLayoutOffset nonWprHeap=0x[0-9a-f]* frts=0x[0-9a-f]*' | tail -1)
win_args=()
if [ -n "$gsci" ]; then
    nw=$(echo "$gsci" | sed -n 's/.*nonWprHeap=0x\([0-9a-f]*\).*/\1/p')
    frts=$(echo "$gsci" | sed -n 's/.*frts=0x\([0-9a-f]*\).*/\1/p')
    say "-- GSCI layout: nonWprHeap=0x$nw frts=0x$frts"
    # stock non-WPR heap is 3 MiB; the WPR base sits right above it.
    wprbase=$(( 0x$nw + 0x300000 ))
    win_args=(--win "nw:0x$nw:0x10000"
              --win "wprbase:$wprbase:0x10000"
              --win "boot:$(( 0x$frts - 0x50000 )):0x10000"
              --win "frts:0x$frts:0x10000")
else
    say "-- no BF16 layout in dmesg; scanning BAR1 for the WPR fill"
    # BAR1 chunks: a single 32 GiB mmap is refused with EINVAL. Try coarser
    # to finer chunk sizes until one maps.
    scanout=""
    for chunk in 268435456 67108864 16777216 4194304; do
        scanout=$("$BIN" --gpu0 "$GPU0_BDF" --gpu1 "$GPU1_BDF" \
                  --probe map0:0:0x10000 --probe maptop:0x7ffff0000:0x10000 \
                  --scan "$BAR1_0" "$chunk" "${ctl_args[@]}")
        ok=$(echo "$scanout" | sed -n 's/.*scan:chunks_ok=\([0-9]*\).*/\1/p')
        say "-- chunk 0x$(printf %x "$chunk"): chunks_ok=${ok:-0}"
        [ "${ok:-0}" -gt 0 ] && break
    done
    echo "$scanout" | tee "$OUT/scan.log"
    s=$(echo "$scanout" | sed -n 's/.*scan:sentinel start=0x\([0-9a-f]*\).*/\1/p')
    e=$(echo "$scanout" | sed -n 's/.*scan:sentinel end=0x\([0-9a-f]*\).*/\1/p')
    if [ -n "$s" ]; then
        say "-- WPR fill: start=0x$s end=0x$e"
        nw=$(( 0x$s - 0x300000 ))
        win_args=(--win "nw:$nw:0x10000"
                  --win "wprbase:0x$s:0x10000"
                  --win "wprtail:$(( 0x$e - 0x10000 )):0x10000")
    else
        win_args=(--win wprbase:0x7e75e0000:0x10000
                  --win nw:0x7e72e0000:0x10000)
        say "WARN: no WPR fill found; trying the stock offsets as a shot in the dark"
    fi
fi

if [ -n "$WINS_OPT" ]; then
    read -r -a win_args <<< "$WINS_OPT"
fi

say "-- target windows: ${win_args[*]:-none}"
say "-- peer run"
"$BIN" --gpu0 "$GPU0_BDF" --gpu1 "$GPU1_BDF" "${ctl_args[@]}" "${win_args[@]}" \
    | tee "$OUT/peer_read.log"

say "-- post-state"
dmesg | tail -80 > "$OUT/dmesg.post" 2>&1
grep -E "Xid|NVRM:.*(error|fail|overlap|BAR)|BUG:" "$OUT/dmesg.post" | tail -20 || true
nvidia-smi -L 2>&1 | tee "$OUT/nvidia-smi-L.post"
say "== done; logs in $OUT"
