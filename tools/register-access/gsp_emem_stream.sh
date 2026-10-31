#!/bin/bash
# Stream the whole GSP EMEM window out through port 0.
#
# EMEM is 8 KB, addressed as (addr - 512) & 0xfffc in EMEMC(0).  AINCR (bit 25)
# makes each read of the same EMEMD(0) address advance by one word, so we read
# one address 64 times per call and repeat -- the pointer lives in hardware and
# carries across processes.
#
# Read-only once the port is armed.  The single write is EMEMC itself.
#
# Usage: sudo ./gsp_emem_stream.sh [gpu_index] [bdf] [start_word] [total_words]
# Env: GPU, BDF, REGOPS, OUTDIR (defaults: 0, 0000:c1:00.0, ./regops, ./runs)

set -u
GPU=${GPU:-${1:-0}}
BDF=${BDF:-${2:-0000:c1:00.0}}
START=${3:-0}          # in words, relative to the port's addressable base
WORDS=${4:-2048}       # 2048 words = 8 KB
BATCH=64
BATCH_HEX=40           # regops parses counts as hex
DIR=$(cd "$(dirname "$0")" && pwd)
REGOPS=${REGOPS:-$DIR/regops}
OUTDIR=${OUTDIR:-$DIR/runs}
mkdir -p "$OUTDIR"
OUT="$OUTDIR/gsp_emem_stream_$(date +%Y%m%d_%H%M%S).txt"
EMEMC=110ac0
EMEMD=110ac4

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

run() { timeout 30 "$REGOPS" "$GPU" "$BDF" "$@" 2>&1; }

# arm: AINCR | (start_word * 4)
arm=$(printf "02%06x" $((START * 4)))
{
    echo "== GSP EMEM stream $(date -Is)"
    echo "== gpu=$GPU bdf=$BDF driver=$(cat /sys/module/nvidia/version 2>/dev/null)"
    echo "== arming EMEMC(0) = 0x$arm  (AINCR | offset $((START * 4)))"
} | tee "$OUT"

run wr "$EMEMC" "$arm" | tee -a "$OUT"

n=$START
while [ "$n" -lt $((START + WORDS)) ]; do
    # show where the port currently points, then stream a batch
    cur=$(run dump "$EMEMC" 01 | awk '/0x00110ac0 =/ {print $3}')
    {
        echo
        echo "---- words $n..$((n + BATCH - 1))   EMEMC=$cur"
    } | tee -a "$OUT"
    run rep "$EMEMD" "$BATCH_HEX" | tee -a "$OUT"
    rc=${PIPESTATUS[0]}
    if [ "${rc:-0}" -eq 124 ]; then
        echo "---- TIMED OUT: stop and reboot" | tee -a "$OUT"
        exit 1
    elif [ "${rc:-0}" -ne 0 ]; then
        echo "---- rep failed rc=$rc: stopping" | tee -a "$OUT"
        exit 1
    fi
    n=$((n + BATCH))
done

{
    echo
    echo "== done"
    echo "== output: $OUT"
} | tee -a "$OUT"
