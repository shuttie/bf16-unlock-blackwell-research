#!/bin/bash
#
# run_step4_fsp_emem.sh - GSP-side test of the FSP core EMEM pair 0x8f0ac0/4,
# plus read-only maps of the FSP block and the PFSP EMEM block.
#
# Run as root:
#   sudo ./run_step4_fsp_emem.sh
#
# What it writes (only when the GSP path is healthy):
#   - 0x8f0ac0 (Falcon EMEMC ch0) through NV2080_CTRL_CMD_GPU_EXEC_REG_OPS:
#       1. wrr 8f0ac0 <orig|AINCR> <orig>   (write/read/restore/read, one RPC)
#       2. if that lands, ememstream: write ctrl, read ctrl, read 16 data
#          words from the current pointer, restore ctrl, read ctrl, read data
#          -- all in one RPC batch
#       3. if that lands, ememstream from OFFS=0/BLK=0 for 32 words
#   - If the AINCR write is dropped, one more diagnostic: wrr with only the
#     OFFS/BLK bits cleared (no AINCR), still restored in the same RPC batch.
#   Nothing else is written.  All other modes are read-only.
#
# The 0x8f0a90 dword is a PLM-shaped word (0xffffff8f = write L3 only), so the
# predicted result is a drop at PL2.  This script measures it rather than
# assuming it.
#
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

BDF="${BDF:-0000:41:00.0}"
GPU="${GPU:-1}"
BDF0="${BDF0:-0000:c1:00.0}"
GPU0="${GPU0:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REG="${REG:-$HERE/../register-access/regops}"
OUT="${OUTDIR:-$HERE/runs}/fsp_emem_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

hexval() {
    # $1 = file, $2 = 0x........ offset as printed by `regops dump`
    awk -v o="$2" '$1 == o { v=$3; sub(/^0x/, "", v); print v; exit }' "$1"
}

norm() {
    local v="${1#0x}"
    [ -n "$v" ] || { echo "00000000"; return; }
    printf '%08x' "$((16#$v))"
}

rb_wrr() {
    # both READBACK values from a wrr log, one per line
    awk '/READBACK/ { v=$5; sub(/^value=/, "", v); print v }' "$1"
}

data_words() {
    # values from all DATA[..] lines of an ememstream log
    awk '/DATA\[/ { for (i=1;i<=NF;i++) if ($i == "=") { print $(i+1); break } }' "$1"
}

same_fields() {
    # compare the documented EMEMC fields: OFFS[7:2], BLK[15:8],
    # AINCW[24], AINCR[25].  Reserved/undecoded high bits are reported but
    # not treated as a failed write.
    [ "$(( (0x$1 ^ 0x$2) & 0x03fffffc ))" -eq 0 ]
}

ctrl_reads() {
    # both ctrl readbacks from an ememstream log
    awk '/CTRL READ/ { for (i=1;i<=NF;i++) if ($i == "=") { print $(i+1); exit } }' "$1"
}

dumpg() {
    local tag=$1 off=$2 cnt=$3
    echo "--- $tag ($off x $cnt, GSP $BDF) ---"
    timeout 30 "$REG" "$GPU" "$BDF" dump "$off" "$cnt" | tee "$OUT/$tag.txt"
}

barg() {
    local tag=$1 off=$2 cnt=$3
    echo "--- $tag ($off x $cnt, host BAR0 $BDF) ---"
    timeout 30 "$REG" "$GPU" "$BDF" bar "$off" "$cnt" | tee "$OUT/$tag.txt"
}

dump0() {
    local tag=$1 off=$2 cnt=$3
    echo "--- $tag ($off x $cnt, GSP $BDF0) ---"
    timeout 30 "$REG" "$GPU0" "$BDF0" dump "$off" "$cnt" | tee "$OUT/$tag.txt" || true
}

bar0() {
    local tag=$1 off=$2 cnt=$3
    echo "--- $tag ($off x $cnt, host BAR0 $BDF0) ---"
    timeout 30 "$REG" "$GPU0" "$BDF0" bar "$off" "$cnt" | tee "$OUT/$tag.txt" || true
}

