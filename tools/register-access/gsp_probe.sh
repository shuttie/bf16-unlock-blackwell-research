#!/bin/bash
# Read-only dump of the GSP Falcon register block through NV2080_CTRL_GPU_EXEC_REG_OPS.
# Every op is REG_OP_READ_32; nothing is written.
#
# Usage: sudo ./gsp_probe.sh [gpu_index] [bdf]
#        (defaults: 0  0000:c1:00.0)
# Env: GPU, BDF, REGOPS, OUTDIR (defaults: 0, 0000:c1:00.0, ./regops, ./runs)

set -u
GPU=${GPU:-${1:-0}}
BDF=${BDF:-${2:-0000:c1:00.0}}
DIR=$(cd "$(dirname "$0")" && pwd)
REGOPS=${REGOPS:-$DIR/regops}
OUTDIR=${OUTDIR:-$DIR/runs}
mkdir -p "$OUTDIR"
OUT="$OUTDIR/gsp_probe_$(date +%Y%m%d_%H%M%S).txt"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (regops needs admin for the register allowlist)" >&2
    exit 1
fi

{
    echo "== GSP register probe $(date -Is)"
    echo "== gpu=$GPU bdf=$BDF driver=$(cat /sys/module/nvidia/version 2>/dev/null)"
    echo
} | tee "$OUT"

# name          base    count (hex words)
DUMPS=(
    "irq_mbox_os    110000 20"
    "hwcfg_cpu      1100c0 20"
    "imem_ports     110180 10"
    "dmem_ports     1101c0 10"
    "engine_plm     1103c0 08"
    "riscv_bcr      110660 0a"
    "emem_ports     110ab0 14"
    "riscv_fault    1116f0 10"
)

fail=0
for d in "${DUMPS[@]}"; do
    read -r name base count <<<"$d"
    {
        echo "---- $name  base=$base count=0x$count"
    } | tee -a "$OUT"

    timeout 30 "$REGOPS" "$GPU" "$BDF" dump "$base" "$count" 2>&1 | tee -a "$OUT"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "---- ^ FAILED rc=$rc (124 = timed out; stop and reboot if so)" | tee -a "$OUT"
        fail=$((fail + 1))
        [ "$rc" -eq 124 ] && break
    fi
    echo | tee -a "$OUT"
done

{
    echo "== done, $fail failed section(s)"
    echo "== output: $OUT"
} | tee -a "$OUT"
