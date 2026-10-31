#!/bin/bash
#
# run_step3.sh - follow-up to run_step1_2.
#
# 1. Read-only stream of the FSP 0x8f0ac0/0x8f0ac4 control/data pair.
# 2. Read-only stream of the SEC2 DMEM 0x8401c0/0x8401c4 pair.
# 3. GSP write/readback/restore of the FECS PLMs and 0x409800:
#      0x409688 <- 0xffffffff  (orig 0xffffffcf)
#      0x409438 <- 0xffffffff  (orig 0xffffffef)
#      0x409660 <- 0xffffffff  (orig 0xfffffbef)
#      0x409800 <- 0x00000000  (orig 0x00000001)
#
# The stream modes write only the control/pointer register, saved first and
# restored at the end.  The FECS tests use regops wrr, which writes, reads,
# restores and reads back in one RPC batch; the script checks the final readback.
#
# Run as root:
#   sudo BDF=0000:41:00.0 GPU=1 ./run_step3.sh
#
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

BDF="${BDF:-0000:41:00.0}"
GPU="${GPU:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REG="${REG:-$HERE/../register-access/regops}"
HW="${HW:-$HERE/hw_probe}"
OUT="${OUTDIR:-$HERE/runs}/hwprobe_$(date +%Y%m%d_%H%M%S)"
ORIG="$OUT/orig_regs.txt"

mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

echo "=== BF16 step 3: FSP/SEC2 streams + FECS write gate ==="
echo "date: $(date -Is)"
echo "BDF=$BDF GPU=$GPU"
echo "logs: $OUT"
echo

if [ ! -x "$REG" ] || [ ! -x "$HW" ]; then
    echo "missing $REG or $HW" >&2
    exit 1
fi

restore_all() {
    local rc=$?
    echo
    echo "=== trap: restore stream pointers (rc=$rc) ==="
    if [ -f "$ORIG" ]; then
        "$HW" restore "$ORIG" | tee "$OUT/99_restore.txt"
    else
        echo "no $ORIG; nothing to restore"
    fi
}
trap restore_all EXIT

check_gsp() {
    local f=$1
    if ! grep -qE 'control status = (0|0x0) \(0\)' "$f"; then
        echo "WARNING: $f: GSP control status is not zero"
        return 2
    fi
    echo "OK: $f: GSP control status zero"
    return 0
}

check_wrr_restore() {
    local f=$1 orig=$2 last orighex
    last=$(grep 'READBACK' "$f" | tail -1 | sed -n 's/.*value=0x0*\([0-9a-f]*\).*/\1/p')
    orighex=$(printf '%x' "$orig")
    if [ "$last" != "$orighex" ]; then
        echo "WARNING: $f final readback 0x$last != 0x$orighex"
        return 1
    fi
    echo "OK: $f final readback restored to 0x$orighex"
    return 0
}

echo "=== health before ==="
nvidia-smi -L
dmesg -T > "$OUT/00_dmesg_before.txt"
grep -iE 'Xid|GSP.*(fault|error)|RmInitAdapter' "$OUT/00_dmesg_before.txt" | tail -20 || true
echo

echo "=== benign GSP read ==="
timeout 30 "$REG" "$GPU" "$BDF" one | tee "$OUT/00_one.txt"
if ! grep -qE 'control status = (0|0x0) \(0\)' "$OUT/00_one.txt"; then
    echo "GSP register-op path is not healthy; aborting" >&2
    exit 1
fi
echo

echo "=== 1: FSP 0x8f0ac0/0x8f0ac4 stream (2048 dwords) ==="
timeout 60 "$HW" stream 0x8f0ac0 0x8f0ac4 0x800 "$ORIG" FSP_8f0ac0 \
    | tee "$OUT/10_fsp_8f0ac0_stream.txt"
echo

echo "=== 2: SEC2 DMEM 0x8401c0/0x8401c4 stream (2048 dwords) ==="
timeout 60 "$HW" stream 0x8401c0 0x8401c4 0x800 "$ORIG" SEC2_DMEM \
    | tee "$OUT/20_sec2_dmem_stream.txt"
echo

echo "=== 3: FECS write-gate tests (GSP wrr) ==="
FECS_OK=1

run_wrr() {
    local tag=$1 off=$2 new=$3 orig=$4 file="$OUT/$1.txt"
    echo "--- $tag: $off <- $new (orig $orig) ---"
    timeout 30 "$REG" "$GPU" "$BDF" wrr "$off" "$new" "$orig" | tee "$file"
    if ! check_gsp "$file"; then
        FECS_OK=0
        return
    fi
    if ! check_wrr_restore "$file" "$orig"; then
        FECS_OK=0
    fi
    echo
}

if [ "$FECS_OK" -eq 1 ]; then
    run_wrr 30_fecs_plm_409688 409688 ffffffff 0xffffffcf
fi
if [ "$FECS_OK" -eq 1 ]; then
    run_wrr 31_fecs_plm_409438 409438 ffffffff 0xffffffef
fi
if [ "$FECS_OK" -eq 1 ]; then
    run_wrr 32_fecs_plm_409660 409660 ffffffff 0xfffffbef
fi
if [ "$FECS_OK" -eq 1 ]; then
    run_wrr 33_fecs_409800 409800 0 0x1
fi
if [ "$FECS_OK" -ne 1 ]; then
    echo "WARNING: a FECS test did not restore cleanly; skipping remaining FECS writes."
    echo "         Reboot before further FECS work."
fi
echo

echo "=== health after ==="
nvidia-smi -L
dmesg -T > "$OUT/90_dmesg_after.txt"
grep -iE 'Xid|GSP.*(fault|error)|RmInitAdapter' "$OUT/90_dmesg_after.txt" | tail -20 || true
echo

echo "=== summaries ==="
for f in "$OUT"/10_fsp_8f0ac0_stream.txt "$OUT"/20_sec2_dmem_stream.txt; do
    echo "--- $(basename "$f") ---"
    grep -E '^==|ctrl (armed|after|restored)|nonzero=' "$f" || true
    echo "top values:"
    awk '/^   \[/{print $NF}' "$f" | sort | uniq -c | sort -rn | head -10
done
echo
for f in "$OUT"/30_*.txt "$OUT"/31_*.txt "$OUT"/32_*.txt "$OUT"/33_*.txt; do
    [ -f "$f" ] || continue
    echo "--- $(basename "$f") ---"
    grep -E 'control status|WRITE|READBACK' "$f" || true
done
echo
echo "=== done; logs in $OUT ==="