CTRL=""
restore_on_exit() {
    local rc=$?
    echo
    echo "=== trap: verify 0x8f0ac0 and capture health (rc=$rc) ==="
    if [ -n "${CTRL:-}" ]; then
        timeout 15 "$REG" "$GPU" "$BDF" dump 8f0ac0 4 | tee "$OUT/98_after_trap_dump.txt" || true
        local cur
        cur=$(norm "$(hexval "$OUT/98_after_trap_dump.txt" 0x008f0ac0)")
        if [ -z "$cur" ]; then
            echo "WARNING: could not read 0x8f0ac0 in the trap"
        elif ! same_fields "$cur" "$CTRL"; then
            echo "WARNING: 0x8f0ac0 = 0x$cur, expected 0x$CTRL; restoring"
            timeout 15 "$REG" "$GPU" "$BDF" wrr 8f0ac0 "$CTRL" "$CTRL" \
                | tee "$OUT/99_trap_restore.txt" || true
        else
            echo "OK: 0x8f0ac0 is back at 0x$CTRL"
        fi
    fi
    echo
    echo "=== health after ==="
    timeout 20 nvidia-smi -L || true
    dmesg -T > "$OUT/97_dmesg_after.txt" 2>&1 || true
    grep -iE 'Xid|GSP.*(fault|error)|RmInitAdapter' "$OUT/97_dmesg_after.txt" | tail -20 || true
    echo
    echo "=== done; logs in $OUT ==="
}
trap restore_on_exit EXIT

echo "=== BF16 step 4: FSP core EMEM 0x8f0ac0/4 + PFSP EMEM wide look ==="
echo "date: $(date -Is)"
echo "BDF=$BDF GPU=$GPU  |  BDF0=$BDF0 GPU0=$GPU0"
echo "logs: $OUT"
echo

echo "=== health before ==="
timeout 20 nvidia-smi -L || true
dmesg -T > "$OUT/00_dmesg_before.txt" 2>&1 || true
grep -iE 'Xid|GSP.*(fault|error)|RmInitAdapter' "$OUT/00_dmesg_before.txt" | tail -20 || true
echo

echo "=== benign GSP read ==="
timeout 30 "$REG" "$GPU" "$BDF" one | tee "$OUT/01_one.txt"
if ! grep -qE 'control status = (0|0x0) \(0\)' "$OUT/01_one.txt"; then
    echo "GSP register-op path is not healthy; aborting" >&2
    exit 1
fi
echo

echo "=== read-only: FSP core block + PFSP EMEM ==="
dumpg 10_fsp_core_8f0a00_gsp 8f0a00 64
barg  11_fsp_core_8f0a00_host 8f0a00 64
dumpg 12_fsp_core_8f0ac0_gsp 8f0ac0 8
barg  13_fsp_core_8f0ac0_host 8f0ac0 8
dump0 14_fsp_core_8f0ac0_gpu0_gsp 8f0ac0 8
bar0  15_fsp_core_8f0ac0_gpu0_host 8f0ac0 8
echo

dumpg 16_falcon_hwcfg_gsp 8f0100 16
dumpg 17_falcon_imem_port_gsp 8f0180 8
dumpg 18_falcon_dmem_port_gsp 8f01c0 8
dumpg 19_falcon_engine_gsp 8f03c0 8
echo

dumpg 20_pfsp_emem_gsp 8f2ac0 16
barg  21_pfsp_emem_host 8f2ac0 16
dump0 22_pfsp_emem_gpu0_gsp 8f2ac0 16
bar0  23_pfsp_emem_gpu0_host 8f2ac0 16
dumpg 24_pfsp_emem_wide_gsp 8f2a80 128
barg  25_pfsp_emem_wide_host 8f2a80 64
dumpg 26_pfsp_emem_wide_gsp2 8f2b80 128
barg  27_pfsp_emem_wide_host2 8f2b80 64
echo

CTRL_RAW=$(hexval "$OUT/12_fsp_core_8f0ac0_gsp.txt" 0x008f0ac0)
DATA_RAW=$(hexval "$OUT/12_fsp_core_8f0ac0_gsp.txt" 0x008f0ac4)
echo "GSP originals: 0x8f0ac0=$CTRL_RAW  0x8f0ac4=$DATA_RAW"
if [ -z "$CTRL_RAW" ] || [ -z "$DATA_RAW" ]; then
    echo "could not parse the pair; aborting before any write" >&2
    exit 2
fi
case "$CTRL_RAW$DATA_RAW" in
    *badf*|*BADF*)
        echo "pair reads a bad-read sentinel; aborting before any write" >&2
        exit 2
        ;;
