#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Phase 2b signed-image boundary test.
#
# Installs a GSP-RM image whose FUN_ram_015ffae8 entry is replaced with `ret`
# (0x00008067), reloads the instrumented driver, captures the result, then puts
# the original firmware back before returning.  If the FMC/BootROM rejects the
# modified image, the GPUs will not come back until a reboot; the restored
# firmware makes that reboot clean.
#
# Usage: sudo ./run_gsp_patch_test.sh
set -u
DIR="$TOOL_DIR"
FW=/lib/firmware/nvidia/595.91.07/gsp_ga10x.bin
ORIG="$DIR/gsp_ga10x.bin.orig"
PATCHED="$DIR/gsp_ga10x.bin.patched"
OUT="$TOOL_DIR/runs/gsp_patch_test_$(date +%Y%m%d_%H%M%S).txt"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi
[ -f "$ORIG" ] && [ -f "$PATCHED" ] || { echo "missing image copies in $DIR" >&2; exit 1; }

say() { echo "$@" | tee -a "$OUT"; }

say "== GSP signed-image boundary test $(date -Is)"
say "== original sha256: $(sha256sum "$ORIG" | awk '{print $1}')"
say "== patched  sha256: $(sha256sum "$PATCHED" | awk '{print $1}')"

cp "$ORIG" "$DIR/gsp_ga10x.bin.pre_test"
cp "$PATCHED" "$FW"
sync
say "== installed patched firmware: $(sha256sum "$FW" | awk '{print $1}')"

# Load the instrumented modules against the patched image.
"$DIR/load_patched.sh" 2>&1 | tee -a "$OUT"
rc=${PIPESTATUS[0]}

# Restore the original firmware immediately, whatever happened.
cp "$ORIG" "$FW"
sync
say "== restored original firmware: $(sha256sum "$FW" | awk '{print $1}')"

# Try to bring the stock driver back.  If the GSP is wedged this will fail;
# a reboot is the recovery and will now use the original image.
"$DIR/load_patched.sh" --restore 2>&1 | tee -a "$OUT" || true

say "== test rc=$rc"
say "== if the GPUs are not back, reboot (firmware is restored)"
say "== log: $OUT"
exit "$rc"
