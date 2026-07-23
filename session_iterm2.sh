#!/usr/bin/env bash
# tmux session launcher.
#
# Attachments are native tmux by default. This avoids routing terminal input
# and pane output through iTerm2's `tmux -CC` control channel, which can wedge
# under sustained high-output TUI workloads. Use --cc (or TMUX_SESSION_CC=1)
# only when iTerm2's window-per-tmux-window integration is wanted.
#
# Commands:
#   tmux-session [--session <name>] [--resume]              resume (default; creates the session if needed)
#   tmux-session [--session <name>] --attach                attach to an existing session
#   tmux-session [--session <name>] --create <tab> <dir>    add or select a tab and attach
#   tmux-session [--session <name>] --detach                detach all clients from the session
#   tmux-session [--session <name>] --list                  print tabs and panes in the session
#   tmux-session [--session <name>] --delete <ref>          delete a tab/window
#   tmux-session [--session <name>] --delete-pane <ref> <pane-ref>
#   tmux-session --delete-session <name>                    delete a whole session
#
# Defaults: session is "main" (override with --session or TMUX_SESSION_NAME).
# --resume, --attach, and --create attach natively by default. Pass --cc to
# opt into iTerm2 control mode; --plain forces the native default.

set -euo pipefail

SESSION_NAME="${TMUX_SESSION_NAME:-main}"
USE_CC=0
if [ "${TMUX_SESSION_CC:-}" = "1" ]; then
    USE_CC=1
fi

die() {
    printf 'tmux-session: %s\n' "$*" >&2
    exit 1
}

# Refuse to run an attach action from inside an existing tmux client.
# The historical behavior was `tmux switch-client`, which silently
# hijacks the current client connection to a different session — surprising
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

session_exists_named() { tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Fxq "$1"; }

tab_index_by_name() {
    tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null \
        | awk -F'|' -v want="$1" '$2 == want { print $1; exit }'
}

attach() {
    if [ "$USE_CC" = "1" ]; then
        exec tmux -CC attach-session -t "$SESSION_NAME"
    fi
    exec tmux attach-session -t "$SESSION_NAME"
}

cmd_resume() {
    require_outside_tmux
    session_exists || tmux new-session -d -s "$SESSION_NAME" -n shell -c "$HOME"
    attach
}

cmd_attach() {
    require_outside_tmux
    session_exists || die "tmux session '$SESSION_NAME' is not running"
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
    local session="$1" active idx name panes path prefix
    local pane_active pane_idx pane_id pane_cmd pane_path pane_prefix
    tmux list-windows -t "$session" \
        -F '#{window_active}|#{window_index}|#{window_name}|#{window_panes}|#{pane_current_path}' \
        | while IFS='|' read -r active idx name panes path; do
            if [ "$active" = "1" ]; then
                prefix="* "
            else
                prefix="  "
            fi
            printf '  %s%s: %s  (%sp)  %s\n' "$prefix" "$idx" "$name" "$panes" "$path"
            tmux list-panes -t "$session:$idx" \
                -F '#{pane_active}|#{pane_index}|#{pane_id}|#{pane_current_command}|#{pane_current_path}' \
                | while IFS='|' read -r pane_active pane_idx pane_id pane_cmd pane_path; do
                    if [ "$pane_active" = "1" ]; then
                        pane_prefix="* "
                    else
                        pane_prefix="  "
                    fi
                    printf '      %spane %s  %s  %s  %s\n' "$pane_prefix" "$pane_idx" "$pane_id" "$pane_cmd" "$pane_path"
                done
        done
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

resolve_pane() {
    # Resolve a pane reference within a window. Numeric refs are pane
    # indexes; %NN refs are stable tmux pane ids.
    local window_target="$1" ref="$2" target
    case "$ref" in
        %*)
            target=$(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null \
                | awk -v want="$ref" '$0 == want { print; exit }')
            [ -n "$target" ] || die "pane not found in $window_target: $ref"
            ;;
        ''|*[!0-9]*)
            die "pane ref must be a pane index or pane id like %13"
            ;;
        *)
            tmux list-panes -t "$window_target" -F '#{pane_index}' 2>/dev/null \
                | grep -qx "$ref" \
                || die "pane index $ref not present in $window_target"
            target="$window_target.$ref"
            ;;
    esac
    printf '%s\n' "$target"
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

cmd_delete_window() {
    local ref target count
    ref="$1"
    session_exists || die "tmux session '$SESSION_NAME' is not running"
    target=$(resolve_window "$ref")
    count=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' | awk 'END { print NR + 0 }')
    [ "$count" -gt 1 ] || die "refusing to delete the last window in session '$SESSION_NAME'"
    tmux kill-window -t "$target"
    printf 'deleted window %s\n' "$target"
}

cmd_delete_pane() {
    local window_ref pane_ref window_target pane_target count
    window_ref="$1"
    pane_ref="$2"
    session_exists || die "tmux session '$SESSION_NAME' is not running"
    window_target=$(resolve_window "$window_ref")
    pane_target=$(resolve_pane "$window_target" "$pane_ref")
    count=$(tmux list-panes -t "$window_target" -F '#{pane_index}' | awk 'END { print NR + 0 }')
    [ "$count" -gt 1 ] || die "refusing to delete the last pane in $window_target; use --delete-window $window_ref"
    tmux kill-pane -t "$pane_target"
    printf 'deleted pane %s in window %s\n' "$pane_target" "$window_target"
}

