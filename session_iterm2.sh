#!/usr/bin/env bash
# iTerm2-first tmux launcher.
#
# Mental model:
#   tmux session "main" = iTerm2 window
#   tmux windows        = iTerm2 tabs
#   tmux panes          = panes inside each tab
#
# Daily commands:
#   tmux-session
#   tmux-session --resume [main]
#   tmux-session --create <tab-name> <folder>
#   tmux-session --switch-tab <tab-name>
#   tmux-session --detach
#   tmux-session --list

set -euo pipefail

SESSION_NAME="${TMUX_SESSION_NAME:-main}"
IT2SETCOLOR="/Applications/iTerm.app/Contents/Resources/utilities/it2setcolor"

usage() {
    cat <<'EOF'
tmux-session - manage the main iTerm2/tmux session and its tabs.

Usage:
  tmux-session
  tmux-session --resume [main]
  tmux-session --create <tab-name> <folder>
  tmux-session --detach
  tmux-session --list

Advanced:
  tmux-session --switch-tab <tab-name>

Examples:
  tmux-session --resume
  tmux-session --create taboola-pm-os ~/Code/taboola-pm-os
  tmux-session --switch-tab taboola-pm-os
EOF
}

die() {
    printf 'tmux-session: %s\n' "$*" >&2
    exit 1
}

apply_iterm_palette() {
    [ -x "$IT2SETCOLOR" ] || return 0
    case "${LC_TERMINAL:-}:${TERM_PROGRAM:-}" in
        *iTerm2*|*iTerm.app*) ;;
        *) return 0 ;;
    esac

    "$IT2SETCOLOR" \
        fg c8ffd8 bg 000000 bold f3fff7 link 58ffc7 \
        selbg 0d3b28 selfg f2fff8 curbg 00ff88 curfg 000000 \
        black 000000 red ff4d5e green 8cff70 yellow f6d365 \
        blue 6db6ff magenta c792ea cyan 58ffc7 white c8ffd8 \
        br_black 89b69b br_red ff8a93 br_green b8ff72 br_yellow ffe58a \
        br_blue 9fd1ff br_magenta e2c7ff br_cyan a8ffd8 br_white e6fff4
}

expand_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

validate_tab_name() {
    [ -n "$1" ] || die "tab name is required"
    case "$1" in
        *:*) die "tab names cannot contain ':'" ;;
    esac
}

session_exists() {
    tmux has-session -t "$SESSION_NAME" 2>/dev/null
}

ensure_session() {
    if ! session_exists; then
        folder="${1:-$HOME}"
        tmux new-session -d -s "$SESSION_NAME" -n shell -c "$folder"
    fi
}

tab_target_by_name() {
    name="$1"
    tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null \
        | awk -F'|' -v want="$name" '$2 == want { print $1; exit }'
}

tab_name_by_index() {
    idx="$1"
    tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null \
        | awk -F'|' -v want="$idx" '$1 == want { print $2; exit }'
}

list_tabs_raw() {
    session_exists || return 0
    tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}|#{window_panes}|#{window_active}|#{pane_current_path}'
}

print_tabs() {
    rows=$(list_tabs_raw)
    if [ -z "$rows" ]; then
        echo "No tmux session is running. Press Enter to start main."
        return 0
    fi

    printf 'tmux session: %s\n' "$SESSION_NAME"
    printf '%-4s %-30s %-7s %-7s %s\n' "tab" "name" "panes" "active" "path"
    printf '%-4s %-30s %-7s %-7s %s\n' "----" "------------------------------" "-----" "------" "----"
    printf '%s\n' "$rows" | while IFS='|' read -r idx name panes active path; do
        marker="no"
        [ "$active" = "1" ] && marker="yes"
        printf '%-4s %-30s %-7s %-7s %s\n' "$idx" "$name" "$panes" "$marker" "$path"
    done
}

resume_main() {
    apply_iterm_palette
    ensure_session "$HOME"

    if [ -n "${TMUX:-}" ]; then
        exec tmux switch-client -t "$SESSION_NAME"
    fi

    exec tmux -CC attach-session -t "$SESSION_NAME"
}

select_tab() {
    apply_iterm_palette
    target="$1"
    tmux select-window -t "$SESSION_NAME:$target"

    if [ -n "${TMUX:-}" ]; then
        exec tmux switch-client -t "$SESSION_NAME:$target"
    fi

    exec tmux -CC attach-session -t "$SESSION_NAME"
}

create_tab() {
    name="$1"
    folder="$(expand_path "$2")"
    validate_tab_name "$name"
    [ -d "$folder" ] || die "folder does not exist: $folder"

    ensure_session "$folder"

    existing=$(tab_target_by_name "$name")
    if [ -n "$existing" ]; then
        select_tab "$existing"
    fi

    tmux new-window -t "$SESSION_NAME:" -n "$name" -c "$folder"
    target=$(tab_target_by_name "$name")
    [ -n "$target" ] || die "created tab but could not find it: $name"
    select_tab "$target"
}

switch_tab() {
    name="$1"
    validate_tab_name "$name"
    session_exists || die "tmux session '$SESSION_NAME' is not running. Resume main first."

    target=$(tab_target_by_name "$name")
    [ -n "$target" ] || die "tab does not exist: $name"
    select_tab "$target"
}

detach_main() {
    session_exists || die "tmux session '$SESSION_NAME' is not running"
    tmux detach-client -s "$SESSION_NAME" 2>/dev/null || true
    printf 'Detached clients from tmux session %s.\n' "$SESSION_NAME"
}

default_folder_for() {
    candidate="$HOME/Code/$1"
    if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
    else
        pwd
    fi
}

prompt_create() {
    printf 'Tab name: '
    read -r name
    validate_tab_name "$name"

    suggested="$(default_folder_for "$name")"
    printf 'Folder [%s]: ' "$suggested"
    read -r folder
    folder="${folder:-$suggested}"

    create_tab "$name" "$folder"
}

interactive() {
    apply_iterm_palette

    while true; do
        clear 2>/dev/null || true
        echo "tmux-session"
        echo
        print_tabs
        echo
        echo "Enter/r) resume main session"
        echo "c) create tab in main"
        echo "d) detach iTerm2 clients"
        echo "l) list tabs"
        echo "q) quit"
        echo
        printf 'Choice: '
        read -r choice

        case "$choice" in
            q|Q) exit 0 ;;
            c|C) prompt_create ;;
            r|R|'') resume_main ;;
            d|D) detach_main; echo; printf 'Press Enter to continue... '; read -r _ ;;
            l|L) print_tabs; echo; printf 'Press Enter to continue... '; read -r _ ;;
            *) die "invalid choice: $choice" ;;
        esac
    done
}

case "${1:-}" in
    "")
        interactive
        ;;
    --resume)
        if [ $# -gt 2 ]; then
            die "$1 accepts at most the managed session name: $SESSION_NAME"
        fi
        if [ $# -eq 2 ] && [ "$2" != "$SESSION_NAME" ]; then
            die "this launcher resumes session '$SESSION_NAME'. Use --switch-tab only if you need a specific tab."
        fi
        resume_main
        ;;
    --create)
        [ $# -eq 3 ] || die "--create requires <tab-name> <folder>"
        create_tab "$2" "$3"
        ;;
    --switch-tab)
        [ $# -eq 2 ] || die "$1 requires <tab-name>"
        switch_tab "$2"
        ;;
    --detach)
        [ $# -eq 1 ] || die "--detach takes no arguments"
        detach_main
        ;;
    --list)
        print_tabs
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
