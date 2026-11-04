#!/usr/bin/env bash
# run_census_probe.sh - C29 engine-map census v2, read-only, one card.
#
# v2 hardening after the v1 run crashed GSP-RM with a read near
# 0x42f900-0x431004 (Xid 120/13/154, card recovered by reboot):
#   - every batch re-reads PMC_BOOT_0 as a canary and checks the RM control
#     status; any mismatch aborts the census instead of printing zeros;
#   - no live X+0x300/X+0x304 doorbell-geometry reads; pairs are derived
#     offline from the 0x100-stride map;
#   - 0x42f804-0x500000 is not scanned at all.
#
# Pass order C, A, D, B (small and valuable first):
#   C. dense follow-ups: 0x1c0000, 0x1ce000, 0x500000, signature reads at the
#      documented falcon bases;
#   A. falcon HWCFG2/CPUCTL/ENGINE_RESET signature at every 0x1000-aligned
#      base below 0x1000000, skipping the 0x300000-0x400000 hazard;
#   D. 0x10000-stride probe to the 64 MiB BAR0 end and a fresh dump of the
#      per-card 0x1f2000 table;
#   B. one read at every 0x100-aligned X in [0x500000, 0x1000000).
#
# Pin the card with PCI ordering: CUDA device 0 is 41:00.0.
# No writes, no falcon port cycles. Run manually and unprivileged.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

GPU=${GPU:-0}
TAG=${TAG:-v2}

gcc -O2 -Wall -shared -fPIC -o rm_debug_hook.so rm_debug_hook.c -ldl

CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$GPU RM_DEBUG_CENSUS=1 \
LD_LIBRARY_PATH=/usr/local/cuda/lib64 \
LD_PRELOAD="$HERE/rm_debug_hook.so" \
    ./cuda_ctx_probe > census-${TAG}-gpu${GPU}.out 2> census-${TAG}-gpu${GPU}.log || true

echo "--- cuda probe ---"
cat census-${TAG}-gpu${GPU}.out
echo "--- aborts / signatures ---"
grep -E "^CENSUS (ABORT|SIG|FALCON|complete|[ACDB]: done)" census-${TAG}-gpu${GPU}.log | head -60
echo "--- map volume ---"
grep -c "^CENSUS MAP" census-${TAG}-gpu${GPU}.log || true
echo "--- end ---"
echo "log: $HERE/census-${TAG}-gpu${GPU}.log"
