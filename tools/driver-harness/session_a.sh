#!/bin/bash
# session_a.sh — Session A: C17 + C12 (register pass) and C05 + C06 (FLR pass).
#
# Run manually as root.  Two subcommands:
#
#   sudo ./session_a.sh regs    # C17 and C12; no FLR, no reboot expected
#   sudo ./session_a.sh c12h    # clean host-only C12 command test
#   sudo ./session_a.sh flr     # C05 and C06; unbind + PCI FLR + bind
#
# Target defaults to 0000:41:00.0 (RM deviceId 1, nvidia-smi index 0).
# Override with BDF=..., GPU=..., NVSMI_INDEX=....
#
# regs: C17 writes SS0/SS1 from PL2 and restores them.  C12 injects FECS
#       command 0x21 with a few feature masks from PL2 and reads the FEAT bank
#       after each.  Set RATE=0 to skip the issue-rate probe.
#
# flr:  read-only BAR0 poller across an FLR: FEAT PLM, SS0/SS1, the fuse
#       security words, the FSP core block, and the GSP core state.  The stock
#       driver stays loaded.  A wedged FLR needs a reboot.
#
# Logs go to $DIR/runs/session_a_<mode>_<timestamp>/.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REGOPS="${REGOPS:-$DIR/../register-access/regops}"
POLLER="${POLLER:-$DIR/runs/session_a_poll}"
BDF="${BDF:-0000:41:00.0}"
RATE="${RATE:-1}"
MASKS="${MASKS:-3fffffff 3ffffffe 3ffffffd 2fffffff}"

case "$BDF" in
  *:c1:00.0) GPU="${GPU:-0}"; NVSMI_INDEX="${NVSMI_INDEX:-1}" ;;
  *)         GPU="${GPU:-1}"; NVSMI_INDEX="${NVSMI_INDEX:-0}" ;;
esac

MODE="${1:-}"
case "$MODE" in
  regs|flr|c12h|c12i) ;;
  *) echo "usage: sudo $0 regs|flr|c12h|c12i" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0 $MODE)" >&2; exit 1; }
[ -x "$REGOPS" ] || { echo "missing $REGOPS (build it: gcc -O2 -o regops regops.c)" >&2; exit 1; }

OUT="$DIR/runs/session_a_${MODE}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
say() { echo "$@" | tee -a "$OUT/run.log"; }

bar_val() {
  "$REGOPS" "$GPU" "$BDF" bar "$1" 1 2>/dev/null |
    awk -F'= ' '/BAR0/ {v=$2} END {print v}'
}

bank() {
  local tag="$1"
  {
    echo "== bank $tag"
    "$REGOPS" "$GPU" "$BDF" bar 823804 1
    "$REGOPS" "$GPU" "$BDF" bar 82381c 2
    "$REGOPS" "$GPU" "$BDF" bar 823818 1
  } 2>&1 | tee -a "$OUT/run.log"
}

probe_rate() {
  local tag="$1"
  [ "$RATE" = 0 ] && { say "== probe $tag skipped (RATE=0)"; return; }
  local cubin="$DIR/../issue-rate-probe/tensor_modes_issue_sm120.cubin"
  [ -f "$cubin" ] || { say "== probe $tag skipped (no cubin)"; return; }
  local hash uuid power
  hash=$(sha256sum "$cubin" | awk '{print $1}')
  uuid=$(nvidia-smi --query-gpu=uuid --format=csv,noheader --id="$NVSMI_INDEX" | tr -d ' ')
  power=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits --id="$NVSMI_INDEX" | tr -d ' ')
  say "== probe $tag: uuid=$uuid power=$power"
  CUDA_VISIBLE_DEVICES="$uuid" python3 \
    "$DIR/../issue-rate-probe/tensor_modes_driver_runner.py" \
    "$cubin" --sha256 "$hash" --expect-uuid "$uuid" \
    --expect-power-limit "$power" --iters 20000 --reps 3 \
    > "$OUT/probe_$tag.json" 2> "$OUT/probe_$tag.err"
  local rc=$?
  say "== probe $tag rc=$rc"
  if [ "$rc" -eq 0 ]; then
    python3 - "$OUT/probe_$tag.json" <<'PY' | tee -a "$OUT/run.log"
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
for name, m in r.get("modes", {}).items():
    print(f"   {name:8s} {m.get('best_Top_per_s', 0):.2f} Top/s")
PY
  fi
}

