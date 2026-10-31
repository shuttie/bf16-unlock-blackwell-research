#!/bin/bash
#
# run_step1_2.sh - read-only step 1 + step 2 probes from the BF16 investigation.
#
# Run as root:
#   sudo BDF=0000:41:00.0 GPU=1 ./run_step1_2.sh
#
# What it touches:
#   - GSP-mediated READ_32 ops via regops (no writes)
#   - direct BAR0 reads of 0x409xxx, 0x8f0xxx, 0x840xxx, 0x10a0xx
#   - FSP EMEMC channel read pointers: written to arm AINCR, then restored
#   - CMS2 indirect-read address register: written per address, then restored
#
# It does NOT write FEAT_OVR_PLM, SS0/SS1, FUSE_SS_*, or any rate register.
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

echo "=== BF16 step 1+2 probes ==="
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
    echo "=== trap: restore pointer registers (rc=$rc) ==="
    if [ -f "$ORIG" ]; then
        "$HW" restore "$ORIG" | tee "$OUT/99_restore.txt"
    else
        echo "no $ORIG; nothing to restore"
    fi
}
trap restore_all EXIT

echo "=== health before ==="
nvidia-smi -L
dmesg -T > "$OUT/00_dmesg_before.txt"
grep -iE 'Xid|GSP.*(fault|error)|RmInitAdapter' "$OUT/00_dmesg_before.txt" | tail -20 || true
echo

echo "=== 00: benign GSP read (PMC_BOOT_0) ==="
timeout 30 "$REG" "$GPU" "$BDF" one | tee "$OUT/00_one.txt"
# regops prints %#x, so zero is "0", not "0x0".
if ! grep -qE 'control status = (0|0x0) \(0\)' "$OUT/00_one.txt"; then
    echo "GSP register-op path is not healthy; aborting" >&2
    exit 1
fi
echo "(dmesg may contain older Xid lines; the control status is authoritative)"
echo

echo "=== Step 1: FECS / FEAT labelled reads (GSP) ==="
timeout 30 "$REG" "$GPU" "$BDF" dump 409660 8  | tee "$OUT/10_fecs_0x409660.txt"
timeout 30 "$REG" "$GPU" "$BDF" dump 409af8 8  | tee "$OUT/11_fecs_0x409af8.txt"
timeout 30 "$REG" "$GPU" "$BDF" dump 823814 4  | tee "$OUT/12_feat_0x823814.txt"
echo

echo "=== Step 1: GSP map 0x409000-0x409fff (32 x 128 dwords) ==="
: > "$OUT/13_fecs_gsp_map.txt"
for ((b=0x409000; b<0x40a000; b+=0x200)); do
    printf '### base=%#x\n' "$b" >> "$OUT/13_fecs_gsp_map.txt"
    timeout 30 "$REG" "$GPU" "$BDF" dump "$(printf '%x' "$b")" 80 \
        >> "$OUT/13_fecs_gsp_map.txt" 2>&1 \
        || echo "FAILED base=$b" >> "$OUT/13_fecs_gsp_map.txt"
done
echo "wrote $OUT/13_fecs_gsp_map.txt"
echo

echo "=== Step 1: direct BAR0 FECS map + labelled reads ==="
timeout 60 "$HW" fecs | tee "$OUT/14_fecs_direct.txt"
echo

echo "=== Step 2: FSP EMEM, 8 channels x 256 dwords ==="
timeout 60 "$HW" fspemem 0x100 "$ORIG" | tee "$OUT/20_fsp_emem.txt"
echo

echo "=== Step 2: OOBHUB CMS2 indirect read, 0x0-0x1fff ==="
timeout 60 "$HW" cms2 0 0x2000 "$ORIG" | tee "$OUT/21_cms2.txt"
echo

echo "=== Step 2: direct BAR0 Falcon block maps ==="
timeout 60 "$HW" falcon 0x8f0000 0x400 | tee "$OUT/22_fsp_block_direct.txt"
timeout 60 "$HW" falcon 0x840000 0x800 | tee "$OUT/23_sec2_block_direct.txt"
timeout 60 "$HW" falcon 0x10a000 0x400 | tee "$OUT/24_pmu_block_direct.txt"
echo

echo "=== Step 2: GSP maps of FSP / SEC2 / PMU blocks ==="
scan_gsp() {
    local base="$1" bytes="$2" tag="$3"
    local end=$((base + bytes)) b
    : > "$OUT/$tag"
    for ((b=base; b<end; b+=0x200)); do
        printf '### base=%#x\n' "$b" >> "$OUT/$tag"
        timeout 30 "$REG" "$GPU" "$BDF" dump "$(printf '%x' "$b")" 80 \
            >> "$OUT/$tag" 2>&1 \
            || echo "FAILED base=$b" >> "$OUT/$tag"
    done
    echo "wrote $OUT/$tag"
}
scan_gsp 0x8f0000 0x1000 30_fsp_gsp_map.txt
scan_gsp 0x840000 0x2000 31_sec2_gsp_map.txt
scan_gsp 0x10a000 0x1000 32_pmu_gsp_map.txt
echo

echo "=== health after ==="
nvidia-smi -L
dmesg -T > "$OUT/90_dmesg_after.txt"
grep -iE 'Xid|GSP.*(fault|error)|RmInitAdapter' "$OUT/90_dmesg_after.txt" | tail -20 || true
echo

echo "=== quick summaries ==="
echo "GSP non-success statuses in FECS map:"
grep -E 'status=[1-9]' "$OUT/13_fecs_gsp_map.txt" | head -20 || true
echo "FECS/FSP/SEC2/PMU badf-sentinel counts (direct):"
for f in "$OUT"/14_fecs_direct.txt "$OUT"/22_fsp_block_direct.txt \
         "$OUT"/23_sec2_block_direct.txt "$OUT"/24_pmu_block_direct.txt; do
    printf '  %-45s ' "$(basename "$f")"
    grep -c 'badf' "$f" || true
done
echo
echo "FSP EMEM nonzero counts:"
grep -E 'nonzero=' "$OUT/20_fsp_emem.txt" || true
echo "CMS2 nonzero count:"
grep -E 'CMS2 summary' "$OUT/21_cms2.txt" || true
echo
echo "=== done; logs in $OUT ==="
