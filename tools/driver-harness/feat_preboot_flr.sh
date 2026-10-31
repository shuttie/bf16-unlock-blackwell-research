#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# feat_preboot_flr.sh - FA and PLM timing across a PCI FLR.
#
# Question: after an FLR resets FEAT_OVR_PLM to 0x80842bcf (write mask L2+L3),
# does the boot path re-lock it BEFORE the COT (FSP/hardware) or at/after the
# COT (FSP response / FMC)?
#
# Method:
#   1. Build the 595.91.07 tree with BF16_FEAT_PREBOOT=1,
#      BF16_FEAT_NVPROBE=1 and BF16_FEAT_RMINIT=1.  Bracket samplers read the
#      10 FEAT words at: nv_pci_probe (after pci_enable_device/BAR0 request),
#      around pci_set_master, RmInitAdapter entry and after osInitNvMapping,
#      kgspInitRm_IMPL entry, just before _kgspBootGspRm, _kgspBootGspRm entry,
#      kgspPrepareForBootstrap_GH100 entry, and kgspSetupGspFmcArgs_GH100
#      (before kfspSendBootCommands, i.e. before the COT);
#      _kgspSetFwWprLayoutOffset reads them again after GSP-RM is up.
#   2. Load the instrumented modules (this also gives a module-load control).
#   3. Unbind the target, FLR it, then bind it back.  The bind probe runs the
#      full GSP bootstrap, so the bracket samplers fire after the FLR.
#   4. Extract the FEAT lines after the bind marker and report the PLM flip
#      interval (the bracket tags bracket the write).
#
# Read-only as far as the GPU register file is concerned: the only mutating
# operations are the PCI FLR and the sysfs unbind/bind.  The FLR can wedge the
# target; the stock DKMS driver is restored in the exit trap, and a reboot is
# the reliable recovery if the bind fails.
#
# Usage:  sudo ./feat_preboot_flr.sh [bdf]
#         BDF=<pci-bdf>
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
GH100="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
KGSP="$TREE/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
COT="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
SR_SRC="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
NVPCI="$TREE/kernel-open/nvidia/nv-pci.c"
NVSRC="$TREE/kernel-open/nvidia/nv.c"
OSINIT="$TREE/src/nvidia/arch/nvalloc/unix/src/osinit.c"
LOAD="$TOOL_DIR/load_patched.sh"
PROBE="$TOOL_DIR/featbank_writer_probe.sh"
TARGET="${1:-${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}}"
OUT="$TOOL_DIR/runs/featpreflr_$(date +%Y%m%d_%H%M%S)"
RUN_START="$(date -Is)"
LOADED=0
mkdir -p "$OUT"

say() { echo "$@" | tee -a "$OUT/run.log"; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 [bdf])"
for f in "$GH100" "$KGSP" "$NVPCI" "$NVSRC" "$OSINIT" "$LOAD" "$PROBE"; do
    [ -f "$f" ] || die "missing $f"
done

exec > >(tee -a "$OUT/run.log") 2>&1
say "== FEAT pre-FMC across FLR"
say "date: $RUN_START"
say "target: $TARGET"
say "tree:   $TREE"
say "out:    $OUT"

# ---------------------------------------------------------------------------
# Instrumentation defines.  Save the two we change so the tree is left as found.
# ---------------------------------------------------------------------------
get_def() { grep -m1 -E "^#define $2 " "$1" | awk '{print $3}'; }
set_def() {
    local f="$1" n="$2" v="$3"
    grep -qE "^#define $n " "$f" || die "no '#define $n' in $f"
    sed -i -E "s/^#define $n .*/#define $n $v/" "$f" \
        || die "could not set $n in $f"
}