esac
CTRL=$(norm "$CTRL_RAW")
DATA=$(norm "$DATA_RAW")
NEW=$(printf '%08x' "$(( 0x$CTRL | 0x02000000 ))")
NEW_PTR=$(printf '%08x' "$(( 0x$CTRL & ~0x0000fffc ))")
NEW0=$(printf '%08x' "$(( (0x$CTRL & ~0x0000fffc) | 0x02000000 ))")
echo "derived: ctrl=$CTRL data=$DATA  ctrl|AINCR=$NEW  ctrl&~OFFS/BLK=$NEW_PTR  addr0|AINCR=$NEW0"
echo

echo "=== write gate A: set AINCR only (pointer unchanged), one non-transactional RPC ==="
timeout 30 "$REG" "$GPU" "$BDF" ememstream 8f0ac0 8f0ac4 "$NEW" "$CTRL" 1 \
    | tee "$OUT/30_emem_aincr.txt"
LANDED=0
if grep -q 'after new.*LANDED' "$OUT/30_emem_aincr.txt"; then
    LANDED=1
    echo "RESULT A: 0x8f0ac0 is GSP-writable (documented AINCR/OFFS/BLK fields read back)."
else
    echo "RESULT A: control write DROPPED at PL2."
fi
A0=$(norm "$(data_words "$OUT/30_emem_aincr.txt" | head -1)")
echo "gate A data word=$A0 (saved data word=$DATA)"
if ! grep -q 'after restore.*-> RESTORED' "$OUT/30_emem_aincr.txt"; then
    echo "WARNING: gate A restore failed; retrying with wrr"
    timeout 30 "$REG" "$GPU" "$BDF" wrr 8f0ac0 "$CTRL" "$CTRL" \
        | tee "$OUT/31_restore_retry.txt"
    LAST=$(norm "$(rb_wrr "$OUT/31_restore_retry.txt" | tail -1)")
    if ! same_fields "$LAST" "$CTRL"; then
        echo "FATAL: cannot restore 0x8f0ac0; stopping before further writes." >&2
        exit 3
    fi
fi
echo

if [ "$LANDED" -eq 0 ]; then
    if [ "$NEW_PTR" = "$CTRL" ]; then
        echo "=== write gate B skipped: the OFFS/BLK fields are already zero ==="
        echo "RESULT B: cannot distinguish a same-value write from a drop."
    else
        echo "=== write gate B: pointer bits only (no AINCR) + single-word read ==="
        timeout 30 "$REG" "$GPU" "$BDF" ememstream 8f0ac0 8f0ac4 "$NEW_PTR" "$CTRL" 1 \
            | tee "$OUT/32_emem_pointer.txt"
        if grep -q 'after new.*LANDED' "$OUT/32_emem_pointer.txt"; then
            echo "RESULT B: pointer bits are GSP-writable, AINCR is not."
            B0=$(norm "$(data_words "$OUT/32_emem_pointer.txt" | head -1)")
            echo "single word read at OFFS=0/BLK=0: $B0 (pointer-control read path works)"
        else
            echo "RESULT B: pointer bits are also dropped; the whole control is read-only at PL2."
        fi
        if ! grep -q 'after restore.*-> RESTORED' "$OUT/32_emem_pointer.txt"; then
            echo "WARNING: pointer test restore failed; retrying with wrr"
            timeout 30 "$REG" "$GPU" "$BDF" wrr 8f0ac0 "$CTRL" "$CTRL" \
                | tee "$OUT/32_restore_retry.txt"
            LAST=$(norm "$(rb_wrr "$OUT/32_restore_retry.txt" | tail -1)")
            if ! same_fields "$LAST" "$CTRL"; then
                echo "FATAL: cannot restore 0x8f0ac0; stopping." >&2
                exit 3
            fi
        fi
    fi
    echo
