#!/usr/bin/env bash
set -euo pipefail

LABEL="com.user.tmux-resurrect-save"
SRC_PLIST="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/tmux-resurrect-save.log"
RESURRECT_SAVE="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"

TMUX_BIN="$(command -v tmux || true)"
if [ -z "$TMUX_BIN" ]; then
    echo "error: tmux not found on PATH" >&2
    exit 1
fi
TMUX_DIR="$(dirname "$TMUX_BIN")"

if [ ! -x "$RESURRECT_SAVE" ]; then
    echo "error: tmux-resurrect not found at $RESURRECT_SAVE" >&2
    echo "install via TPM or clone tmux-plugins/tmux-resurrect manually" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Always unload by file if present, *and* by label regardless, so a prior
# partial install (loaded but plist deleted) gets cleaned up.
launchctl unload -w "$DEST_PLIST" 2>/dev/null || true
launchctl remove "$LABEL" 2>/dev/null || true

echo "installing $DEST_PLIST (tmux=$TMUX_BIN)"
sed -e "s|__HOME__|$HOME|g" -e "s|__TMUX_DIR__|$TMUX_DIR|g" "$SRC_PLIST" > "$DEST_PLIST"
chmod 644 "$DEST_PLIST"

echo "loading job"
launchctl load -w "$DEST_PLIST"

echo
echo "installed. verify with:"
echo "  launchctl list | grep tmux-resurrect-save"
echo "  tail $LOG_FILE"
echo "  ls -lt ~/.tmux/resurrect/ | head"
