#!/usr/bin/env bash
set -euo pipefail

LABEL="com.user.tmux-resurrect-save"
DEST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# Unload by file if present, and by label regardless. This handles the case
# where the plist was deleted manually but the job is still loaded.
if [ -f "$DEST_PLIST" ]; then
    echo "unloading job"
    launchctl unload -w "$DEST_PLIST" 2>/dev/null || true
fi
launchctl remove "$LABEL" 2>/dev/null || true

if [ -f "$DEST_PLIST" ]; then
    echo "removing $DEST_PLIST"
    rm -f "$DEST_PLIST"
fi

echo
echo "uninstalled. snapshots in ~/.tmux/resurrect/ left alone."
echo "log file ~/Library/Logs/tmux-resurrect-save.log left alone (rm manually if you want)."
