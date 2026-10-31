#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# icd_trace_run.sh - arm the read-only GSP PC/state tracer and run one boot.
#
# The tracer (BF16_ICD_TRACE in kern_fsp_gh100.c) samples, immediately after
# the COT round-trip, the host-visible GSP PRISCV/Falcon state:
#
#   0x111388 CPUCTL   0x1113ec PC mirror   0x1113d0 ICD_CMD
#   0x1103c0 ENGINE   0x1103c4 reset PLM
#
# Nothing is written to the GPU and no hart is halted, so the boot completes
# and the machine stays healthy.  The point is to learn whether the host can
# see the HS boot window (BootROM/FMC) at all and where the core executes,
# before any STOP is risked.
#
# Usage:  sudo ./icd_trace_run.sh
# Env:    ICD_US=100 (sample interval, microseconds)
#         ICD_MS=3000 (trace duration)
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
COT_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
HARNESS="$TOOL_DIR/dump_ctx.sh"
OUTDIR="$TOOL_DIR/runs/icd_trace"
ICD_US="${ICD_US:-100}"
ICD_MS="${ICD_MS:-1500}"

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)" >&2; exit 1; }
[ -f "$COT_SRC" ] || { echo "missing $COT_SRC" >&2; exit 1; }
[ -x "$HARNESS" ] || { echo "$HARNESS is not executable" >&2; exit 1; }

mkdir -p "$OUTDIR"
chmod 0755 "$OUTDIR"

KFSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/kern_fsp.c"
[ -f "$KFSP_SRC" ] || { echo "missing $KFSP_SRC" >&2; exit 1; }

set_def() {  # file name value
    local f="$1" n="$2" v="$3"
    grep -qE "^#define $n[[:space:]]" "$f" \
        || { echo "define $n not found in $f" >&2; return 1; }
    sed -i -E "s/^#define $n[[:space:]]+.*/#define $n $v/" "$f"
}

reset_all() {
    set_def "$COT_SRC" BF16_ICD_TRACE 0
    set_def "$COT_SRC" BF16_FMCTAMPER 0
    set_def "$COT_SRC" BF16_COT_VARY 0
    set_def "$COT_SRC" BF16_COT_VALUE 0ULL
    # FMCDUMP must agree in both translation units: kern_fsp.c calls the
    # function that kern_fsp_gh100.c defines under the same macro name.
    set_def "$COT_SRC" BF16_FMCDUMP 0
    set_def "$KFSP_SRC" BF16_FMCDUMP 0
}
trap reset_all EXIT

# One variable at a time: only the tracer is armed.
set_def "$COT_SRC" BF16_ICD_TRACE 1
set_def "$COT_SRC" BF16_ICD_TRACE_US "$ICD_US"
set_def "$COT_SRC" BF16_ICD_TRACE_MS "$ICD_MS"
set_def "$COT_SRC" BF16_FMCTAMPER 0
set_def "$COT_SRC" BF16_COT_VARY 0
set_def "$COT_SRC" BF16_COT_VALUE 0ULL
set_def "$COT_SRC" BF16_FMCDUMP 0
set_def "$KFSP_SRC" BF16_FMCDUMP 0

echo "== ICD trace armed: interval ${ICD_US}us duration ${ICD_MS}ms"
grep -nE "^#define BF16_(ICD_TRACE|FMCDUMP|FMCTAMPER|COT_VARY)" "$COT_SRC" "$KFSP_SRC"

OLD=$(ls -1 "$OUTDIR"/pc_*.csv 2>/dev/null || true)
[ -n "$OLD" ] && mv -f $OLD "$OUTDIR/old_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

# No context dumps, no CUDA trigger: module load + the harness's nvidia-smi -L
# is what initializes the GPU and sends the COT.
env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 "$HARNESS" --no-trigger

chmod 0644 "$OUTDIR"/pc_*.csv 2>/dev/null || true

echo
echo "== trace files:"
ls -la "$OUTDIR"/pc_*.csv 2>/dev/null || echo "   (none written)"
echo
echo "== dmesg summary:"
dmesg -T | grep -E "BF16: ICDTRACE|BF16: COT|Fatal GSP|Xid|RmInitAdapter" | tail -20 || true
