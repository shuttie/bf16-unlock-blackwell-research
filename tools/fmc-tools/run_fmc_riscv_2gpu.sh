#!/bin/bash
# RISC-V-validity FMC oracle over the whole 16! key space, split across both
# 5090s.  The encrypted container body is [code][data][manifest 0xa00], so the
# first block is RISC-V code; the old magic oracle could discard the true key.
# Stage 1 scores one block against a parcel language model; Stage 2 (8 blocks)
# runs only for Stage-1 survivors.  Every hit is checked against the whole code
# component (fmc_riscv_verify.py).
#
# Usage: run_fmc_riscv_2gpu.sh <container.bin> <outdir> [cross-container.bin]
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$HERE/key37_cuda}
LOGP=${LOGP:-$HERE/riscv_logp_q.bin}
CONTAINER=${1:?usage: $0 <container.bin> <outdir> [cross-container.bin]}
OUT=${2:?usage: $0 <container.bin> <outdir> [cross-container.bin]}
CROSS=${3:-}
# The oracle runs with cwd=$OUT/gpuN, so every path passed to it must be absolute.
CONTAINER=$(realpath "$CONTAINER")
OUT=$(realpath -m "$OUT")
if [ -n "$CROSS" ]; then
  CROSS=$(realpath "$CROSS")
fi
[ -x "$BIN" ] || { echo "oracle binary missing: $BIN" >&2; exit 2; }
[ -f "$LOGP" ] || { echo "logp table missing: $LOGP" >&2; exit 2; }
[ -f "$CONTAINER" ] || { echo "container missing: $CONTAINER" >&2; exit 2; }
TOTAL=${TOTAL:-20922789888000}
HALF=${HALF:-10461394944000}
BLOCKS=${BLOCKS:-8}
CHUNKS=${CHUNKS:-128}

mkdir -p "$OUT/gpu0" "$OUT/gpu1"
date -Is > "$OUT/start.txt"
sha256sum "$CONTAINER" "$LOGP" > "$OUT/inputs.sha256"

( cd "$OUT/gpu0" && "$BIN" --device 0 --fmc-riscv --fmc "$CONTAINER" \
    --logp "$LOGP" --riscv-blocks "$BLOCKS" --start 0 --count "$HALF" \
    --chunks "$CHUNKS" > run.log 2>&1; echo $? > rc.txt ) &
P0=$!
( cd "$OUT/gpu1" && "$BIN" --device 1 --fmc-riscv --fmc "$CONTAINER" \
    --logp "$LOGP" --riscv-blocks "$BLOCKS" --start "$HALF" --count "$HALF" \
    --chunks "$CHUNKS" > run.log 2>&1; echo $? > rc.txt ) &
P1=$!
wait "$P0" "$P1"
date -Is > "$OUT/end.txt"

cat "$OUT/gpu0/fmc_hits.txt" "$OUT/gpu1/fmc_hits.txt" > "$OUT/fmc_hits_all.txt" 2>/dev/null
sort -u "$OUT/fmc_hits_all.txt" > "$OUT/fmc_hits.txt"
{
  echo "gpu0 rc=$(cat "$OUT/gpu0/rc.txt" 2>/dev/null)"
  echo "gpu1 rc=$(cat "$OUT/gpu1/rc.txt" 2>/dev/null)"
  tail -1 "$OUT/gpu0/run.log" 2>/dev/null
  tail -1 "$OUT/gpu1/run.log" 2>/dev/null
  wc -l "$OUT/fmc_hits_all.txt" "$OUT/fmc_hits.txt"
} > "$OUT/summary.txt"

if [ -s "$OUT/fmc_hits.txt" ]; then
  if [ -n "$CROSS" ]; then
    python3 -I "$HERE/fmc_riscv_verify.py" --hits "$OUT/fmc_hits.txt" \
      --container "$CONTAINER" --cross "$CROSS" --outdir "$OUT/dec" \
      > "$OUT/verify.log" 2>&1
  else
    python3 -I "$HERE/fmc_riscv_verify.py" --hits "$OUT/fmc_hits.txt" \
      --container "$CONTAINER" --outdir "$OUT/dec" > "$OUT/verify.log" 2>&1
  fi
fi

echo done > "$OUT/done.txt"
