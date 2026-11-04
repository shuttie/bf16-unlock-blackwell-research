#!/usr/bin/env bash
# run_c27.sh - C27 debugger-class command census.
#
# Builds the hook and the CUDA probe, runs the census against device 0, and
# stores the log. No root and no register writes. C27_SUSPEND=1 adds the
# context suspend/resume pair (state-changing; run it only after the read-only
# pass).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/runs/c27_$(date +%Y%m%d_%H%M%S)"
CUBIN="${C27_CUBIN:-$HERE/../issue-rate-probe/tensor_modes_issue_sm120.cubin}"

mkdir -p "$OUT"

echo "== build"
gcc -O2 -Wall -shared -fPIC -o "$HERE/c27_hook.so" "$HERE/c27_hook.c" -ldl
gcc -O2 -Wall -o "$HERE/c27_probe" "$HERE/c27_probe.c" \
    -I/usr/local/cuda/include -L/usr/local/cuda/lib64 -lcuda

echo "== run (cubin=$CUBIN)"
set +e
C27_CUBIN="$CUBIN" \
LD_LIBRARY_PATH=/usr/local/cuda/lib64 \
LD_PRELOAD="$HERE/c27_hook.so" \
    "$HERE/c27_probe" > "$OUT/probe.out" 2> "$OUT/census.log"
rc=$?
set -e

echo "== probe stdout"
cat "$OUT/probe.out"
echo "== census"
cat "$OUT/census.log"

# Optional kernel log delta: informational, not required.
if command -v dmesg >/dev/null 2>&1 && dmesg -T >/dev/null 2>&1; then
    dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
fi

echo "== rc=$rc out=$OUT"
