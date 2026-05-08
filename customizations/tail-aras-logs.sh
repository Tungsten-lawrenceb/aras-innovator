#!/bin/bash
# Quick log-tail helper. Run from the Linux side that has the SMB share mounted at /mnt/aras-share.
# Usage:
#   tail-aras-logs.sh [server|client|oauthserver|ngrok|iis] [N]
# Defaults: oauthserver, last 60 lines of the newest stdout_*.log
set -e
WHICH="${1:-oauthserver}"
N="${2:-60}"
LOGS_BASE=/mnt/aras-share/logs
DIR="$LOGS_BASE/$WHICH"
[ -d "$DIR" ] || { echo "no such log dir: $DIR" >&2; exit 1; }

case "$WHICH" in
    ngrok)
        tail -n "$N" "$DIR/ngrok.log" 2>/dev/null
        ;;
    iis)
        # IIS rotates per day under W3SVC1/
        latest=$(find "$DIR" -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
        [ -n "$latest" ] && tail -n "$N" "$latest"
        ;;
    *)
        # ASP.NET Core stdout_*.log — find newest by mtime
        latest=$(ls -t "$DIR"/stdout_*.log 2>/dev/null | head -1)
        [ -n "$latest" ] && tail -n "$N" "$latest"
        ;;
esac
