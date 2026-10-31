#!/bin/bash
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TOOL_DIR/runs"
#
# featbank_writer_probe.sh - read-only FEAT-bank sampler for the "who writes
# SS0 (0x82381c) / 0x823808 before the FMC runs" question.
#
# It reads ONLY a fixed set of documented offsets:
#   0x823800..0x823824   10 dwords, the FEAT bank (see the register map spec)
#   0x000000             PMC_BOOT_0                     (control)
#   0x001fa824/28        WPR2 low/high                  (FLR-effect control)
#   0x008f0320..0x8f0a58 FSP scratch/version/status     (did the FSP re-run?)
#   0x001103c0/3c4       GSP engine / reset PLM         (reset-domain control)
# No GPU register is written. No aperture scan. No BAR1 access.
#
# Subcommands:
#   selftest                  verify the reader works on both cards
#   snapshot                  one sample per card, human + CSV
#   watch [sec] [count]       timecourse; print only rows that change
#   flr [bdf]                 unbind -> FLR -> sample -> rebind timeline
#   boot-install              install early-boot + post-driver systemd samplers
#   boot-collect              summarise the cross-boot CSV
#   boot-status               show unit state + journal
#   boot-uninstall            remove the units (keeps the CSV)
#
# The cold-boot half of the experiment is: boot-install, then power the machine
# fully OFF and ON N times, then boot-collect. The pre unit runs before
# systemd-udev-trigger, i.e. before the nvidia module binds and before the host
# sends the COT, so its sample is a true pre-FMC sample without an instrumented
# driver build. The post unit samples after multi-user with the driver up.
#
# Run as root. The FLR subcommand can wedge the target GPU; expect one reboot
# if the rebind fails. Do not run it while CUDA/ollama/docker jobs hold the card.
#
set -u

VERSION=1
DEF_BDFS="${FEATBANK_BDFS:-0000:41:00.0 0000:c1:00.0}"
TARGET="${FEATBANK_TARGET:-0000:41:00.0}"
LOGDIR="${FEATBANK_LOGDIR:-/var/log/featbank}"
CSV="$LOGDIR/samples.csv"
SELF="$(readlink -f "$0")"
UNITDIR=/etc/systemd/system

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warn:  $*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 $*)"; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------- sampling ---
# Runs inside python3 -I -.  argv[1]=phase argv[2..]=bdf list.
# FEATBANK_CSV / FEATBANK_OUT are appended to (created with a header).
snapshot() {
    local phase="manual" out="" bdfs="$DEF_BDFS" csv="$CSV"
    while [ $# -gt 0 ]; do
        case "$1" in
            --phase) phase="$2"; shift 2 ;;
            --out)   out="$2";   shift 2 ;;
            --bdfs)  bdfs="$2";  shift 2 ;;
            --no-csv) csv="";    shift ;;
            *) die "snapshot: unknown argument $1" ;;
        esac
    done
    mkdir -p "$LOGDIR" 2>/dev/null || true
    FEATBANK_CSV="$csv" FEATBANK_OUT="$out" \
        python3 -I - "$phase" $bdfs <<'PY'
import datetime, mmap, os, struct, sys

phase = sys.argv[1]
bdfs  = sys.argv[2:]
csv_path = os.environ.get("FEATBANK_CSV", "")
out_path = os.environ.get("FEATBANK_OUT", "")

FEAT_OFFS  = [0x823800 + 4 * i for i in range(10)]
FEAT_NAMES = ["823800", "823804", "823808", "82380c", "823810",
              "823814", "823818", "82381c", "823820", "823824"]
CTRL = [
    ("pmc_boot0",   0x000000),
    ("wpr2_lo",     0x1fa824),
    ("wpr2_hi",     0x1fa828),
    ("fsp_scratch", 0x8f0320),
    ("fsp_32c",     0x8f032c),
    ("fsp_ver",     0x8f0330),
    ("fsp_334",     0x8f0334),
    ("fsp_status",  0x8f0a58),
    ("gsp_engine",  0x1103c0),
    ("gsp_rstplm",  0x1103c4),
]
LINK = [
    ("link_speed",     "current_link_speed"),
    ("link_width",     "current_link_width"),
    ("max_link_speed", "max_link_speed"),
    ("max_link_width", "max_link_width"),
    ("boot_vga",       "boot_vga"),
]
HEADER = (["ts", "boot_id", "uptime_s", "phase", "bdf", "driver", "power",
           "method"] + [k for k, _ in LINK] + FEAT_NAMES +
          [k for k, _ in CTRL] + ["err"])

