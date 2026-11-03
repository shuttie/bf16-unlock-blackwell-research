#!/bin/bash
#
# console_debug.sh - keep kernel console output alive across a suspend and let
# the level-4 nv_printf lines through.
#
# Ubuntu boots with console_loglevel=4, and nv_printf prefixes every message
# with KERN_CONT, which parses as level 4.  printk drops messages with
# level >= console_loglevel, so at stock every BF16/NVRM line is filtered off
# every console.  printk also suspends consoles before the NVIDIA suspend
# callback runs unless console_suspend=N.
#
# Usage:
#   sudo ./console_debug.sh on
#   sudo ./console_debug.sh off
#
# The original values are saved in /run/console_debug.saved and restored by
# off.  on is idempotent: a second call does not overwrite the saved values.
set -u

SAVE=/run/console_debug.saved

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

case "${1:-}" in
on)
    if [ ! -f "$SAVE" ]; then
        {
            cat /proc/sys/kernel/printk
            cat /sys/module/printk/parameters/console_suspend
        } > "$SAVE" 2>/dev/null || true
    fi
    read -r _cl _dl _ml _bl < /proc/sys/kernel/printk || true
    echo "7 ${_dl:-4} ${_ml:-1} ${_bl:-7}" > /proc/sys/kernel/printk 2>/dev/null || true
    echo N > /sys/module/printk/parameters/console_suspend 2>/dev/null || true
    echo "console debug on: printk=$(cat /proc/sys/kernel/printk) console_suspend=$(cat /sys/module/printk/parameters/console_suspend)"
    ;;
off)
    if [ -f "$SAVE" ]; then
        SAVED_PRINTK="$(sed -n 1p "$SAVE")"
        SAVED_SUSPEND="$(sed -n 2p "$SAVE")"
        [ -n "$SAVED_PRINTK" ] && \
            echo "$SAVED_PRINTK" > /proc/sys/kernel/printk 2>/dev/null || true
        [ -n "$SAVED_SUSPEND" ] && \
            echo "$SAVED_SUSPEND" > /sys/module/printk/parameters/console_suspend 2>/dev/null || true
        rm -f "$SAVE"
        echo "console debug off: printk=$(cat /proc/sys/kernel/printk) console_suspend=$(cat /sys/module/printk/parameters/console_suspend)"
    fi
    ;;
*)
    echo "usage: sudo $0 on|off" >&2
    exit 2
    ;;
esac
