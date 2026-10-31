#!/usr/bin/env bash
# One-shot PRISCV ICD RSTAT command (non-halting status read).
# Writes ICD_CMD once and does NOT restore (0 would be opcode STOP).
# usage: sudo bash icd_rstat_probe.sh
# Env: BDF=<pci-bdf> BIN=./icd_cmd
set -u
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
RO=${RO:-$TOOL_DIR/../register-access/regops}
BIN=${BIN:-$TOOL_DIR/icd_cmd}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
[ -x "$BIN" ] || { echo "missing $BIN (compile icd_cmd.c first)"; exit 1; }

echo "# icd_rstat $(date -Is) bdf=$BDF"
echo "== before =="
"$RO" 1 "$BDF" bar 1113d0 8 || true
echo "== RSTAT idx 0: CMD=0x0000000e (single write, no restore) =="
"$BIN" "$BDF" 0000000e 1113d0 20
echo "== after =="
"$RO" 1 "$BDF" bar 1113d0 8 || true
echo "== dmesg tail =="
dmesg -T 2>/dev/null | grep -iE 'Xid|NVRM' | tail -8 || true
