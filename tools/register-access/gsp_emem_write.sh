#!/bin/bash
# Is EMEM real read/write storage at PL2, or does EMEMD just loop back?
#
# Writes 0xDEADBEEF to word 0x1FFC with AINCW set, then reads three addresses:
#   0x1FFC  -> expect 0xdeadbeef
#   0x1FF8  -> expect 0          (neighbour, rules out loopback)
#   0x1FFC  -> expect 0xdeadbeef after re-arm (rules out stale read register)
# then restores 0 and verifies.
#
# Arm encoding: EMEMC = (AINCW<<24 | AINCR<<25) | addr[15:0]
#
# Usage: sudo ./gsp_emem_write.sh [gpu_index] [bdf]
# Env: GPU, BDF, REGOPS, OUTDIR (defaults: 0, 0000:c1:00.0, ./regops, ./runs)

set -u
GPU=${GPU:-${1:-0}}
BDF=${BDF:-${2:-0000:c1:00.0}}
DIR=$(cd "$(dirname "$0")" && pwd)
REGOPS=${REGOPS:-$DIR/regops}
OUTDIR=${OUTDIR:-$DIR/runs}
mkdir -p "$OUTDIR"
OUT="$OUTDIR/gsp_emem_write_$(date +%Y%m%d_%H%M%S).txt"
EMEMC=110ac0
EMEMD=110ac4
OFF=0x1ffc
MARK=deadbeef
PASS=0
FAIL=0

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

w_arm=$(printf "01%06x" "$OFF")          # AINCW | addr
r_arm=$(printf "02%06x" "$OFF")          # AINCR | addr
r_arm_prev=$(printf "02%06x" $((OFF - 4)))

run() { timeout 30 "$REGOPS" "$GPU" "$BDF" "$@" 2>&1; }
say() { echo "$@" | tee -a "$OUT"; }

# read one word: arm the port, then one read
# note: regops prints %#010x, which drops the 0x prefix for zero -- normalise it
read_word() {
    local v
    run wr "$EMEMC" "$1" >/dev/null 2>&1
    v=$(run rep "$EMEMD" 01 | awk '/^ *\[ *0\]/ {print $3; exit}')
    case "$v" in
        "")  echo "" ;;
        0x*) echo "$v" ;;
        *)   echo "0x$v" ;;
    esac
}

check() {   # check <label> <got> <want>
    local got want
    got=$(printf '%u' "$2" 2>/dev/null || echo x)
    want=$(printf '%u' "$3" 2>/dev/null || echo y)
    if [ "$got" = "$want" ]; then
        say "  PASS  $1: $2"
        PASS=$((PASS + 1))
    else
        say "  FAIL  $1: got $2, want $3"
        FAIL=$((FAIL + 1))
    fi
}

{
    echo "== GSP EMEM write/readback $(date -Is)"
    echo "== gpu=$GPU bdf=$BDF driver=$(cat /sys/module/nvidia/version 2>/dev/null)"
    echo "== write arm=0x$w_arm  read arm=0x$r_arm"
} | tee "$OUT"

say ""
say "---- 1. arm write port with AINCW and confirm the bit sticks"
run wr "$EMEMC" "$w_arm" | tee -a "$OUT"
arm_rb=$(run dump "$EMEMC" 01 | awk '/0x00110ac0 =/ {print $3}')
check "AINCW arm readback" "$arm_rb" "0x$w_arm"

say ""
say "---- 2. write 0x$MARK to EMEMD"
run wr "$EMEMD" "$MARK" | grep -E "WRITE|READBACK" | tee -a "$OUT"

say ""
say "---- 3. read 0x$OFF back"
got=$(read_word "$r_arm")
check "word at 0x$OFF" "$got" "0x$MARK"

say ""
say "---- 4. read neighbour 0x$(printf %x $((OFF - 4))) (loopback control)"
got_prev=$(read_word "$r_arm_prev")
check "word at 0x$(printf %x $((OFF - 4)))" "$got_prev" "0x0"

say ""
say "---- 5. read 0x$OFF again (stale-read control)"
got2=$(read_word "$r_arm")
check "word at 0x$OFF (2nd)" "$got2" "0x$MARK"

say ""
say "---- 6. restore 0 and verify"
run wr "$EMEMC" "$w_arm" >/dev/null 2>&1
run wr "$EMEMD" 0 | grep -E "WRITE|READBACK" | tee -a "$OUT"
got3=$(read_word "$r_arm")
check "word at 0x$OFF after restore" "$got3" "0x0"

say ""
say "== RESULT: $PASS passed, $FAIL failed"
say "== output: $OUT"
[ "$FAIL" -eq 0 ] || exit 1