ORIG_FEAT_GH=$(get_def "$GH100" BF16_FEAT_PREBOOT)
ORIG_FEAT_KG=$(get_def "$KGSP" BF16_FEAT_PREBOOT)
ORIG_SRDUMP=$(get_def "$GH100" BF16_SRDUMP)
ORIG_NVPROBE=$(get_def "$NVPCI" BF16_FEAT_NVPROBE)
ORIG_NVPROBE_NV=$(get_def "$NVSRC" BF16_FEAT_NVPROBE)
ORIG_RMINIT=$(get_def "$OSINIT" BF16_FEAT_RMINIT)
[ -n "$ORIG_FEAT_GH" ] && [ -n "$ORIG_FEAT_KG" ] || die "FEAT_PREBOOT define missing"
[ -n "$ORIG_SRDUMP" ] || ORIG_SRDUMP=1
[ -n "$ORIG_NVPROBE" ] || ORIG_NVPROBE=0
[ -n "$ORIG_NVPROBE_NV" ] || ORIG_NVPROBE_NV=0
[ -n "$ORIG_RMINIT" ] || ORIG_RMINIT=0

cleanup() {
    set_def "$GH100" BF16_FEAT_PREBOOT "$ORIG_FEAT_GH" 2>/dev/null || true
    set_def "$KGSP"  BF16_FEAT_PREBOOT "$ORIG_FEAT_KG" 2>/dev/null || true
    set_def "$GH100" BF16_SRDUMP "$ORIG_SRDUMP" 2>/dev/null || true
    set_def "$NVPCI" BF16_FEAT_NVPROBE "$ORIG_NVPROBE" 2>/dev/null || true
    set_def "$NVSRC" BF16_FEAT_NVPROBE "$ORIG_NVPROBE_NV" 2>/dev/null || true
    set_def "$OSINIT" BF16_FEAT_RMINIT "$ORIG_RMINIT" 2>/dev/null || true
    if [ "$LOADED" -eq 1 ]; then
        say "== restoring stock modules"
        "$LOAD" --restore | tee -a "$OUT/restore.log" || \
            say "== RESTORE FAILED - reboot is the reliable recovery"
    fi
}
trap cleanup EXIT

set_def "$GH100" BF16_FEAT_PREBOOT 1
set_def "$KGSP"  BF16_FEAT_PREBOOT 1
set_def "$GH100" BF16_SRDUMP 0
set_def "$NVPCI" BF16_FEAT_NVPROBE 1
set_def "$NVSRC" BF16_FEAT_NVPROBE 1
set_def "$OSINIT" BF16_FEAT_RMINIT 1
# This run must vary nothing else.
[ -f "$COT" ] && { set_def "$COT" BF16_COT_VARY 0; set_def "$COT" BF16_COT_VALUE 0ULL; }
set_def "$GH100" BF16_WPR_VARY 0
set_def "$GH100" BF16_WPR_VALUE 0ULL
[ -f "$SR_SRC" ] && { set_def "$SR_SRC" BF16_SR_VARY 0; set_def "$SR_SRC" BF16_SR_VALUE 0ULL; }
say "== defines:"
grep -nE '^#define BF16_(FEAT_PREBOOT|FEAT_NVPROBE|FEAT_RMINIT|SRDUMP|COT_VARY|WPR_VARY|SR_VARY)' \
    "$GH100" "$KGSP" "$NVPCI" "$NVSRC" "$OSINIT" "$COT" "$SR_SRC" 2>/dev/null | tee -a "$OUT/run.log"

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
say "== incremental build of 595.91.07 modules"
grep -q '595.91.07' "$TREE/version.mk" || die "$TREE is not at 595.91.07"
(cd "$TREE" && timeout 1800 make modules -j"$(nproc)") 2>&1 | tee "$OUT/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "build failed; see $OUT/build.log"
for m in nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko; do
    [ -f "$TREE/kernel-open/$m" ] || die "missing $TREE/kernel-open/$m"
done
say "== build ok"