else
    echo "=== stream: 16 words from the current pointer (AINCR) ==="
    timeout 30 "$REG" "$GPU" "$BDF" ememstream 8f0ac0 8f0ac4 "$NEW" "$CTRL" 16 \
        | tee "$OUT/33_stream_current.txt"
    D0_RAW=$(data_words "$OUT/33_stream_current.txt" | head -1)
    D0=$(norm "${D0_RAW:-0}")
    echo "first streamed word=$D0 (saved data word=$DATA)"
    if [ "$D0" = "$DATA" ]; then
        echo "RESULT C: pointer preserved and AINCR works; the pair streams FSP EMEM."
    else
        echo "RESULT C: stream did not start at the saved pointer (or AINCR is not honored)."
    fi
    NDISTINCT=$(data_words "$OUT/33_stream_current.txt" | sort -u | wc -l)
    echo "distinct data words in the 16-word stream: $NDISTINCT"
    if grep -q 'NOT RESTORED' "$OUT/33_stream_current.txt"; then
        echo "WARNING: ememstream restore failed; retrying"
        timeout 30 "$REG" "$GPU" "$BDF" wrr 8f0ac0 "$CTRL" "$CTRL" \
            | tee "$OUT/34_stream_restore_retry.txt"
        LAST=$(norm "$(rb_wrr "$OUT/34_stream_restore_retry.txt" | tail -1)")
        if ! same_fields "$LAST" "$CTRL"; then
            echo "FATAL: cannot restore 0x8f0ac0; stopping." >&2
            exit 3
        fi
    fi
    echo

    echo "=== stream: 32 words from OFFS=0/BLK=0 (high ctrl bits preserved) ==="
    timeout 30 "$REG" "$GPU" "$BDF" ememstream 8f0ac0 8f0ac4 "$NEW0" "$CTRL" 32 \
        | tee "$OUT/35_stream_addr0.txt"
    NDISTINCT2=$(data_words "$OUT/35_stream_addr0.txt" | sort -u | wc -l)
    echo "distinct data words in the 32-word address-0 stream: $NDISTINCT2"
    if grep -q 'NOT RESTORED' "$OUT/35_stream_addr0.txt"; then
        echo "WARNING: address-0 stream restore failed; retrying"
        timeout 30 "$REG" "$GPU" "$BDF" wrr 8f0ac0 "$CTRL" "$CTRL" \
            | tee "$OUT/36_addr0_restore_retry.txt"
        LAST=$(norm "$(rb_wrr "$OUT/36_addr0_restore_retry.txt" | tail -1)")
        if ! same_fields "$LAST" "$CTRL"; then
            echo "FATAL: cannot restore 0x8f0ac0; stopping." >&2
            exit 3
        fi
    fi
    echo
fi

echo "=== PFSP EMEM channel summary (0x8f2ac0 + 8*i) ==="
for i in 0 1 2 3 4 5 6 7; do
    off=$(printf '0x008f%04x' $((0x2ac0 + 8 * i)))
    doff=$(printf '0x008f%04x' $((0x2ac4 + 8 * i)))
    g=$(awk -v o="$off" '$1 == o { print $3; exit }' "$OUT/20_pfsp_emem_gsp.txt")
    h=$(awk -v o="$off" '$1 == o { print $3; exit }' "$OUT/21_pfsp_emem_host.txt")
    gd=$(awk -v o="$doff" '$1 == o { print $3; exit }' "$OUT/20_pfsp_emem_gsp.txt")
    hd=$(awk -v o="$doff" '$1 == o { print $3; exit }' "$OUT/21_pfsp_emem_host.txt")
    printf '  ch%u C gsp=%-10s host=%-10s   D gsp=%-10s host=%-10s\n' \
        "$i" "${g:-?}" "${h:-?}" "${gd:-?}" "${hd:-?}"
done
echo
echo "=== FSP core channel summary (0x8f0ac0 + 8*i) ==="
for i in 0 1 2 3; do
    off=$(printf '0x008f%04x' $((0x0ac0 + 8 * i)))
    doff=$(printf '0x008f%04x' $((0x0ac4 + 8 * i)))
    g=$(awk -v o="$off" '$1 == o { print $3; exit }' "$OUT/10_fsp_core_8f0a00_gsp.txt")
    h=$(awk -v o="$off" '$1 == o { print $3; exit }' "$OUT/11_fsp_core_8f0a00_host.txt")
    gd=$(awk -v o="$doff" '$1 == o { print $3; exit }' "$OUT/10_fsp_core_8f0a00_gsp.txt")
    hd=$(awk -v o="$doff" '$1 == o { print $3; exit }' "$OUT/11_fsp_core_8f0a00_host.txt")
    printf '  ch%u C gsp=%-10s host=%-10s   D gsp=%-10s host=%-10s\n' \
        "$i" "${g:-?}" "${h:-?}" "${gd:-?}" "${hd:-?}"
done
echo
echo "=== high-entropy block and PLM (0x8f0a58..0x8f0ab0) ==="
awk '$1 >= "0x008f0a58" && $1 <= "0x008f0ab0" {print}' "$OUT/10_fsp_core_8f0a00_gsp.txt" || true
echo
echo "=== done; logs in $OUT ==="
