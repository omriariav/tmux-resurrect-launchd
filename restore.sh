#!/usr/bin/env bash
# Interactive picker for restoring a tmux-resurrect snapshot.
#
# Default behavior with no args: interactive picker (fzf if available,
# else numbered-list fallback) listing snapshots newest-first with
# timestamp, age, session count, pane count, size, and session names.
# A horizontal rule marks the macOS last-boot time so post-crash
# regressions are visually distinct from pre-crash state.
#
# Flags:
#   --list                  machine-readable list (one row per snapshot)
#   --restore <ts|latest-good>
#                           non-interactive restore (timestamp matches
#                           the YYYYMMDDTHHMMSS portion of a snapshot
#                           filename, or "latest-good" = newest snapshot
#                           with >= MIN_GOOD_PANES panes)
#   --no-confirm            skip the "kill server?" prompt
#   -h, --help              show usage
#
# Refuses to run inside tmux ($TMUX set) — restoring requires killing
# the server you'd be sitting in.

set -euo pipefail

RESURRECT_DIR="$HOME/.tmux/resurrect"
TMUX_RESURRECT_PLUGIN="$HOME/.tmux/plugins/tmux-resurrect"
RESTORE_SCRIPT="$TMUX_RESURRECT_PLUGIN/scripts/restore.sh"
LAUNCHAGENT="$HOME/Library/LaunchAgents/com.user.tmux-resurrect-save.plist"
MIN_GOOD_PANES=3

# --- helpers ---------------------------------------------------------------

err() { printf 'restore: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed -n '/^# /{s/^# \?//;p;}'
    echo
    echo "Usage: $(basename "$0") [--list | --restore <ts|latest-good>] [--no-confirm]"
}

count_panes() { awk -F'\t' '$1=="pane"' "$1" 2>/dev/null | wc -l | tr -d ' '; }
count_sessions() {
    awk -F'\t' '$1=="pane"{print $2}' "$1" 2>/dev/null | sort -u | wc -l | tr -d ' '
}
list_sessions() {
    awk -F'\t' '$1=="pane"{print $2}' "$1" 2>/dev/null | sort -u | paste -sd ',' -
}

human_size() {
    # $1 = bytes
    b="$1"
    if   [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.1fM", b/1048576}'
    elif [ "$b" -ge 1024 ];   then awk -v b="$b" 'BEGIN{printf "%.0fK", b/1024}'
    else echo "${b}B"
    fi
}

human_age() {
    # $1 = epoch seconds
    now=$(date +%s)
    diff=$(( now - $1 ))
    if   [ "$diff" -lt 60 ];     then echo "${diff}s ago"
    elif [ "$diff" -lt 3600 ];   then echo "$(( diff / 60 ))m ago"
    elif [ "$diff" -lt 86400 ];  then echo "$(( diff / 3600 ))h ago"
    else echo "$(( diff / 86400 ))d ago"
    fi
}

last_boot_epoch() {
    # macOS only — extract sec from `kern.boottime: { sec = N, usec = M } ...`
    sysctl -n kern.boottime 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="sec") {gsub(",","",$(i+2)); print $(i+2); exit}}'
}

# Convert YYYYMMDDTHHMMSS → epoch (BSD `date -j`).
ts_to_epoch() {
    date -j -f '%Y%m%dT%H%M%S' "$1" '+%s' 2>/dev/null || echo 0
}

snapshot_files() {
    # Print snapshot filenames newest-first. Only rows whose embedded
    # timestamp is a valid YYYYMMDDTHHMMSS — manual backup copies
    # (e.g. tmux_resurrect_PRECRASH_BACKUP.txt) are filtered out.
    find "$RESURRECT_DIR" -maxdepth 1 -type f -name 'tmux_resurrect_*.txt' \
        -exec stat -f '%m %N' {} + 2>/dev/null \
        | sort -rn \
        | awk '{ $1=""; sub(/^ /,""); print }' \
        | awk -F/ '{ b=$NF; ts=b; sub(/^tmux_resurrect_/,"",ts); sub(/\.txt$/,"",ts);
                     if (ts ~ /^[0-9]{8}T[0-9]{6}$/) print $0 }'
}

# Print rows: ts<TAB>epoch<TAB>panes<TAB>sessions<TAB>size<TAB>names<TAB>filename
build_rows() {
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        base=$(basename "$path")
        ts="${base#tmux_resurrect_}"
        ts="${ts%.txt}"
        epoch=$(ts_to_epoch "$ts")
        panes=$(count_panes "$path")
        sess=$(count_sessions "$path")
        size=$(stat -f '%z' "$path" 2>/dev/null || echo 0)
        names=$(list_sessions "$path")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ts" "$epoch" "$panes" "$sess" "$size" "$names" "$base"
    done
}

