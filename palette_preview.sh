#!/usr/bin/env bash
# Preview iTerm2 and tmux palettes without persisting them.

set -euo pipefail

SESSION_NAME="${TMUX_SESSION_NAME:-main}"
IT2SETCOLOR="/Applications/iTerm.app/Contents/Resources/utilities/it2setcolor"
IT2PROFILE="/Applications/iTerm.app/Contents/Resources/utilities/it2profile"
DYNAMIC_PROFILE_DIR="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
DYNAMIC_PROFILE_FILE="$DYNAMIC_PROFILE_DIR/codex-palette-preview.json"

usage() {
    cat <<'EOF'
palette_preview.sh - preview terminal colors live

Usage:
  ./palette_preview.sh
  ./palette_preview.sh old-green
  ./palette_preview.sh mint-green
  ./palette_preview.sh high-contrast-green
  ./palette_preview.sh slick-green
  ./palette_preview.sh slick-green-other-font

These previews affect the current iTerm2 session and running tmux server only.
They do not update the saved iTerm2 profile or dotfiles.
EOF
}

set_palette() {
    FONT_PROFILE=""
    FONT_NOTE=""

    case "$1" in
        old-green)
            NAME="old-green"
            BG="000000"
            FG="8fd7b9"
            BOLD="b7f7d2"
            DIM="5c806f"
            BORDER="4f735f"
            SELECT_BG="164d36"
            CURSOR="33ff99"
            RED="ff5f6d"
            GREEN="7ee787"
            YELLOW="d8c26a"
            BLUE="5fa8d3"
            MAGENTA="d2a8ff"
            CYAN="6ee7b7"
            BR_GREEN="a6ff8f"
            ;;
        mint-green)
            NAME="mint-green"
            BG="00120c"
            FG="d4f8e8"
            BOLD="f0fff8"
            DIM="79a892"
            BORDER="4d8f71"
            SELECT_BG="0b4a32"
            CURSOR="4ade80"
            RED="ff6b7a"
            GREEN="4ade80"
            YELLOW="f3d26b"
            BLUE="67b7dc"
            MAGENTA="d6a6ff"
            CYAN="64e6b6"
            BR_GREEN="9cffb8"
            ;;
        high-contrast-green)
            NAME="high-contrast-green"
            BG="000000"
            FG="d7ffe8"
            BOLD="ffffff"
            DIM="8ab89f"
            BORDER="69a784"
            SELECT_BG="1d5c40"
            CURSOR="9cff57"
            RED="ff6b6b"
            GREEN="9cff57"
            YELLOW="ffe66d"
            BLUE="9bd4ff"
            MAGENTA="e4c1ff"
            CYAN="9fffe0"
            BR_GREEN="c8ff9a"
            ;;
        slick-green)
            NAME="slick-green"
            BG="000000"
            FG="c8ffd8"
            BOLD="f3fff7"
            DIM="89b69b"
            BORDER="367a58"
            SELECT_BG="0d3b28"
            CURSOR="00ff88"
            RED="ff4d5e"
            GREEN="8cff70"
            YELLOW="f6d365"
            BLUE="6db6ff"
            MAGENTA="c792ea"
            CYAN="58ffc7"
            BR_GREEN="b8ff72"
            ;;
        slick-green-other-font)
            NAME="slick-green-other-font"
            BG="000000"
            FG="c8ffd8"
            BOLD="f3fff7"
            DIM="89b69b"
            BORDER="367a58"
            SELECT_BG="0d3b28"
            CURSOR="00ff88"
            RED="ff4d5e"
            GREEN="8cff70"
            YELLOW="f6d365"
            BLUE="6db6ff"
            MAGENTA="c792ea"
            CYAN="58ffc7"
            BR_GREEN="b8ff72"
            FONT_PROFILE="slick-green-other-font"
            FONT_NOTE="MesloLGS Nerd Font Mono Regular 14, line height 1.2"
            ;;
        *)
            printf 'Unknown palette: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
}