boot_id = "?"
try:
    boot_id = open("/proc/sys/kernel/random/boot_id").read().strip()
except OSError:
    pass
uptime = "?"
try:
    uptime = "%.1f" % float(open("/proc/uptime").read().split()[0])
except (OSError, ValueError):
    pass

def hx(v):
    return "--------" if v is None else "%08x" % (v & 0xffffffff)

def read_dev(bdf):
    base = "/sys/bus/pci/devices/" + bdf
    rp = base + "/resource0"
    info = {"bdf": bdf, "driver": "-", "power": "?", "method": "?",
            "feat": [None] * 10, "ctrl": {k: None for k, _ in CTRL},
            "err": ""}
    for key, name in LINK:
        try:
            info[key] = open(base + "/" + name).read().strip()
        except OSError:
            info[key] = ""
    if not os.path.exists(rp):
        info["err"] = "no resource0"
        return info
    drv = os.path.realpath(base + "/driver")
    if os.path.isdir(drv):
        info["driver"] = os.path.basename(drv)
    try:
        info["power"] = open(base + "/power_state").read().strip()
    except OSError:
        pass
    try:
        fd = os.open(rp, os.O_RDONLY | os.O_SYNC)
    except OSError as e:
        info["err"] = "open: %s" % e
        return info
    try:
        size = os.fstat(fd).st_size or 0x4000000
        try:
            m = mmap.mmap(fd, size, prot=mmap.PROT_READ)
            info["method"] = "mmap"
            def rd(off):
                try:
                    return struct.unpack_from("<I", m, off)[0]
                except Exception:
                    return None
            info["feat"] = [rd(o) for o in FEAT_OFFS]
            info["ctrl"] = {k: rd(o) for k, o in CTRL}
            m.close()
        except (OSError, ValueError) as e:
            info["method"] = "pread"
            def rd(off):
                try:
                    b = os.pread(fd, 4, off)
                    return struct.unpack("<I", b)[0] if len(b) == 4 else None
                except OSError:
                    return None
            info["feat"] = [rd(o) for o in FEAT_OFFS]
            info["ctrl"] = {k: rd(o) for k, o in CTRL}
            info["err"] = "mmap: %s" % e
    finally:
        os.close(fd)
    return info

HEADER_LINE = ",".join(HEADER)

def emit(path, lines):
    if not path:
        return
    try:
        new = not os.path.exists(path) or os.path.getsize(path) == 0
        if not new:
            with open(path) as f:
                first = f.readline().rstrip("\n")
            if first != HEADER_LINE:
                # Schema changed under an existing file: rotate it aside so
                # rows are never silently re-read under the wrong header.
                stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
                oldn = len(first.split(","))
                base = path[:-4] if path.endswith(".csv") else path
                rot = "%s-schema%d-%s.csv" % (base, oldn, stamp)
                os.replace(path, rot)
                print("warn: rotated %s -> %s (schema changed)" %
                      (path, rot), file=sys.stderr)
                new = True
        with open(path, "a") as f:
            if new:
                f.write(HEADER_LINE + "\n")
            for line in lines:
                f.write(line + "\n")
    except OSError as e:
        print("warn: cannot write %s: %s" % (path, e), file=sys.stderr)

rows = []
print("== FEAT bank sample phase=%s boot=%s uptime=%ss" %
      (phase, boot_id[:8], uptime))
for bdf in bdfs:
    info = read_dev(bdf)
    ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    row = ([ts, boot_id, uptime, phase, bdf, info["driver"], info["power"],
            info["method"]] +
           [info[k] for k, _ in LINK] +
           ["" if v is None else "%08x" % v for v in info["feat"]] +
           ["" if info["ctrl"][k] is None else "%08x" % info["ctrl"][k]
            for k, _ in CTRL] +
           [info["err"]])
    rows.append(",".join(row))
    speed = info.get("link_speed", "").split(" ")[0] or "?"
    print("[%s] %s driver=%s power=%s link=%sx%s method=%s%s" %
          (phase, bdf, info["driver"], info["power"], speed,
           info.get("link_width", "?") or "?", info["method"],
           ("  ERR=" + info["err"]) if info["err"] else ""))
    print("  FEAT " + " ".join("%s=%s" % (n, hx(v))
                               for n, v in zip(FEAT_NAMES, info["feat"])))
    print("  SS0=%s SS1=%s 808=%s READOUT_1=%s PLM=%s" %
          (hx(info["feat"][7]), hx(info["feat"][8]), hx(info["feat"][2]),
           hx(info["feat"][6]), hx(info["feat"][1])))
    print("  CTRL " + " ".join("%s=%s" % (k, hx(info["ctrl"][k]))
                               for k, _ in CTRL))
