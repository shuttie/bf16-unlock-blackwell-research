#!/usr/bin/env bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Non-halting ICD register/PC probe. No STOP, no RDM, no memory access.
# Each line issues one CMD write; values are the Ampere ICD encoding
# (OPC[4:0], IDX[12:8], SZ[7:6], PARM[31:16]).
#
#   RPC        0x00000012          -> RDATA should be a code address
#   RSTAT idx3 0x0000030e
#   RSTAT idx4 0x0000040e
#   RREG  x2   0x00000208          -> stack pointer (nonzero if live)
#   RREG  x1   0x00000108          -> return address
#   RCSR misa  0x03010010          -> ISA string (nonzero if live)
#
# usage: sudo bash icd_probe2.sh
set -u
RO=${RO:-$TOOL_DIR/../register-access/regops}
BIN=${BIN:-$TOOL_DIR/icd_cmd}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }

echo "# icd_probe2 $(date -Is) bdf=$BDF"
echo "== GSP-side RPC (0x1113ec, GSP master) before =="
"$RO" 1 "$BDF" dump 1113e0 8 | grep -E '1113ec' || true

for c in 00000012 0000030e 0000040e 00000208 00000108 03010010; do
  echo
  echo "== CMD=$c =="
  "$BIN" "$BDF" "$c" 1113d0 20
done

echo
echo "== GSP-side RPC after =="
"$RO" 1 "$BDF" dump 1113e0 8 | grep -E '1113ec' || true
echo "== host view 0x1113d0..0x1113e8 =="
"$RO" 1 "$BDF" bar 1113d0 8 || true
echo "== dmesg tail =="
dmesg -T 2>/dev/null | grep -iE 'Xid|NVRM' | tail -6 || true