component() {
    value=$((16#$1))
    /usr/bin/awk -v n="$value" 'BEGIN { printf "%.6f", n / 255 }'
}

color_json() {
    name="$1"
    hex="$2"
    r=$(component "${hex:0:2}")
    g=$(component "${hex:2:2}")
    b=$(component "${hex:4:2}")

    cat <<EOF
      "$name": {
        "Color Space": "sRGB",
        "Red Component": $r,
        "Green Component": $g,
        "Blue Component": $b,
        "Alpha Component": 1
      }
EOF
}

write_font_preview_profile() {
    mkdir -p "$DYNAMIC_PROFILE_DIR"
    tmpdir=$(mktemp -d "$DYNAMIC_PROFILE_DIR/.codex-palette-preview.XXXXXX")
    tmp="$tmpdir/profile.json"
    {
        cat <<'EOF'
{
  "Profiles": [
    {
      "Name": "slick-green-other-font",
      "Guid": "4B40EE71-C242-4B4D-A34E-3C27998B6A55",
      "Normal Font": "MesloLGSNFM-Regular 14",
      "Non Ascii Font": "MesloLGSNFM-Regular 14",
      "Use Non-ASCII Font": false,
      "Vertical Spacing": 1.2,
      "Horizontal Spacing": 1,
      "Minimum Contrast": 0.5,
EOF
        color_json "Background Color" "$BG"; printf ',\n'
        color_json "Foreground Color" "$FG"; printf ',\n'
        color_json "Bold Color" "$BOLD"; printf ',\n'
        color_json "Cursor Color" "$CURSOR"; printf ',\n'
        color_json "Cursor Text Color" "$BG"; printf ',\n'
        color_json "Selection Color" "$SELECT_BG"; printf ',\n'
        color_json "Selected Text Color" "f2fff8"; printf ',\n'
        color_json "Ansi 0 Color" "$BG"; printf ',\n'
        color_json "Ansi 1 Color" "$RED"; printf ',\n'
        color_json "Ansi 2 Color" "$GREEN"; printf ',\n'
        color_json "Ansi 3 Color" "$YELLOW"; printf ',\n'
        color_json "Ansi 4 Color" "$BLUE"; printf ',\n'
        color_json "Ansi 5 Color" "$MAGENTA"; printf ',\n'
        color_json "Ansi 6 Color" "$CYAN"; printf ',\n'
        color_json "Ansi 7 Color" "$FG"; printf ',\n'
        color_json "Ansi 8 Color" "$DIM"; printf ',\n'
        color_json "Ansi 9 Color" "ff8a93"; printf ',\n'
        color_json "Ansi 10 Color" "$BR_GREEN"; printf ',\n'
        color_json "Ansi 11 Color" "ffe58a"; printf ',\n'
        color_json "Ansi 12 Color" "9fd1ff"; printf ',\n'
        color_json "Ansi 13 Color" "e2c7ff"; printf ',\n'
        color_json "Ansi 14 Color" "a8ffd8"; printf ',\n'
        color_json "Ansi 15 Color" "e6fff4"
        cat <<'EOF'
    }
  ]
}
EOF
    } > "$tmp"
    /usr/bin/python3 -m json.tool "$tmp" >/dev/null || {
        rm -rf "$tmpdir"
        return 1
    }
    mv "$tmp" "$DYNAMIC_PROFILE_FILE"
    rm -rf "$tmpdir"
}

apply_profile_switch() {
    if [ "$NAME" = "slick-green" ]; then
        rm -f "$DYNAMIC_PROFILE_FILE"
        return 0
    fi

    [ -x "$IT2PROFILE" ] || return 0
    case "${LC_TERMINAL:-}:${TERM_PROGRAM:-}" in
        *iTerm2*|*iTerm.app*) ;;
        *) return 0 ;;
    esac

    [ -n "$FONT_PROFILE" ] || return 0
    write_font_preview_profile
    "$IT2PROFILE" -s "$FONT_PROFILE" || true
}

