#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Dump the host-supplied GspRmBoot buffer before the FMC reads it and after
# GSP-RM is up.  The buffer is the unprotected sysmem image the FMC consumes
# (WprMeta.sysmemAddrOfBootloader).  If the post copy is not the stock
# ciphertext, the FMC decrypted it in place and the HS image is readable at PL0.
#
#   sudo ./bootbuf_dump.sh
#
# Builds 595.91.07 with BF16_BOOTDUMP=1, loads the instrumented modules,
# triggers a normal boot, restores the stock driver, and compares the two
# copies.  The tree is left as found.  No register is written.
set -u

TREE="${TREE:?set TREE to the NVIDIA open kernel modules checkout at 595.91.07}"
ROOT="${ROOT:-$(cd "$TOOL_DIR/../../.." && pwd)}"
GH100="$TREE/src/nvidia/src/kernel/gpu/gsp/arch/hopper/kernel_gsp_gh100.c"
KGSP="$TREE/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
FMC="$TREE/src/nvidia/src/kernel/gpu/fsp/arch/hopper/kern_fsp_gh100.c"
LOAD="$TOOL_DIR/load_patched.sh"
DUMPDIR="$TOOL_DIR/runs/bootbuf"
OUT="$TOOL_DIR/bootdump_$(date +%Y%m%d_%H%M%S)"
LOADED=0
mkdir -p "$OUT" "$DUMPDIR"
rm -f "$DUMPDIR"/boot_pre_gpu*.bin "$DUMPDIR"/boot_post_gpu*.bin

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

# Save only the defines this harness changes.
O_BOOT_GH=$(get_def "$GH100" BF16_BOOTDUMP)
O_BOOT_KG=$(get_def "$KGSP"  BF16_BOOTDUMP)
O_SRDUMP=$(get_def "$GH100" BF16_SRDUMP)
O_TAMPER=$(get_def "$GH100" BF16_BOOT_TAMPER)
O_WPR=$(get_def "$GH100" BF16_WPR_VARY)
O_FEAT_GH=$(get_def "$GH100" BF16_FEAT_PREBOOT)
O_FEAT_KG=$(get_def "$KGSP"  BF16_FEAT_PREBOOT)
O_FMCDUMP=$(get_def "$FMC"   BF16_FMCDUMP)
[ -n "$O_BOOT_GH" ] && [ -n "$O_BOOT_KG" ] || die "BF16_BOOTDUMP define missing (did the hook land?)"

cleanup() {
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
say "== boot-buffer dump $(date -Is)"
say "   gh100=$GH100"
say "   dumpdir=$DUMPDIR"

set_def "$GH100" BF16_BOOTDUMP 1
set_def "$KGSP"  BF16_BOOTDUMP 1
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

# load_patched.sh already waits 20 s and runs nvidia-smi, which triggers the
# GSP boot (and the post-boot dump).  Give the dump a moment, then capture.
sleep 5
dmesg -T > "$OUT/dmesg_post.txt"
say "== BOOTDUMP lines:"
grep -E "BF16: BOOTDUMP" "$OUT/dmesg_post.txt" | tee -a "$OUT/run.log" || \
    say "   (none - did the boot path run?)"

LOADED=0
"$LOAD" --restore | tee -a "$OUT/restore.log"
say "== stock restored"

# ---------------------------------------------------------------------------
# Compare.
# ---------------------------------------------------------------------------
python3 -I - "$DUMPDIR" "$OUT" <<'PY'
import glob, hashlib, math, os, sys
d, out = sys.argv[1], sys.argv[2]
rows = []
def ent(b):
    if not b: return 0.0
    c = [0]*256
    for x in b: c[x] += 1
    n = len(b)
    return -sum((v/n)*math.log2(v/n) for v in c if v)
for gpu in (0, 1):
    pre = os.path.join(d, f"boot_pre_gpu{gpu}.bin")
    post = os.path.join(d, f"boot_post_gpu{gpu}.bin")
    if not (os.path.exists(pre) and os.path.exists(post)):
        rows.append(f"gpu{gpu}: missing pre={os.path.exists(pre)} post={os.path.exists(post)}")
        continue
    a = open(pre, "rb").read(); b = open(post, "rb").read()
    diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a)-len(b))
    rows.append(
        f"gpu{gpu}: size {len(a)}/{len(b)} "
        f"entropy {ent(a):.4f}/{ent(b):.4f} "
        f"sha256 {hashlib.sha256(a).hexdigest()[:16]}/{hashlib.sha256(b).hexdigest()[:16]} "
        f"diff_bytes {diff}")
    if diff:
        i = next(k for k, (x, y) in enumerate(zip(a, b)) if x != y)
        rows.append(f"  first diff at 0x{i:x}: {a[i]:02x} -> {b[i]:02x}")
        # printable strings in the post copy
        import re
        ss = [m.group() for m in re.finditer(rb"[ -~]{6,}", b[:0x2000])]
        if ss:
            rows.append("  post head strings: " + " | ".join(s.decode() for s in ss[:8]))
text = "\n".join(rows)
print(text)
open(os.path.join(out, "compare.txt"), "w").write(text + "\n")
PY

say "== compare:"
cat "$OUT/compare.txt" | tee -a "$OUT/run.log"
say "== done: $OUT"
