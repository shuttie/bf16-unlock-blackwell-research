#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# fmc_buffer_probe.sh - read the host-supplied FMC container back out of
# sysmem, and (optionally) corrupt one field of it while the COT hash,
# signature and key stay stock.
#
# Background (boot-input experiments E28, E61):
#   kfspSetupGspImages() copies the FMC container (plaintext 0x48 header +
#   encrypted body) into unprotected sysmem at COT.gspFmcSysmemOffset.  The
#   COT hash/signature are copied verbatim from driver bindata; the driver
#   never computes them and never reads the buffer back.  Two things are
#   unknown and both are cheap to answer:
#
#     1. Does the FSP decrypt in place?  If the buffer holds plaintext after
#        the boot, the FMC corpus is free.
#     2. Does secure firmware re-hash the bytes it loads?  If it only checks
#        the signature over the *supplied* 48-byte hash, a ciphertext bit flip
#        reaches the decrypted FMC as a plaintext bit flip: a fault-injection
#        primitive into HS code.
#
# Usage:
#   sudo ./fmc_buffer_probe.sh dump                 # read-only, no risk
#   sudo ./fmc_buffer_probe.sh tamper 1 [off]       # flip one ciphertext bit
#   sudo ./fmc_buffer_probe.sh tamper 2 [val]       # overwrite body-size field
#   sudo ./fmc_buffer_probe.sh tamper 3             # flip container magic bit
#
#   tamper 1 default off  = 0x1048 (0x1000 into the encrypted body)
#   tamper 2 default val  = 0x46300 (stock body size 0x46200 + 0x100)
#
# Expected outcomes for a tamper run:
#   "FSP response ... Error code: 0x377"  -> hash is recomputed over the image;
#                                            route closed, WPR2 stays armed,
#                                            one reboot required.
#   clean boot / different code / hang    -> the supplied hash is trusted;
#                                            ciphertext tampering is not detected.
#
# Safety: the dump is a read-only memdescMap.  The tamper run feeds modified
# bytes to secure firmware; a refused boot is restored by the harness trap, a
# WPR2-armed failure needs a reboot.  The stock DKMS modules are the recovery
# path and are never modified.
#
set -u

ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
FSP_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
GEN_SRC="$TREE/src/nvidia/src/kernel/gpu/fsp/kern_fsp.c"
ART="$TOOL_DIR/runs/artifacts"
HARNESS="$TOOL_DIR/dump_ctx.sh"
REF_CONT="${REF_CONT:-$TOOL_DIR/../fmc-tools/out/c04_cont.bin}"
REF_SIZE=287304

usage() {
    sed -n '2,40p' "$0"
}

MODE="${1:-dump}"
TAMPER=0
TAMP_VAL=0x46300
TAMP_OFF=0x1048

case "$MODE" in
    dump)
        ;;
    tamper)
        TAMPER="${2:-1}"
        case "$TAMPER" in
            1) TAMP_OFF="${3:-0x1048}" ;;
            2) TAMP_VAL="${3:-0x46300}" ;;
            3) ;;
            *) echo "tamper mode must be 1, 2 or 3" >&2; exit 2 ;;
        esac
        ;;
    *)
        usage >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0 $*)" >&2; exit 1; }
