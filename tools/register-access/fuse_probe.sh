#!/bin/bash
# fuse_probe.sh - read-only map of the FUSE/OTP register block through
# NV2080_CTRL_CMD_GPU_EXEC_REG_OPS. No writes, no BAR0 aperture scanning.
#
# Usage: sudo ./fuse_probe.sh [gpu_index] [bdf]
#        defaults: 1  0000:41:00.0
# Env: GPU, BDF, REGOPS, OUTDIR (defaults: 1, 0000:41:00.0, ./regops, ./runs)
set -u
GPU=${GPU:-${1:-1}}
BDF=${BDF:-${2:-0000:41:00.0}}
DIR=$(cd "$(dirname "$0")" && pwd)
REGOPS=${REGOPS:-$DIR/regops}
OUTDIR=${OUTDIR:-$DIR/runs}
mkdir -p "$OUTDIR"
RAW="$OUTDIR/fuse_probe_$(date +%Y%m%d_%H%M%S).txt"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (the register allowlist is bypassed only for admin)" >&2
    exit 1
fi

echo "== FUSE block read-only probe $(date -Is)" | tee "$RAW"
echo "== gpu=$GPU bdf=$BDF driver=$(cat /sys/module/nvidia/version 2>/dev/null)" | tee -a "$RAW"
echo | tee -a "$RAW"

echo "---- sanity: PMC_BOOT_0" | tee -a "$RAW"
timeout 30 "$REGOPS" "$GPU" "$BDF" one 2>&1 | tee -a "$RAW" \
    | grep -E "control status|PMC_BOOT_0|alloc (client|device|subdevice)"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
    echo "sanity read failed rc=$rc -- stopping" | tee -a "$RAW"
    exit 1
fi
if ! grep -qE 'PMC_BOOT_0.*value=0x[0-9a-f]' "$RAW"; then
    echo "PMC_BOOT_0 did not read back as a nonzero 0x value -- stopping" | tee -a "$RAW"
    exit 1
fi
echo | tee -a "$RAW"

for base in 820000 820200 820400 820600; do
    last=$(printf '%x' $((0x$base + 4 * 127)))
    echo "---- dump 0x$base..0x$last (128 words)" | tee -a "$RAW"
    timeout 30 "$REGOPS" "$GPU" "$BDF" dump "$base" 80 2>&1 \
        | tee -a "$RAW" >/dev/null
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "---- ^ FAILED rc=$rc (124 = timeout; if 124, reboot before continuing)" | tee -a "$RAW"
        exit 1
    fi
    echo | tee -a "$RAW"
done

echo "== summary: non-sentinel registers (0xBADFxxxx = unimplemented)"
awk '
  /^dump .*status = / { print "  control " $0; next }
  /^  / && $1 ~ /^0x/ {
      off=$1; val=$3
      if (val ~ /badf/) {
          if (!inrun) { inrun=1; rstart=off; rcount=0 }
          rlast=off; rcount++
          next
      }
      if (inrun) { printf "  [sentinel %s .. %s, %d words]\n", rstart, rlast, rcount; inrun=0 }
      printf "  %-12s = %s\n", off, val
  }
  END { if (inrun) printf "  [sentinel %s .. %s, %d words]\n", rstart, rlast, rcount }
' "$RAW"

echo
echo "== raw log: $RAW"
