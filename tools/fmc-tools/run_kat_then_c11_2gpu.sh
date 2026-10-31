#!/bin/bash
# Step 1: corrected zero-KAT 16! search (both GPUs, disjoint halves).
# If it finds key #37, stop: the FMC mode/IV question can then be answered by
# testing that one key directly.  Otherwise run the c11 (0x30500) FMC oracle
# over the same 16! space on both GPUs, then validate the hits.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$HERE/key37_cuda}
CONTAINERS=${CONTAINERS:-$HERE/containers}
C11=${C11:-$CONTAINERS/c11_00706338_030500.bin}
OUT=${OUT:-$HERE/out/kat_then_c11_2gpu}
TOTAL=20922789888000
HALF=10461394944000

mkdir -p "$OUT/kat0" "$OUT/kat1" "$OUT/c11/gpu0" "$OUT/c11/gpu1"
date -Is > "$OUT/start.txt"

# Step 1: corrected zero-KAT.
( cd "$OUT/kat0" && "$BIN" --device 0 --start 0 --count "$HALF" --chunks 128 \
    > run.log 2>&1; echo $? > rc.txt ) &
P0=$!
( cd "$OUT/kat1" && "$BIN" --device 1 --start "$HALF" --count "$HALF" --chunks 128 \
    > run.log 2>&1; echo $? > rc.txt ) &
P1=$!
wait "$P0" "$P1"
date -Is > "$OUT/kat_end.txt"

if [ -f "$OUT/kat0/key37_found.bin" ] || [ -f "$OUT/kat1/key37_found.bin" ]; then
    if [ -f "$OUT/kat0/key37_found.bin" ]; then
        cp "$OUT/kat0/key37_found.bin" "$OUT/key37_found.bin"
    else
        cp "$OUT/kat1/key37_found.bin" "$OUT/key37_found.bin"
    fi
    grep -h "^FOUND" "$OUT"/kat*/run.log > "$OUT/kat_found.txt" 2>/dev/null
    echo "KAT_FOUND" > "$OUT/status.txt"
    echo done > "$OUT/done.txt"
    exit 0
fi
echo "KAT_NEGATIVE" > "$OUT/status.txt"

# Step 2: c11 FMC oracle over 16!.
( cd "$OUT/c11/gpu0" && "$BIN" --device 0 --fmc-rf --fmc "$C11" \
    --start 0 --count "$HALF" --chunks 128 > run.log 2>&1; echo $? > rc.txt ) &
P0=$!
( cd "$OUT/c11/gpu1" && "$BIN" --device 1 --fmc-rf --fmc "$C11" \
    --start "$HALF" --count "$HALF" --chunks 128 > run.log 2>&1; echo $? > rc.txt ) &
P1=$!
wait "$P0" "$P1"
date -Is > "$OUT/c11_end.txt"

cat "$OUT/c11/gpu0/fmc_hits.txt" "$OUT/c11/gpu1/fmc_hits.txt" > "$OUT/c11/fmc_hits_all.txt" 2>/dev/null
sort -u "$OUT/c11/fmc_hits_all.txt" > "$OUT/c11/fmc_hits.txt"
wc -l "$OUT/c11/fmc_hits_all.txt" "$OUT/c11/fmc_hits.txt" > "$OUT/c11/counts.txt"

if [ -s "$OUT/c11/fmc_hits.txt" ]; then
    python3 -I "$HERE/fmc_hits_test.py" \
        --hits "$OUT/c11/fmc_hits.txt" --container "$C11" > "$OUT/c11/hits_test.log" 2>&1
    python3 -I "$HERE/fmc_fullbody.py" \
        --hits "$OUT/c11/fmc_hits.txt" --container "$C11" --outdir "$OUT/c11/dec" \
        > "$OUT/c11/fullbody.log" 2>&1
fi

echo done > "$OUT/done.txt"
