#!/usr/bin/env bash
set -euo pipefail

LABEL="com.user.tmux-resurrect-save"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PLIST="$REPO_DIR/${LABEL}.plist"
SRC_SAVE_BIN="$REPO_DIR/bin/tmux-resurrect-save"
SRC_PRECHECK="$REPO_DIR/bin/tmux-resurrect-precheck"
SRC_RESTORE="$REPO_DIR/restore.sh"
DEST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DEST_BIN_DIR="$HOME/.local/bin"
DEST_SAVE_BIN="$DEST_BIN_DIR/tmux-resurrect-save"
LEGACY_TICK="$DEST_BIN_DIR/tmux-resurrect-tick"
DEST_PRECHECK="$DEST_BIN_DIR/tmux-resurrect-precheck"
DEST_RESTORE="$DEST_BIN_DIR/tmux-resurrect-restore"
LOG_FILE="$HOME/Library/Logs/tmux-resurrect-save.log"
RESURRECT_SAVE="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"

PRECHECK_MODE="prompt"  # prompt|enable|disable
for arg in "$@"; do
    case "$arg" in
        --precheck) PRECHECK_MODE=enable ;;
        --no-precheck) PRECHECK_MODE=disable ;;
        -h|--help)
            cat <<EOF
install.sh — install tmux-resurrect-launchd

Options:
  --precheck       enable shell-rc nudge non-interactively
  --no-precheck    skip rc wiring non-interactively
  (default)        prompt if interactive, skip otherwise
EOF
            exit 0
            ;;
    esac
done

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

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$DEST_BIN_DIR"

# Always unload by file if present, *and* by label regardless, so a prior
# partial install (loaded but plist deleted) gets cleaned up.
launchctl unload -w "$DEST_PLIST" 2>/dev/null || true
launchctl remove "$LABEL" 2>/dev/null || true

echo "installing $DEST_SAVE_BIN"
sed -e "s|__HOME__|$HOME|g" -e "s|__TMUX_DIR__|$TMUX_DIR|g" "$SRC_SAVE_BIN" > "$DEST_SAVE_BIN"
chmod 755 "$DEST_SAVE_BIN"

# Legacy: prior versions installed the same script as `tmux-resurrect-tick`.
# Remove the dead binary so users upgrading don't have an orphan in PATH.
if [ -f "$LEGACY_TICK" ]; then
    echo "removing legacy $LEGACY_TICK"
    rm -f "$LEGACY_TICK"
fi

echo "installing $DEST_PRECHECK"
install -m 755 "$SRC_PRECHECK" "$DEST_PRECHECK"

echo "installing $DEST_RESTORE"
install -m 755 "$SRC_RESTORE" "$DEST_RESTORE"

echo "installing $DEST_PLIST (tmux=$TMUX_BIN)"
sed -e "s|__BIN__|$DEST_BIN_DIR|g" -e "s|__HOME__|$HOME|g" "$SRC_PLIST" > "$DEST_PLIST"
chmod 644 "$DEST_PLIST"

echo "loading job"
launchctl load -w "$DEST_PLIST"

# --- shell rc wiring -------------------------------------------------------

wire_rc() {
    rc="$1"
    [ -n "$rc" ] || return 0
    [ -f "$rc" ] || touch "$rc"
    if grep -q '>>> tmux-resurrect-launchd >>>' "$rc"; then
        echo "rc already wired: $rc"
        return 0
    fi
    {
        echo ''
        echo '# >>> tmux-resurrect-launchd >>>'
        echo '[ -x "$HOME/.local/bin/tmux-resurrect-precheck" ] && "$HOME/.local/bin/tmux-resurrect-precheck"'
        echo '# <<< tmux-resurrect-launchd <<<'
    } >> "$rc"
    echo "wired precheck into $rc"
}

unwire_rc() {
    rc="$1"
    [ -f "$rc" ] || return 0
    grep -q '>>> tmux-resurrect-launchd >>>' "$rc" || return 0
    # Strip the managed block in-place (BSD sed compatible).
    tmp=$(mktemp)
    awk '
        /^# >>> tmux-resurrect-launchd >>>$/ {skip=1; next}
        /^# <<< tmux-resurrect-launchd <<<$/ {skip=0; next}
        !skip
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
    echo "removed precheck from $rc"
}

case "$PRECHECK_MODE" in
    prompt)
        if [ -t 0 ] && [ -t 1 ]; then
            echo
            echo "Optional: add a one-line nudge to your shell rc that fires on new shells when"
            echo "saved tmux sessions aren't currently running. (Silence with TMUX_RESURRECT_QUIET=1.)"
            printf 'Wire precheck into your shell rc? [Y/n] '
            read -r ans
            case "$ans" in
                n|N|no|NO) PRECHECK_MODE=disable ;;
                *) PRECHECK_MODE=enable ;;
            esac
        else
            echo
            echo "non-interactive install — skipping rc wiring."
            echo "to enable later: re-run with --precheck, or add this line to ~/.zshrc:"
            echo '  [ -x "$HOME/.local/bin/tmux-resurrect-precheck" ] && "$HOME/.local/bin/tmux-resurrect-precheck"'
            PRECHECK_MODE=disable
        fi
        ;;
esac

if [ "$PRECHECK_MODE" = "enable" ]; then
    case "${SHELL:-}" in
        */zsh)  wire_rc "$HOME/.zshrc" ;;
        */bash) wire_rc "$HOME/.bashrc"; wire_rc "$HOME/.bash_profile" ;;
        *)      wire_rc "$HOME/.zshrc" ;;
    esac
fi

echo
echo "installed. RunAtLoad fired the first save — last log lines:"
# Give launchd a beat to write the line, then show the freshest lines so
# the user sees real proof of life before leaving the install.
sleep 1
if [ -f "$LOG_FILE" ]; then
    sed 's/^/  /' "$LOG_FILE" | tail -n 5
else
    echo "  (no log yet at $LOG_FILE — check 'launchctl list | grep tmux-resurrect-save')"
fi
echo
echo "verify later with: tail $LOG_FILE   |   tmux-resurrect-restore --list"
echo "manual recovery:   tmux-resurrect-restore"
