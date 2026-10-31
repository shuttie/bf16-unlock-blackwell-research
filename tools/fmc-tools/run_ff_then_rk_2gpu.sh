#!/bin/bash
# Re-run the two remaining KAT-hypothesis variants with the corrected
# lexicographic enumeration, both GPUs, disjoint halves:
#   1. FF-block KAT:  AES(K, FF^16) = 717d1494...
#   2. last-round-key: K = round key 10 of schedule(P), AES(K, 0^16) = 717d...
# Stops at the first match.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$HERE/key37_cuda}
OUT=${OUT:-$HERE/out/ff_then_rk_2gpu}
TOTAL=20922789888000
HALF=10461394944000

mkdir -p "$OUT/ff0" "$OUT/ff1" "$OUT/rk0" "$OUT/rk1"
date -Is > "$OUT/start.txt"

run_pair() {
    local tag="$1"; shift
    local extra="$1"; shift
    ( cd "$OUT/${tag}0" && "$BIN" --device 0 $extra --start 0 --count "$HALF" \
        --chunks 128 > run.log 2>&1; echo $? > rc.txt ) &
    local p0=$!
    ( cd "$OUT/${tag}1" && "$BIN" --device 1 $extra --start "$HALF" --count "$HALF" \
        --chunks 128 > run.log 2>&1; echo $? > rc.txt ) &
    local p1=$!
    wait "$p0" "$p1"
}

found() {
    [ -f "$OUT/${1}0/key37_found.bin" ] || [ -f "$OUT/${1}1/key37_found.bin" ]
}

save_key() {
    if [ -f "$OUT/${1}0/key37_found.bin" ]; then
        cp "$OUT/${1}0/key37_found.bin" "$OUT/key37_found.bin"
    else
        cp "$OUT/${1}1/key37_found.bin" "$OUT/key37_found.bin"
    fi
    grep -h "^FOUND" "$OUT"/${1}*/run.log > "$OUT/found_${1}.txt" 2>/dev/null
}

# 1. FF-block KAT.
run_pair ff "--ff"
date -Is > "$OUT/ff_end.txt"
if found ff; then
    save_key ff
    echo "FF_FOUND" > "$OUT/status.txt"
    echo done > "$OUT/done.txt"
    exit 0
fi
echo "FF_NEGATIVE" > "$OUT/status.txt"

# 2. Last-round-key transform.
run_pair rk "--rk"
date -Is > "$OUT/rk_end.txt"
if found rk; then
    save_key rk
    echo "RK_FOUND" >> "$OUT/status.txt"
    echo done > "$OUT/done.txt"
    exit 0
fi
echo "RK_NEGATIVE" >> "$OUT/status.txt"
echo done > "$OUT/done.txt"
