#!/bin/bash
#
# netconsole.sh - mirror this host's kernel console to a UDP collector on the
# local net, so a hung suspend/resume leaves the last printk on the wire.
#
# Usage:
#   sudo ./netconsole.sh start <server-ip> [port]
#   sudo ./netconsole.sh stop
#   sudo ./netconsole.sh status
#
# Env:
#   IFACE  source interface (default: the route to <server-ip>)
#   MAC    override the next-hop MAC if ARP cannot resolve it
#   PORT   collector port (default 6666)
#
# The collector on the server:
#   socat -u UDP-RECVFROM:6666,fork OPEN:/tmp/netconsole.log,creat,append
# or, without socat:
#   python3 -u -c 'import socket
#   s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("0.0.0.0",6666))
#   f=open("/tmp/netconsole.log","ab",0)
#   while True: f.write(s.recvfrom(65535)[0])'
#
# netpoll writes straight to the NIC driver, so this works while the kernel is
# stuck in a device suspend/resume.  The nvidia modules are loaded long after
# the NIC is probed, so the GPU suspends first and the NIC is still up.
set -u

CFS=/sys/kernel/config/netconsole
TARGET="$CFS/t1"
PORT="${PORT:-6666}"

die() { echo "$@" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root"

case "${1:-}" in
start)
    SRV="${2:?usage: sudo $0 start <server-ip> [port]}"
    [ $# -ge 3 ] && PORT="$3"

    IFACE="${IFACE:-$(ip -4 route get "$SRV" 2>/dev/null | \
        sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)}"
    [ -n "$IFACE" ] || die "no route to $SRV"
    LOCAL_IP="$(ip -4 -o addr show dev "$IFACE" | \
        awk '{print $4}' | cut -d/ -f1 | head -1)"
    [ -n "$LOCAL_IP" ] || die "no IPv4 address on $IFACE"

    # The frame needs the next-hop MAC: the server itself on-link, else the
    # gateway the route names.
    HOP="$SRV"
    VIA="$(ip -4 route get "$SRV" | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -1)"
    [ -n "$VIA" ] && HOP="$VIA"
    if [ -z "${MAC:-}" ]; then
        ping -c1 -W1 "$HOP" >/dev/null 2>&1 || true
        # iproute2 omits the "dev" token when the query filters by device, so
        # the MAC is not at a fixed field position.
        MAC=""
        for _ in 1 2 3 4; do
            MAC="$(ip neigh show "$HOP" dev "$IFACE" 2>/dev/null | \
                awk '{for (i=1;i<NF;i++) if ($i=="lladdr") {print $(i+1); exit}}')"
            [ -n "$MAC" ] && break
            sleep 0.5
        done
    fi
    [ -n "${MAC:-}" ] || die "no ARP entry for $HOP; ping it or set MAC=.."

    modprobe netconsole || die "modprobe netconsole failed"
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
    [ -d "$CFS" ] || die "configfs netconsole unavailable (CONFIG_NETCONSOLE_DYNAMIC?)"

    if [ -d "$TARGET" ]; then
        echo 0 > "$TARGET/enabled" 2>/dev/null || true
        rmdir "$TARGET" 2>/dev/null || true
    fi
    mkdir "$TARGET" || die "mkdir $TARGET failed"

    echo "$LOCAL_IP" > "$TARGET/local_ip"   || die "set local_ip"
    echo "$IFACE"    > "$TARGET/dev_name"   || die "set dev_name"
    echo "$SRV"      > "$TARGET/remote_ip"  || die "set remote_ip"
    echo "$PORT"     > "$TARGET/local_port" || die "set local_port"
    echo "$PORT"     > "$TARGET/remote_port"|| die "set remote_port"
    echo "$MAC"      > "$TARGET/remote_mac" || die "set remote_mac"
    echo 1           > "$TARGET/enabled"    || die "enable target"

    # Timestamps make the last line before a freeze easy to place.
    echo 1 > /sys/module/printk/parameters/time 2>/dev/null || \
        echo 1 > /proc/sys/kernel/printk_time 2>/dev/null || true

    # Consoles must survive the suspend and pass level-4 nv_printf lines.
    "$TOOL_DIR/console_debug.sh" on 2>&1 || true

    echo "netconsole: $LOCAL_IP/$IFACE -> $SRV:$PORT via $HOP ($MAC)"
    echo "<0>netconsole test $(hostname) $(date -Is)" > /dev/kmsg
    echo "sent test line; check /tmp/netconsole.log on the server"
    ;;
stop)
    "$TOOL_DIR/console_debug.sh" off 2>&1 || true
    [ -d "$TARGET" ] || { echo "netconsole: no target"; exit 0; }
    echo 0 > "$TARGET/enabled" 2>/dev/null || true
    rmdir "$TARGET" 2>/dev/null || true
    echo "netconsole: stopped"
    ;;
status)
    [ -d "$TARGET" ] || { echo "netconsole: no target"; exit 1; }
    for a in enabled local_ip local_port dev_name remote_ip remote_port remote_mac; do
        printf '%-12s %s\n' "$a" "$(cat "$TARGET/$a" 2>/dev/null)"
    done
    ;;
*)
    echo "usage: sudo $0 start <server-ip> [port] | stop | status" >&2
    exit 2
    ;;
esac
