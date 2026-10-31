#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# dump_ctx.sh - Phase 2b: dump initialized GR context buffers (read-only).
#
# The patch adds a one-shot memdescMap/memdescUnmap read of the main and patch
# GR context buffers in kgrctxMarkCtxBufferInitialized_IMPL, after the GSP has
# initialized them.  It writes each buffer to /dev/shm/bf16_ctxdump_*.bin and prints
# a small header in dmesg; parse_ctxfiles.py summarizes the files.
#
# Usage:
#   sudo ./dump_ctx.sh                 # patch, incremental build, load, probe, parse, restore
#   sudo ./dump_ctx.sh --no-build      # reuse the existing build (no make at all)
#   sudo ./dump_ctx.sh --clean-build   # force make clean + full rebuild
#   sudo ./dump_ctx.sh --no-load       # only apply/build
#   sudo ./dump_ctx.sh --restore       # unload and restore the stock DKMS modules
#   sudo ./dump_ctx.sh --parse-only dmesg.txt outdir
#
# Environment:
#   BDF=0000:41:00.0   target GPU (default: GPU1, the non-display card in the
#                      local two-card setup; confirm with nvidia-smi -L)
#   BYTES=8192         bytes per buffer for the optional dmesg hex dump
#   FILEMAX=0x400000   max bytes written per /dev/shm/bf16_ctxdump_*.bin
#   MAIN_OFF=0         start offset for the main-context buffer dump
#   MAXDUMPS=8         number of creation-time context buffers to dump
#   EXITMAX=2          number of post-use main/patch dumps (channel teardown)
#   GLOBALMAX=6        number of global context buffers to dump
#   POWER_LIMIT=575    expected power limit for the probe
#   TREE=<NVIDIA open kernel modules checkout at 595.91.07>
#   ROOT="$(cd "$TOOL_DIR/../../.." && pwd)"
#
# Safety: no register or firmware writes; the only GPU operation is a
# read-only memdescMap of a buffer the driver already owns, unmapped in the
# same call.  The driver is the instrumented 595.91.07 tree; the DKMS modules
# remain the recovery path.  If rmmod/insmod fails, reboot.
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
export MODDIR="$TREE/kernel-open"
PATCH="$TOOL_DIR/bf16_ctxdump.patch"
LOAD="$TOOL_DIR/load_patched.sh"
PARSER="$TOOL_DIR/parse_ctxdump.py"
FILEPARSER="$TOOL_DIR/parse_ctxfiles.py"
CUBIN="$TOOL_DIR/../issue-rate-probe/tensor_modes_issue_sm120.cubin"
RUNNER="$TOOL_DIR/../issue-rate-probe/tensor_modes_driver_runner.py"

BDF="${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}"
BYTES="${BYTES:-8192}"
MAIN_OFF="${MAIN_OFF:-0}"
FILEMAX="${FILEMAX:-0x400000}"
MAXDUMPS="${MAXDUMPS:-8}"
EXITMAX="${EXITMAX:-2}"
GLOBALMAX="${GLOBALMAX:-6}"
POWER_LIMIT="${POWER_LIMIT:-575}"

DO_BUILD=1
DO_CLEAN=0
DO_LOAD=1
DO_TRIGGER=1
DO_PARSE=1
LOADED=0
OUT="$TOOL_DIR/runs/ctxdump_$(date +%Y%m%d_%H%M%S)"
RUN_START="$(date -Is)"

say() { echo "$@" | tee -a "$OUT/run.log"; }
die() { say "ERROR: $*"; exit 1; }

if [ "${1:-}" = "--parse-only" ]; then
    [ $# -eq 3 ] || die "usage: $0 --parse-only <dmesg.txt> <outdir>"
    exec python3 -I "$PARSER" "$2" "$3"
fi

if [ "$(id -u)" -ne 0 ]; then
    die "run as root (sudo)"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --restore)
            exec "$LOAD" --restore
            ;;
        --no-build)    DO_BUILD=0 ;;
        --clean-build) DO_CLEAN=1 ;;
        --no-load)     DO_LOAD=0; DO_TRIGGER=0 ;;
        --no-trigger)  DO_TRIGGER=0 ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

say "== BF16 GR context-buffer dump =="
say "date: $(date -Is)"
say "BDF=$BDF BYTES=$BYTES FILEMAX=$FILEMAX MAIN_OFF=$MAIN_OFF MAXDUMPS=$MAXDUMPS EXITMAX=$EXITMAX GLOBALMAX=$GLOBALMAX"
say "tree: $TREE"
say "out:  $OUT"
echo