current_last_target() {
    [ -L "$RESURRECT_DIR/last" ] || return 1
    readlink "$RESURRECT_DIR/last"
}

# --- listing / picker ------------------------------------------------------

render_human_table() {
    boot=$(last_boot_epoch || echo 0)
    cur=$(current_last_target 2>/dev/null || true)
    boot_marked=0
    idx=0
    while IFS=$'\t' read -r ts epoch panes sess size names base; do
        idx=$((idx+1))
        # Insert boot-boundary rule before the first row whose epoch < boot.
        if [ "$boot_marked" -eq 0 ] && [ "$boot" -gt 0 ] && [ "$epoch" -lt "$boot" ]; then
            printf '       ─────────── boot %s ───────────\n' \
                "$(date -r "$boot" '+%Y-%m-%d %H:%M')"
            boot_marked=1
        fi
        marker=' '
        [ "$base" = "$cur" ] && marker='*'
        nice_ts=$(date -j -f '%Y%m%dT%H%M%S' "$ts" '+%m-%d %H:%M' 2>/dev/null || echo "$ts")
        age=$(human_age "$epoch")
        size_h=$(human_size "$size")
        # Truncate names list for display
        short_names="$names"
        if [ "${#short_names}" -gt 40 ]; then
            short_names="${short_names:0:37}..."
        fi
        printf '%s %2d) %s  %-9s  %2ds/%3dp  %6s  %s\n' \
            "$marker" "$idx" "$nice_ts" "$age" "$sess" "$panes" "$size_h" "$short_names"
    done
    if [ "$idx" -eq 0 ]; then
        err "no snapshots found in $RESURRECT_DIR"
        return 1
    fi
}

render_machine_table() {
    # tab-separated, includes filename in last column
    while IFS=$'\t' read -r ts epoch panes sess size names base; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ts" "$epoch" "$sess" "$panes" "$size" "$base" "$names"
    done
}

pick_recommended_index() {
    # Recommend the newest pre-boot row with >= MIN_GOOD_PANES; falls back to
    # the newest row overall with >= MIN_GOOD_PANES.
    boot=$(last_boot_epoch || echo 0)
    idx=0; rec_pre=0; rec_any=0
    while IFS=$'\t' read -r ts epoch panes sess size names base; do
        idx=$((idx+1))
        if [ "$panes" -ge "$MIN_GOOD_PANES" ]; then
            [ "$rec_any" -eq 0 ] && rec_any="$idx"
            if [ "$boot" -gt 0 ] && [ "$epoch" -lt "$boot" ] && [ "$rec_pre" -eq 0 ]; then
                rec_pre="$idx"
            fi
        fi
    done
    if [ "$rec_pre" -gt 0 ]; then echo "$rec_pre"
    elif [ "$rec_any" -gt 0 ]; then echo "$rec_any"
    else echo 1
    fi
}

# Resolve a user pick (number, ts, or "latest-good") to a filename.
resolve_pick() {
    pick="$1"
    rows="$2"  # the cached rows
    if [ "$pick" = "latest-good" ]; then
        echo "$rows" | awk -F'\t' -v min="$MIN_GOOD_PANES" '$3 >= min {print $7; exit}'
        return
    fi
    # Numeric index
    if [ "$pick" -eq "$pick" ] 2>/dev/null; then
        echo "$rows" | awk -F'\t' -v n="$pick" 'NR==n {print $7}'
        return
    fi
    # Timestamp
    echo "$rows" | awk -F'\t' -v ts="$pick" '$1 == ts {print $7; exit}'
}

# --- restore execution -----------------------------------------------------

