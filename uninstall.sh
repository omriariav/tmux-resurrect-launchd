#!/usr/bin/env bash
set -euo pipefail

LABEL="com.user.tmux-resurrect-save"
DEST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DEST_BIN_DIR="$HOME/.local/bin"
DEST_TICK="$DEST_BIN_DIR/tmux-resurrect-tick"
DEST_PRECHECK="$DEST_BIN_DIR/tmux-resurrect-precheck"
DEST_RESTORE="$DEST_BIN_DIR/tmux-resurrect-restore"

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

for f in "$DEST_TICK" "$DEST_PRECHECK" "$DEST_RESTORE"; do
    if [ -f "$f" ]; then
        echo "removing $f"
        rm -f "$f"
    fi
done

# Strip the managed precheck block from rc files if present. Refuses to
# touch the file if the start marker is present but the end marker is
# missing — under those conditions the awk filter would delete everything
# below the start marker. Writes via `> "$rc"` (not `mv`), which preserves
# the inode so symlinked dotfiles (e.g. ~/.zshrc → ~/dotfiles/.zshrc) are
# not silently replaced with regular files.
unwire_rc() {
    rc="$1"
    [ -f "$rc" ] || return 0
    grep -q '^# >>> tmux-resurrect-launchd >>>$' "$rc" || return 0
    if ! grep -q '^# <<< tmux-resurrect-launchd <<<$' "$rc"; then
        echo "warning: $rc has start marker but no end marker — refusing to edit. Strip manually." >&2
        return 0
    fi
    tmp=$(mktemp)
    awk '
        /^# >>> tmux-resurrect-launchd >>>$/ {skip=1; next}
        /^# <<< tmux-resurrect-launchd <<<$/ {skip=0; next}
        !skip
    ' "$rc" > "$tmp"
    cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "removed precheck block from $rc"
}
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    unwire_rc "$rc"
done

echo
echo "uninstalled. snapshots in ~/.tmux/resurrect/ left alone."
echo "log file ~/Library/Logs/tmux-resurrect-save.log left alone (rm manually if you want)."