do_regs() {
  say "== Session A regs on $BDF (GPU=$GPU, nvidia-smi index=$NVSMI_INDEX)"
  say "== baseline"
  bank baseline
  local base_door base_data
  base_door=$(bar_val 409800); base_door=${base_door#0x}; base_door=${base_door:-1}
  base_data=$(bar_val 409500); base_data=${base_data#0x}; base_data=${base_data:-0}
  say "   FECS baseline: 0x409800=$base_door 0x409500=$base_data"
  "$REGOPS" "$GPU" "$BDF" bar 409500 1 2>&1 | tee -a "$OUT/run.log"
  "$REGOPS" "$GPU" "$BDF" bar 409504 1 2>&1 | tee -a "$OUT/run.log"
  "$REGOPS" "$GPU" "$BDF" bar 409800 1 2>&1 | tee -a "$OUT/run.log"
  probe_rate pre

  # ---------------------------------------------------------------- C17
  say "== C17: exact Ada payload from PL2"
  local ss0 ss1
  ss0=$(bar_val 82381c)
  ss1=$(bar_val 823820)
  say "   stock SS0=$ss0 SS1=$ss1"
  if [ -z "$ss0" ] || [ -z "$ss1" ]; then
    say "   FATAL: could not read SS0/SS1; is $BDF bound and idle?"
    return 1
  fi
  "$REGOPS" "$GPU" "$BDF" wrr 82381c 88888888 "${ss0#0x}" 2>&1 | tee -a "$OUT/c17.txt"
  "$REGOPS" "$GPU" "$BDF" wrr 823820 8 "${ss1#0x}" 2>&1 | tee -a "$OUT/c17.txt"
  bank c17
  probe_rate c17

  # ---------------------------------------------------------------- C12
  say "== C12: FECS command-ID injection from PL2 (id 0x21)"
  say "   note: 0x409504 is read-blocked; the readback is a sentinel, not a restore value"
  say "   note: 0x30 (GR init) is deliberately not replayed post-boot"
  local base_plm base_ss0 base_ss1
  base_plm=$(bar_val 823804)
  base_ss0=$(bar_val 82381c)
  base_ss1=$(bar_val 823820)
  say "   C12 baseline: plm=$base_plm ss0=$base_ss0 ss1=$base_ss1"
  for mask in $MASKS; do
    say "== C12 mask $mask"
    "$REGOPS" "$GPU" "$BDF" wr 409500 "$mask" 2>&1 | tee -a "$OUT/c12.txt"
    "$REGOPS" "$GPU" "$BDF" wr 409504 21 2>&1 | tee -a "$OUT/c12.txt"
    sleep 1
    "$REGOPS" "$GPU" "$BDF" bar 409800 1 2>&1 | tee -a "$OUT/c12.txt"
    local plm ss0b ss1b
    plm=$(bar_val 823804)
    ss0b=$(bar_val 82381c)
    ss1b=$(bar_val 823820)
    say "   after mask $mask: plm=$plm ss0=$ss0b ss1=$ss1b"
    if [ "$plm" != "$base_plm" ] || \
       [ "$ss0b" != "$base_ss0" ] || [ "$ss1b" != "$base_ss1" ]; then
      say "   *** FEAT bank changed: stop and inspect ***"
      break
    fi
  done

  say "== C12 host BAR0 pass (expected drop: the FECS write mask excludes PL0)"
  local host_door host_data
  host_door="$base_door"
  host_data="$base_data"
  say "   host baseline: 0x409800=$host_door 0x409500=$host_data"
  say "   host write to the fully open 0x409800 doorbell:"
  "$REGOPS" "$GPU" "$BDF" barw 409800 1 "$host_door" 2>&1 | tee -a "$OUT/c12_host.txt"
  for mask in $MASKS; do
    say "== C12 host mask $mask"
    # Leave the mask in the data register for the command-ID write; restore
    # it only after the readback.
    "$REGOPS" "$GPU" "$BDF" barw 409500 "$mask" "$mask" 2>&1 | tee -a "$OUT/c12_host.txt"
    "$REGOPS" "$GPU" "$BDF" barw 409504 21 21 2>&1 | tee -a "$OUT/c12_host.txt"
    sleep 1
    "$REGOPS" "$GPU" "$BDF" bar 409800 1 2>&1 | tee -a "$OUT/c12_host.txt"
    local hplm hss0 hss1
    hplm=$(bar_val 823804)
    hss0=$(bar_val 82381c)
    hss1=$(bar_val 823820)
    say "   after host mask $mask: plm=$hplm ss0=$hss0 ss1=$hss1"
    "$REGOPS" "$GPU" "$BDF" barw 409500 "$host_data" "$host_data" \
      2>&1 | tee -a "$OUT/c12_host.txt"
    if [ "$hplm" != "$base_plm" ] || \
       [ "$hss0" != "$base_ss0" ] || [ "$hss1" != "$base_ss1" ]; then
      say "   *** FEAT bank changed after host write: stop and inspect ***"
      break
    fi
  done

  bank c12
  probe_rate c12
  say "== restoring FECS data/status registers to baseline"
  "$REGOPS" "$GPU" "$BDF" barw 409800 "$base_door" "$base_door" 2>&1 | tee -a "$OUT/c12_restore.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409500 "$base_data" "$base_data" 2>&1 | tee -a "$OUT/c12_restore.txt"
  dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
  grep -iE "NVRM|Xid|FECS|GSP" "$OUT/dmesg.txt" | tail -40 | tee -a "$OUT/run.log" || true
  say "== regs done; artifacts in $OUT"
}

do_c12i() {
  local id="${ID:-21}" data="${DATA:-3fffffff}" poll_ms="${POLL_MS:-200}"
  say "== C12 single host command id=0x$id data=0x$data on $BDF"
  local base_door base_data
  base_door=$(bar_val 409800); base_door=${base_door#0x}; base_door=${base_door:-1}
  base_data=$(bar_val 409500); base_data=${base_data#0x}; base_data=${base_data:-0}
  say "   baseline: 0x409800=$base_door 0x409500=$base_data"
  "$REGOPS" "$GPU" "$BDF" barw 409800 0 0 2>&1 | tee -a "$OUT/c12i.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409500 "$data" "$data" 2>&1 | tee -a "$OUT/c12i.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409504 "$id" "$id" 2>&1 | tee -a "$OUT/c12i.txt"
  say "   status poll:"
  local prev="" v i
  for i in $(seq 1 $((poll_ms / 5))); do
    v=$(bar_val 409800)
    if [ "$v" != "$prev" ]; then
      say "     t=$((i * 5))ms status=$v"
      prev="$v"
    fi
    sleep 0.005
  done
  say "   final status=$v"
  bank "c12i_$id"
  "$REGOPS" "$GPU" "$BDF" barw 409800 "$base_door" "$base_door" 2>&1 | tee -a "$OUT/c12i.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409500 "$base_data" "$base_data" 2>&1 | tee -a "$OUT/c12i.txt"
  dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
  grep -iE "NVRM|Xid|FECS|GSP" "$OUT/dmesg.txt" | tail -40 | tee -a "$OUT/run.log" || true
  say "== c12i done; artifacts in $OUT"
}

do_c12h() {
  say "== C12 host-only command injection on $BDF"
  local base_door base_data
  base_door=$(bar_val 409800); base_door=${base_door#0x}; base_door=${base_door:-1}
  base_data=$(bar_val 409500); base_data=${base_data#0x}; base_data=${base_data:-0}
  say "   baseline: 0x409800=$base_door 0x409500=$base_data"
  say "   clear status, leave the mask in 0x409500, write id 0x21 from BAR0"
  "$REGOPS" "$GPU" "$BDF" barw 409800 0 0 2>&1 | tee -a "$OUT/c12h.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409500 3fffffff 3fffffff 2>&1 | tee -a "$OUT/c12h.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409504 21 21 2>&1 | tee -a "$OUT/c12h.txt"
  sleep 1
  "$REGOPS" "$GPU" "$BDF" bar 409800 1 2>&1 | tee -a "$OUT/c12h.txt"
  local st
  st=$(bar_val 409800)
  say "   0x409800 after host command = $st"
  case "$st" in
    0x00000021|0x21) say "   RESULT: host command path live (0x21 echoed)";;
    *) say "   RESULT: no 0x21 echo; host id write did not trigger or was rejected";;
  esac
  bank c12h
  "$REGOPS" "$GPU" "$BDF" barw 409800 "$base_door" "$base_door" 2>&1 | tee -a "$OUT/c12h.txt"
  "$REGOPS" "$GPU" "$BDF" barw 409500 "$base_data" "$base_data" 2>&1 | tee -a "$OUT/c12h.txt"
  dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
  grep -iE "NVRM|Xid|FECS|GSP" "$OUT/dmesg.txt" | tail -40 | tee -a "$OUT/run.log" || true
  say "== c12h done; artifacts in $OUT"
}

do_flr() {
  RP="/sys/bus/pci/devices/$BDF"
  [ -e "$RP/resource0" ] || { say "FATAL: no $BDF"; exit 1; }
  [ -e "$RP/reset" ] || { say "FATAL: no reset file"; exit 1; }

  grep -q flr "$RP/reset_method" 2>/dev/null || \
    say "WARN: reset_method=$(cat "$RP/reset_method" 2>/dev/null)"

  command -v gcc >/dev/null || { say "FATAL: gcc missing"; exit 1; }
  mkdir -p "$DIR/runs"
  gcc -O2 -Wall -o "$POLLER" "$DIR/session_a_poll.c" || { say "FATAL: poller build failed"; exit 1; }

  say "== Session A flr on $BDF (GPU=$GPU, nvidia-smi index=$NVSMI_INDEX)"
  local hold=""
  for f in /proc/[0-9]*/fd/*; do
    local l
    l=$(readlink "$f" 2>/dev/null) || continue
    case "$l" in /dev/nvidia*) hold="$hold ${f#/proc/}";; esac
  done
  [ -n "$hold" ] && say "WARN: open /dev/nvidia* fds:$hold (unbind may hang)"

  pkill -9 -x nvidia-smi 2>/dev/null || true
  systemctl stop nvidia-persistenced 2>/dev/null || true

  DRV=$(basename "$(readlink -f "$RP/driver" 2>/dev/null)" 2>/dev/null || echo nvidia)
  say "== driver $DRV"

  restore_bind() {
    if [ ! -L "$RP/driver" ]; then
      say "== restoring bind"
      timeout 120 sh -c "echo '$BDF' > /sys/bus/pci/drivers/$DRV/bind" || \
        say "WARN: bind failed; reboot is the reliable recovery"
    fi
    systemctl start nvidia-persistenced 2>/dev/null || true
  }
  trap restore_bind EXIT

  say "== pre-FLR sample"
  "$POLLER" "$BDF" 20 50 > "$OUT/pre.csv" 2> "$OUT/pre.err"
  tail -1 "$OUT/pre.csv" | tee -a "$OUT/run.log"

  say "== unbind"
  echo "BF16: SESSION_A unbind $BDF" > /dev/kmsg 2>/dev/null || true
  timeout 60 sh -c "echo '$BDF' > /sys/bus/pci/drivers/$DRV/unbind" || say "WARN: unbind rc=$?"

  say "== FLR"
  echo "BF16: SESSION_A reset $BDF" > /dev/kmsg 2>/dev/null || true
  timeout 120 sh -c "echo 1 > '$RP/reset'" || say "WARN: reset rc=$?"

  # Start the poller before the bind: the re-lock lands ~1.2 s after the FLR.
  "$POLLER" "$BDF" 5 6000 > "$OUT/poll.csv" 2> "$OUT/poll.err" &
  local POLL_PID=$!
  local FLR_WALL_MS
  FLR_WALL_MS=$(date +%s%3N)
  say "== poller $POLL_PID started at $FLR_WALL_MS"

  say "== bind (first open below triggers RmInitAdapter)"
  echo "BF16: SESSION_A bind $BDF" > /dev/kmsg 2>/dev/null || true
  timeout 120 sh -c "echo '$BDF' > /sys/bus/pci/drivers/$DRV/bind" || say "WARN: bind rc=$?"
  for _ in $(seq 1 200); do [ -L "$RP/driver" ] && break; sleep 0.01; done
  if [ -L "$RP/driver" ]; then
    say "== bound; first open"
    timeout -s KILL 15 nvidia-smi -L 2>&1 | tee -a "$OUT/run.log" || true
  else
    say "WARN: device did not rebind"
  fi

  say "== waiting for poller (<= 60 s)"
  for _ in $(seq 1 120); do
    kill -0 "$POLL_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$POLL_PID" 2>/dev/null || true
  wait "$POLL_PID" 2>/dev/null || true
  say "== poller done"

  dmesg -T > "$OUT/dmesg.txt" 2>/dev/null || true
  grep -E "SESSION_A|NVRM|Xid|FSP|GSP" "$OUT/dmesg.txt" | tail -80 | tee -a "$OUT/run.log" || true

  # Print only the rows where a register column (3..NF) changes.
  awk -F, '
    NR==1 { print; next }
    {
      ch = (NR==2)
      if (!ch) for (i=3; i<=NF; i++) if ($i != prev[i]) { ch=1; break }
      if (ch) print
      for (i=1; i<=NF; i++) prev[i]=$i
    }' "$OUT/poll.csv" > "$OUT/changes.csv"
  say "== register transitions:"
  cat "$OUT/changes.csv" | tee -a "$OUT/run.log"

  say "== analysis:"
  python3 "$DIR/session_a_analyze.py" "$OUT" 2>&1 | tee -a "$OUT/run.log" || true

  say "== flr done; artifacts in $OUT"
}

"do_$MODE"