# ---------------------------------------------------------------------------
# Load the instrumented modules.  load_patched.sh clears dmesg, unloads stock,
# insmods, waits 20 s and prints nvidia-smi.  It does not restore.
# ---------------------------------------------------------------------------
hold=""
for f in /proc/[0-9]*/fd/*; do
    l=$(readlink "$f" 2>/dev/null) || continue
    case "$l" in /dev/nvidia*) hold="$hold ${f#/proc/}";; esac
done
[ -n "$hold" ] && say "WARN: open /dev/nvidia* fds:$hold (stop CUDA jobs if the unbind hangs)"

LOADED=1
"$LOAD" | tee "$OUT/load.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || die "load failed; see $OUT/load.log"
dmesg -T > "$OUT/dmesg_load.txt"
say "== GPUs after load:"
timeout -s KILL 15 nvidia-smi -L | tee -a "$OUT/run.log" || true
say "== module-load FEAT lines (control):"
grep -E 'BF16: FEAT|BF16: GSCI' "$OUT/dmesg_load.txt" | tee -a "$OUT/run.log" || true

RP="/sys/bus/pci/devices/$TARGET"
[ -e "$RP/resource0" ] || die "no device $TARGET"
[ -L "$RP/driver" ] || die "$TARGET is not bound after load"
DRV=$(basename "$(readlink -f "$RP/driver")")

snap() { "$PROBE" snapshot --phase "$1" --no-csv --bdfs "$TARGET" | tee -a "$OUT/run.log"; }

# ---------------------------------------------------------------------------
# FLR sequence.
# ---------------------------------------------------------------------------
say "== pre-FLR snapshot"
snap flr2-pre

say "== unbinding $TARGET from $DRV"
echo "BF16: FEAT_FLR_MARKER unbind $TARGET" > /dev/kmsg
timeout 60 sh -c "echo '$TARGET' > /sys/bus/pci/drivers/$DRV/unbind"
say "   unbind rc=$?"
[ -L "$RP/driver" ] && say "   WARN: still bound after unbind"
snap flr2-unbound

say "== triggering FLR"
say "   reset_method: $(cat "$RP/reset_method" 2>/dev/null || echo '?')"
timeout 120 sh -c "echo 1 > '$RP/reset'"
say "   flr rc=$?"
sleep 1
snap flr2-after

say "== binding $TARGET back to $DRV (probe runs the pre-FMC hook)"
echo "BF16: FEAT_FLR_MARKER bind $TARGET" > /dev/kmsg
timeout 120 sh -c "echo '$TARGET' > /sys/bus/pci/drivers/$DRV/bind"
say "   bind rc=$?"
for _ in $(seq 1 60); do [ -L "$RP/driver" ] && break; sleep 1; done
sleep 10
timeout -s KILL 20 nvidia-smi -L | tee -a "$OUT/run.log" || say "   WARN: nvidia-smi did not list the cards"
snap flr2-bound

# ---------------------------------------------------------------------------
# Capture and classify.
# ---------------------------------------------------------------------------
dmesg -T > "$OUT/dmesg_final.txt"
journalctl -k --since "$RUN_START" --no-pager > "$OUT/kernel_journal.txt" 2>/dev/null || true

TARGET_SS0=$(grep -o 'SS0=[0-9a-fA-F]*' "$OUT/run.log" | tail -1 | cut -d= -f2)
say "== target SS0 (last direct snapshot): ${TARGET_SS0:-unknown}"

python3 -I - "$OUT/dmesg_final.txt" "$TARGET_SS0" <<'PY' | tee -a "$OUT/run.log"
import re, sys
path, ss0 = sys.argv[1], (sys.argv[2] or "").lower()
lines = open(path, errors="replace").read().splitlines()

def mark_idx(tag):
    for i in range(len(lines) - 1, -1, -1):
        if tag in lines[i]:
            return i
    return None

def feat(line):
    m = re.search(r'FEAT (pre-FMC|post-boot|\[[^\]]+\]).*?=\s*'
                  r'((?:[0-9a-fA-F]{8}\s*){10})', line)
    if not m:
        return None
    tag = m.group(1)
    if tag.startswith("["):
        tag = tag[1:-1]
    return tag, [int(x, 16) for x in m.group(2).split()]

def verdict(v, note=""):
    plm = v[1]
    if plm == 0xfffffb8f:
        print("  VERDICT%s: PLM is ALREADY LOCKED before the COT (write mask "
              "L3 only).  The re-lock is pre-COT (FSP init / hardware); the "
              "PL2 window is closed on this path." % note)
    elif plm == 0x80842bcf:
        print("  VERDICT%s: PLM is STILL AT THE RESET VALUE before the COT "
              "(write mask L2+L3).  The lock happens at/after the COT (FSP "
              "COT response or FMC); a PL2 window exists until then." % note)
    else:
        print("  VERDICT%s: PLM pre-COT = 0x%08x (new value; record it)."
              % (note, plm))

def show(tag, start, want_verdict=False):
    print("\n== FEAT lines after '%s'" % tag)
    found = 0
    matched = False
    last_pre = None
    for line in lines[start:]:
        f = feat(line)
        if not f:
            continue
        found += 1
        kind, v = f
        gpu = re.search(r'GPU(\d+)', line)
        print("  %-9s GPU%s  PLM(804)=%08x 808=%08x SS0(81c)=%08x SS1(820)=%08x"
              " READOUT_1(818)=%08x" %
              (kind, gpu.group(1) if gpu else "?", v[1], v[2], v[7], v[8], v[6]))
        if kind == "pre-FMC":
            last_pre = v
            if ss0 and ("%08x" % v[7]) == ss0:
                matched = True
                print("            ^ target match (SS0=%s)" % ss0)
                verdict(v)
    if want_verdict and not matched and last_pre is not None:
        print("            (no target SS0 match; using the last pre-FMC line)")
        verdict(last_pre, " (fallback)")
    if not found:
        print("  none (hook did not fire; check bootMode and the dmesg tail)")

bi = mark_idx("FEAT_FLR_MARKER bind")
ui = mark_idx("FEAT_FLR_MARKER unbind")
if ui is not None:
    print("\n== module-load control (before the unbind marker)")
    for line in lines[:ui]:
        f = feat(line)
        if f:
            kind, v = f
            gpu = re.search(r'GPU(\d+)', line)
            print("  %-9s GPU%s  PLM(804)=%08x 808=%08x SS0(81c)=%08x SS1(820)=%08x"
                  % (kind, gpu.group(1) if gpu else "?", v[1], v[2], v[7], v[8]))
if bi is not None:
    show("FEAT_FLR_MARKER bind (post-FLR probe)", bi, want_verdict=True)

    tl = []
    for line in lines[bi:]:
        f = feat(line)
        if f:
            tl.append((f[0], f[1][1], f[1][7]))
    if tl:
        print("\n== PLM timeline after the bind marker")
        for tag, plm, s0 in tl:
            print("  %-16s PLM=%08x SS0=%08x" % (tag, plm, s0))
        first_locked = next((i for i, t in enumerate(tl)
                             if t[1] == 0xfffffb8f), None)
        if first_locked is not None and first_locked > 0:
            prev = tl[first_locked - 1]
            print("  FLIP: %s (PLM=%08x) -> %s (PLM=%08x)" %
                  (prev[0], prev[1], tl[first_locked][0],
                   tl[first_locked][1]))
        elif first_locked == 0:
            print("  FLIP: already 0xfffffb8f at the earliest bracket point (%s)"
                  % tl[0][0])
else:
    print("\n== no bind marker found; dmesg tail:")
    print("\n".join(lines[-25:]))
PY

say "== dmesg: $OUT/dmesg_final.txt"
say "== after-bind FEAT lines:"
awk '/FEAT_FLR_MARKER bind/{f=1} f' "$OUT/dmesg_final.txt" \
    | grep -E 'BF16: FEAT|BF16: GSCI|Fatal GSP|RmInitAdapter|Xid' \
    | tee "$OUT/after_bind.txt" || true
say "== run dir: $OUT"
