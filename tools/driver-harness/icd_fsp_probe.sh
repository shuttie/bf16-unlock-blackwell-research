#!/usr/bin/env bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Read-only probe of the FSP core's PRISCV block for an ICD (E67 follow-up).
# No writes, no halt. Run after reboot on a healthy card.
#
# GB202 FSP block is at 0x8f0000 (A.7). Candidate ICD offsets, same shape as
# the GSP's 0x111000 block:
#   CPUCTL  0x8f0388
#   ICD_CMD 0x8f03d0  ADDR0 0x8f03d4  ADDR1 0x8f03d8
#   RDATA0  0x8f03e4  RDATA1 0x8f03e8
#   RPC     0x8f03ec
# If those read as implemented (not 0xBADF5040 / 0xBADF5720), the next step is
# the same benign ADDR-latch write/readback test used on the GSP (E67).
#
# usage: sudo bash icd_fsp_probe.sh
# Env: BDF=0000:41:00.0 DEVID=1
set -u
RO=${RO:-$TOOL_DIR/../register-access/regops}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
DEVID=${DEVID:-1}

echo "# icd_fsp_probe $(date -Is) bdf=$BDF"
echo "== host BAR0 =="
"$RO" "$DEVID" "$BDF" bar 8f0000 40     || true
"$RO" "$DEVID" "$BDF" bar 8f0100 10     || true
"$RO" "$DEVID" "$BDF" bar 8f0380 20     || true
"$RO" "$DEVID" "$BDF" bar 8f0a80 20     || true
echo "== GSP master (GPU_EXEC_REG_OPS) =="
"$RO" "$DEVID" "$BDF" dump 8f0000 40    || true
"$RO" "$DEVID" "$BDF" dump 8f0100 10    || true
"$RO" "$DEVID" "$BDF" dump 8f0380 20    || true
"$RO" "$DEVID" "$BDF" dump 8f0a80 20    || true
echo "== dmesg tail =="
dmesg -T 2>/dev/null | grep -iE 'Xid|NVRM' | tail -6 || true
