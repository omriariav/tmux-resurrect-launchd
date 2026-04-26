#!/usr/bin/env bash
set -euo pipefail

LABEL="com.user.tmux-resurrect-save"
DEST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [ ! -f "$DEST_PLIST" ]; then
    echo "not installed: $DEST_PLIST"
    exit 0
fi

echo "unloading job"
launchctl unload -w "$DEST_PLIST" 2>/dev/null || true

echo "removing $DEST_PLIST"
rm -f "$DEST_PLIST"

echo
echo "uninstalled. snapshots in ~/.tmux/resurrect/ left alone."
echo "log file ~/Library/Logs/tmux-resurrect-save.log left alone (rm manually if you want)."