apply_iterm() {
    [ -x "$IT2SETCOLOR" ] || return 0
    case "${LC_TERMINAL:-}:${TERM_PROGRAM:-}" in
        *iTerm2*|*iTerm.app*) ;;
        *) return 0 ;;
    esac

    "$IT2SETCOLOR" \
        fg "$FG" bg "$BG" bold "$BOLD" link "$CYAN" \
        selbg "$SELECT_BG" selfg f2fff8 curbg "$CURSOR" curfg "$BG" \
        black "$BG" red "$RED" green "$GREEN" yellow "$YELLOW" \
        blue "$BLUE" magenta "$MAGENTA" cyan "$CYAN" white "$FG" \
        br_black "$DIM" br_red ff8a93 br_green "$BR_GREEN" br_yellow ffe58a \
        br_blue 9fd1ff br_magenta e2c7ff br_cyan a8ffd8 br_white e6fff4
}

apply_tmux() {
    command -v tmux >/dev/null 2>&1 || return 0
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 0

    tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-palette-preview.XXXXXX")
    {
        printf "set -g status-style 'bg=#%s fg=#%s'\n" "$BG" "$FG"
        printf "set -g window-status-current-style 'bg=#%s fg=#%s bold'\n" "$CURSOR" "$BG"
        printf "set -g window-status-style 'bg=#%s fg=#%s'\n" "$BG" "$DIM"
        printf "set -g pane-active-border-style 'fg=#%s'\n" "$CURSOR"
        printf "set -g pane-border-style 'fg=#%s'\n" "$BORDER"
        printf "set -g message-style 'bg=#%s fg=#%s bold'\n" "$BG" "$CURSOR"
        printf "set -g message-command-style 'bg=#%s fg=#%s'\n" "$BG" "$CURSOR"
        printf "set -g window-status-format '#{?#{==:#{window_index},0},#[bg=#%s fg=#%s] #I:#W ,#{?#{==:#{window_index},1},#[bg=#%s fg=#%s] #I:#W ,#{?#{==:#{window_index},2},#[bg=#%s fg=#%s] #I:#W ,#[bg=#%s fg=#%s] #I:#W }}}'\n" "$RED" "$BG" "$CURSOR" "$BG" "$MAGENTA" "$BG" "$BG" "$DIM"
    } > "$tmp"

    tmux source-file "$tmp" || true
    rm -f "$tmp"
}

swatch() {
    printf '\033[48;2;%d;%d;%dm  \033[0m #%s ' "$((16#${1:0:2}))" "$((16#${1:2:2}))" "$((16#${1:4:2}))" "$1"
}

show_palette() {
    printf '\n%s\n' "$NAME"
    swatch "$BG"; printf 'background\n'
    swatch "$FG"; printf 'foreground\n'
    swatch "$GREEN"; printf 'green text\n'
    swatch "$DIM"; printf 'dim text\n'
    swatch "$CURSOR"; printf 'accent\n\n'
    if [ -n "$FONT_NOTE" ]; then
        printf 'font preview: %s\n\n' "$FONT_NOTE"
    fi
}

choose_palette() {
    while true; do
        cat >/dev/tty <<'EOF'
Choose palette preview:
1) old-green
2) mint-green
3) high-contrast-green
4) slick-green
5) slick-green-other-font
q) quit

EOF
        printf 'Choice: ' >/dev/tty
        read -r choice </dev/tty
        case "$choice" in
            1) printf '%s\n' old-green; return 0 ;;
            2) printf '%s\n' mint-green; return 0 ;;
            3) printf '%s\n' high-contrast-green; return 0 ;;
            4) printf '%s\n' slick-green; return 0 ;;
            5) printf '%s\n' slick-green-other-font; return 0 ;;
            q|Q) exit 0 ;;
            *) printf 'Invalid choice.\n\n' >/dev/tty ;;
        esac
    done
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        palette=$(choose_palette)
        ;;
    *)
        palette="$1"
        ;;
esac

set_palette "$palette"
apply_profile_switch
apply_iterm
apply_tmux
show_palette
printf 'Preview applied. Tell Codex what to change, or approve this palette.\n'
