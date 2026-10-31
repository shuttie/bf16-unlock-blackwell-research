#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
# Measure the post-FLR FEAT_OVR_PLM window and optionally race a PL2 write
# into it.  This is the E65 window: after an FLR the PLM reads 0x80842bcf
# (write mask L2+L3) and a GPU-side master re-locks it to 0xfffffb8f a few
# seconds later.  A stock boot opens the device after the lock; this harness
# opens it immediately after the bind, boots the GSP-RM inside the window, and
# issues the SS0/SS1 override while L2 writes are still admitted.
#
#   sudo ./plm_window_race.sh measure [BDF]   # read-only window timeline
#   sudo ./plm_window_race.sh benign  [BDF]   # write SS0^1 / SS1^1, restore
#   sudo ./plm_window_race.sh payload [BDF]   # write 0x88888888 / 0x8, keep
#
# Default BDF 0000:41:00.0 (RM deviceId 1).  For c1:00.0 pass the BDF.
# Only the PCI unbind/FLR/bind is mutating; the nvidia module stays loaded and
# the stock driver serves the bind.  A wedged FLR needs a reboot.
set -u

BDF="${2:-${BDF:?set BDF to your GPU PCI address (for example 0000:41:00.0)}}"
MODE="${1:-measure}"
REGOPS="${REGOPS:-$TOOL_DIR/../register-access/regops}"
OUTROOT="${OUTROOT:-$TOOL_DIR/runs}"
RP="/sys/bus/pci/devices/$BDF"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$OUTROOT/plmrace_${STAMP}_${MODE}"
mkdir -p "$OUT"

case "$BDF" in
  *:c1:00.0) GPU=0 ;;
  *:41:00.0) GPU=1 ;;
  *) GPU="${GPU:-1}"; echo "WARN: unknown BDF, using deviceId $GPU (override with GPU=)" >&2 ;;
esac

