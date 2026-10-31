#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# E73: read the decrypted GSP boot image out of FB through the BAR0 PRAMIN
# window, after the GSP boot, from inside the driver.
#
# BAR1 is not usable at boot time (kbusInitBar1 runs after kgspInitRm), so the
# first attempt (BAR1 VAS mapping) oopsed on a NULL PTE array.  This version
# uses the BAR0 window RM itself uses before BAR1 exists: 64 KiB at a time at
# BAR0 0x700000, moved with kbusSetBAR0WindowVidOffset (cache-consistent) and
# restored afterwards.  Read-only.
#
#   sudo ./fb_capture.sh
#
# Builds 595.91.07 with BF16_FBREAD and BF16_WPRLAYOUT, loads it, lets the
# boot run, restores the stock driver, and prints what was read.  The tree is
# left as found.
set -u

TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
GH100="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
KGSP="$TREE/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
FMC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
LOAD="$TOOL_DIR/load_patched.sh"
DUMPDIR="$TOOL_DIR/runs/fbread"
OUT="$TOOL_DIR/runs/fbread_$(date +%Y%m%d_%H%M%S)"
LOADED=0
mkdir -p "$OUT" "$DUMPDIR"
rm -f "$DUMPDIR"/fb_*.bin

say() { echo "$@" | tee -a "$OUT/run.log"; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"
for f in "$GH100" "$KGSP" "$FMC" "$LOAD"; do [ -f "$f" ] || die "missing $f"; done

get_def() { grep -m1 -E "^#define $2 " "$1" | awk '{print $3}'; }
set_def() {
    local f="$1" n="$2" v="$3"
    grep -qE "^#define $n " "$f" || die "no '#define $n' in $f"
    sed -i -E "s/^#define $n .*/#define $n $v/" "$f" || die "set $n failed"
}

O_FBREAD=$(get_def "$KGSP" BF16_FBREAD)
O_WPRLAYOUT=$(get_def "$KGSP" BF16_WPRLAYOUT)
O_BOOT_GH=$(get_def "$GH100" BF16_BOOTDUMP)
O_BOOT_KG=$(get_def "$KGSP"  BF16_BOOTDUMP)
O_SRDUMP=$(get_def "$GH100" BF16_SRDUMP)
O_TAMPER=$(get_def "$GH100" BF16_BOOT_TAMPER)
O_WPR=$(get_def "$GH100" BF16_WPR_VARY)
O_FEAT_GH=$(get_def "$GH100" BF16_FEAT_PREBOOT)
O_FEAT_KG=$(get_def "$KGSP"  BF16_FEAT_PREBOOT)
O_FMCDUMP=$(get_def "$FMC"   BF16_FMCDUMP)
[ -n "$O_FBREAD" ] || die "BF16_FBREAD define missing"
[ -n "$O_WPRLAYOUT" ] || die "BF16_WPRLAYOUT define missing"

cleanup() {
    set_def "$KGSP"  BF16_FBREAD "$O_FBREAD" 2>/dev/null || true
    set_def "$KGSP"  BF16_WPRLAYOUT "$O_WPRLAYOUT" 2>/dev/null || true
    set_def "$GH100" BF16_BOOTDUMP "$O_BOOT_GH" 2>/dev/null || true
    set_def "$KGSP"  BF16_BOOTDUMP "$O_BOOT_KG" 2>/dev/null || true
    set_def "$GH100" BF16_SRDUMP   "${O_SRDUMP:-1}" 2>/dev/null || true
    set_def "$GH100" BF16_BOOT_TAMPER "${O_TAMPER:-0}" 2>/dev/null || true
    set_def "$GH100" BF16_WPR_VARY "${O_WPR:-0}" 2>/dev/null || true
    set_def "$GH100" BF16_FEAT_PREBOOT "${O_FEAT_GH:-0}" 2>/dev/null || true
    set_def "$KGSP"  BF16_FEAT_PREBOOT "${O_FEAT_KG:-0}" 2>/dev/null || true
    set_def "$FMC"   BF16_FMCDUMP  "${O_FMCDUMP:-0}" 2>/dev/null || true
    if [ "$LOADED" -eq 1 ]; then
        say "== restoring stock modules"
        "$LOAD" --restore | tee -a "$OUT/restore.log" || \
            say "== RESTORE FAILED - reboot is the reliable recovery"
    fi
}
trap cleanup EXIT

exec > >(tee -a "$OUT/run.log") 2>&1
say "== E73 FB capture $(date -Is)"

set_def "$KGSP"  BF16_FBREAD 1
set_def "$KGSP"  BF16_WPRLAYOUT 1
set_def "$GH100" BF16_BOOTDUMP 0
set_def "$KGSP"  BF16_BOOTDUMP 0
set_def "$GH100" BF16_SRDUMP 0
set_def "$GH100" BF16_BOOT_TAMPER 0
set_def "$GH100" BF16_WPR_VARY 0
set_def "$GH100" BF16_FEAT_PREBOOT 0
set_def "$KGSP"  BF16_FEAT_PREBOOT 0
set_def "$FMC"   BF16_FMCDUMP 0

say "== build"
(cd "$TREE" && timeout 1800 make modules -j"$(nproc)") > "$OUT/build.log" 2>&1 \
    || die "build failed; see $OUT/build.log"
tail -5 "$OUT/build.log" | tee -a "$OUT/run.log"
say "== build ok"

LOADED=1
"$LOAD" | tee -a "$OUT/load.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "load failed; see $OUT/load.log"

sleep 3
dmesg -T > "$OUT/dmesg_post.txt"
say "== FBREAD / WPRLAYOUT / BAR1STAT lines:"
grep -E "BF16: (FBREAD|WPRLAYOUT|BAR1STAT|GSCI)" "$OUT/dmesg_post.txt" | tee -a "$OUT/run.log" || \
    say "   (none)"
say "== boot lines:"
grep -E "BF16:|Xid|Fatal GSP|NVRM: GPU" "$OUT/dmesg_post.txt" | tail -30 | tee -a "$OUT/run.log" || true

say "== dumps:"
ls -la "$DUMPDIR" | tee -a "$OUT/run.log"
chmod 644 "$DUMPDIR"/fb_*.bin 2>/dev/null || true

say "== heap mining (full report in $OUT/heap_report.txt):"
python3 -I "$TOOL_DIR/fbread_analyze.py" "$DUMPDIR" "$OUT/heap_report.txt" \
    > "$OUT/heap_stdout.txt" 2>&1 || true
tail -40 "$OUT/heap_stdout.txt" | tee -a "$OUT/run.log"

# Bounded analysis: entropy and ELF magic for each dump.
python3 -I - "$DUMPDIR" "$OUT" <<'PY'
import glob, hashlib, math, os, sys
d, out = sys.argv[1], sys.argv[2]
rows = []
for p in sorted(glob.glob(os.path.join(d, "fb_*.bin"))):
    b = open(p, "rb").read()
    if not b:
        continue
    c = [0]*256
    for x in b: c[x] += 1
    n = len(b)
    ent = -sum((v/n)*math.log2(v/n) for v in c if v)
    nz = n - c[0]
    ff = c[0xFF]
    rows.append("%-42s size=0x%x nz=%d ff=%d ent=%.4f elf=%s head=%s" % (
        os.path.basename(p), n, nz, ff, ent,
        b[:4] == b"\x7fELF", b[:16].hex()))
text = "\n".join(rows) if rows else "no files"
print(text)
open(os.path.join(out, "compare.txt"), "w").write(text + "\n")
PY

LOADED=0
"$LOAD" --restore | tee -a "$OUT/restore.log"
say "== stock restored"
say "== done: $OUT"