[ -f "$FSP_SRC" ] || { echo "missing $FSP_SRC" >&2; exit 1; }
[ -f "$GEN_SRC" ] || { echo "missing $GEN_SRC" >&2; exit 1; }
[ -x "$HARNESS" ] || { echo "missing $HARNESS" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Refuse to start on a wedged GPU: every run here ends in a driver reload,
#    and a stale WPR2 only adds a reboot to the cost.
# ---------------------------------------------------------------------------
if ! timeout -s KILL 15 nvidia-smi -L >/dev/null 2>&1; then
    echo "!! nvidia-smi cannot enumerate the GPUs; reboot before running this." >&2
    exit 1
fi
if dmesg -T 2>/dev/null | tail -200 | grep -q "GPU Reset Required"; then
    echo "!! a GPU reports 'Reset Required'; reboot before running this." >&2
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$TOOL_DIR/runs/fmcprobe_$STAMP"
mkdir -p "$LOG" "$ART"
chmod 0777 "$ART"

set_define() {
    local file="$1" name="$2" value="$3"
    sed -i -E "s/^#define ${name} .*/#define ${name} ${value}/" "$file" \
        || { echo "could not set ${name} in ${file}" >&2; exit 1; }
}

# Never leave a tampered build armed for the next boot.
cleanup() {
    set_define "$FSP_SRC" BF16_FMCTAMPER 0
    set_define "$FSP_SRC" BF16_TAMPER_OFF 0x1048
    set_define "$FSP_SRC" BF16_TAMPER_VAL 0x46300
}
trap cleanup EXIT

set_define "$FSP_SRC" BF16_FMCDUMP 1
set_define "$FSP_SRC" BF16_FMCTAMPER "$TAMPER"
set_define "$FSP_SRC" BF16_TAMPER_OFF "$TAMP_OFF"
set_define "$FSP_SRC" BF16_TAMPER_VAL "$TAMP_VAL"

echo "== BF16 FMC buffer probe: mode=$MODE tamper=$TAMPER off=$TAMP_OFF val=$TAMP_VAL"
grep -n "^#define BF16_\(FMCDUMP\|FMCTAMPER\|TAMPER_\)" "$FSP_SRC" | tee "$LOG/config.txt"
echo

# ---------------------------------------------------------------------------
# 1. Build, load, capture, restore (dump_ctx.sh --no-trigger).
# ---------------------------------------------------------------------------
env EXITMAX=0 MAXDUMPS=0 GLOBALMAX=0 BYTES=64 \
    "$HARNESS" --no-trigger 2>&1 | tee "$LOG/harness.log"
HARNESS_RC=${PIPESTATUS[0]}

# The restore trap has run by now.  Capture the log ourselves: on a refused
# boot the harness may die before writing its own dmesg.txt.
dmesg -T > "$LOG/dmesg_probe.txt" 2>/dev/null || true

cp -a "$ART"/fmc_*.bin "$LOG"/ 2>/dev/null || true
chmod -R a+r "$ART" "$LOG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Verdict-relevant lines.
# ---------------------------------------------------------------------------
echo
echo "== probe lines"
grep -hE "BF16: FMCDUMP|BF16: FMCTAMPER|Fatal GSP-FMC|FSP response reported|unexpected WPR2|RmInitAdapter failed|Max GSP-RM boot|GPU Reset Required|Xid" \
    "$LOG/harness.log" "$LOG/dmesg_probe.txt" 2>/dev/null \
    | sed 's/^/   /' | sort -u | tail -80

echo
echo "== artifacts"
for f in "$LOG"/fmc_*.bin; do
    [ -f "$f" ] || continue
    echo "   $f  ($(stat -c %s "$f") bytes)"

    if [ -f "$REF_CONT" ] && [ "$(stat -c %s "$f")" -ge "$REF_SIZE" ]; then
        if cmp -s -n "$REF_SIZE" "$f" "$REF_CONT"; then
            echo "      first $REF_SIZE bytes: identical to c04 (stock container)"
        else
            echo "      first $REF_SIZE bytes: DIFFERS from c04 at: $(cmp -n "$REF_SIZE" "$f" "$REF_CONT" 2>&1 | head -1)"
        fi
    fi

    # A quick plaintext test: ASCII runs in the encrypted body.
    if [ "$(stat -c %s "$f")" -gt 4096 ]; then
        RUNS=$(strings -n 16 -t d "$f" 2>/dev/null | awk '$1 >= 72 {c++} END {print c+0}')
        echo "      printable runs (>=16 chars) past the 0x48 header: $RUNS"
    fi
done

echo
echo "== run dir: $LOG"
echo "== harness rc: $HARNESS_RC"
if grep -qE "unexpected WPR2 already up|Error code: 0x377" "$LOG/harness.log" "$LOG/dmesg_probe.txt" 2>/dev/null; then
    echo "== WPR2 armed / hash refused: reboot before the next run."
elif [ "$HARNESS_RC" -ne 0 ]; then
    echo "== harness failed; check $LOG/harness.log, reboot if the GPUs are unhealthy."
else
    echo "== clean run."
fi

exit "$HARNESS_RC"