say() { echo "$@" | tee -a "$OUT/run.log"; }
die() { say "FATAL: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (BAR0 mmap + RM regops)"
[ -e "$RP/resource0" ] || die "no device $BDF"
[ -x "$REGOPS" ] || die "missing $REGOPS"

# The FLR needs the function idle.  Stop the keepers and warn about open fds.
hold=""
for f in /proc/[0-9]*/fd/*; do
    l=$(readlink "$f" 2>/dev/null) || continue
    case "$l" in /dev/nvidia*) hold="$hold ${f#/proc/}";; esac
done
[ -n "$hold" ] && say "WARN: open /dev/nvidia* fds:$hold (unbind may hang; stop CUDA jobs)"
pkill -9 -x nvidia-smi 2>/dev/null || true
systemctl stop nvidia-persistenced 2>/dev/null || true

restore_bind() {
    if [ ! -L "$RP/driver" ]; then
        say "== restoring bind"
        timeout 120 sh -c "echo '$BDF' > /sys/bus/pci/drivers/nvidia/bind" || \
            say "WARN: bind failed; reboot is the reliable recovery"
    fi
    systemctl start nvidia-persistenced 2>/dev/null || true
}
trap restore_bind EXIT

DRV=$(basename "$(readlink -f "$RP/driver" 2>/dev/null)" 2>/dev/null || echo nvidia)
say "== $MODE on $BDF (deviceId $GPU), driver $DRV, reset_method=$(cat "$RP/reset_method" 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------------
# Baseline SS values (they survive an FLR; only cold power cycles move them).
# ---------------------------------------------------------------------------
"$REGOPS" "$GPU" "$BDF" bar 82381c 2 | tee -a "$OUT/baseline.txt"
SS0=$(awk '/0x0082381c/{print $4}' "$OUT/baseline.txt" | tail -1)
SS1=$(awk '/0x00823820/{print $4}' "$OUT/baseline.txt" | tail -1)
SS0=${SS0:-0x21240001}
SS1=${SS1:-0x00000002}
say "== baseline SS0=$SS0 SS1=$SS1"

# ---------------------------------------------------------------------------
# The poller starts after the FLR and *before* the bind: the bind probe itself
# consumes part of the window, so a poller started after it can miss the whole
# thing.  plmpoll re-maps BAR0 on every sample, so it survives the bind.
# ---------------------------------------------------------------------------
say "== unbind"
echo "BF16: PLMRACE unbind $BDF" > /dev/kmsg 2>/dev/null || true
timeout 60 sh -c "echo '$BDF' > /sys/bus/pci/drivers/$DRV/unbind" || say "WARN: unbind rc=$?"

say "== FLR"
echo "BF16: PLMRACE reset $BDF" > /dev/kmsg 2>/dev/null || true
timeout 120 sh -c "echo 1 > '$RP/reset'" || say "WARN: reset rc=$?"
# Start the poller and the bind immediately: every millisecond of the ~1.16 s
# window that the probe does not consume is margin for the GSP boot.
sleep 0.02

# Fresh mapping after the FLR, while the function is unbound.
"$REGOPS" 0 "$BDF" plmpoll 5 6000 > "$OUT/poll.txt" 2>"$OUT/poll.err" &
POLL_PID=$!
FLR_WALL_MS=$(date +%s%3N)

say "== bind (first open below triggers RmInitAdapter inside the window)"
echo "BF16: PLMRACE bind $BDF" > /dev/kmsg 2>/dev/null || true
timeout 120 sh -c "echo '$BDF' > /sys/bus/pci/drivers/$DRV/bind" || say "WARN: bind rc=$?"

# Wait for the driver to exist, then race the open immediately.
for _ in $(seq 1 200); do [ -L "$RP/driver" ] && break; sleep 0.01; done
[ -L "$RP/driver" ] || die "device did not rebind"

BIND_WALL_MS=$(date +%s%3N)
case "$MODE" in
  benign)
    # Flip one non-enable bit in each word: proves admission without changing rate.
    NEW0=$(printf '0x%08x' $(( SS0 ^ 1 )))
    NEW1=$(printf '0x%08x' $(( SS1 ^ 1 )))
    "$REGOPS" "$GPU" "$BDF" race "$NEW0" "$SS0" "$NEW1" "$SS1" 2>&1 | tee "$OUT/race.txt"
    ;;
  payload)
    # Ada payload, kept: orig == new so the trailing "restore" is a no-op.
    "$REGOPS" "$GPU" "$BDF" race 88888888 88888888 8 8 2>&1 | tee "$OUT/race.txt"
    ;;
  measure)
    say "== measure only; no register write"
    timeout -s KILL 12 nvidia-smi -L 2>&1 | tee -a "$OUT/run.log" || true
    ;;
esac

WRITE_WALL_NS=$(awk '/RACE post wall_ns=/{sub("wall_ns=","",$3); print $3}' "$OUT/race.txt" 2>/dev/null | tail -1)
sleep 2

# Post-write state (direct BAR0).
"$REGOPS" "$GPU" "$BDF" bar 823804 1 2>&1 | tee -a "$OUT/post.txt"
"$REGOPS" "$GPU" "$BDF" bar 82381c 2 2>&1 | tee -a "$OUT/post.txt"
"$REGOPS" "$GPU" "$BDF" rate 2>&1 | tee -a "$OUT/post.txt" || true

kill "$POLL_PID" 2>/dev/null || true
wait "$POLL_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Timeline: first 0x80842bcf after the FLR, first 0xfffffb8f after that, and
# the PLM sample nearest the write.
# ---------------------------------------------------------------------------
python3 -I - "$OUT/poll.txt" "${WRITE_WALL_NS:-0}" "$OUT/summary.txt" <<'PY'
import sys
path, write_ns, outpath = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
rows = []
for line in open(path, errors="replace"):
    if line.startswith("#") or not line.strip():
        continue
    f = line.split()
    if len(f) < 7:
        continue
    t_ms, wall_ms = int(f[0]), int(f[1])
    plm, ss0, ss1 = (int(x, 16) for x in f[2:5])
    eng, rplm, pc = (int(x, 16) for x in f[7:10]) if len(f) >= 10 else (0, 0, 0)
    rows.append((t_ms, wall_ms, plm, ss0, ss1, eng, rplm, pc))

out = []
open_idx = None
for i, r in enumerate(rows):
    if r[2] == 0x80842BCF:
        open_idx = i
        open_ms = r[0]
        break
relock_idx = None
if open_idx is not None:
    for i in range(open_idx, len(rows)):
        if rows[i][2] == 0xFFFFFB8F:
            relock_idx = i
            break

if not rows:
    text = "NO SAMPLES: poller failed (check poll.err / permissions)"
    print(text)
    open(outpath, "w").write(text + "\n")
    sys.exit(0)

write_wall_ms = write_ns // 1_000_000
near = None
if write_wall_ms > 0:
    near = min(rows, key=lambda r: abs(r[1] - write_wall_ms))

out.append(f"samples={len(rows)} first={rows[0][2]:#010x} last={rows[-1][2]:#010x}")
boot_idx = next((i for i, r in enumerate(rows)
                 if (r[7] & 0xFFF00000) == 0xEFD00000), None)
rm_idx = next((i for i, r in enumerate(rows)
               if (r[7] & 0xFF000000) == 0x93000000), None)
if boot_idx is not None:
    out.append(f"boot image first PC ({rows[boot_idx][7]:#010x}) at t={rows[boot_idx][0]} ms")
else:
    out.append("boot image PC (0xefd0xxxx) never seen")
if rm_idx is not None:
    out.append(f"GSP-RM first PC ({rows[rm_idx][7]:#010x}) at t={rows[rm_idx][0]} ms")
else:
    out.append("GSP-RM PC (0x93xxxxxx) never seen")
if open_idx is None:
    out.append("NO 0x80842bcf sample: the window was missed or the poller started late")
else:
    out.append(f"window opens at t={rows[open_idx][0]} ms (plm=0x80842bcf)")
    if relock_idx is None:
        out.append("no re-lock seen within the poll window")
    else:
        out.append(f"re-lock at t={rows[relock_idx][0]} ms "
                   f"(+{rows[relock_idx][0]-rows[open_idx][0]} ms after open)")
        if rm_idx is None:
            out.append("MECHANISM: no GSP-RM PC sampled; cannot classify")
        elif relock_idx > rm_idx:
            out.append("MECHANISM: re-lock AFTER GSP-RM is up -> the race can win")
        elif boot_idx is not None and relock_idx >= boot_idx:
            out.append("MECHANISM: re-lock during the boot-image phase "
                       "(FMC/early boot code)")
        else:
            gap = rows[rm_idx][0] - rows[relock_idx][0]
            out.append(f"MECHANISM: re-lock {gap} ms before the first GSP-RM PC; "
                       "boot image PC not sampled -> independent timer or "
                       "pre-boot devinit (FSP/PMU)")
if near is not None:
    out.append(f"nearest write sample: t={near[0]} ms plm={near[2]:#010x} "
               f"ss0={near[3]:#010x} ss1={near[4]:#010x} "
               f"delta={near[1]-write_wall_ms:+d} ms")
    out.append("WRITE INSIDE WINDOW" if near[2] == 0x80842BCF else
               "write landed after the PLM re-lock (expect a silent drop)")
text = "\n".join(out)
print(text)
open(outpath, "w").write(text + "\n")
PY

# ---------------------------------------------------------------------------
# Restore the override if a payload was applied.
# ---------------------------------------------------------------------------
CUR0=$("$REGOPS" "$GPU" "$BDF" bar 82381c 1 2>/dev/null | awk '/0x0082381c/{print $4}' | tail -1)
CUR1=$("$REGOPS" "$GPU" "$BDF" bar 823820 1 2>/dev/null | awk '/0x00823820/{print $4}' | tail -1)
if [ "$MODE" = "payload" ] && [ "${CUR0:-}" != "$SS0" ]; then
    say "== override took; leaving it for measurement.  To restore:"
    say "   $REGOPS $GPU $BDF wrr 82381c $SS0 $SS0"
    say "   $REGOPS $GPU $BDF wrr 823820 $SS1 $SS1"
fi
say "== done: $OUT"
say "== summary:"; cat "$OUT/summary.txt" | tee -a "$OUT/run.log"
