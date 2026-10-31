#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# icd_halt_run.sh - catch the GSP boot image at the ICD unblock.
#
# BF16_ICD_HALT polls the host PC mirror (0x1113ec) after the COT response.
# The read-only trace showed the register is blocked (0xbadf5620) through the
# whole HS window and unblocks ~0.5 ms before GSP-RM starts, with the boot
# image executing at 0xefd0xxxx.  On the first valid PC the hook writes STOP,
# reads RPC/RREG, probes the boot-image address hypotheses (0xEFD00000,
# 0x5DD00000, ...), and dumps 64 KB at the first working address.
#
# THIS HALTS THE GSP.  The boot fails and a reboot is required.  If STOP is
# refused, the boot continues and the machine stays healthy; the sidecar says
# which happened.  Stock modules are NOT restored (a halted GSP can block
# rmmod); reboot instead.
#
# Usage:  sudo ./icd_halt_run.sh
# Env:    HALT_GPU=1 (41:00.0)  POLL_US=10  HALT_MS=3000  DUMP_LEN=0x10000
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
COT_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
KFSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/kern_fsp.c"
LOAD="$TOOL_DIR/load_patched.sh"
OUTDIR="$TOOL_DIR/runs/icd_boot"
HALT_GPU="${HALT_GPU:-1}"
HALT_MODE="${HALT_MODE:-0}"
POLL_US="${POLL_US:-10}"
HALT_MS="${HALT_MS:-3000}"
DUMP_LEN="${DUMP_LEN:-0x10000}"

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)" >&2; exit 1; }
for f in "$COT_SRC" "$KFSP_SRC" "$LOAD"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

mkdir -p "$OUTDIR"
chmod 0755 "$OUTDIR"

set_def() {  # file name value
    local f="$1" n="$2" v="$3"
    grep -qE "^#define $n[[:space:]]" "$f" \
        || { echo "define $n not found in $f" >&2; return 1; }
    sed -i -E "s/^#define $n[[:space:]]+.*/#define $n $v/" "$f"
}

reset_all() {
    set_def "$COT_SRC" BF16_ICD_HALT 0
    set_def "$COT_SRC" BF16_ICD_HALT_MODE 0
    set_def "$COT_SRC" BF16_ICD_TRACE 0
    set_def "$COT_SRC" BF16_FMCTAMPER 0
    set_def "$COT_SRC" BF16_COT_VARY 0
    set_def "$COT_SRC" BF16_COT_VALUE 0ULL
    set_def "$COT_SRC" BF16_ICD_DUMP_LEN 0x10000
    set_def "$COT_SRC" BF16_FMCDUMP 0
    set_def "$KFSP_SRC" BF16_FMCDUMP 0
}
trap reset_all EXIT

set_def "$COT_SRC" BF16_ICD_HALT 1
set_def "$COT_SRC" BF16_ICD_HALT_GPU "$HALT_GPU"
set_def "$COT_SRC" BF16_ICD_HALT_MODE "$HALT_MODE"
set_def "$COT_SRC" BF16_ICD_POLL_US "$POLL_US"
set_def "$COT_SRC" BF16_ICD_HALT_MS "$HALT_MS"
set_def "$COT_SRC" BF16_ICD_DUMP_LEN "$DUMP_LEN"
set_def "$COT_SRC" BF16_ICD_TRACE 0
set_def "$COT_SRC" BF16_FMCTAMPER 0
set_def "$COT_SRC" BF16_COT_VARY 0
set_def "$COT_SRC" BF16_COT_VALUE 0ULL
set_def "$COT_SRC" BF16_FMCDUMP 0
set_def "$KFSP_SRC" BF16_FMCDUMP 0

echo "== ICD halt armed: gpu=$HALT_GPU mode=$HALT_MODE poll=${POLL_US}us window=${HALT_MS}ms dump=$DUMP_LEN"
grep -nE "^#define BF16_(ICD_HALT|ICD_POLL|ICD_TRACE|FMCDUMP)" "$COT_SRC" "$KFSP_SRC"

rm -f "$OUTDIR"/halt_*.txt "$OUTDIR"/halt_*.bin

echo "== building 595.91.07 modules"
( cd "$TREE" && timeout 1800 make modules -j"$(nproc)" ) 2>&1 | tail -5
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "build failed" >&2; exit 1; }

echo "== loading instrumented modules (this triggers the COT, then the halt)"
MODDIR="$TREE/kernel-open" timeout -s KILL 120 "$LOAD"
rc=$?
echo "== load_patched rc=$rc (nonzero is expected after a halt)"

echo
echo "== dmesg:"
dmesg -T | grep -E "BF16: ICDHALT|BF16: COT|Fatal GSP|Xid|RmInitAdapter|GSP-FMC" | tail -30 || true

chmod 0644 "$OUTDIR"/halt_*.txt "$OUTDIR"/halt_*.bin 2>/dev/null || true
echo
echo "== artifacts:"
ls -la "$OUTDIR"/halt_* 2>/dev/null || echo "   (none)"
echo
echo "== sidecar:"
cat "$OUTDIR"/halt_"$HALT_GPU".txt 2>/dev/null || true
echo
echo "== Stock modules were NOT restored; if the GSP was halted, reboot:"
echo "   sudo systemctl reboot -f"
