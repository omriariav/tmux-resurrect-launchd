#!/usr/bin/env bash
# iTerm2-first tmux launcher.
#
# How iTerm2 native tmux integration (`tmux -CC`) actually behaves:
#   - Run this from a fresh (non-tmux) iTerm2 window.
#   - That window becomes the -CC control channel — you'll see iTerm2's
#     "Command Menu / esc Detach cleanly" prompt. Don't work there;
#     minimize it. Press `esc` to cleanly detach the session.
#   - iTerm2 opens a separate native iTerm2 window for each tmux window
#     in the session. Those are where you actually work.
#   - To run two sessions side-by-side, open a second fresh iTerm2 window
#     (Shell -> New Window, not Cmd-T inside the tmux-attached window)
#     and run --resume there for the other session. You get one control
#     channel per session plus N working windows per session.
#
# Commands:
#   tmux-session [--session <name>] [--resume]              resume (default; creates the session if needed)
#   tmux-session [--session <name>] --create <tab> <dir>    add or select a tab and attach
#   tmux-session [--session <name>] --detach                detach all clients from the session
#   tmux-session [--session <name>] --list                  print tabs in the session
#
# Defaults: session is "main" (override with --session or TMUX_SESSION_NAME).
# Both --resume and --create attach via `tmux -CC attach`.

set -euo pipefail

SESSION_NAME="${TMUX_SESSION_NAME:-main}"

die() {
    printf 'tmux-session: %s\n' "$*" >&2
    exit 1
}

# Refuse to run an attach action from inside an existing tmux client.
# The historical behavior was `tmux switch-client`, which silently
# hijacks the current -CC connection to a different session — surprising
# and the source of "where did my main session go" reports. For adding
# a tab to the session you're already in, `tmux new-window` does the
# right thing without this wrapper.
require_outside_tmux() {
    [ -z "${TMUX:-}" ] || die "already inside tmux. To add a tab to the current session: tmux new-window -n <name> -c <dir>"
}

expand_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

validate_name() {
    label="$1"; name="$2"
    [ -n "$name" ] || die "$label is required"
    case "$name" in
        -*) die "$label cannot start with '-'" ;;
        *:*) die "$label cannot contain ':'" ;;
    esac
}

session_exists() { tmux has-session -t "$SESSION_NAME" 2>/dev/null; }

tab_index_by_name() {
    tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null \
        | awk -F'|' -v want="$1" '$2 == want { print $1; exit }'
}

attach() {
    exec tmux -CC attach-session -t "$SESSION_NAME"
}

cmd_resume() {
    require_outside_tmux
    session_exists || tmux new-session -d -s "$SESSION_NAME" -n shell -c "$HOME"
    attach
}

cmd_create() {
    local name folder existing
    name="$1"
    folder="$(expand_path "$2")"
    validate_name "tab name" "$name"
    [ -d "$folder" ] || die "folder does not exist: $folder"
    require_outside_tmux

    if ! session_exists; then
        # First tab of a brand-new session: new-session names the
        # initial window and roots it at <folder> in one shot.
        tmux new-session -d -s "$SESSION_NAME" -n "$name" -c "$folder"
    else
        existing=$(tab_index_by_name "$name")
        if [ -n "$existing" ]; then
            tmux select-window -t "$SESSION_NAME:$existing"
        else
            tmux new-window -t "$SESSION_NAME:" -n "$name" -c "$folder"
        fi
    fi
    attach
}

cmd_detach() {
    session_exists || die "tmux session '$SESSION_NAME' is not running"
    tmux detach-client -s "$SESSION_NAME" 2>/dev/null || true
    printf 'Detached clients from tmux session %s.\n' "$SESSION_NAME"
}

print_session_windows() {
    tmux list-windows -t "$1" \
        -F '  #{?window_active,* , }#{window_index}: #{window_name}  (#{window_panes}p)  #{pane_current_path}'
}

cmd_ls_one() {
    session_exists || { printf 'tmux session %s is not running.\n' "$SESSION_NAME"; return 0; }
    printf 'session: %s\n' "$SESSION_NAME"
    print_session_windows "$SESSION_NAME"
}

resolve_window() {
    # Resolve a user-supplied window reference (numeric index or current
    # window name) to a tmux target like "main:3". Errors out if not found.
    local ref="$1" idx
    case "$ref" in
        ''|*[!0-9]*)
            idx=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null \
                | awk -F'|' -v want="$ref" '$2 == want { print $1; exit }')
            [ -n "$idx" ] || die "window not found in session '$SESSION_NAME': $ref"
            ;;
        *)
            idx="$ref"
            tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null \
                | grep -qx "$idx" \
                || die "window index $idx not present in session '$SESSION_NAME'"
            ;;
    esac
    printf '%s:%s\n' "$SESSION_NAME" "$idx"
}

cmd_rename() {
    local ref new_name target
    ref="$1"
    new_name="$2"
    validate_name "tab name" "$new_name"
    session_exists || die "tmux session '$SESSION_NAME' is not running"
    target=$(resolve_window "$ref")
    tmux rename-window -t "$target" "$new_name"
    printf 'renamed %s -> %s\n' "$target" "$new_name"
}

