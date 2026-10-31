#!/usr/bin/env bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Read-only sweep of the FSP block for a PRISCV ICD (E67 follow-up).
#
# The original icd_fsp_probe.sh probes 0x8f0388/0x8f03d0, i.e. Falcon base
# 0x8f0000 + 0x388/0x3d0.  On the GSP the PRISCV block is NOT at Falcon base:
# the Falcon block ends at 0x110d4c and PRISCV starts at 0x111004, so
# CPUCTL = PRISCV+0x388 = 0x111388 and ICD_CMD = 0x1113d0.  If the FSP follows
# the same placement its PRISCV base is 0x8f1000 and the ICD is at 0x8f13d0.
# This script reads both hypotheses plus the FSP core PLM/EMEM block.
#
# Nothing is written.  Host view = BAR0 mmap (64-dword chunks); GSP view =
# READ_32 through GPU_EXEC_REG_OPS (128-dword chunks).
#
# usage: sudo bash icd_fsp_probe2.sh
# env:   BDF=0000:41:00.0 DEVID=1
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
REG="${REG:-$TOOL_DIR/../register-access/regops}"
BDF="${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}"
DEVID="${DEVID:-1}"
OUTDIR="$TOOL_DIR/runs/regops_results"
OUT="$OUTDIR/icd_fsp_sweep_$(date +%Y%m%d_%H%M%S).txt"

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)" >&2; exit 1; }
[ -x "$REG" ] || { echo "missing $REG" >&2; exit 1; }
mkdir -p "$OUTDIR"
: > "$OUT"

# Half-open ranges.  The PFSP aperture is 0x8f0000..0x8f3fff (16 KB), so the
# default covers all of it: the Falcon block, the +0x1000 PRISCV candidate, the
# FSP core PLM/EMEM block, and the previously unswept 0x8f1800..0x8f4000 tail.
# Override with RANGES="a:b c:d" (hex, half-open).
RANGES="${RANGES:-0x8f0000:0x8f4000}"

echo "# icd_fsp_probe2 $(date -Is) bdf=$BDF devid=$DEVID"
echo "# output: $OUT"

for r in $RANGES; do
    b=${r%%:*}; e=${r##*:}
    echo "== host BAR0 $b..$e" | tee -a "$OUT"
    off=$(printf '%d' "$b"); end=$(printf '%d' "$e")
    while [ "$off" -lt "$end" ]; do
        cnt=$(( (end - off) / 4 )); [ "$cnt" -gt 64 ] && cnt=64
        "$REG" "$DEVID" "$BDF" bar "$(printf '%x' "$off")" "$(printf '%x' "$cnt")" \
            >> "$OUT" 2>&1 || { echo "!! bar failed at $(printf '%x' "$off")" >&2; break; }
        off=$(( off + cnt * 4 ))
    done
    echo "== GSP master $b..$e" | tee -a "$OUT"
    off=$(printf '%d' "$b")
    while [ "$off" -lt "$end" ]; do
        cnt=$(( (end - off) / 4 )); [ "$cnt" -gt 128 ] && cnt=128
        "$REG" "$DEVID" "$BDF" dump "$(printf '%x' "$off")" "$(printf '%x' "$cnt")" \
            >> "$OUT" 2>&1 || { echo "!! dump failed at $(printf '%x' "$off")" >&2; break; }
        off=$(( off + cnt * 4 ))
    done
done

chmod 0644 "$OUT"

python3 -I - "$OUT" <<'PY'
import re, sys
rows = []
pat_gsp = re.compile(r"^\s+0x([0-9a-fA-F]+)\s*=\s*(?:0x)?([0-9a-fA-F]+)\s+status=(\d+)\s*(.*)$")
pat_host = re.compile(r"^\s*BAR0 0x([0-9a-fA-F]+) = (?:0x)?([0-9a-fA-F]+)")
view = None
for line in open(sys.argv[1], errors="replace"):
    s = line.strip()
    if s.startswith("=="):
        view = "host" if "host BAR0" in s else "gsp"
        continue
    m = pat_host.match(line)
    if m and view == "host":
        rows.append((view, int(m.group(1), 16), int(m.group(2), 16), 0))
        continue
    m = pat_gsp.match(line)
    if m and view == "gsp":
        rows.append((view, int(m.group(1), 16), int(m.group(2), 16), int(m.group(3))))

def sent(v): return 0xbadf0000 <= v <= 0xbadfffff

names = {
 0x8f0388:"CPUCTL? (Falcon+0x388)", 0x8f03d0:"ICD_CMD? (Falcon+0x3d0)",
 0x8f03d4:"ADDR0?", 0x8f03d8:"ADDR1?", 0x8f03e4:"RDATA0?", 0x8f03e8:"RDATA1?",
 0x8f03ec:"RPC?", 0x8f03c0:"FSP FALCON_ENGINE", 0x8f03c4:"FSP PLM",
 0x8f1388:"CPUCTL? (PRISCV+0x388)", 0x8f13d0:"ICD_CMD? (PRISCV+0x3d0)",
 0x8f13d4:"ADDR0?", 0x8f13d8:"ADDR1?", 0x8f13e4:"RDATA0?", 0x8f13e8:"RDATA1?",
 0x8f13ec:"RPC?", 0x8f1320:"PLM? (PRISCV+0x320)", 0x8f1328:"PLM? (PRISCV+0x328)",
 0x8f0a90:"FSP core PLM", 0x8f0ac0:"FSP core EMEMC0",
}
for view in ("host", "gsp"):
    vr = [(o, v, s) for (vw, o, v, s) in rows if vw == view]
    print(f"--- {view}: {len(vr)} reads")
    impl = [(o, v, s) for o, v, s in vr if not sent(v)]
    print(f"    implemented (non-sentinel): {len(impl)}")
    for o, v, s in impl:
        tag = f"  <{names[o]}>" if o in names else ""
        print(f"    0x{o:06x} = 0x{v:08x} status={s}{tag}")
    print("    candidate check:")
    for o in (0x8f0388, 0x8f03d0, 0x8f03d4, 0x8f03d8, 0x8f03e4, 0x8f03e8, 0x8f03ec,
              0x8f1388, 0x8f13d0, 0x8f13d4, 0x8f13d8, 0x8f13e4, 0x8f13e8, 0x8f13ec):
        hit = [(v, s) for oo, v, s in vr if oo == o]
        if not hit:
            continue
        v, s = hit[0]
        state = "SENTINEL" if sent(v) else "IMPLEMENTED"
        print(f"      0x{o:06x} {names.get(o,''):26s} = 0x{v:08x} {state}")
PY

echo
echo "== done. Nothing was written to the GPU."
