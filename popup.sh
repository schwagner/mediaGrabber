#!/usr/bin/env bash
# ============================================================
# popup.sh — a desktop notification for one rip's outcome
#
# Usage: mediagrab-popup <ok|fail|note> <message>
#
# Critical urgency with no expiry (-t 0), the same treatment as an incoming
# call: it stays on screen until it is dismissed. Sent to the session bus of
# whoever runs it (the service's `user`), so it shows on that user's desktop
# and is skipped quietly when they are not logged in.
# ============================================================
set -u

level=${1:?usage: mediagrab-popup <ok|fail|note> <message>}
body=${2:-}
case $level in
  ok)   title="Disc ripped"          icon=media-optical ;;
  fail) title="Disc rip FAILED"      icon=dialog-error ;;
  *)    title="Disc needs attention" icon=dialog-warning ;;
esac

bus=/run/user/$(id -u)/bus
[[ -S $bus ]] || exit 0

# The body may carry markup; dvdrip's messages contain "<season>".
body=${body//&/&amp;} body=${body//</&lt;} body=${body//>/&gt;}

DBUS_SESSION_BUS_ADDRESS=unix:path=$bus \
  notify-send -u critical -t 0 -a mediagrab -i "$icon" "$title" "$body" || true