cmd_delete_session() {
    local name current
    name="$1"
    validate_name "session name" "$name"
    session_exists_named "$name" || die "tmux session '$name' is not running"
    if [ -n "${TMUX:-}" ]; then
        current=$(tmux display-message -p '#S' 2>/dev/null || true)
        [ "$current" != "$name" ] || die "refusing to delete the current tmux session from inside it"
    fi
    tmux kill-session -t "$name"
    printf 'deleted session %s\n' "$name"
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
tmux-session - launcher for tmux sessions.

Usage:
  tmux-session [--session <name>] [--resume]            resume (default; creates if needed)
  tmux-session [--session <name>] --attach              attach to an existing session
  tmux-session [--session <name>] --create <tab> <dir>  add/select a tab and attach
  tmux-session [--session <name>] --detach              detach all clients
  tmux-session ls                                       list all sessions, tabs, and panes
  tmux-session --session <name> --list                  list tabs and panes in one session
  tmux-session [--session <name>] --delete <ref>        delete one window (ref = index or current name)
  tmux-session [--session <name>] --delete-window <ref> delete one window (ref = index or current name)
  tmux-session [--session <name>] --delete-pane <window-ref> <pane-ref>
                                                          delete one pane (pane-ref = index or %id)
  tmux-session --delete-session <name>                  delete one session
  tmux-session --kill-session <name>                    delete one session
  tmux-session [--session <name>] --rename <ref> <new>  rename one window (ref = index or current name)
  tmux-session [--session <name>] --rename-all         rename all windows to basename(folder)

Flags:
  --cc                                                   use iTerm2's tmux control mode for an attach action
  --plain                                                use native tmux mode for an attach action

Attachments use native tmux by default. `--cc` opts into iTerm2's `tmux -CC`
control mode (also settable as TMUX_SESSION_CC=1); `--plain` explicitly uses
native tmux. `--cc` is only meaningful for --resume, --attach, and --create.
Default session is "main" (override with --session or TMUX_SESSION_NAME).

Examples:
  tmux-session                                          # resume main
  tmux-session ls                                       # all sessions + tabs + panes
  tmux-session --session work --attach                  # attach to existing "work"
  tmux-session --session work --resume                  # resume/create "work" with a default shell tab
  tmux-session --session work --cc --resume             # resume/create through iTerm2 control mode
  tmux-session --session work --create api ~/Code/api   # create "work" with first tab "api" in ~/Code/api and attach
  tmux-session --session work --create notes ~/notes    # add "notes" tab to existing "work" session
  tmux-session --delete notes                            # delete window "notes" from main
  tmux-session --delete-pane api 1                       # delete pane index 1 from window "api"
  tmux-session --delete-pane api '%13'                   # delete pane id %13 from window "api"
  tmux-session --delete-session work                     # delete the whole "work" session
  tmux-session --rename 0 pm-os                         # rename window 0 in main to "pm-os"
  tmux-session --rename-all                             # auto-rename all main windows to their folder basename
EOF
}

ACTION=""
SESSION_EXPLICIT=0
ATTACH_MODE=""
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
        --cc)
            case "$ATTACH_MODE" in
                '') USE_CC=1; ATTACH_MODE="--cc" ;;
                --cc) die "--cc may only be specified once" ;;
                --plain) die "--cc and --plain cannot be combined" ;;
            esac
            shift
            ;;
        --plain)
            case "$ATTACH_MODE" in
                '') USE_CC=0; ATTACH_MODE="--plain" ;;
                --plain) die "--plain may only be specified once" ;;
                --cc) die "--cc and --plain cannot be combined" ;;
            esac
            shift
            ;;
        --resume|--attach|--create|--detach|--list|--ls|--delete|--delete-window|--delete-pane|--delete-session|--kill-session|--rename|--rename-all)
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

case "$ACTION" in
    --delete-session|--kill-session) ;;
    *) validate_name "session name" "$SESSION_NAME" ;;
esac

case "$ACTION" in
    ""|--resume|--attach|--create) ;;
    *) [ -z "$ATTACH_MODE" ] || die "--cc and --plain are only valid with --resume, --attach, or --create" ;;
esac

case "$ACTION" in
    ""|--resume)
        [ ${#ARGS[@]} -eq 0 ] || die "--resume takes no positional arguments"
        cmd_resume
        ;;
    --attach)
        [ ${#ARGS[@]} -eq 0 ] || die "--attach takes no positional arguments"
        cmd_attach
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
    --delete|--delete-window)
        [ ${#ARGS[@]} -eq 1 ] || die "$ACTION requires <window-ref>"
        cmd_delete_window "${ARGS[0]}"
        ;;
    --delete-pane)
        [ ${#ARGS[@]} -eq 2 ] || die "--delete-pane requires <window-ref> <pane-ref>"
        cmd_delete_pane "${ARGS[0]}" "${ARGS[1]}"
        ;;
    --delete-session|--kill-session)
        [ "$SESSION_EXPLICIT" = "0" ] || die "$ACTION takes an explicit session name argument; do not use --session"
        [ ${#ARGS[@]} -eq 1 ] || die "$ACTION requires <session-name>"
        cmd_delete_session "${ARGS[0]}"
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
