#!/bin/bash
# Run regops gprobe (and optionally gw) while a CUDA context is live on the
# target GPU.  The GR_CTX regtypes return NV_ERR_INVALID_ARGUMENT with no
# channel; a live context tests whether a channel is the missing argument.
#
#   sudo ./gprobe_with_ctx.sh          # read-only gprobe
#   sudo ./gprobe_with_ctx.sh gw       # gprobe, then gw 1 504204 0 5
set -u
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
MODE="${1:-probe}"
BDF="${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}"
GPU="${GPU:-1}"
UUID="${UUID:?set UUID to the target GPU UUID}"
ROOT="$(cd "$TOOL_DIR/../../.." && pwd)"
CTX="$TOOL_DIR/cuda_ctx"
REGOPS="$TOOL_DIR/../register-access/regops"
OUT="$TOOL_DIR/runs/gprobe_$(date +%Y%m%d_%H%M%S)_$MODE"
mkdir -p "$OUT"
say() { echo "$@" | tee -a "$OUT/run.log"; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 [gw])"
[ -x "$CTX" ] || die "missing $CTX"
[ -x "$REGOPS" ] || die "missing $REGOPS"

export CUDA_VISIBLE_DEVICES="$UUID"
"$CTX" 90 > "$OUT/ctx.log" 2>&1 &
KPID=$!
trap 'kill "$KPID" 2>/dev/null' EXIT
sleep 2
grep -q "ctx ok" "$OUT/ctx.log" || { cat "$OUT/ctx.log"; die "CUDA context failed"; }
say "== CUDA context live on $UUID (pid $KPID)"

if [ "$MODE" = "route" ]; then
    say "== gprobe_route (GR_CTX with route flags 0..3)"
    "$REGOPS" "$GPU" "$BDF" gprobe_route | tee "$OUT/gprobe_route.txt"
else
    say "== gprobe (target $BDF, deviceId $GPU)"
    "$REGOPS" "$GPU" "$BDF" gprobe | tee "$OUT/gprobe.txt"
fi

if [ "$MODE" = "gw" ]; then
    say "== gw 1 504204 0 5 (GR_CTX write 0, restore 5)"
    "$REGOPS" "$GPU" "$BDF" gw 1 504204 0 5 | tee "$OUT/gw.txt"
    say "== run the sm_120 probe now to see whether the context write moved the rate"
fi
say "== done: $OUT"
