#!/bin/bash
# Stage B: drive the GSP EMEM port from PL2 (GSP-RM) and read 256 bytes out of it.
#
# EMEMC(0) = 0x110ac0, EMEMD(0) = 0x110ac4.  Value written is AINCR(bit25) | addr 0,
# which is exactly what GSP-RM's own FUN_ram_0166a4fc programs.
#
# The script stops before reading if the write does not stick -- a dropped write
# means the port is PLM-gated at level 2 and the route is closed.
#
# Usage: sudo ./gsp_emem.sh [gpu_index] [bdf]
# Env: GPU, BDF, REGOPS, OUTDIR (defaults: 0, 0000:c1:00.0, ./regops, ./runs)

set -u
GPU=${GPU:-${1:-0}}
BDF=${BDF:-${2:-0000:c1:00.0}}
DIR=$(cd "$(dirname "$0")" && pwd)
REGOPS=${REGOPS:-$DIR/regops}
OUTDIR=${OUTDIR:-$DIR/runs}
mkdir -p "$OUTDIR"
OUT="$OUTDIR/gsp_emem_$(date +%Y%m%d_%H%M%S).txt"
EMEMC=110ac0
EMEMD=110ac4
VAL=02000000          # AINCR | address 0

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

run() { timeout 30 "$REGOPS" "$GPU" "$BDF" "$@" 2>&1; }

{
    echo "== GSP EMEM probe $(date -Is)"
    echo "== gpu=$GPU bdf=$BDF driver=$(cat /sys/module/nvidia/version 2>/dev/null)"
    echo
    echo "---- baseline: EMEMC(0)/EMEMD(0)"
} | tee "$OUT"
run dump "$EMEMC" 02 | tee -a "$OUT"

{
    echo
    echo "---- write EMEMC(0) = 0x$VAL"
} | tee -a "$OUT"
wout=$(run wr "$EMEMC" "$VAL")
echo "$wout" | tee -a "$OUT"
rc=$?
if [ "$rc" -eq 124 ]; then
    echo "---- TIMED OUT: stop here and reboot" | tee -a "$OUT"
    exit 1
fi

rb=$(sed -n 's/.*READBACK.*value=\(0x[0-9a-fA-F]*\).*/\1/p' <<<"$wout")
if [ -z "$rb" ]; then
    echo "---- could not parse readback, not reading EMEM" | tee -a "$OUT"
    exit 1
fi
if [ "$((rb))" -ne "$((0x$VAL))" ]; then
    {
        echo "---- WRITE DROPPED: readback $rb != 0x$VAL"
        echo "---- the port is gated at PL2; stopping without reading EMEM"
    } | tee -a "$OUT"
    exit 0
fi

{
    echo
    echo "---- write stuck; reading 256 bytes from EMEMD(0), AINCR"
} | tee -a "$OUT"
run dump "$EMEMD" 40 | tee -a "$OUT"
rc=$?
if [ "$rc" -eq 124 ]; then
    echo | tee -a "$OUT"
    echo "---- TIMED OUT during EMEM read: stop here and reboot" | tee -a "$OUT"
    exit 1
fi

{
    echo
    echo "== done"
    echo "== output: $OUT"
} | tee -a "$OUT"