emit(csv_path, rows)
emit(out_path, rows)
PY
}

# --------------------------------------------------------------- selftest ---
cmd_selftest() {
    need_root selftest
    echo "== featbank_writer_probe v$VERSION selftest"
    echo "   reading 0x823800..0x823824 + documented controls, no writes"
    snapshot --phase selftest --bdfs "$DEF_BDFS"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "RESULT: FAIL (sampler returned $rc)"
        return "$rc"
    fi
    echo "RESULT: PASS if both cards show a non-sentinel 0x823804 and 0x823818 above"
}

cmd_snapshot() {
    need_root snapshot
    snapshot "$@"
}

# ---------------------------------------------------------------- timecourse ---
cmd_watch() {
    need_root watch
    local every="${1:-5}" count="${2:-12}" prev=""
    echo "== FEAT watch: every ${every}s, ${count} samples, printing changes only"
    local i
    for i in $(seq 1 "$count"); do
        local cur
        cur=$(snapshot --phase watch --no-csv --bdfs "$DEF_BDFS" 2>/dev/null |
              grep -E '^  FEAT|^  CTRL|^\[')
        if [ "$cur" != "$prev" ]; then
            echo "--- sample $i ($(date +%H:%M:%S))"
            echo "$cur"
            prev="$cur"
        fi
        [ "$i" -lt "$count" ] && sleep "$every"
    done
}

