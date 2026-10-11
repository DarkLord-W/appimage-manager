#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 DarkLord-W
#
# ui-helpers.sh — shared shell helpers for tests/ui-test.sh
#
# Sourced, never executed directly. All helpers assume the caller has set:
#   DISPLAY, OUT_DIR, SANDBOX, FIXTURES_DIR, APP_BIN, MAIN_WIN,
#   DIALOG_CLASS, TMP_PNG (scratch path inside OUT_DIR)
#
# Nothing in here touches the real user home: all XDG_* variables are
# exported by ui-test.sh before any helper runs, and file operations only
# ever touch "$SANDBOX" / "$OUT_DIR".

# ── small utilities ──────────────────────────────────────────────────────────

to_int() { # to_int <value> <fallback>
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}

# ── window discovery ─────────────────────────────────────────────────────────

win_h() { # win_h <window-id> — prints height, empty on failure
    xdotool getwindowgeometry "$1" 2>/dev/null \
        | sed -n 's/.*Geometry: [0-9]*x\([0-9]*\).*/\1/p'
}

win_w() { # win_w <window-id>
    xdotool getwindowgeometry "$1" 2>/dev/null \
        | sed -n 's/.*Geometry: \([0-9]*\)x.*/\1/p'
}

learn_dialog_class() { # learn_dialog_class <window-id>
    # The GTK dialogs of this app carry the application's WM_CLASS (derived
    # from the binary name), while the main window uses an explicit class.
    # Untitled dialogs (e.g. the delete confirmation) can only be found via
    # that class, so remember it the first time we see any dialog.
    local id="$1" cls=""
    [ -n "$id" ] || return 1
    cls="$(xprop -id "$id" WM_CLASS 2>/dev/null \
           | sed -n 's/.*WM_CLASS(STRING) = "\([^"]*\)".*/\1/p')"
    if [ -n "$cls" ] && [ "$cls" != "AppImage Manager" ]; then
        DIALOG_CLASS="$cls"
        return 0
    fi
    return 1
}

find_win_by_name() { # find_win_by_name <regex> — echoes id or nothing
    # time-boxed: a hung/broken X server must never wedge the whole suite
    timeout 4 xdotool search --onlyvisible --name "$1" 2>/dev/null | tail -n 1
}

wait_win_by_name() { # wait_win_by_name <regex> [tries] [interval]
    local pat="$1" tries="${2:-24}" iv="${3:-0.25}" i=0 id=""
    while [ "$i" -lt "$tries" ]; do
        id="$(find_win_by_name "$pat")"
        if [ -n "$id" ]; then
            WIN_FOUND="$id"
            learn_dialog_class "$id"
            return 0
        fi
        sleep "$iv"
        i=$((i + 1))
    done
    WIN_FOUND=""
    return 1
}

wait_win_gone_by_name() { # wait_win_gone_by_name <regex> [tries] [interval]
    local pat="$1" tries="${2:-24}" iv="${3:-0.25}" i=0
    while [ "$i" -lt "$tries" ]; do
        [ -z "$(find_win_by_name "$pat")" ] && return 0
        sleep "$iv"
        i=$((i + 1))
    done
    return 1
}

app_window_ids() { # all visible windows carrying the app's dialog class
    timeout 4 xdotool search --onlyvisible --class "$DIALOG_CLASS" 2>/dev/null
}

count_app_dialogs() { # number of visible dialog-class windows (not the main
                      # window, not tooltips: dialogs are ≥ 80 px tall)
    local n=0 id h
    for id in $(app_window_ids); do
        [ "$id" = "$MAIN_WIN" ] && continue
        h="$(win_h "$id")"
        if [ -n "$h" ] && [ "$h" -ge 80 ]; then
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}

find_app_popup() { # find_app_popup [min-height] — echoes id of a popup/menu/dialog
    # Menus, combo popups and dialogs are all visible windows with the app's
    # dialog class; the main window is explicitly excluded. For menus we ask
    # for a minimum height so tooltips (short, wide) are skipped.
    local minh="${1:-61}" id best="" bh=0 h
    for id in $(app_window_ids); do
        [ "$id" = "$MAIN_WIN" ] && continue
        h="$(win_h "$id")"
        [ -n "$h" ] || continue
        if [ "$h" -ge "$minh" ] && [ "$h" -gt "$bh" ]; then
            best="$id"; bh="$h"
        fi
    done
    [ -n "$best" ] && printf '%s' "$best"
}

wait_app_popup() { # wait_app_popup [min-height] [tries] — sets POPUP_FOUND
    local minh="${1:-61}" tries="${2:-16}" i=0 id=""
    while [ "$i" -lt "$tries" ]; do
        id="$(find_app_popup "$minh")"
        if [ -n "$id" ]; then POPUP_FOUND="$id"; return 0; fi
        sleep 0.25
        i=$((i + 1))
    done
    POPUP_FOUND=""
    return 1
}

# ── input helpers ────────────────────────────────────────────────────────────

focus_win() { # focus_win <window-id> — never block the whole suite on a WM
              # that is slow/absent: both calls are time-boxed
    timeout 3 xdotool windowactivate --sync "$1" >/dev/null 2>&1 && return 0
    timeout 3 xdotool windowfocus --sync "$1" >/dev/null 2>&1
}

focus_main() { focus_win "$MAIN_WIN"; }

click_win() { # click_win <window-id> <x> <y> — window-relative click
    local win="$1" x="$2" y="$3"
    xdotool mousemove --sync --window "$win" "$x" "$y" >/dev/null 2>&1 || return 1
    sleep 0.2
    xdotool click 1 >/dev/null 2>&1
}

click_main() { click_win "$MAIN_WIN" "$1" "$2"; }

park_mouse() { # move the pointer to a neutral spot (no tooltip sources)
    xdotool mousemove --sync --window "$MAIN_WIN" "$((WIN_W - 15))" "$((WIN_H - 15))" \
        >/dev/null 2>&1 || true
}

send_key() { # send_key <window-id> <keys...>
    local win="$1"; shift
    focus_win "$win"
    sleep 0.15
    xdotool key --clearmodifiers "$@"
}

type_text() { # type_text <window-id> <text>
    local win="$1" text="$2"
    focus_win "$win"
    sleep 0.15
    xdotool type --clearmodifiers --delay 25 -- "$text" >/dev/null 2>&1
}

clear_search() { # clear the search entry without relying on Ctrl+A (that accel
                 # is globally bound to "select all rows" in this app)
    send_key "$MAIN_WIN" ctrl+f
    sleep 0.2
    xdotool key --clearmodifiers End
    sleep 0.1
    xdotool key --clearmodifiers --repeat 40 --delay 15 BackSpace
    sleep 0.6
}

search_for() { # search_for <text>
    clear_search
    type_text "$MAIN_WIN" "$1"
    sleep 1.0
}

open_menu() { # open_menu <alt+key> [settle] — opens a menu bar menu
    focus_main
    sleep 0.15
    xdotool key --clearmodifiers "$1"
    sleep "${2:-0.7}"
}

menu_move_down() { # menu_move_down <n> — one key event per call (batched Down
                   # events get coalesced by GTK and move fewer items)
    local n="$1" i=0
    while [ "$i" -lt "$n" ]; do
        xdotool key --clearmodifiers Down
        sleep 0.15
        i=$((i + 1))
    done
}

menu_pick() { # menu_pick <alt+key> <downs> — open menu, move, activate
    # Never open a menu while a dialog is mapped: the menu would not open and
    # the Down/Return keys would end up in the dialog instead.
    local i=0
    while [ "$(count_app_dialogs)" -gt 0 ] && [ "$i" -lt 4 ]; do
        xdotool key --clearmodifiers Escape
        sleep 0.4
        i=$((i + 1))
    done
    open_menu "$1"
    if ! wait_app_popup 61 12; then
        # never let stray Down/Return keys hit the main window (Return would
        # trigger the primary action on the list selection)
        echo "  warning: menu '$1' did not open; aborting selection" >&2
        xdotool key --clearmodifiers Escape
        return 1
    fi
    menu_move_down "$2"
    xdotool key --clearmodifiers Return
    return 0
}

# ── screenshot / image helpers ───────────────────────────────────────────────

grab_main() { # grab_main <png>
    timeout 20 import -window "$MAIN_WIN" "$1" 2>>"$OUT_DIR/import.log" || return 1
    [ -s "$1" ]
}

grab_root() { # grab_root <png>
    timeout 20 import -window root "$1" 2>>"$OUT_DIR/import.log" || return 1
    [ -s "$1" ]
}

grab_win() { # grab_win <window-id> <png>
    timeout 20 import -window "$1" "$2" 2>>"$OUT_DIR/import.log" || return 1
    [ -s "$2" ]
}

crop_img() { # crop_img <src> <dst> <WxH+X+Y>
    convert "$1" -crop "$3" +repage "$2" 2>>"$OUT_DIR/import.log"
}

unique_colors() { # unique_colours of an image (flat ⇒ 1)
    local n
    n="$(identify -format '%k' "$1" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

image_sig() { identify -format '%#' "$1" 2>/dev/null; }

region_sig() { # region_sig <png> <WxH+X+Y> — content hash of a crop
    crop_img "$1" "$TMP_PNG" "$2" >/dev/null 2>&1 || { printf ''; return; }
    image_sig "$TMP_PNG"
}

count_bands_in() { # count_bands_in <img> <threshold> — merged text bands
    # Projects the image onto a 1-pixel column (row brightness profile),
    # keeps the rows containing text (loosely: anything brighter than the
    # flat background), and merges fragments closer than 13 px so that
    # accelerator labels ("Ctrl+,") do not split one menu row into several.
    local img="$1" thr="$2"
    convert "$img" -shave 5x5 -colorspace Gray -threshold "$thr" -negate \
            -resize 1x! -depth 8 txt:- 2>/dev/null \
        | awk -F'[(),]' 'NR>1 {print NR-2, $3}' \
        | awk '$2<250 {print $1}' \
        | awk 'BEGIN{g=0;p=-1000} {if(g==0 || $1>p+13){g++}; p=$1} END{print g+0}'
}

count_popup_bands() { # count_popup_bands <popup-shot> — menu/number of rows
    # 阈値 45% 而不是 55%。
    #
    # 55% 在菜单栏那六个菜单上是对的，但上下文菜单里「创建启动器」
    # 「修复问题…」在被管理的条目上是**禁用态**（灰字），亮度落在
    # 55% 之下 —— 8 项只数出 6 项，报成「菜单只有 6 项」，
    # 看着像功能缺了两项。
    #
    # 45% 是实测出来的下界：把六张菜单截图和上下文菜单截图都拿来复算，
    # 45%/50% 全部数对，40% 会把「文件」菜单少数一项（分隔线与首项粘连）。
    count_bands_in "$1" 45%
}

count_list_rows() { # count_list_rows <main-window-shot>
    # The icon column of the TreeView (x≈45..115, first row starts ≈y=190)
    # renders one placeholder/icon tile per row; counting the bright bands
    # in that column counts visible rows.
    local img="$1"
    crop_img "$img" "$TMP_PNG" "70x460+45+185" 2>/dev/null || { printf '0'; return; }
    count_bands_in "$TMP_PNG" 45%
}

# ── .desktop / data helpers (read-only mirrors of app logic) ─────────────────

desktop_get() { # desktop_get <file> <key-first-match>
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

desktop_marker_count() { # desktop_marker_count <file> <exact-line-prefix>
    grep -c "^$2" "$1" 2>/dev/null | head -n 1
}

desktop_strip_markers() { # drop all marker lines (used for byte-preservation diff)
    grep -v '^X-AppImage-Manager' "$1" 2>/dev/null
}

desktop_exec_target() { # desktop_exec_target <file> — shell mirror of extract_exec_path
    local line val
    line="$(sed -n 's/^Exec=//p' "$1" 2>/dev/null | head -n 1)"
    [ -n "$line" ] || return 0
    val="$(printf '%s' "$line" | sed 's/%%/@PCT@/g; s/%[fFuUidDnNvVmck]//g; s/@PCT@/%/g')"
    case "$val" in
        \"*) val="${val#\"}"; val="${val%%\"*}" ;;
        *)   val="${val%% *}" ;;
    esac
    printf '%s' "$val"
}

scan_appimages() { # scan_appimages <dir> — shell mirror of Scanner.scan (recursive)
    local dir="$1" f magic
    find "$dir" -type f \( -iname '*.appimage' -o -iname '*.appimage.zsync' \) \
         -print0 2>/dev/null | while IFS= read -r -d '' f; do
        magic="$(head -c 10 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        if [ "${magic:0:8}" = "7f454c46" ] && [ "${magic:16:4}" = "4149" ]; then
            printf '%s\n' "$f"
        fi
    done
}

count_manifests() { # number of committed transaction manifests
    find "$SANDBOX/data/appimage-manager/history" -name manifest.json 2>/dev/null | wc -l | tr -d ' '
}

newest_tx_dir() { # newest history transaction directory (txid sorts by time)
    ls -1dt "$SANDBOX"/data/appimage-manager/history/*/ 2>/dev/null | head -n 1
}

tx_field() { # tx_field <manifest.json> <"operation":"x"> — convenience grep
    grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -n 1
}

list_applications() { # sorted file names in the sandbox launcher dir
    ls -1 "$SANDBOX/data/applications" 2>/dev/null
}