execute_restore() {
    target_base="$1"  # filename basename
    no_confirm="$2"

    if [ -n "${TMUX:-}" ]; then
        die "cannot restore from inside tmux. Open a fresh shell (no tmux integration) and re-run."
    fi

    target_path="$RESURRECT_DIR/$target_base"
    [ -f "$target_path" ] || die "snapshot not found: $target_path"

    cur=$(current_last_target 2>/dev/null || true)
    panes=$(count_panes "$target_path")
    sess=$(count_sessions "$target_path")
    names=$(list_sessions "$target_path")
    bootstrap="_restore_bootstrap_$$"

    echo
    echo "Restore plan:"
    echo "  snapshot:  $target_base"
    echo "  sessions:  $sess ($names)"
    echo "  panes:     $panes"
    [ -n "$cur" ] && [ "$cur" != "$target_base" ] && echo "  replaces:  $cur (current 'last')"
    echo
    echo "This will kill the running tmux server. Any attached clients will disconnect."
    if [ "$no_confirm" -ne 1 ]; then
        printf 'Proceed? [y/N] '
        read -r ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) die "aborted." ;;
        esac
    fi

    # State for the cleanup trap.
    daemon_was_loaded=0
    if launchctl list 2>/dev/null | grep -q com.user.tmux-resurrect-save; then
        daemon_was_loaded=1
    fi

    cleanup() {
        rc=$?
        # Always remove the fence and try to re-arm the daemon, even on error.
        rm -f "$RESURRECT_DIR/.restoring" 2>/dev/null || true
        if [ "$daemon_was_loaded" -eq 1 ]; then
            launchctl list 2>/dev/null | grep -q com.user.tmux-resurrect-save \
                || launchctl load -w "$LAUNCHAGENT" 2>/dev/null || true
        fi
        if [ "$rc" -ne 0 ]; then
            err "restore aborted (exit $rc). Inspect tmux state with: tmux ls"
            err "if you're left without a server, start one with: tmux new-session -d -s recovery"
        fi
    }
    trap cleanup EXIT

    # One-way fence — see bin/tmux-resurrect-tick.
    touch "$RESURRECT_DIR/.restoring"

    if [ "$daemon_was_loaded" -eq 1 ]; then
        launchctl unload "$LAUNCHAGENT" 2>/dev/null || true
    fi

    echo "==> Killing current tmux server"
    tmux kill-server 2>/dev/null || true
    # Clean stale socket if any
    sock_dir=$(find /private/tmp -maxdepth 1 -type d -name "tmux-$(id -u)" 2>/dev/null || true)
    [ -n "$sock_dir" ] && rm -f "$sock_dir/default" 2>/dev/null || true
    sleep 1

    echo "==> Pointing 'last' at $target_base"
    ln -sf "$target_base" "$RESURRECT_DIR/last"

    echo "==> Starting detached server"
    tmux new-session -d -s "$bootstrap"

    echo "==> Running tmux-resurrect restore (via run-shell)"
    tmux run-shell "$RESTORE_SCRIPT"

    echo "==> Cleaning up bootstrap session ($bootstrap)"
    tmux kill-session -t "$bootstrap" 2>/dev/null || true

    if [ "$daemon_was_loaded" -eq 1 ]; then
        echo "==> Re-arming the save daemon"
        launchctl load -w "$LAUNCHAGENT"
    fi

    echo
    echo "Restored. Sessions on the server now:"
    tmux ls
    echo
    primary=$(tmux ls -F '#{session_name}' | grep -v "^$bootstrap\$" | head -1 || true)
    [ -z "$primary" ] && primary='<session-name>'
    echo "Attach via iTerm2 -CC integration with:"
    echo "    tmux -CC attach -t $primary"

    trap - EXIT
    rm -f "$RESURRECT_DIR/.restoring" 2>/dev/null || true
}

# --- main ------------------------------------------------------------------

[ -d "$RESURRECT_DIR" ] || die "no resurrect directory at $RESURRECT_DIR"
[ -x "$RESTORE_SCRIPT" ] || die "tmux-resurrect plugin not found at $TMUX_RESURRECT_PLUGIN"

mode="interactive"
target=""
no_confirm=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) mode="list" ;;
        --restore) mode="restore"; shift; target="${1:-}";;
        --restore=*) mode="restore"; target="${1#--restore=}";;
        --no-confirm) no_confirm=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown arg: $1 (try --help)" ;;
    esac
    shift
done

# Cache rows once.
rows=$(snapshot_files | build_rows)
[ -n "$rows" ] || die "no snapshots found in $RESURRECT_DIR"

case "$mode" in
    list)
        echo "$rows" | render_machine_table
        ;;
    restore)
        [ -n "$target" ] || die "--restore requires a value"
        resolved=$(resolve_pick "$target" "$rows")
        [ -n "$resolved" ] || die "no snapshot matching: $target"
        execute_restore "$resolved" "$no_confirm"
        ;;
    interactive)
        rec_idx=$(echo "$rows" | pick_recommended_index)
        echo "Snapshots in $RESURRECT_DIR (newest first; * = current 'last'):"
        echo
        echo "$rows" | render_human_table
        echo
        echo "  recommended: $rec_idx (newest pre-boot snapshot with >= $MIN_GOOD_PANES panes)"
        echo
        printf 'Pick a number [%s], a timestamp, "latest-good", or q to quit: ' "$rec_idx"
        read -r choice
        choice="${choice:-$rec_idx}"
        case "$choice" in
            q|Q) exit 0 ;;
        esac
        resolved=$(resolve_pick "$choice" "$rows")
        [ -n "$resolved" ] || die "invalid choice: $choice"
        execute_restore "$resolved" "$no_confirm"
        ;;
esac