[ -f "$PATCH" ] || die "missing $PATCH"
[ -f "$LOAD" ]  || die "missing $LOAD"
[ -f "$PARSER" ] || die "missing $PARSER"
[ -f "$FILEPARSER" ] || die "missing $FILEPARSER"
[ -f "$CUBIN" ] || die "missing $CUBIN"
[ -f "$RUNNER" ] || die "missing $RUNNER"

rm -f /dev/shm/bf16_ctxdump_*.bin

if [ "$DO_BUILD" -eq 1 ]; then
    grep -q "595.91.07" "$TREE/version.mk" || die "$TREE is not at 595.91.07"
fi

# ---------------------------------------------------------------------------
# 1. Apply the patch (idempotent) and set the dump parameters.
# ---------------------------------------------------------------------------
CTXSRC="$TREE/src/nvidia/src/kernel/gpu/gr/kernel_graphics_context.c"
[ -f "$CTXSRC" ] || die "missing $CTXSRC"

if grep -q "BF16_CTXDUMP_BEGIN" "$CTXSRC"; then
    say "== patch already present in $CTXSRC"
else
    say "== applying $PATCH"
    (cd "$TREE" && git apply "$PATCH") || die "git apply failed"
fi

if ! grep -qE "^#define BF16_CTXDUMP_BYTES[[:space:]]+$BYTES\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_BYTES[[:space:]]+.*/#define BF16_CTXDUMP_BYTES $BYTES/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_BYTES"
fi
if ! grep -qE "^#define BF16_CTXDUMP_FILE_MAX[[:space:]]+$FILEMAX\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_FILE_MAX[[:space:]]+.*/#define BF16_CTXDUMP_FILE_MAX $FILEMAX/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_FILE_MAX"
fi
if ! grep -qE "^#define BF16_CTXDUMP_MAX[[:space:]]+$MAXDUMPS\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_MAX[[:space:]]+.*/#define BF16_CTXDUMP_MAX   $MAXDUMPS/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_MAX"
fi
if ! grep -qE "^#define BF16_CTXDUMP_MAIN_OFFSET[[:space:]]+$MAIN_OFF\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_MAIN_OFFSET[[:space:]]+.*/#define BF16_CTXDUMP_MAIN_OFFSET $MAIN_OFF/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_MAIN_OFFSET"
fi
if ! grep -qE "^#define BF16_CTXDUMP_EXIT_MAX[[:space:]]+$EXITMAX\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_EXIT_MAX[[:space:]]+.*/#define BF16_CTXDUMP_EXIT_MAX $EXITMAX/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_EXIT_MAX"
fi
if ! grep -qE "^#define BF16_CTXDUMP_PATCH_EXIT_MAX[[:space:]]+$EXITMAX\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_PATCH_EXIT_MAX[[:space:]]+.*/#define BF16_CTXDUMP_PATCH_EXIT_MAX $EXITMAX/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_PATCH_EXIT_MAX"
fi
if ! grep -qE "^#define BF16_CTXDUMP_GLOBAL_MAX[[:space:]]+$GLOBALMAX\$" "$CTXSRC"; then
    sed -i -E "s/^#define BF16_CTXDUMP_GLOBAL_MAX[[:space:]]+.*/#define BF16_CTXDUMP_GLOBAL_MAX $GLOBALMAX/" "$CTXSRC" \
        || die "could not set BF16_CTXDUMP_GLOBAL_MAX"
fi
say "== dump config:"
grep -nE "^#define BF16_CTXDUMP_(BYTES|FILE_MAX|MAIN_OFFSET|CREATE|MAX|EXIT_MAX|PATCH_EXIT_MAX|GLOBAL|GLOBAL_MAX)" "$CTXSRC" | tee -a "$OUT/run.log"
echo

# ---------------------------------------------------------------------------
# 2. Build.
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
    if [ "$DO_CLEAN" -eq 1 ]; then
        say "== clean building 595.91.07 modules (this takes a few minutes)"
        (cd "$TREE" && timeout 1800 make clean && timeout 1800 make modules -j"$(nproc)") \
            | tee "$OUT/build.log"
    else
        say "== incremental build of 595.91.07 modules"
        (cd "$TREE" && timeout 1800 make modules -j"$(nproc)") \
            | tee "$OUT/build.log"
    fi
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "build failed; see $OUT/build.log"
    for m in nvidia.ko nvidia-modeset.ko nvidia-uvm.ko nvidia-drm.ko; do
        [ -f "$TREE/kernel-open/$m" ] || die "missing $TREE/kernel-open/$m"
    done
    say "== build ok"
