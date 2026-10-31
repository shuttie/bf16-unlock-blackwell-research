#!/usr/bin/env bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Probe the ICD RDM address window with single 8-byte reads.
# Read-only; only ADDR/CMD are written. Requires the halted core.
#
# Expected if the window is linear FB physical with base 0xE71000:
#   0x01000000 -> 7f454c4602010100 (ELF header at file 0x18F000)
#   0x01400000 -> e7b99306c752be96 (confirmed, file 0x58F000)
#   addresses below ~0x01000000 or past the image end may ERROR.
#
# usage: sudo bash icd_map_probe.sh
set -u
BIN=${BIN:-$TOOL_DIR/icd_dump}
BDF=${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}
OUT=${OUT:-$TOOL_DIR/runs/icd_dumps}
mkdir -p "$OUT"; chmod 755 "$OUT"

probe() {
    a=$1
    f="$OUT/p_$a.bin"
    rm -f "$f"
    if "$BIN" "$BDF" "$a" 8 "$f" >/dev/null 2>&1 && [ -s "$f" ]; then
        printf "  %-11s OK   %s\n" "$a" "$(od -An -v -tx1 "$f" | tr -d ' \n')"
    else
        printf "  %-11s ERROR\n" "$a"
    fi
}

echo "# icd_map_probe $(date -Is) bdf=$BDF"
echo "== image window (base hypothesis 0xE71000) =="
for a in 00e71000 00f00000 01000000 01100000 01200000 01300000 \
         01400000 01440000 01500000 01600000 01800000 02000000 \
         03000000 04000000 05000000 05300000 05400000 05600000; do
    probe "$a"
done

echo "== FB physical candidates (WPR/FRTS/radix3) =="
for a in 01b40000 13ec00000 7dd580000 7e72e0000 7f0000000 7f42c0000; do
    probe "$a"
done

echo "== boundary =="
probe 00000000
ls -l "$OUT" | tail -5