cmd_rename_all() {
    # Rename every window in the session to basename(pane_current_path) of
    # its active pane. Useful for tidying up sessions where windows
    # inherited process names like "codex-aarch64-a" or "2.1.131".
    # Windows whose active pane sits in $HOME are skipped (basename
    # would be the username, which is not a useful tab label).
    session_exists || die "tmux session '$SESSION_NAME' is not running"
    local renamed=0 skipped=0
    while IFS='|' read -r idx path; do
        if [ -z "$path" ] || [ "$path" = "$HOME" ]; then
            printf 'skipped %s:%s (path: %s)\n' "$SESSION_NAME" "$idx" "${path:-<empty>}"
            skipped=$((skipped + 1))
            continue
        fi
        new_name=$(basename "$path")
        tmux rename-window -t "$SESSION_NAME:$idx" "$new_name"
        printf 'renamed %s:%s -> %s\n' "$SESSION_NAME" "$idx" "$new_name"
        renamed=$((renamed + 1))
    done < <(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{pane_current_path}')
    printf '\n%d renamed, %d skipped.\n' "$renamed" "$skipped"
}

cmd_ls_all() {
    if ! tmux ls >/dev/null 2>&1; then
        printf 'no tmux server running.\n'
        return 0
    fi
    # Each line: name<TAB>attached_clients
    tmux list-sessions -F '#{session_name}|#{session_attached}' \
        | while IFS='|' read -r name clients; do
            if [ "${clients:-0}" -gt 0 ]; then
                printf 'session: %s (attached, %s client%s)\n' "$name" "$clients" "$([ "$clients" -eq 1 ] || printf s)"
            else
                printf 'session: %s\n' "$name"
            fi
            print_session_windows "$name"
            echo
        done
}

usage() {
    cat <<'EOF'
tmux-session - iTerm2-first launcher for tmux sessions.

Usage:
  tmux-session [--session <name>] [--resume]            resume (default; creates if needed)
  tmux-session [--session <name>] --create <tab> <dir>  add/select a tab and attach
  tmux-session [--session <name>] --detach              detach all clients
  tmux-session ls                                       list all sessions and their tabs
  tmux-session --session <name> --list                  list tabs in one session
  tmux-session [--session <name>] --rename <ref> <new>  rename one window (ref = index or current name)
  tmux-session [--session <name>] --rename-all         rename all windows to basename(folder)

Run from a fresh iTerm2 window — that window becomes the -CC control
channel, and iTerm2 opens a native window per tmux window in the session.
Default session is "main" (override with --session or TMUX_SESSION_NAME).

Examples:
  tmux-session                                          # resume main
  tmux-session ls                                       # all sessions + tabs
  tmux-session --session work --resume                  # resume/create "work" with a default shell tab
  tmux-session --session work --create api ~/Code/api   # create "work" with first tab "api" in ~/Code/api and attach
  tmux-session --session work --create notes ~/notes    # add "notes" tab to existing "work" session
  tmux-session --rename 0 pm-os                         # rename window 0 in main to "pm-os"
  tmux-session --rename-all                             # auto-rename all main windows to their folder basename
EOF
}

ACTION=""
SESSION_EXPLICIT=0
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--session)
            [ $# -ge 2 ] || die "$1 requires <name>"
            SESSION_NAME="$2"
            SESSION_EXPLICIT=1
            shift 2
            ;;
        --session=*)
            SESSION_NAME="${1#--session=}"
            SESSION_EXPLICIT=1
            shift
            ;;
        --resume|--create|--detach|--list|--ls|--rename|--rename-all)
            [ -z "$ACTION" ] || die "specify only one action"
            ACTION="$1"
            shift
            ;;
        -h|--help)
            usage; exit 0
            ;;
        --)
            shift; ARGS+=("$@"); break
            ;;
        -*)
            die "unknown option: $1"
            ;;
        ls)
            # Positional alias for --ls (lists all sessions by default).
            [ -z "$ACTION" ] || die "specify only one action"
            ACTION="--ls"
            shift
            ;;
        *)
            ARGS+=("$1"); shift
            ;;
    esac
done

validate_name "session name" "$SESSION_NAME"

case "$ACTION" in
    ""|--resume)
        [ ${#ARGS[@]} -eq 0 ] || die "--resume takes no positional arguments"
        cmd_resume
        ;;
    --create)
        [ ${#ARGS[@]} -eq 2 ] || die "--create requires <tab-name> <folder>"
        cmd_create "${ARGS[0]}" "${ARGS[1]}"
        ;;
    --detach)
        [ ${#ARGS[@]} -eq 0 ] || die "--detach takes no positional arguments"
        cmd_detach
        ;;
    --list)
        # --list is session-scoped (use --session to pick the session).
        [ ${#ARGS[@]} -eq 0 ] || die "--list takes no positional arguments"
        cmd_ls_one
        ;;
    --rename)
        [ ${#ARGS[@]} -eq 2 ] || die "--rename requires <window-ref> <new-name>"
        cmd_rename "${ARGS[0]}" "${ARGS[1]}"
        ;;
    --rename-all)
        [ ${#ARGS[@]} -eq 0 ] || die "--rename-all takes no positional arguments"
        cmd_rename_all
        ;;
    --ls)
        # `ls` / `--ls`: scoped if --session was explicit, otherwise all sessions.
        [ ${#ARGS[@]} -eq 0 ] || die "ls takes no positional arguments"
        if [ "$SESSION_EXPLICIT" = "1" ]; then
            cmd_ls_one
        else
            cmd_ls_all
        fi
        ;;
esac
