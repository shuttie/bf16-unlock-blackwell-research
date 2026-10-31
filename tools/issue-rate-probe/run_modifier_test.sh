#!/bin/bash
# Set SM_ISSUE_RATE_MODIFIER=0, run the sm_120 issue-rate probe, read the
# register back (did the driver rewrite it?), then restore 5. Run as root:
# regops needs the admin register-allowlist bypass.
#
# Environment:
#   UUID          target GPU UUID (required)
#   HASH          cubin SHA-256 (default: computed from the local cubin)
#   BDF           PCI BDF (default 0000:41:00.0)
#   GPU           RM deviceId (default 1)
#   REG           BAR0 offset without 0x (default 504204)
#   POWER_LIMIT   expected power cap in W (default 575)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REGOPS="${REGOPS:-$(cd "$DIR/../register-access" && pwd)/regops}"
UUID="${UUID:?set UUID to the target GPU UUID}"
BDF="${BDF:-0000:41:00.0}"
GPU="${GPU:-1}"
REG="${REG:-504204}"
POWER_LIMIT="${POWER_LIMIT:-575}"
CUBIN="$DIR/tensor_modes_issue_sm120.cubin"

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root" >&2
    exit 1
fi
if [ ! -x "$REGOPS" ]; then
    echo "missing $REGOPS (build tools/register-access first)" >&2
    exit 1
fi
if [ ! -f "$CUBIN" ]; then
    echo "missing $CUBIN (build it first; see README)" >&2
    exit 1
fi
HASH="${HASH:-$(sha256sum "$CUBIN" | cut -d' ' -f1)}"

echo "== before"
"$REGOPS" "$GPU" "$BDF" bar "$REG" 1

echo "== setting $REG = 0"
"$REGOPS" "$GPU" "$BDF" barw "$REG" 0 0

echo "== probe (modifier = 0)"
mkdir -p "$DIR/results"
OUT="$DIR/results/modifier_test_$(date +%Y%m%d_%H%M%S).txt"
CUDA_VISIBLE_DEVICES="$UUID" timeout 180 python3 "$DIR/tensor_modes_driver_runner.py" \
    "$CUBIN" --sha256 "$HASH" --expect-uuid "$UUID" \
    --expect-power-limit "$POWER_LIMIT" --iters 20000 --reps 3 \
    --bdf "$BDF" --reg-offset "0x$REG" --reg-value 0 | tee "$OUT"
rc=${PIPESTATUS[0]}

echo "== readback after probe (5 means the driver rewrote it at context creation)"
"$REGOPS" "$GPU" "$BDF" bar "$REG" 1

echo "== restoring $REG = 5"
"$REGOPS" "$GPU" "$BDF" barw "$REG" 5 5

echo "== final"
"$REGOPS" "$GPU" "$BDF" bar "$REG" 1
echo "== probe output: $OUT"
exit "$rc"
