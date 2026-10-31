#!/bin/bash
#
# riscv_dm_probe.sh - read-only sweep of the GSP Falcon/PRISCV register area
# looking for a RISC-V debug-module (ICD/DM) interface.
#
# The GSP is a RISC-V core (HWCFG2 bit 10), its legacy IMEM/DMEM ports are
# absent (experiment E10), and nvidia.ko compiles the ICD host path to
# NV_ERR_NOT_SUPPORTED.  The hardware may still expose the debug block.  The
# public dev_riscv_pri.h puts the ICD at +0x3d0..+0x3e8 (CMD/ADDR0/ADDR1/
# RDATA0/RDATA1, opcodes STOP/RREG/RDM/RSTAT), i.e. 0x1103d0 on the GSP block.
#
# This pass only READS.  Every op is READ_32 through GPU_EXEC_REG_OPS, so the
# GSP is the bus master and the result is the PL2 view.  No register is written,
# no Falcon is reset, and no firmware is touched.
#
# Usage:
#   sudo ./riscv_dm_probe.sh                 # sweep 0x110000..0x113fff on 41:00.0
#   sudo ./riscv_dm_probe.sh <base> <end>    # custom half-open range (hex)
#   DEVID=0 BDF=0000:c1:00.0 sudo ./riscv_dm_probe.sh
#
# Env: DEVID, BDF, REGOPS/REG, OUTDIR (defaults: 1, 0000:41:00.0, ./regops, ./runs)
# Output: $OUTDIR/riscv_dm_<stamp>.txt (raw) plus a collapsed summary on stdout.
# The raw file is chmod 0644 so it can be read without root.
#
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
REG="${REG:-${REGOPS:-$DIR/regops}}"
BDF="${BDF:-0000:41:00.0}"
DEVID="${DEVID:-1}"                 # 1 = 41:00.0, 0 = c1:00.0
BASE="${1:-0x110000}"
END="${2:-0x114000}"                # half-open
OUTDIR="${OUTDIR:-$DIR/runs}"
OUT="$OUTDIR/riscv_dm_$(date +%Y%m%d_%H%M%S).txt"
CHUNK=128                           # regops dump limit: 128 dwords

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)" >&2; exit 1; }
[ -x "$REG" ] || { echo "missing $REG" >&2; exit 1; }
timeout -s KILL 15 nvidia-smi -L >/dev/null 2>&1 || {
    echo "!! nvidia-smi cannot enumerate the GPUs; reboot first." >&2
    exit 1
}

mkdir -p "$OUTDIR"
: > "$OUT"

echo "== read-only GSP/PRISCV sweep $BASE..$END on $BDF (deviceId $DEVID)"
b=$(printf '%d' "$BASE")
e=$(printf '%d' "$END")
off=$b
while [ "$off" -lt "$e" ]; do
    cnt=$(( (e - off) / 4 ))
    if [ "$cnt" -gt "$CHUNK" ]; then cnt=$CHUNK; fi
    "$REG" "$DEVID" "$BDF" dump "$(printf '%x' "$off")" "$(printf '%x' "$cnt")" \
        >> "$OUT" 2>&1 || { echo "!! regops failed at 0x$(printf '%x' "$off")" >&2; break; }
    off=$(( off + cnt * 4 ))
done

chmod 0644 "$OUT"
echo "== raw: $OUT"
echo

python3 -I - "$OUT" <<'PY'
import re, sys

path = sys.argv[1]
rows = []
# regops prints %#010x: nonzero values as 0x........, zero as 0000000000.
pat = re.compile(r"^\s+0x([0-9a-fA-F]+)\s*=\s*(?:0x)?([0-9a-fA-F]+)\s+status=(\d+)\s*(.*)$")
for line in open(path, errors="replace"):
    m = pat.match(line)
    if m:
        rows.append((int(m.group(1), 16), int(m.group(2), 16),
                     int(m.group(3)), m.group(4).strip()))

if not rows:
    print("no register records parsed")
    sys.exit(0)

def sentinel(v):
    return 0xbadf0000 <= v <= 0xbadfffff

def plmish(v):
    return (v >> 12) == 0xfffff or (v & 0xffffff00) == 0xffffff00

st = {}
for _, _, s, _ in rows:
    st[s] = st.get(s, 0) + 1