# ---------------------------------------------------------------------- FLR ---
open_gpu_users() {
    local pids=""
    local fd link pid comm
    for fd in /proc/[0-9]*/fd/*; do
        link=$(readlink "$fd" 2>/dev/null) || continue
        case "$link" in
            /dev/nvidia*) pids="$pids ${fd#/proc/}";;
        esac
    done
    [ -n "$pids" ] || return 0
    for pid in $(echo $pids | tr ' ' '\n' | cut -d/ -f1 | sort -u); do
        comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
        echo "  pid $pid ($comm)"
    done
}

compare_run() {
    python3 -I - "$1" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("compare: no rows")
    raise SystemExit
phases = []
for r in rows:
    if r["phase"] not in phases:
        phases.append(r["phase"])
bdfs = []
for r in rows:
    if r["bdf"] not in bdfs:
        bdfs.append(r["bdf"])
cols = [("823808", "808"), ("82381c", "SS0"), ("823820", "SS1"),
        ("823818", "READOUT_1"), ("823804", "PLM"),
        ("pmc_boot0", "PMC_BOOT_0"), ("wpr2_lo", "WPR2lo"),
        ("wpr2_hi", "WPR2hi"), ("fsp_scratch", "FSPscr"),
        ("fsp_status", "FSPstat"), ("gsp_engine", "GSPeng"),
        ("gsp_rstplm", "GSPplm")]
for bdf in bdfs:
    rs = [r for r in rows if r["bdf"] == bdf]
    print("\n== FLR timeline: %s" % bdf)
    print("%-10s  %-10s" % ("field", "") + "".join("%-11s" % p for p in phases))
    for key, label in cols:
        vals = [r.get(key, "") or "--------" for r in rs]
        mark = "  *" if len(set(vals)) > 1 else ""
        print("%-10s  %-10s" % (label, "") + "".join("%-11s" % v for v in vals) + mark)
    print("phases: " + ", ".join(phases))
    print("(* = value changed across the timeline)")
PY
}

cmd_flr() {
    need_root flr
    local bdf="$TARGET" force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            *) bdf="$1"; shift ;;
        esac
    done
    local rp="/sys/bus/pci/devices/$bdf"
    [ -e "$rp/resource0" ] || die "no device $bdf"
    [ -r "$rp/reset" ] || die "$bdf/reset not readable"
    echo "== FLR probe on $bdf"
    echo "   reset_method: $(cat "$rp/reset_method" 2>/dev/null || echo '?')"
    case "$(cat "$rp/reset_method" 2>/dev/null)" in
        *flr*) ;;
        *) warn "reset_method does not list flr; sysfs reset may use bus reset" ;;
    esac

    local users
    users=$(open_gpu_users)
    if [ -n "$users" ]; then
        echo "processes holding /dev/nvidia*:"; echo "$users"
        [ "$force" -eq 1 ] || die "stop them or rerun with --force"
    fi

    local persist=0
    if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
        persist=1
        systemctl stop nvidia-persistenced
    fi

    local was_bound=0
    [ -L "$rp/driver" ] && was_bound=1
    local drv=""
    [ "$was_bound" -eq 1 ] && drv=$(basename "$(readlink -f "$rp/driver")")

    mkdir -p "$LOGDIR"
    local run="$LOGDIR/flr-$(date +%Y%m%d_%H%M%S).csv"
    : > "$run"

    snapshot --phase flr-pre --out "$run" --bdfs "$bdf"

    if [ "$was_bound" -eq 1 ]; then
        echo "== unbinding $bdf from $drv"
        timeout 60 sh -c "echo '$bdf' > /sys/bus/pci/drivers/$drv/unbind"
        echo "   unbind rc=$?"
        [ -L "$rp/driver" ] && warn "device still bound after unbind"
    fi
    snapshot --phase flr-unbound --out "$run" --bdfs "$bdf"

    echo "== triggering FLR (echo 1 > $rp/reset)"
    timeout 120 sh -c "echo 1 > '$rp/reset'"
    echo "   flr rc=$?"
    sleep 1
    snapshot --phase flr-after --out "$run" --bdfs "$bdf"

    if [ "$was_bound" -eq 1 ]; then
        echo "== rebinding $bdf to $drv"
        timeout 120 sh -c "echo '$bdf' > /sys/bus/pci/drivers/$drv/bind"
        echo "   bind rc=$?"
        local i
        for i in $(seq 1 60); do
            [ -L "$rp/driver" ] && break
            sleep 1
        done
        sleep 2
        snapshot --phase flr-bound --out "$run" --bdfs "$bdf"
        echo "== nvidia-smi after rebind (20 s timeout)"
        timeout 20 nvidia-smi -L || warn "nvidia-smi did not list the card"
    fi

    compare_run "$run"
    echo
    echo "== dmesg tail since the FLR step"
    dmesg -T 2>/dev/null | tail -n 40 | grep -iE 'nvidia|NVRM|Xid|fsp|fmc|WPR' || true

    [ "$persist" -eq 1 ] && systemctl start nvidia-persistenced
    echo
    echo "== run file: $run"
    echo "   If the card did not come back: reboot (systemctl reboot -f; cold"
    echo "   power cycle if WPR2 survives). The stock driver is untouched."
}

# ------------------------------------------------------------- boot sampler ---
cmd_boot_install() {
    need_root boot-install
    mkdir -p "$LOGDIR"; chmod 755 "$LOGDIR"
    install -m 0755 "$SELF" /usr/local/sbin/featbank-boot-sample
    cat > "$UNITDIR/featbank-pre.service" <<EOF
[Unit]
Description=FEAT bank pre-driver sample (before udev coldplug)
DefaultDependencies=no
After=systemd-udevd.service
Before=systemd-udev-trigger.service
ConditionPathExists=/sys/bus/pci/devices/$TARGET/resource0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/featbank-boot-sample snapshot --phase pre
TimeoutStartSec=15

[Install]
WantedBy=sysinit.target
EOF
    cat > "$UNITDIR/featbank-post.service" <<'EOF'
[Unit]
Description=FEAT bank post-driver sample
After=nvidia-persistenced.service systemd-udev-trigger.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/featbank-boot-sample snapshot --phase post
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
    cat > "$UNITDIR/featbank-late.service" <<'EOF'
[Unit]
Description=FEAT bank sample 60 s after multi-user (driver fully up)
After=featbank-post.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 60; exec /usr/local/sbin/featbank-boot-sample snapshot --phase late'
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
    cat > "$UNITDIR/featbank-shutdown.service" <<'EOF'
[Unit]
Description=FEAT bank sample at shutdown
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/featbank-boot-sample snapshot --phase shutdown
TimeoutStartSec=10

[Install]
WantedBy=shutdown.target
EOF
    systemctl daemon-reload
    systemctl enable featbank-pre.service featbank-post.service \
        featbank-late.service featbank-shutdown.service
    echo
    echo "== installed. CSV: $CSV"
    echo "   Cold arm : shut down, power OFF, power ON, wait for login"
    echo "   Warm arm : sudo reboot (host POST runs, GPU power is retained)"
    echo "   After each boot, label it: sudo $0 label warm   (or cold)"
    echo "   Then     : sudo $0 boot-collect"
    echo "   A change on the warm arm implicates the host POST/devinit path;"
    echo "   stability on the warm arm points at power-on (FSP or hardware)."
}

cmd_boot_collect() {
    [ -d "$LOGDIR" ] || die "no $LOGDIR (run boot-install and reboot first)"
    python3 -I - "$LOGDIR" <<'PY'
import glob, os, sys
D = sys.argv[1]
OLD = ("ts,boot_id,uptime_s,phase,bdf,driver,power,method,823800,823804,"
       "823808,82380c,823810,823814,823818,82381c,823820,823824,pmc_boot0,"
       "wpr2_lo,wpr2_hi,fsp_scratch,fsp_32c,fsp_ver,fsp_334,fsp_status,"
       "gsp_engine,gsp_rstplm,err").split(",")
NEW = ("ts,boot_id,uptime_s,phase,bdf,driver,power,method,link_speed,"
       "link_width,max_link_speed,max_link_width,boot_vga,"
       "823800,823804,823808,82380c,823810,823814,823818,82381c,823820,"
       "823824,pmc_boot0,wpr2_lo,wpr2_hi,fsp_scratch,fsp_32c,fsp_ver,"
       "fsp_334,fsp_status,gsp_engine,gsp_rstplm,err").split(",")
rows = []
files = sorted(glob.glob(os.path.join(D, "samples*.csv")))
for p in files:
    for line in open(p):
        line = line.rstrip("\n")
        if not line or line.startswith("ts,"):
            continue
        f = line.split(",")
        h = OLD if len(f) == len(OLD) else NEW if len(f) == len(NEW) else None
        if h is None:
            print("warn: %s: skip %d-field row" % (os.path.basename(p), len(f)),
                  file=sys.stderr)
            continue
        r = dict(zip(h, f))
        r["_file"] = os.path.basename(p)
        rows.append(r)
rows.sort(key=lambda r: r.get("ts", ""))
labels = {}
lp = os.path.join(D, "labels.tsv")
if os.path.exists(lp):
    for line in open(lp):
        q = line.rstrip("\n").split("\t")
        if len(q) >= 3:
            labels[q[0]] = q[2]
labels.setdefault("", "")

def cyc(r):
    return labels.get(r.get("boot_id", ""), "") or "-"

def cell(r, k, w=12):
    return (r.get(k, "") or "-")[:w]

print("== cross-boot samples (%d rows from %d file%s)" %
      (len(rows), len(files), "" if len(files) == 1 else "s"))
hdr = ["ts", "boot", "phase", "bdf", "driver", "cycle", "link_speed",
       "link_width", "823808", "82381c", "823820", "823818", "823804"]
for r in rows:
    print("  ".join([r.get("ts", "")[:19], r.get("boot_id", "")[:8],
                     cell(r, "phase"), cell(r, "bdf", 14), cell(r, "driver"),
                     cyc(r), cell(r, "link_speed", 14),
                     cell(r, "link_width", 4), cell(r, "823808"),
                     cell(r, "82381c"), cell(r, "823820"),
                     cell(r, "823818"), cell(r, "823804")]))

bdfs = sorted({r["bdf"] for r in rows})
print("\n== pre rows per card, chronological")
for bdf in bdfs:
    print("  " + bdf)
    pv = [r for r in rows if r["bdf"] == bdf and r["phase"] == "pre"]
    prev = None
    for r in pv:
        mark = ""
        if prev is not None:
            ch = [n for n, k in (("SS0", "82381c"), ("SS1", "823820"),
                                 ("808", "823808"))
                  if prev.get(k) != r.get(k)]
            if ch:
                mark = "  CHANGED " + ",".join(ch)
        print("    %s boot=%s cycle=%-5s link=%-13s 808=%s SS0=%s SS1=%s "
              "READOUT=%s%s" %
              (r.get("ts", "")[:19], r.get("boot_id", "")[:8], cyc(r),
               cell(r, "link_speed", 13), cell(r, "823808"),
               cell(r, "82381c"), cell(r, "823820"), cell(r, "823818"), mark))
        prev = r

print("\n== per-card uniqueness across boots")
for bdf in bdfs:
    for phase in ("pre", "post", "late", "shutdown"):
        rs = [r for r in rows if r["bdf"] == bdf and r["phase"] == phase]
        if not rs:
            continue
        for key, label in (("823808", "0x823808"), ("82381c", "SS0"),
                           ("823820", "SS1"), ("823818", "READOUT_1")):
            vals = sorted({r.get(key, "") for r in rs})
            tag = "CHANGED" if len(vals) > 1 else "stable "
            print("  %s %-8s %-10s %s  %s" %
                  (bdf, phase, label, tag, " ".join(v or "-" for v in vals)))

print("\n== within-boot stability (any phase differs)")
for boot in sorted({r["boot_id"] for r in rows}):
    for bdf in bdfs:
        xs = [r for r in rows if r["boot_id"] == boot and r["bdf"] == bdf]
        if len(xs) < 2:
            continue
        for key, label in (("82381c", "SS0"), ("823820", "SS1"),
                           ("823808", "808"), ("823804", "PLM")):
            vals = {r["phase"]: r.get(key, "") for r in xs}
            if len(set(vals.values())) > 1:
                print("  CHANGED %s %s %-3s %s" %
                      (boot[:8], bdf, label,
                       " ".join("%s=%s" % (p, v or "-")
                                for p, v in vals.items())))
PY
    echo
    echo "== how to read it"
    echo "   pre != late/shutdown within a boot -> runtime writer (unexpected)"
    echo "   pre varies across cold boots       -> power-on source with per-boot state"
    echo "   pre varies across warm reboots     -> host POST/devinit path is implicated"
    echo "   pre stable across warm reboots     -> FSP-at-power-on or hardware latch"
    echo "   late/shutdown != next pre          -> change at power-off or power-on"
    echo "   driver=nvidia in a pre row         -> the unit lost the race; row is post-FMC"
}

cmd_label() {
    need_root label
    local text="${1:-}" boot="${2:-}"
    [ -n "$text" ] || die "usage: $0 label <warm|cold|...> [boot_id]"
    [ -n "$boot" ] || boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ -n "$boot" ] || die "cannot read current boot_id"
    mkdir -p "$LOGDIR"
    printf '%s\t%s\t%s\n' "$boot" "$(date -Is)" "$text" >> "$LOGDIR/labels.tsv"
    echo "labelled boot ${boot:0:8} as '$text'"
}

cmd_boot_status() {
    need_root boot-status
    systemctl status featbank-pre.service featbank-post.service \
        featbank-late.service featbank-shutdown.service --no-pager -l 2>&1 | head -50
    echo "== journal"
    journalctl -u featbank-pre.service -u featbank-post.service \
        -u featbank-late.service -u featbank-shutdown.service \
        --no-pager -o short-iso 2>/dev/null | tail -40
}

cmd_boot_uninstall() {
    need_root boot-uninstall
    systemctl disable featbank-pre.service featbank-post.service \
        featbank-late.service featbank-shutdown.service 2>/dev/null || true
    rm -f "$UNITDIR/featbank-pre.service" "$UNITDIR/featbank-post.service" \
          "$UNITDIR/featbank-late.service" "$UNITDIR/featbank-shutdown.service" \
          /usr/local/sbin/featbank-boot-sample
    systemctl daemon-reload
    echo "== units removed; CSV kept at $CSV"
}

case "${1:-help}" in
    selftest)      shift; cmd_selftest "$@" ;;
    snapshot)      shift; cmd_snapshot "$@" ;;
    watch)         shift; cmd_watch "$@" ;;
    flr)           shift; cmd_flr "$@" ;;
    boot-install)  shift; cmd_boot_install "$@" ;;
    boot-collect)  shift; cmd_boot_collect "$@" ;;
    label)         shift; cmd_label "$@" ;;
    boot-status)   shift; cmd_boot_status "$@" ;;
    boot-uninstall) shift; cmd_boot_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $1" >&2; usage ;;
esac
