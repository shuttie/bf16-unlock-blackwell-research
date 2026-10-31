#!/usr/bin/env bash
# Dump a few key regions from the halted GSP core via ICD RDM.
# Read-only with respect to the core's memory; only ADDR/CMD are written.
# Run while the core is halted (after the STOP probe), before rebooting.
#
# usage: sudo bash icd_scan.sh
# Env: BDF=<pci-bdf> OUT=./runs/icd_dumps
set -u
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
BIN=${BIN:-$TOOL_DIR/icd_dump}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
OUT=${OUT:-$TOOL_DIR/runs/icd_dumps}
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }
mkdir -p "$OUT"; chmod 755 "$OUT"

echo "# icd_scan $(date -Is) bdf=$BDF"
# addr len(hex) name
for spec in "93002e00 400 pc" \
            "93000000 100 codebase" \
            "01400000 400 img" \
            "a3003e00 200 stack" \
            "0e71000 100 rtbase" \
            "10000000 100 elf1000" \
            "0 100 addr0"; do
    set -- $spec
    echo "== $3 @ $1 len $2 =="
    "$BIN" "$BDF" "$1" "$2" "$OUT/$3.bin" || echo "  (aborted)"
done

chmod 644 "$OUT"/*.bin 2>/dev/null || true
echo "== files =="
ls -l "$OUT"