print(f"ops: {len(rows)}  range 0x{rows[0][0]:x}..0x{rows[-1][0]:x}")
print("status histogram: " + ", ".join(f"{k}:{v}" for k, v in sorted(st.items())))
print()

# collapse runs of sentinel values
runs = []
i = 0
while i < len(rows):
    off, val, _, _ = rows[i]
    if sentinel(val):
        j = i
        vals = {val}
        while j + 1 < len(rows) and sentinel(rows[j + 1][1]) and \
              rows[j + 1][0] == rows[j][0] + 4:
            j += 1
            vals.add(rows[j][1])
        if len(vals) == 1:
            runs.append((off, rows[j][0], f"sentinel 0x{val:08x}"))
        else:
            runs.append((off, rows[j][0], "sentinel mixed"))
        i = j + 1
    else:
        j = i
        while j + 1 < len(rows) and not sentinel(rows[j + 1][1]) and \
              rows[j + 1][0] == rows[j][0] + 4:
            j += 1
        runs.append((off, rows[j][0], "implemented"))
        i = j + 1

print("map (consecutive runs):")
for a, b, kind in runs:
    if a == b:
        print(f"  0x{a:06x}            {kind}")
    else:
        print(f"  0x{a:06x}..0x{b:06x}  {kind}")

impl = [r for r in rows if not sentinel(r[1])]
print()
print(f"implemented dwords: {len(impl)}")
print()
print("implemented values:")
for off, val, s, name in impl:
    tag = " PLM?" if plmish(val) else ""
    print(f"  0x{off:06x} = 0x{val:08x}  status={s} {name}{tag}")

# The PRISCV block is at BAR0 0x111000 (E63): every gb202/dev_riscv_pri.h
# offset lands there (CPUCTL 0x388 -> 0x111388, RPC 0x3ec -> 0x1113ec), and
# E10's FAULT_CONTAINMENT_SRCSTAT read at 0x111700 is offset 0x700.  The ICD
# candidates are therefore at 0x1113d0..; the fields at 0x1103d0 belong to the
# Falcon block, not to this one.
known = {
    0x1103d0: "Falcon block 0x3d0 (not ICD)",
    0x1103e0: "Falcon block 0x3e0 (not ICD)",
    0x111388: "PRISCV_CPUCTL",
    0x1113d0: "PRISCV_ICD_CMD (Ampere layout)",
    0x1113d4: "PRISCV_ICD_ADDR0 (Ampere layout)",
    0x1113d8: "PRISCV_ICD_ADDR1 (Ampere layout)",
    0x1113dc: "PRISCV ICD +0x3dc",
    0x1113e4: "PRISCV_ICD_RDATA0 (Ampere layout)",
    0x1113e8: "PRISCV_ICD_RDATA1 (Ampere layout)",
    0x1113ec: "PRISCV_RPC",
    0x111400: "PRISCV_TRACECTL (inferred)",
    0x111404: "PRISCV_TRACE_RDIDX (inferred)",
    0x111408: "PRISCV_TRACE_WTIDX (inferred)",
    0x11140c: "PRISCV_TRACEPC_LO (inferred)",
    0x111410: "PRISCV_TRACEPC_HI (inferred)",
    0x111420: "PRISCV_PRIV_ERR_STAT",
    0x111424: "PRISCV_PRIV_ERR_INFO",
    0x111428: "PRISCV_PRIV_ERR_ADDR",
    0x11142c: "PRISCV_PRIV_ERR_ADDR_HI",
    0x111430: "PRISCV_HUB_ERR_STAT",
    0x111528: "PRISCV_IRQMASK",
    0x11152c: "PRISCV_IRQDEST",
    0x111534: "PRISCV_IRQDELEG",
    0x111700: "PRISCV_FAULT_CONTAINMENT_SRCSTAT",
}
byoff = {o: (v, s) for o, v, s, _ in rows}
print()
print("known-offset check:")
for off, name in sorted(known.items()):
    if off not in byoff:
        print(f"  0x{off:06x} {name:40s} = (outside sweep)")
        continue
    v, s = byoff[off]
    note = ""
    if off == 0x111388:
        note = f"  halted={(v >> 4) & 1} active={(v >> 7) & 1}"
    elif off == 0x1113ec:
        note = "  (core PC)"
    print(f"  0x{off:06x} {name:40s} = 0x{v:08x} status={s}{note}")
PY

echo
echo "== done. Nothing was written to the GPU."
