#!/usr/bin/env bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Non-halting RDM (debug memory read) test against known GSP-RM code words.
# No STOP. If RDM requires a halted hart it should ERROR + return 0xbadfbadf.
#
# Expected if the read works:
#   0x01400000 size 8 -> 0x0187f7b300a6161b
#   0x01404f64 size 4 -> 0x00000000979b8e6d
#   0x01404f66 size 2 -> 0x000000000000979b
#
# usage: sudo bash icd_rdm_probe.sh
set -u
RO=${RO:-$TOOL_DIR/../register-access/regops}
BIN=${BIN:-$TOOL_DIR/icd_rdm}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }

echo "# icd_rdm $(date -Is) bdf=$BDF"
pc=$("$RO" 1 "$BDF" dump 1113e0 8 | awk '/0x001113ec/{print $3; exit}')
echo "GSP live PC (0x1113ec, GSP master) = ${pc:-<read failed>}"

echo "== host view before =="
"$RO" 1 "$BDF" bar 1113d0 8 || true

for spec in 01400000:8 01404f64:4 01404f66:2; do
  a=${spec%:*}; s=${spec#*:}
  echo
  echo "== RDM $a size $s =="
  "$BIN" "$BDF" "$a" "$s" 1113d0 || true
done

if [ -n "${pc:-}" ] && [ "$pc" != "0000000000" ]; then
  echo
  echo "== RDM live PC $pc size 2 =="
  "$BIN" "$BDF" "$pc" 2 1113d0 || true
fi

echo
echo "== host view after =="
"$RO" 1 "$BDF" bar 1113d0 8 || true
echo "== dmesg tail =="
dmesg -T 2>/dev/null | grep -iE 'Xid|NVRM' | tail -6 || true
