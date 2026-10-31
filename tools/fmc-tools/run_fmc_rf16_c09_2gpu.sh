#!/bin/bash
# Corrected 16! FMC first-block oracle pass on the debug GB202 container (c09),
# split into two disjoint halves across both 5090s.  RF=16 oracle kernel.
# Writes per-GPU logs and hit files, combines them, then validates the hits
# against the whole container body.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$HERE/key37_cuda}
CONTAINERS=${CONTAINERS:-$HERE/containers}
C09=${C09:-$CONTAINERS/c09_00691480_046200.bin}
OUT=${OUT:-$HERE/out/fmc_run_rf16_c09_2gpu}
TOTAL=20922789888000
HALF=10461394944000

mkdir -p "$OUT/gpu0" "$OUT/gpu1"
date -Is > "$OUT/start.txt"

( cd "$OUT/gpu0" && "$BIN" --device 0 --fmc-rf --fmc "$C09" \
    --start 0 --count "$HALF" --chunks 128 > run.log 2>&1; echo $? > rc.txt ) &
P0=$!
( cd "$OUT/gpu1" && "$BIN" --device 1 --fmc-rf --fmc "$C09" \
    --start "$HALF" --count "$HALF" --chunks 128 > run.log 2>&1; echo $? > rc.txt ) &
P1=$!
wait "$P0" "$P1"
date -Is > "$OUT/end.txt"

cat "$OUT/gpu0/fmc_hits.txt" "$OUT/gpu1/fmc_hits.txt" > "$OUT/fmc_hits_all.txt" 2>/dev/null
sort -u "$OUT/fmc_hits_all.txt" > "$OUT/fmc_hits.txt"
{ wc -l "$OUT/fmc_hits_all.txt" "$OUT/fmc_hits.txt"; } > "$OUT/counts.txt"
{
  echo "gpu0 rc=$(cat "$OUT/gpu0/rc.txt" 2>/dev/null)"
  echo "gpu1 rc=$(cat "$OUT/gpu1/rc.txt" 2>/dev/null)"
  tail -2 "$OUT/gpu0/run.log" 2>/dev/null
  tail -2 "$OUT/gpu1/run.log" 2>/dev/null
} > "$OUT/summary.txt"

if [ -s "$OUT/fmc_hits.txt" ]; then
  python3 -I "$HERE/fmc_hits_test.py" \
    --hits "$OUT/fmc_hits.txt" --container "$C09" > "$OUT/hits_test.log" 2>&1
  python3 -I "$HERE/fmc_fullbody.py" \
    --hits "$OUT/fmc_hits.txt" --container "$C09" --outdir "$OUT/dec" \
    > "$OUT/fullbody.log" 2>&1
fi

echo done > "$OUT/done.txt"
