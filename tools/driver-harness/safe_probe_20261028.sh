#!/usr/bin/env bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
# Safe probes for three leads:
#   (1) PRISCV ICD presence (read-only; optional benign ADDR write/restore)
#   (2) fuse-controller control regs, incl. DISABLE_FUSE_PROGRAM (read-only)
#   (3) +0xb4 feature-token live state (read-only FEAT control read)
#
# Default is READ-ONLY. Pass --writes for the two ADDR0/ADDR1 write/readback/
# restore tests (address latches only; no ICD command is ever written, so
# STOP/RDM/RSTAT are NOT issued).
#
# Usage:
#   sudo bash safe_probe_20261028.sh             # read-only
#   sudo bash safe_probe_20261028.sh --writes    # + ADDR latch write/restore
#
# Env: BDF=0000:41:00.0 DEVID=1

set -u
RO=${RO:-$TOOL_DIR/../register-access/regops}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
DEVID=${DEVID:-1}
WRITES=0
[ "${1:-}" = "--writes" ] && WRITES=1
mkdir -p "$TOOL_DIR/runs"; OUT="$TOOL_DIR/runs/safe_probe_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$OUT") 2>&1

r() { echo; echo "## $*"; "$@"; }
rdword() { "$RO" "$DEVID" "$BDF" bar "$1" 1 2>/dev/null | awk '/=/{print $NF; exit}'; }

echo "# safe_probe $(date -Is)  bdf=$BDF devid=$DEVID writes=$WRITES"
echo "# log: $OUT"
echo "# dmesg baseline (Xid/NVRM):"
dmesg -T 2>/dev/null | grep -iE 'Xid|NVRM' | tail -5 || echo "  (none)"

echo
echo "================ STAGE 0: PATH CONTROL ================"
r "$RO" "$DEVID" "$BDF" one
r "$RO" "$DEVID" "$BDF" bar 823800 12

echo
echo "================ STAGE 1: READ-ONLY ================"

echo
echo "--- (1) ICD / PRISCV, host BAR0 ---"
r "$RO" "$DEVID" "$BDF" bar 1112c0 40      # counts are hex: 0x40 = 64 dwords
r "$RO" "$DEVID" "$BDF" bar 1113c0 20

echo
echo "--- (1) ICD / PRISCV, GSP master (GPU_EXEC_REG_OPS) ---"
r "$RO" "$DEVID" "$BDF" dump 1112c0 40
r "$RO" "$DEVID" "$BDF" dump 1113c0 20

echo
echo "--- (2) FUSE controller, host BAR0 (0x820000..0x82007f) ---"
r "$RO" "$DEVID" "$BDF" bar 820000 32
r "$RO" "$DEVID" "$BDF" bar 8207c0 12

echo
echo "--- (2) FUSE controller, GSP master ---"
r "$RO" "$DEVID" "$BDF" dump 820000 32
r "$RO" "$DEVID" "$BDF" dump 8207c0 12

echo
echo "--- (3) FEAT block control (known-good values for context) ---"
r "$RO" "$DEVID" "$BDF" bar 823818 4

if [ "$WRITES" = 1 ]; then
  echo
  echo "================ STAGE 2: BENIGN ICD ADDR LATCH TEST ================"
  echo "# No ICD_CMD write. Only ADDR0/ADDR1 (RW address latches), restored."

  a0=$(rdword 1113d4); a1=$(rdword 1113d8)
  echo "# current ADDR0=$a0 ADDR1=$a1"
  r "$RO" "$DEVID" "$BDF" barw 1113d4 deadbe00 "${a0:-0x00000000}"
  r "$RO" "$DEVID" "$BDF" barw 1113d8 deadbe00 "${a1:-0x00000000}"
  r "$RO" "$DEVID" "$BDF" bar 1113d0 8
fi

echo
echo "================ POST: dmesg delta ================"
dmesg -T 2>/dev/null | grep -iE 'Xid|NVRM' | tail -10 || echo "  (none)"
echo "# done; log at $OUT"
