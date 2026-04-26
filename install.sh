#!/usr/bin/env bash
set -euo pipefail

LABEL="com.user.tmux-resurrect-save"
SRC_PLIST="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/tmux-resurrect-save.log"
RESURRECT_SAVE="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"

if ! command -v tmux >/dev/null 2>&1; then
    echo "error: tmux not found on PATH" >&2
    exit 1
fi

if [ ! -x "$RESURRECT_SAVE" ]; then
    echo "error: tmux-resurrect not found at $RESURRECT_SAVE" >&2
    echo "install via TPM or clone tmux-plugins/tmux-resurrect manually" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

if [ -f "$DEST_PLIST" ]; then
    echo "unloading existing job"
    launchctl unload -w "$DEST_PLIST" 2>/dev/null || true
fi

echo "installing $DEST_PLIST"
sed "s|__HOME__|$HOME|g" "$SRC_PLIST" > "$DEST_PLIST"

echo "loading job"
launchctl load -w "$DEST_PLIST"

echo
echo "installed. verify with:"
echo "  launchctl list | grep tmux-resurrect-save"
echo "  tail $LOG_FILE"
echo "  ls -lt ~/.tmux/resurrect/ | head"