else
    say "== skipping build"
fi
echo

# ---------------------------------------------------------------------------
# 3. Identify the target GPU UUID.
# ---------------------------------------------------------------------------
BDF_TAIL="${BDF#*:}"
UUID="${UUID:-}"
if [ -z "$UUID" ]; then
    UUID=$(nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader 2>/dev/null \
        | awk -F', ' -v s=":$BDF_TAIL" 'index(tolower($2), tolower(s)) > 0 {print $1; exit}')
fi
[ -n "$UUID" ] || die "could not find a GPU with BDF $BDF; run 'nvidia-smi -L'"
say "== target UUID: $UUID"
echo

# ---------------------------------------------------------------------------
# 4. Load the instrumented modules.
# ---------------------------------------------------------------------------
restore_driver() {
    if [ "$LOADED" -eq 1 ]; then
        say "== restoring stock modules"
        "$LOAD" --restore | tee "$OUT/restore.log" || true
    fi
}
trap restore_driver EXIT

if [ "$DO_LOAD" -eq 1 ]; then
    # load_patched.sh clears dmesg, unloads stock, insmods the tree modules.
    # Mark LOADED first: if the loader unloads stock and then fails, the exit
    # trap must still restore a working driver.
    LOADED=1
    "$LOAD" | tee "$OUT/load.log"
    rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || die "load failed; see $OUT/load.log"
    # load_patched.sh already waits 20 s and prints nvidia-smi -L.
    echo
    say "== GPUs after load:"
    timeout -s KILL 15 nvidia-smi -L || true
    echo
else
    say "== skipping load; assuming the instrumented driver is already loaded"
    LOADED=0
fi

# ---------------------------------------------------------------------------
# 5. Trigger a GR context with the sm_120 probe, then capture dmesg.
# ---------------------------------------------------------------------------
if [ "$DO_TRIGGER" -eq 1 ]; then
    HASH=$(sha256sum "$CUBIN" | awk '{print $1}')
    say "== triggering a CUDA context (iters=1 reps=1, no register poke)"
    ( cd "$TOOL_DIR/../issue-rate-probe" && \
      CUDA_VISIBLE_DEVICES="$UUID" timeout 240 python3 "$RUNNER" "$CUBIN" \
        --sha256 "$HASH" --expect-uuid "$UUID" \
        --expect-power-limit "$POWER_LIMIT" --iters 1 --reps 1 ) \
        | tee "$OUT/probe.log"
    say "== probe rc=${PIPESTATUS[0]} (a nonzero rc is not fatal for the dump)"
    sleep 2
fi

dmesg -T > "$OUT/dmesg.txt"
say "== dmesg written to $OUT/dmesg.txt"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --since "$RUN_START" --no-pager > "$OUT/kernel_journal.txt" 2>/dev/null || true
    say "== kernel journal written to $OUT/kernel_journal.txt"
fi
grep -E "BF16: ctxdump|BF16: COT|BF16: WprMeta|BF16: FMC|BF16CTX|Xid|Fatal GSP|RmInitAdapter" "$OUT/dmesg.txt" \
    | tail -40 | tee -a "$OUT/run.log" || true
echo

if compgen -G "/dev/shm/bf16_ctxdump_*.bin" >/dev/null; then
    cp -f /dev/shm/bf16_ctxdump_*.bin "$OUT/" || true
    chmod 0644 "$OUT"/bf16_ctxdump_*.bin 2>/dev/null || true
    say "== copied $(ls -1 "$OUT"/bf16_ctxdump_*.bin | wc -l) context file(s)"
fi

# ---------------------------------------------------------------------------
# 6. Parse the dump.
# ---------------------------------------------------------------------------
if [ "$DO_PARSE" -eq 1 ]; then
    if compgen -G "$OUT/bf16_ctxdump_*.bin" >/dev/null; then
        say "== summarizing context files"
        python3 -I "$FILEPARSER" "$OUT" | tee "$OUT/file_summary.txt"
    else
        say "== parsing BF16CTX records"
        python3 -I "$PARSER" "$OUT/dmesg.txt" "$OUT" | tee "$OUT/parse.log"
    fi
fi

echo
say "== done: $OUT"
say "== restore with: sudo $0 --restore"
