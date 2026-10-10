#!/usr/bin/env bash
#
# ui-test.sh — UI + on-disk integration test for AppImage Manager (GTK3).
#
# Drives the real GUI inside a PRIVATE Xvfb display (with xfwm4) using
# xdotool, captures screenshots, and — crucially — asserts the files the app
# writes are correct (claim markers, repairs, backups, transactions).
# The real user config/home is never touched: every app invocation runs with
# HOME and XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME pointed into a
# throw-away sandbox under the output directory.
#
# Usage:
#     tests/ui-test.sh [output-dir]          # default: /tmp/appmgr-uitest
#
# Environment overrides (all optional):
#     APPMGR_BIN        app binary   (default: /tmp/opencode/appimage-manager-snapshot)
#     APPMGR_FIXTURES   fixture root (default: /tmp/appmgr-fixtures)
#     APPMGR_UITEST_OUT default output dir (used when no positional arg)
#     APPMGR_DISPLAY    first Xvfb display number to try (default: 99)
#
# Exit status:
#     0 — all steps passed, or required tools are missing (test skipped)
#     1 — setup failed (no Xvfb / no window) or at least one step FAILed
#
# NOTE: the app's process comm is truncated to "appimage-manage" (15 chars),
#       so final cleanup uses `pkill -x appimage-manage` (NOT `pkill -f name`).
#
# STEP COVERAGE
#   Layer 1 (entry points):
#     step_window            main window mapped, sane geometry
#     step_rows              TreeView shows all scanned rows
#     step_actionbar         action-bar strip capture (manual review)
#     step_menu_file        文件 menu opens, 4 items, band-counted
#     step_menu_edit        编辑 menu opens, 6 items
#     step_menu_view        视图 menu opens, 9 items
#     step_menu_tools       工具 menu opens, 5 items
#     step_menu_help        帮助 menu opens, 2 items
#     step_dialogs          设置 / 修复历史 / 失效与孤儿清理 / 快捷键 / 关于 /
#                           添加扫描目录 / 健康检查 open & close
#     step_actionbar_btns   创建/修复/认领/图标/删除 — dialog or correctly
#                           insensitive for NEW / REGISTERED rows
#     step_context_menu     right-click menu renders all 8 items; 复制路径
#                           verified through the X clipboard; 创建 cancelled;
#                           打开目录 / 测试运行 never activated
#     step_filters          every filter value, row counts asserted
#     step_search           query filters rows, clearing restores them
#     step_empty_state      empty scan-dir config → guidance page + 常见位置
#   Layer 2 (on-disk truth, GUI-driven):
#     step_repair_ondisk    Version=2.0 → 1.5, comments kept, validate passes,
#                           history transaction + byte-identical backup
#     step_claim_ondisk     exactly +3 marker lines, every other byte equal,
#                           markers inside [Desktop Entry], validate passes,
#                           backup == pristine original
#     step_claim_idem       second claim attempt is a no-op (markers stay 1×,
#                           file hash unchanged)
#     step_create_icon      GUI create with a picked icon → Icon= on disk,
#                           file exists inside the sandbox icon cache
#     step_delete_ondisk    GUI delete removes the .desktop, history keeps a
#                           byte-identical undo backup
#     step_safety           real ~/.local/share/applications unchanged
#
# Shared shell helpers live in tests/ui-helpers.sh (sourced, not executed).
#
set -u
set -o pipefail

# ── paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_BIN="${APPMGR_BIN:-/tmp/opencode/appimage-manager-snapshot}"
FIXTURES_DIR="${APPMGR_FIXTURES:-/tmp/appmgr-fixtures}"
OUT_DIR="${1:-${APPMGR_UITEST_OUT:-/tmp/appmgr-uitest}}"

# ── required external tools: skip (exit 0), do not fail ─────────────────────

missing_tools=()
for tool in Xvfb xdotool import convert identify desktop-file-validate; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools+=("$tool")
    fi
done
if [ "${#missing_tools[@]}" -gt 0 ]; then
    echo "SKIP: required tool(s) not found: ${missing_tools[*]}"
    echo "      install with: sudo apt-get install xvfb xdotool imagemagick desktop-file-utils"
    exit 0
fi
HAS_XCLIP=0
command -v xclip >/dev/null 2>&1 && HAS_XCLIP=1

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
mkdir -p "$OUT_DIR"

SANDBOX="$OUT_DIR/sandbox"
PRISTINE="$OUT_DIR/pristine"
TMP_PNG="$OUT_DIR/.tmp-crop.png"
TMP_SHOT="$OUT_DIR/.tmp-main.png"

# ── shared helpers (source this early: the display probe uses to_int) ────────

# shellcheck source=tests/ui-helpers.sh
. "$SCRIPT_DIR/ui-helpers.sh"

# Baseline of the REAL user launcher directory (must not change). Captured
# before HOME/XDG are overridden below.
SAFE_HOME="${HOME:-/root}"
SAFE_APPS_DIR="$SAFE_HOME/.local/share/applications"
SAFE_APPS_BEFORE="$(ls -1 "$SAFE_APPS_DIR" 2>/dev/null | sort)"
SAFE_EXPECTED="cc-switch-handler.desktop
mimeinfo.cache
openchatcut-0.2.16-x86_64.desktop"

# ── state / results ──────────────────────────────────────────────────────────

APP_PID=""
XVFB_PID=""
XFWM_PID=""
WINDOW_ID=""
MAIN_WIN=""
WIN_FOUND=""
POPUP_FOUND=""
DISPLAY_NUM=""
CLEANUP_DONE=0
APP_SETUP=""
DIALOG_CLASS="$(basename "$APP_BIN")"

WIN_X=0
WIN_Y=0
WIN_W=0
WIN_H=0

RES_STEPS=()
RES_STATUS=()
RES_DETAIL=()
SHOTS=()
FAILURES=0

record() { # record <step> <PASS|FAIL> <detail>
    RES_STEPS+=("$1")
    RES_STATUS+=("$2")
    RES_DETAIL+=("$3")
    if [ "$2" = "FAIL" ]; then
        FAILURES=$((FAILURES + 1))
    fi
}

add_shot() { # add_shot <path> — remember only files that exist and are non-empty
    if [ -s "$1" ]; then
        SHOTS+=("$1")
        echo "  screenshot: $1"
    fi
}

# ── cleanup: always kill app + WM + Xvfb, drop the sandbox ───────────────────

# app_stop is used by cleanup, so it must be defined before the trap is set.
app_stop() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        for ((_i = 0; _i < 20; _i++)); do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$APP_PID" 2>/dev/null
    fi
    # comm is truncated to 15 chars: "appimage-manage"
    if command -v pkill >/dev/null 2>&1; then
        pkill -x appimage-manage 2>/dev/null
    fi
    APP_PID=""
    MAIN_WIN=""
    APP_SETUP=""
}

cleanup() {
    if [ "$CLEANUP_DONE" = "1" ]; then
        return
    fi
    CLEANUP_DONE=1
    echo
    echo "── cleanup ──"

    app_stop

    if [ -n "$XFWM_PID" ] && kill -0 "$XFWM_PID" 2>/dev/null; then
        kill "$XFWM_PID" 2>/dev/null
        sleep 0.2
        kill -9 "$XFWM_PID" 2>/dev/null
    fi

    if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
        kill "$XVFB_PID" 2>/dev/null
        for ((_i = 0; _i < 20; _i++)); do
            kill -0 "$XVFB_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$XVFB_PID" 2>/dev/null
    fi

    if [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi

    echo "cleanup done (app pid=${APP_PID:-none}, Xvfb pid=${XVFB_PID:-none}, display=:${DISPLAY_NUM:-?})"
    echo "sandbox removed; screenshots kept in $OUT_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── private Xvfb (+ xfwm4 for real window management) ────────────────────────

DISPLAY_BASE="$(to_int "${APPMGR_DISPLAY:-99}" 99)"
for ((n = DISPLAY_BASE; n < DISPLAY_BASE + 20; n++)); do
    if [ -e "/tmp/.X${n}-lock" ]; then
        continue
    fi
    if DISPLAY=":$n" xdotool getdisplaygeometry >/dev/null 2>&1; then
        continue
    fi
    DISPLAY_NUM="$n"
    break
done
if [ -z "$DISPLAY_NUM" ]; then
    echo "ERROR: no free X display in ${DISPLAY_BASE}..$((DISPLAY_BASE + 19))"
    exit 1
fi

echo "════════ AppImage Manager UI test ════════"
echo "binary     : $APP_BIN"
echo "fixtures   : $FIXTURES_DIR"
echo "output dir : $OUT_DIR"
echo "display    : :$DISPLAY_NUM (private Xvfb)"

Xvfb ":$DISPLAY_NUM" -screen 0 1600x1000x24 -nolisten tcp >"$OUT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!

xvfb_ready=0
for ((i = 0; i < 40; i++)); do
    if DISPLAY=":$DISPLAY_NUM" xdotool getdisplaygeometry >/dev/null 2>&1; then
        xvfb_ready=1
        break
    fi
    kill -0 "$XVFB_PID" 2>/dev/null || break
    sleep 0.25
done
if [ "$xvfb_ready" != "1" ]; then
    echo "ERROR: Xvfb failed to start on :$DISPLAY_NUM"
    sed -n '1,20p' "$OUT_DIR/xvfb.log" 2>/dev/null
    exit 1
fi
export DISPLAY=":$DISPLAY_NUM"

# A WM gives us real focus handling (windowactivate) and sane dialog
# placement. Without it GTK dialogs still work, but focus is unreliable.
if command -v xfwm4 >/dev/null 2>&1; then
    xfwm4 >"$OUT_DIR/xfwm4.log" 2>&1 &
    XFWM_PID=$!
    sleep 1.0
    if ! kill -0 "$XFWM_PID" 2>/dev/null; then
        echo "WARNING: xfwm4 exited, continuing without a window manager"
        XFWM_PID=""
    fi
fi

# ── sandboxed HOME / XDG — the safety net ────────────────────────────────────

export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$SANDBOX/cfg"
export XDG_DATA_HOME="$SANDBOX/data"
export XDG_CACHE_HOME="$SANDBOX/cache"
export XDG_RUNTIME_DIR="$SANDBOX/runtime"
export GDK_BACKEND=x11
export NO_AT_BRIDGE=1
# avoid remote activation of a real user instance through the session bus
unset DBUS_SESSION_BUS_ADDRESS

mkdir -p "$XDG_CONFIG_HOME/appimage-manager" \
         "$XDG_DATA_HOME/applications" \
         "$XDG_CACHE_HOME" \
         "$XDG_RUNTIME_DIR" \
         "$PRISTINE"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null

# ── fixed UI geometry (client-relative, calibrated on this build) ────────────
# These are only used after all keyboard-driven alternatives; each use is
# verified by its effect (a dialog opens / the file on disk changes).

COMBO_X=54;  COMBO_Y=134            # filter combo
BTN_Y=133                           # action-bar row (创建/修复/认领/图标/删除)
BTN_CREATE_X=670
BTN_REPAIR_X=760
BTN_CLAIM_X=850
BTN_ICON_X=940
BTN_DELETE_X=1030
LIST_ROW1_X=300; LIST_ROW1_Y=209    # first list row centre
EMPTY_COMMON_X=595; EMPTY_COMMON_Y=509   # empty-state "看看常见位置" button

# ── config / state preparation ───────────────────────────────────────────────

write_config() { # write_config <scan-dirs-value>
    local dirs="$1"
    mkdir -p "$XDG_CONFIG_HOME/appimage-manager"
    cat > "$XDG_CONFIG_HOME/appimage-manager/config.ini" <<EOF
[general]
configured=true
icon_size=256

[scan]
recursive=true
auto_on_startup=false
ignore_system_dirs=true
dirs=$dirs

[icons]
custom_icon_dir=false
custom_icon_dir_path=

[sync]
update_desktop_database=false
update_icon_cache=false
write_managed_marker=true
delete_icon_with_launcher=false

[repair]
confirm_destructive=true
parallel_extraction=4
batch_failure_policy=0

[backup]
retention_days=30
retention_tx=200
enabled=true
EOF
}

APPS_DIR="$XDG_DATA_HOME/applications"
CLAIM_FILE="$APPS_DIR/claim-crafted.desktop"
CLAIM_PRISTINE="$PRISTINE/claim-crafted.desktop"
REPAIR_FILE="$APPS_DIR/bad-version.desktop"
REPAIR_PRISTINE="$PRISTINE/bad-version.desktop"
GNU_FILE="$APPS_DIR/gnu_octave-9.1.0.desktop"

APPMGR_VERSION="$(sed -n 's/.*APPMGR_VERSION *= *"\([^"]*\)".*/\1/p' \
                  "$PROJECT_DIR/src/version.vala" 2>/dev/null | head -n 1)"
[ -n "$APPMGR_VERSION" ] || APPMGR_VERSION="0"

write_crafted_claim_file() { # the deliberately nasty 认领 target
    local ai="$FIXTURES_DIR/apps/Obsidian-1.5.3-x86_64.AppImage"
    cat > "$CLAIM_FILE" <<EOF
# Leading comment that must survive the claim byte-for-byte
[Desktop Entry]
Type=Application
Name = Foo Bar
Exec="$ai" %U

Icon=nonexistent-icon-name
Categories=Utility;
Actions=Something;

[Desktop Action Something]
Name=Do Something
Exec="$ai" --flag
EOF
}

write_manual_launcher() { # fallback launcher for the delete step
    local ai="$FIXTURES_DIR/apps/GNU_Octave-9.1.0.AppImage"
    cat > "$GNU_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=GNU_Octave
Exec="$ai" %U
TryExec=$ai
Terminal=false
StartupNotify=true
StartupWMClass=GNU_Octave
Categories=Utility;
X-AppImage-Manager=true
X-AppImage-Manager-Path=$ai
X-AppImage-Manager-Version=$APPMGR_VERSION
EOF
}

prepare_state() { # prepare_state <tag>
    case "$1" in
        populated|menus)
            rm -f "$APPS_DIR"/*.desktop
            write_config "$FIXTURES_DIR/apps"
            ;;
        perfect|context)
            rm -f "$APPS_DIR"/*.desktop
            cp "$FIXTURES_DIR/desktops/perfect.desktop" "$APPS_DIR/" 2>/dev/null || true
            write_config "$FIXTURES_DIR/apps"
            ;;
        repair)
            rm -f "$APPS_DIR"/*.desktop
            cp "$FIXTURES_DIR/desktops/bad-version.desktop" "$REPAIR_FILE" 2>/dev/null || true
            # keep a comment in front: the repair path must not eat it
            if [ -f "$REPAIR_FILE" ]; then
                { echo "# keep me: comment line one"
                  echo "# keep me too"
                  cat "$REPAIR_FILE"
                } > "$REPAIR_FILE.tmp" && mv "$REPAIR_FILE.tmp" "$REPAIR_FILE"
                cp "$REPAIR_FILE" "$REPAIR_PRISTINE"
            fi
            write_config "$FIXTURES_DIR/apps"
            ;;
        claim|filters|search)
            rm -f "$APPS_DIR"/*.desktop
            cp "$FIXTURES_DIR/desktops/external.desktop" "$APPS_DIR/" 2>/dev/null || true
            cp "$FIXTURES_DIR/desktops/claim-target.desktop" "$APPS_DIR/" 2>/dev/null || true
            write_crafted_claim_file
            cp "$CLAIM_FILE" "$CLAIM_PRISTINE"
            write_config "$FIXTURES_DIR/apps"
            ;;
        create)
            rm -f "$APPS_DIR"/*.desktop
            rm -f "$XDG_DATA_HOME"/icons/hicolor/*/apps/gnu_octave-* 2>/dev/null || true
            write_config "$FIXTURES_DIR/apps"
            ;;
        delete)
            # keep the launcher created by the previous step; if it is missing
            # (earlier step failed), write a valid one by hand so this step
            # still exercises the delete path independently.
            if [ ! -f "$GNU_FILE" ]; then
                write_manual_launcher
            fi
            write_config "$FIXTURES_DIR/apps"
            ;;
        empty)
            write_config ""
            ;;
        *)
            write_config "$FIXTURES_DIR/apps"
            ;;
    esac
    mkdir -p "$APPS_DIR"
}

# ── app lifecycle ────────────────────────────────────────────────────────────

refresh_geometry() { # sets WIN_X/WIN_Y/WIN_W/WIN_H from MAIN_WIN
    local out
    out="$(xdotool getwindowgeometry --shell "$MAIN_WIN" 2>/dev/null)" || {
        WIN_W=0; WIN_H=0
        return 1
    }
    local WINDOW X Y WIDTH HEIGHT SCREEN
    eval "$out"
    WIN_X="${X:-0}"; WIN_Y="${Y:-0}"
    WIN_W="${WIDTH:-0}"; WIN_H="${HEIGHT:-0}"
    [ "$WIN_W" -gt 0 ] && [ "$WIN_H" -gt 0 ]
}

dismiss_startup_dialogs() { # crash-recovery prompt if a stale journal exists
    # The crash-recovery MessageDialog has no window title, so look for any
    # dialog-class window right after startup; Return activates its default
    # response ("保留现状并归档", harmless: archives the stale journal).
    if [ "$(count_app_dialogs)" -ge 1 ]; then
        echo "  note: startup dialog detected — dismissing with its default"
        local id; id="$(find_app_popup 80)"
        if [ -n "$id" ]; then send_key "$id" Return; else send_key "$MAIN_WIN" Return; fi
        local gone=0
        for ((_i = 0; _i < 16; _i++)); do
            [ "$(count_app_dialogs)" -eq 0 ] && { gone=1; break; }
            sleep 0.25
        done
        if [ "$gone" != "1" ]; then
            id="$(find_app_popup 80)"
            [ -n "$id" ] && send_key "$id" Escape
            sleep 0.5
        fi
    fi
}

display_alive() { # is the X display still answering?
    xdotool getdisplaygeometry >/dev/null 2>&1
}

respawn_display() { # replace a dead Xvfb + WM with a fresh pair
    # A concurrent process on this machine may kill our Xvfb (this has burned
    # real runs); if that happens we bring up a fresh display and continue
    # with the remaining steps instead of cascading failures.
    echo "  warning: X display :$DISPLAY_NUM died — starting a fresh one" >&2
    [ -n "$XFWM_PID" ] && kill "$XFWM_PID" 2>/dev/null
    [ -n "$XVFB_PID" ] && kill -9 "$XVFB_PID" 2>/dev/null
    XFWM_PID=""; XVFB_PID=""
    local n
    DISPLAY_NUM=""
    for ((n = DISPLAY_BASE; n < DISPLAY_BASE + 60; n++)); do
        [ -e "/tmp/.X${n}-lock" ] && continue
        DISPLAY=":$n" xdotool getdisplaygeometry >/dev/null 2>&1 && continue
        DISPLAY_NUM="$n"
        break
    done
    [ -z "$DISPLAY_NUM" ] && return 1
    Xvfb ":$DISPLAY_NUM" -screen 0 1600x1000x24 -nolisten tcp >>"$OUT_DIR/xvfb.log" 2>&1 &
    XVFB_PID=$!
    local i
    for ((i = 0; i < 40; i++)); do
        DISPLAY=":$DISPLAY_NUM" xdotool getdisplaygeometry >/dev/null 2>&1 && break
        sleep 0.25
    done
    export DISPLAY=":$DISPLAY_NUM"
    if command -v xfwm4 >/dev/null 2>&1; then
        xfwm4 >>"$OUT_DIR/xfwm4.log" 2>&1 &
        XFWM_PID=$!
        sleep 1.0
    fi
    display_alive
}

app_start() {
    local attempt
    for attempt in 1 2 3; do
        if ! display_alive; then
            respawn_display || return 1
        fi
        APP_PID=""
        MAIN_WIN=""
        ( cd "$PROJECT_DIR" && exec "$APP_BIN" ) >"$OUT_DIR/app.log" 2>&1 &
        APP_PID=$!
        local i id
        for ((i = 0; i < 80; i++)); do  # up to ~20 s per attempt
            kill -0 "$APP_PID" 2>/dev/null || break
            id="$(find_win_by_name '^AppImage Manager$')"
            if [ -n "$id" ]; then
                MAIN_WIN="$id"
                break
            fi
            sleep 0.25
        done
        if [ -z "$MAIN_WIN" ]; then
            app_stop
            [ "$attempt" -lt 3 ] && sleep 2
            continue
        fi
        sleep 1.0   # let the initial scan settle
        dismiss_startup_dialogs
        refresh_geometry || true
        return 0
    done
    return 1
}

ensure_app() { # ensure_app <tag> — (re)start with the right on-disk state
    local tag="$1"
    if [ "$tag" = "keep" ]; then
        if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null \
           && [ -n "$MAIN_WIN" ]; then
            refresh_geometry || true
            return 0
        fi
        app_stop
        app_start
        return $?
    fi

    if [ "$APP_SETUP" = "$tag" ] && [ -n "$APP_PID" ] \
       && kill -0 "$APP_PID" 2>/dev/null && [ -n "$MAIN_WIN" ]; then
        refresh_geometry || true
        return 0
    fi

    app_stop
    prepare_state "$tag"
    app_start || return 1
    APP_SETUP="$tag"
    return 0
}

app_alive() { # app_alive — the process exists AND the main window is mapped
    [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null \
        && [ -n "$(find_win_by_name '^AppImage Manager$')" ]
}

wait_rows() { # wait_rows <expected> [tries] — poll until the list shows N rows
    local want="$1" tries="${2:-20}" i=0 n=-1
    while [ "$i" -lt "$tries" ]; do
        grab_main "$TMP_SHOT" >/dev/null 2>&1 || true
        n="$(count_list_rows "$TMP_SHOT")"
        [ "$n" = "$want" ] && { printf '%s' "$n"; return 0; }
        sleep 0.4
        i=$((i + 1))
    done
    printf '%s' "$n"
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP IMPLEMENTATIONS
# ═════════════════════════════════════════════════════════════════════════════

step_window() {
    echo
    echo "── step_window: main window exists and is mapped ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_window FAIL "no visible 'AppImage Manager' window"
        echo "app.log tail:"
        tail -n 20 "$OUT_DIR/app.log" 2>/dev/null | sed 's/^/  /'
        return
    fi
    if ! refresh_geometry; then
        record step_window FAIL "window $MAIN_WIN has no usable geometry"
        return
    fi

    echo "  window id : $MAIN_WIN"
    echo "  geometry  : ${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y} (display :$DISPLAY_NUM)"

    local shot="$OUT_DIR/01_step_window.png"
    if grab_main "$shot"; then
        add_shot "$shot"
        if [ "$WIN_W" -ge 1000 ] && [ "$WIN_H" -ge 600 ]; then
            record step_window PASS "mapped ${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y}, display :$DISPLAY_NUM"
        else
            record step_window FAIL "window too small: ${WIN_W}x${WIN_H} (crops are calibrated for ≥1000x600)"
        fi
    else
        record step_window FAIL "window mapped but screenshot failed (see import.log)"
    fi
}

step_rows() {
    echo
    echo "── step_rows: TreeView contains the scanned rows ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_rows FAIL "window unavailable"
        return
    fi
    refresh_geometry || true

    local want rows
    want="$(scan_appimages "$FIXTURES_DIR/apps" | grep -c .)"
    [ "$want" -gt 0 ] || want=1
    rows="$(wait_rows "$want" 30)"

    local full="$OUT_DIR/02_step_rows_full.png"
    grab_main "$full" >/dev/null 2>&1 || true
    local area="$OUT_DIR/02_step_rows_listarea.png"
    local top=170 h=220
    [ "$h" -gt "$((WIN_H - top - 20))" ] && h=$((WIN_H - top - 20))
    crop_img "$full" "$area" "${WIN_W}x${h}+0+${top}" >/dev/null 2>&1 || true
    add_shot "$full"
    add_shot "$area"

    local colors
    colors="$(unique_colors "$area")"
    echo "  visible rows (icon-column bands): $rows (expected $want)"
    echo "  list-area unique colours: $colors"

    if [ "$rows" = "$want" ] && [ "$colors" -gt 1 ]; then
        record step_rows PASS "list shows $rows/$want rows, area not flat (colours=$colors)"
    elif [ "$colors" -le 1 ]; then
        record step_rows FAIL "list area is a flat colour — no rows rendered?"
    else
        record step_rows FAIL "visible row count $rows != expected $want"
    fi
}

step_actionbar() {
    echo
    echo "── step_actionbar: capture action-bar region for manual review ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_actionbar FAIL "window unavailable"
        return
    fi

    local full="$OUT_DIR/03_step_actionbar_full.png"
    if ! grab_main "$full"; then
        record step_actionbar FAIL "screenshot failed (see import.log)"
        return
    fi
    add_shot "$full"

    local top=100 h=80
    local max_h=$((WIN_H - top - 10))
    [ "$h" -gt "$max_h" ] && h="$max_h"
    [ "$h" -lt 20 ] && h=20

    local strip="$OUT_DIR/03_step_actionbar_region.png"
    if ! crop_img "$full" "$strip" "${WIN_W}x${h}+0+${top}"; then
        record step_actionbar FAIL "crop failed"
        return
    fi
    add_shot "$strip"

    local bottom="$OUT_DIR/03_step_actionbar_bottom.png"
    local btop=$((WIN_H - 110))
    [ "$btop" -lt 0 ] && btop=0
    crop_img "$full" "$bottom" "${WIN_W}x100+0+${btop}" >/dev/null 2>&1 || true
    add_shot "$bottom"

    local colors
    colors="$(unique_colors "$strip")"
    echo "  region y=$top h=$h unique-colours=$colors"
    record step_actionbar PASS "captured action-bar region (unique colours=$colors) — manual review"
}

step_menu_file() {
    echo
    echo "── step_menu_file: 文件 menu opens with 4 items ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_menu_file FAIL "window unavailable"
        return
    fi
    grab_root "$OUT_DIR/04_menu_file_closed.png" >/dev/null 2>&1 || true
    open_menu "alt+f"
    if ! wait_app_popup 61 12; then
        record step_menu_file FAIL "文件 menu did not open"
        return
    fi
    local pop="$POPUP_FOUND"
    park_mouse
    grab_win "$pop" "$OUT_DIR/04_menu_file.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/04_menu_file.png"
    local bands; bands="$(count_popup_bands "$OUT_DIR/04_menu_file.png")"
    send_key "$MAIN_WIN" Escape
    sleep 0.4
    if [ "$bands" = "4" ]; then
        record step_menu_file PASS "menu opened, 4 items (添加扫描目录/打开启动器目录/打开配置目录/退出)"
    else
        record step_menu_file FAIL "menu item count $bands != 4"
    fi
}

step_menu_edit() {
    echo
    echo "── step_menu_edit: 编辑 menu opens with 6 items ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_menu_edit FAIL "window unavailable"
        return
    fi
    open_menu "alt+e"
    if ! wait_app_popup 61 12; then
        record step_menu_edit FAIL "编辑 menu did not open"
        return
    fi
    park_mouse
    grab_win "$POPUP_FOUND" "$OUT_DIR/05_menu_edit.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/05_menu_edit.png"
    local bands; bands="$(count_popup_bands "$OUT_DIR/05_menu_edit.png")"
    send_key "$MAIN_WIN" Escape
    sleep 0.4
    if [ "$bands" = "6" ]; then
        record step_menu_edit PASS "menu opened, 6 items (全选/取消选择/创建/修复/认领/删除)"
    else
        record step_menu_edit FAIL "menu item count $bands != 6"
    fi
}

step_menu_view() {
    echo
    echo "── step_menu_view: 视图 menu opens with 9 items ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_menu_view FAIL "window unavailable"
        return
    fi
    open_menu "alt+v"
    if ! wait_app_popup 61 12; then
        record step_menu_view FAIL "视图 menu did not open"
        return
    fi
    park_mouse
    grab_win "$POPUP_FOUND" "$OUT_DIR/06_menu_view.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/06_menu_view.png"
    local bands; bands="$(count_popup_bands "$OUT_DIR/06_menu_view.png")"
    send_key "$MAIN_WIN" Escape
    sleep 0.4
    if [ "$bands" = "9" ]; then
        record step_menu_view PASS "menu opened, 9 items (2×重新扫描 + 6 filters + 全屏)"
    else
        record step_menu_view FAIL "menu item count $bands != 9"
    fi
}

step_menu_tools() {
    echo
    echo "── step_menu_tools: 工具 menu opens with 5 items ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_menu_tools FAIL "window unavailable"
        return
    fi
    open_menu "alt+t"
    if ! wait_app_popup 61 12; then
        record step_menu_tools FAIL "工具 menu did not open"
        return
    fi
    park_mouse
    grab_win "$POPUP_FOUND" "$OUT_DIR/07_menu_tools.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/07_menu_tools.png"
    local bands; bands="$(count_popup_bands "$OUT_DIR/07_menu_tools.png")"
    send_key "$MAIN_WIN" Escape
    sleep 0.4
    if [ "$bands" = "5" ]; then
        record step_menu_tools PASS "menu opened, 5 items (健康检查/修复历史/清理/提取元数据/设置)"
    else
        record step_menu_tools FAIL "menu item count $bands != 5"
    fi
}

step_menu_help() {
    echo
    echo "── step_menu_help: 帮助 menu opens with 2 items ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_menu_help FAIL "window unavailable"
        return
    fi
    open_menu "alt+h"
    if ! wait_app_popup 61 12; then
        record step_menu_help FAIL "帮助 menu did not open"
        return
    fi
    park_mouse
    grab_win "$POPUP_FOUND" "$OUT_DIR/08_menu_help.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/08_menu_help.png"
    local bands; bands="$(count_popup_bands "$OUT_DIR/08_menu_help.png")"
    send_key "$MAIN_WIN" Escape
    sleep 0.4
    if [ "$bands" = "2" ]; then
        record step_menu_help PASS "menu opened, 2 items (键盘快捷键/关于)"
    else
        record step_menu_help FAIL "menu item count $bands != 2"
    fi
}

dlg_check() { # dlg_check <title-regex> <label> <screenshot> [tries]
    # Waits for a titled dialog, screenshots it, closes it with Escape and
    # asserts it went away. Sets DLG_RESULT in the CALLER's shell (a command
    # substitution would run in a subshell and lose SHOTS/DLG_RESULT).
    local pat="$1" label="$2" shot="$3" tries="${4:-24}"
    DLG_RESULT=""
    if ! wait_win_by_name "$pat" "$tries"; then
        # let a slow dialog (cold gtk file chooser) have one more chance
        sleep 1.5
        if ! wait_win_by_name "$pat" 8; then
            DLG_RESULT="FAIL($label did not open)"
            # if something odd is mapped in its place, capture + dismiss it
            local stray; stray="$(find_app_popup 80)"
            if [ -n "$stray" ]; then
                grab_root "$OUT_DIR/${shot%.png}_stray.png" >/dev/null 2>&1 || true
                add_shot "$OUT_DIR/${shot%.png}_stray.png"
                send_key "$stray" Escape
                sleep 0.5
            fi
            return 1
        fi
    fi
    local id="$WIN_FOUND"
    park_mouse
    grab_root "$OUT_DIR/$shot" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/$shot"
    send_key "$id" Escape
    if wait_win_gone_by_name "$pat" 16; then
        DLG_RESULT="OK"
    else
        DLG_RESULT="FAIL($label did not close)"
        send_key "$id" Escape
    fi
    return 0
}

step_dialogs() {
    echo
    echo "── step_dialogs: self-contained dialogs open and close ──"
    if ! ensure_app populated || [ -z "$MAIN_WIN" ]; then
        record step_dialogs FAIL "window unavailable"
        return
    fi

    local r_settings r_history r_cleanup r_shortcuts r_about r_adddir r_health
    local detail=""

    # 设置（工具第 5 项）
    menu_pick "alt+t" 4
    dlg_check '^设置$' '设置' '09_dialog_settings.png'
    r_settings="$DLG_RESULT"

    # 修复历史（工具第 2 项）
    menu_pick "alt+t" 1
    dlg_check '^操作历史$' '修复历史' '09_dialog_history.png'
    r_history="$DLG_RESULT"

    # 失效与孤儿清理（工具第 3 项）— only open/cancel, never run the cleanup
    menu_pick "alt+t" 2
    dlg_check '^清理$' '失效与孤儿清理' '09_dialog_cleanup.png'
    r_cleanup="$DLG_RESULT"

    # 键盘快捷键（帮助第 1 项）— MessageDialog has no window title, so it is
    # detected through the application's dialog WM_CLASS.
    menu_pick "alt+h" 0
    sleep 0.8
    if [ "$(count_app_dialogs)" -ge 1 ]; then
        park_mouse
        grab_root "$OUT_DIR/09_dialog_shortcuts.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/09_dialog_shortcuts.png"
        local sid; sid="$(find_app_popup 100)"
        [ -n "$sid" ] && send_key "$sid" Escape || send_key "$MAIN_WIN" Escape
        local gone=0
        for ((_i = 0; _i < 16; _i++)); do
            [ "$(count_app_dialogs)" -eq 0 ] && { gone=1; break; }
            sleep 0.25
        done
        if [ "$gone" = "1" ]; then r_shortcuts="OK"; else r_shortcuts="FAIL(stayed open)"; fi
    else
        r_shortcuts="FAIL(did not open)"
    fi

    # 关于（帮助第 2 项）
    menu_pick "alt+h" 1
    dlg_check '^About AppImage Manager$' '关于' '09_dialog_about.png'
    r_about="$DLG_RESULT"

    # 添加扫描目录（文件第 1 项）— cancel the chooser. A cold HOME can make
    # the GtkFileChooser take several seconds to build its places sidebar,
    # so this one gets a long timeout.
    menu_pick "alt+f" 0
    dlg_check '^选择要扫描的目录$' '添加扫描目录' '09_dialog_adddir.png' 80
    if [ "$DLG_RESULT" != "OK" ]; then
        # one more attempt: the Return that should activate the menu item can
        # be swallowed if the menu was still settling
        menu_pick "alt+f" 0
        dlg_check '^选择要扫描的目录$' '添加扫描目录' '09_dialog_adddir.png' 40
    fi
    r_adddir="$DLG_RESULT"

    # 健康检查（工具第 1 项）— no dialog; it switches the filter to 可优化
    # and re-checks problem rows. With no matched entries this yields 0 rows.
    menu_pick "alt+t" 0
    sleep 1.0
    local dlgs; dlgs="$(count_app_dialogs)"
    local rows; rows="$(wait_rows 0 12)"
    park_mouse
    grab_main "$OUT_DIR/09_health_infobar.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/09_health_infobar.png"
    if [ -z "$(find_win_by_name '^设置$')" ] && [ "$dlgs" = "0" ] && [ "$rows" = "0" ]; then
        r_health="OK"
    else
        r_health="FAIL(dialogs=$dlgs rows=$rows)"
    fi

    detail="设置=$r_settings 历史=$r_history 清理=$r_cleanup 快捷键=$r_shortcuts 关于=$r_about 添加目录=$r_adddir 健康检查=$r_health"
    case "$detail" in
        *FAIL*) record step_dialogs FAIL "$detail" ;;
        *)      record step_dialogs PASS "$detail" ;;
    esac
}

click_until_dialog() { # click_until_dialog <dlg-regex> <x> <y> [alts...]
    # Clicks are measured coordinates; retry a few nearby spots and verify the
    # effect (dialog appeared) before giving up.
    local pat="$1" x="$2" y="$3"; shift 3
    local off
    click_main "$x" "$y"
    for off in "$@"; do
        if wait_win_by_name "$pat" 10; then return 0; fi
        click_main "$off" "$y"
    done
    wait_win_by_name "$pat" 6
}

step_actionbar_btns() {
    echo
    echo "── step_actionbar_btns: action-bar buttons open a dialog or are correctly insensitive ──"
    if ! ensure_app perfect || [ -z "$MAIN_WIN" ]; then
        record step_actionbar_btns FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    # ── A NEW row (Bitwarden): 创建 opens, 修复/删除 insensitive, 认领 manual,
    #    图标 triggers a (failing, harmless) extraction + rescan ─────────────
    search_for "Bitwarden"
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6

    if click_until_dialog '^创建启动器 — Bitwarden$' "$BTN_CREATE_X" "$BTN_Y" $((BTN_CREATE_X - 9)) $((BTN_CREATE_X + 9)); then
        detail="$detail 创建(NEW)=OK"
        park_mouse
        grab_root "$OUT_DIR/10_btn_create.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/10_btn_create.png"
        send_key "$WIN_FOUND" Escape
        wait_win_gone_by_name '^创建启动器 — Bitwarden$' 16 >/dev/null 2>&1 || true
    else
        detail="$detail 创建(NEW)=FAIL(no dialog)"
        ok=0
    fi

    # Closing the create dialog cancels the batch and triggers a rescan, which
    # clears the checkboxes — re-check the row so the following assertions
    # really have a target (and are not trivially "insensitive").
    sleep 0.6
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.8

    # 修复 on a NEW row has no target problems → button is insensitive.
    click_main "$BTN_REPAIR_X" "$BTN_Y"
    sleep 1.0
    if [ "$(count_app_dialogs)" -eq 0 ]; then
        detail="$detail 修复(NEW)=insensitive-OK"
    else
        detail="$detail 修复(NEW)=FAIL(unexpected dialog)"
        ok=0
        local off; for off in $(app_window_ids); do
            [ "$off" = "$MAIN_WIN" ] && continue
            send_key "$off" Escape
        done
    fi

    # 删除 on a NEW row has no launcher → insensitive.
    click_main "$BTN_DELETE_X" "$BTN_Y"
    sleep 1.0
    if [ "$(count_app_dialogs)" -eq 0 ]; then
        detail="$detail 删除(NEW)=insensitive-OK"
    else
        detail="$detail 删除(NEW)=FAIL(unexpected dialog)"
        ok=0
    fi

    # 认领 with no EXTERNAL target falls back to the manual claim dialog.
    click_main "$BTN_CLAIM_X" "$BTN_Y"
    if wait_win_by_name '^认领启动器$' 20; then
        detail="$detail 认领(NEW)=manual-dialog-OK"
        park_mouse
        grab_root "$OUT_DIR/10_btn_claim.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/10_btn_claim.png"
        send_key "$WIN_FOUND" Escape
        wait_win_gone_by_name '^认领启动器$' 16 >/dev/null 2>&1 || true
    else
        detail="$detail 认领(NEW)=FAIL(no dialog)"
        ok=0
    fi

    # 图标 on a row without a cached icon is sensitive; the fake AppImage
    # extraction fails fast, then a rescan clears the checkboxes. The visible
    # proof is the checkbox flipping back within the timeout.
    search_for "Bitwarden"
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6
    park_mouse
    grab_main "$OUT_DIR/10_icon_before.png" >/dev/null 2>&1 || true
    local sig_before; sig_before="$(region_sig "$OUT_DIR/10_icon_before.png" '28x28+3+194')"
    click_main "$BTN_ICON_X" "$BTN_Y"
    local flipped=0 sig_now
    for ((_i = 0; _i < 40; _i++)); do
        sleep 0.4
        park_mouse
        grab_main "$OUT_DIR/10_icon_after.png" >/dev/null 2>&1 || true
        sig_now="$(region_sig "$OUT_DIR/10_icon_after.png" '28x28+3+194')"
        if [ -n "$sig_now" ] && [ "$sig_now" != "$sig_before" ]; then
            flipped=1
            break
        fi
    done
    add_shot "$OUT_DIR/10_icon_after.png"
    if [ "$flipped" = "1" ]; then
        detail="$detail 图标(no-icon)=ran+rescan-OK"
    else
        detail="$detail 图标(no-icon)=FAIL(no rescan observed)"
        ok=0
    fi

    # ── REGISTERED row (perfect.desktop → Obsidian): 创建/修复 insensitive,
    #    删除 opens the confirm dialog (cancelled) ───────────────────────────
    search_for "Obsidian"
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6

    click_main "$BTN_CREATE_X" "$BTN_Y"
    sleep 1.0
    if [ "$(count_app_dialogs)" -eq 0 ]; then
        detail="$detail 创建(已创建)=insensitive-OK"
    else
        detail="$detail 创建(已创建)=FAIL(unexpected dialog)"
        ok=0
    fi

    click_main "$BTN_REPAIR_X" "$BTN_Y"
    sleep 1.0
    if [ "$(count_app_dialogs)" -eq 0 ]; then
        detail="$detail 修复(healthy)=insensitive-OK"
    else
        detail="$detail 修复(healthy)=FAIL(unexpected dialog)"
        ok=0
    fi

    click_main "$BTN_DELETE_X" "$BTN_Y"
    if wait_app_popup 61 20; then
        detail="$detail 删除(已创建)=confirm-OK"
        park_mouse
        grab_root "$OUT_DIR/10_btn_delete_cancel.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/10_btn_delete_cancel.png"
        send_key "$POPUP_FOUND" Escape
        for ((_i = 0; _i < 16; _i++)); do
            [ "$(count_app_dialogs)" -eq 0 ] && break
            sleep 0.25
        done
        if [ -f "$APPS_DIR/perfect.desktop" ]; then
            detail="$detail+file-intact-OK"
        else
            detail="$detail+FAIL(file deleted)"
            ok=0
        fi
    else
        detail="$detail 删除(已创建)=FAIL(no confirm dialog)"
        ok=0
    fi

    if ! app_alive; then
        detail="$detail APP-DEAD"
        ok=0
    fi

    if [ "$ok" = "1" ]; then
        record step_actionbar_btns PASS "$detail"
    else
        record step_actionbar_btns FAIL "$detail"
    fi
}

step_context_menu() {
    echo
    echo "── step_context_menu: right-click menu renders with all 8 items ──"
    if ! ensure_app context || [ -z "$MAIN_WIN" ]; then
        record step_context_menu FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    # REGISTERED row: menu renders, then 复制路径 (an entry that writes to the
    # clipboard, verifiable from the shell). Items are clicked through the
    # popup's own geometry (window-relative), with a keyboard fallback.
    search_for "Obsidian"
    xdotool mousemove --sync --window "$MAIN_WIN" "$LIST_ROW1_X" "$LIST_ROW1_Y"
    sleep 0.3
    xdotool click 3
    sleep 0.6
    park_mouse
    if wait_app_popup 61 16; then
        local pop; pop="$POPUP_FOUND"
        grab_win "$pop" "$OUT_DIR/11_ctxmenu.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/11_ctxmenu.png"
        local bands; bands="$(count_popup_bands "$OUT_DIR/11_ctxmenu.png")"
        if [ "$bands" = "8" ]; then
            detail="ctx-menu=8-items-OK"
        else
            detail="ctx-menu=FAIL($bands items)"
            ok=0
        fi
        # primary: End selects the last entry (复制路径), Return activates it
        focus_win "$pop"
        xdotool key --clearmodifiers End; sleep 0.3
        xdotool key --clearmodifiers Return
        sleep 1.0
        local clip=""
        [ "$HAS_XCLIP" = "1" ] && clip="$(xclip -o -selection clipboard 2>/dev/null)"
        if [ "$HAS_XCLIP" = "1" ] \
           && [ "$clip" != "$FIXTURES_DIR/apps/Obsidian-1.5.3-x86_64.AppImage" ]; then
            # fallback: clear any stray dialog, reopen the menu and click the
            # last row by geometry (rows are ~27 px apart)
            for ((_i = 0; _i < 3; _i++)); do
                [ "$(count_app_dialogs)" -eq 0 ] && break
                xdotool key --clearmodifiers Escape; sleep 0.4
            done
            xdotool mousemove --sync --window "$MAIN_WIN" "$LIST_ROW1_X" "$LIST_ROW1_Y"
            sleep 0.3
            xdotool click 3
            sleep 0.6
            park_mouse
            if wait_app_popup 61 16; then
                local p2; p2="$POPUP_FOUND"
                local w2 h2
                w2="$(win_w "$p2")"; h2="$(win_h "$p2")"
                click_win "$p2" $((w2 / 2)) $((h2 - 37))
                sleep 1.0
                clip="$(xclip -o -selection clipboard 2>/dev/null)"
            fi
        fi
        if [ "$HAS_XCLIP" = "1" ]; then
            if [ "$clip" = "$FIXTURES_DIR/apps/Obsidian-1.5.3-x86_64.AppImage" ]; then
                detail="$detail 复制路径=clipboard-OK"
            else
                detail="$detail 复制路径=FAIL(clipboard='$clip')"
                ok=0
            fi
        else
            detail="$detail 复制路径=SKIP(xclip missing)"
        fi
    else
        detail="ctx-menu=FAIL(no popup)"
        ok=0
        xdotool key --clearmodifiers Escape
    fi

    # NEW row: 创建启动器 is the first item; open it and cancel. 打开目录 and
    # 测试运行 are deliberately never activated.
    search_for "Bitwarden"
    xdotool mousemove --sync --window "$MAIN_WIN" "$LIST_ROW1_X" "$LIST_ROW1_Y"
    sleep 0.3
    xdotool click 3
    sleep 0.6
    park_mouse
    if wait_app_popup 61 16; then
        local pop2; pop2="$POPUP_FOUND"
        local mw2
        mw2="$(win_w "$pop2")"
        click_win "$pop2" $((mw2 / 2)) 33
        if ! wait_win_by_name '^创建启动器 — Bitwarden$' 20; then
            # fallback: keyboard Home + Return (first sensitive item)
            focus_win "$pop2"
            xdotool key --clearmodifiers Home; sleep 0.3
            xdotool key --clearmodifiers Return
            wait_win_by_name '^创建启动器 — Bitwarden$' 12
        fi
        if [ -n "$WIN_FOUND" ]; then
            detail="$detail ctx-创建=OK"
            park_mouse
            grab_root "$OUT_DIR/11_ctx_create.png" >/dev/null 2>&1 || true
            add_shot "$OUT_DIR/11_ctx_create.png"
            send_key "$WIN_FOUND" Escape
            wait_win_gone_by_name '^创建启动器 — Bitwarden$' 16 >/dev/null 2>&1 || true
        else
            detail="$detail ctx-创建=FAIL"
            ok=0
            xdotool key --clearmodifiers Escape
        fi
    else
        detail="$detail ctx-create=FAIL(no popup)"
        ok=0
        xdotool key --clearmodifiers Escape
    fi

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_context_menu PASS "$detail"
    else
        record step_context_menu FAIL "$detail"
    fi
}

step_repair_ondisk() {
    echo
    echo "── step_repair_ondisk: 修复 writes Version=1.5, keeps comments, makes a backup ──"
    if ! ensure_app repair || [ -z "$MAIN_WIN" ]; then
        record step_repair_ondisk FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    # Sanity of the input fixture
    if grep -q '^Version=2\.0$' "$FIXTURES_DIR/desktops/bad-version.desktop" 2>/dev/null; then
        detail="pristine-Version=2.0-OK"
    else
        detail="pristine-Version=FAIL"
        ok=0
    fi
    grep -q '^Version=2\.0$' "$REPAIR_FILE" || { detail="$detail input-Version=FAIL"; ok=0; }

    local tx_before; tx_before="$(count_manifests)"

    search_for "Bad Version"
    local rows; rows="$(wait_rows 1 16)"
    [ "$rows" = "1" ] || { detail="$detail row-count=FAIL($rows)"; ok=0; }
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6

    menu_pick "alt+e" 3
    if wait_win_by_name '^修复 Obsidian$' 24; then
        detail="$detail repair-dialog=OK"
        park_mouse
        grab_root "$OUT_DIR/12_repair_dialog.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/12_repair_dialog.png"
        # 保守 mode is the dialog default (verified by the disk diff below);
        # confirm via the measured button, every alternative verified by
        # the dialog actually closing.
        local rid="$WIN_FOUND" clicked=0 off
        for off in 367 360 374 355 380; do
            click_win "$rid" "$off" 733
            for ((_i = 0; _i < 12; _i++)); do
                sleep 0.4
                if [ -z "$(find_win_by_name '^修复 Obsidian$')" ]; then clicked=1; break; fi
            done
            [ "$clicked" = "1" ] && break
        done
        if [ "$clicked" != "1" ]; then
            detail="$detail apply-click=FAIL"
            ok=0
            send_key "$rid" Escape
        else
            detail="$detail apply-click=OK"
            if wait_win_by_name '^修复结果$' 20; then
                park_mouse
                grab_root "$OUT_DIR/12_repair_result.png" >/dev/null 2>&1 || true
                add_shot "$OUT_DIR/12_repair_result.png"
                local rid2="$WIN_FOUND"
                send_key "$rid2" Escape
                wait_win_gone_by_name '^修复结果$' 16 >/dev/null 2>&1 || true
            fi
        fi
    else
        detail="$detail repair-dialog=FAIL"
        ok=0
    fi

    # ── on-disk assertions ────────────────────────────────────────────────
    if grep -q '^Version=1\.5$' "$REPAIR_FILE" 2>/dev/null; then
        detail="$detail Version=1.5-OK"
    else
        detail="$detail Version=1.5-FAIL"
        ok=0
    fi
    local comments
    comments="$(grep -c '^# keep me' "$REPAIR_FILE" 2>/dev/null)"
    if [ "$comments" = "2" ]; then
        detail="$detail comments-kept-OK"
    else
        detail="$detail comments-kept-FAIL($comments)"
        ok=0
    fi
    if desktop-file-validate "$REPAIR_FILE" >/dev/null 2>&1; then
        detail="$detail validate-OK"
    else
        detail="$detail validate-FAIL"
        ok=0
    fi

    local tx_after; tx_after="$(count_manifests)"
    local txdir; txdir="$(newest_tx_dir)"
    local manifest="$txdir/manifest.json"
    if [ "$tx_after" -eq $((tx_before + 1)) ] && grep -q '"operation":"repair"' "$manifest" 2>/dev/null; then
        detail="$detail tx+1-OK"
    else
        detail="$detail tx=FAIL(before=$tx_before after=$tx_after)"
        ok=0
    fi
    local backup="$txdir/file/bad-version.desktop"
    if [ -f "$backup" ] && cmp -s "$backup" "$REPAIR_PRISTINE"; then
        detail="$detail backup-matches-pristine-OK"
    else
        detail="$detail backup=FAIL"
        ok=0
    fi

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_repair_ondisk PASS "$detail"
    else
        record step_repair_ondisk FAIL "$detail"
    fi
}

step_claim_ondisk() {
    echo
    echo "── step_claim_ondisk: 认领 appends exactly 3 markers, keeps every other byte ──"
    if ! ensure_app claim || [ -z "$MAIN_WIN" ]; then
        record step_claim_ondisk FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    local tx_before; tx_before="$(count_manifests)"

    search_for "Obsidian"
    local rows; rows="$(wait_rows 1 16)"
    [ "$rows" = "1" ] || { detail="row-count=FAIL($rows)"; ok=0; }
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6

    menu_pick "alt+e" 4
    if wait_win_by_name '^认领 Obsidian$' 24; then
        detail="claim-dialog=OK"
        park_mouse
        grab_root "$OUT_DIR/13_claim_dialog.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/13_claim_dialog.png"
        local cid="$WIN_FOUND"
        send_key "$cid" Return      # default response = 认领
        if wait_win_by_name '^认领结果$' 24; then
            park_mouse
            grab_root "$OUT_DIR/13_claim_result.png" >/dev/null 2>&1 || true
            add_shot "$OUT_DIR/13_claim_result.png"
            local iid="$WIN_FOUND"
            send_key "$iid" Escape
            wait_win_gone_by_name '^认领结果$' 16 >/dev/null 2>&1 || true
        fi
    else
        detail="claim-dialog=FAIL"
        ok=0
    fi

    # ── on-disk assertions ────────────────────────────────────────────────
    if [ ! -f "$CLAIM_FILE" ]; then
        detail="$detail claim-file=FAIL(missing)"
        record step_claim_ondisk FAIL "$detail"
        return
    fi

    local diff_out added removed
    diff_out="$(diff "$CLAIM_PRISTINE" "$CLAIM_FILE" 2>&1 || true)"
    added="$(printf '%s\n' "$diff_out" | grep -c '^>')"
    removed="$(printf '%s\n' "$diff_out" | grep -c '^<')"
    if [ "$added" = "3" ] && [ "$removed" = "0" ]; then
        detail="$detail diff=+3/-0-OK"
    else
        detail="$detail diff=FAIL(+$added/-$removed)"
        ok=0
    fi

    local ai="$FIXTURES_DIR/apps/Obsidian-1.5.3-x86_64.AppImage"
    if grep -qxF "X-AppImage-Manager=true" "$CLAIM_FILE" \
       && grep -qxF "X-AppImage-Manager-Path=$ai" "$CLAIM_FILE" \
       && grep -qxF "X-AppImage-Manager-Version=$APPMGR_VERSION" "$CLAIM_FILE"; then
        detail="$detail marker-lines-OK"
    else
        detail="$detail marker-lines=FAIL"
        ok=0
    fi

    # every non-marker byte must be identical to the pristine file
    desktop_strip_markers "$CLAIM_FILE" > "$OUT_DIR/.claim.base"
    if cmp -s "$CLAIM_PRISTINE" "$OUT_DIR/.claim.base"; then
        detail="$detail bytes-preserved-OK"
    else
        detail="$detail bytes-preserved=FAIL(comment/blank/[Desktop Action] changed)"
        ok=0
    fi

    # markers must land inside [Desktop Entry], before [Desktop Action ...]
    local action_line
    action_line="$(grep -n '^\[Desktop Action' "$CLAIM_FILE" | head -n 1 | cut -d: -f1)"
    if [ -n "$action_line" ] && awk -v last="$action_line" '
            /^X-AppImage-Manager=/         {c1=NR}
            /^X-AppImage-Manager-Path=/    {c2=NR}
            /^X-AppImage-Manager-Version=/ {c3=NR}
            END { exit !(c1>0 && c2>c1 && c3>c2 && c3<last) }' "$CLAIM_FILE"; then
        detail="$detail marker-placement-OK"
    else
        detail="$detail marker-placement=FAIL"
        ok=0
    fi

    if desktop-file-validate "$CLAIM_FILE" >/dev/null 2>&1; then
        detail="$detail validate-OK"
    else
        detail="$detail validate-FAIL"
        ok=0
    fi

    local tx_after; tx_after="$(count_manifests)"
    local txdir; txdir="$(newest_tx_dir)"
    local manifest="$txdir/manifest.json"
    if [ "$tx_after" -eq $((tx_before + 1)) ] \
       && grep -q '"operation":"repair"' "$manifest" 2>/dev/null \
       && grep -q '"claim"' "$manifest" 2>/dev/null; then
        detail="$detail tx+claim-record-OK"
    else
        detail="$detail tx-record=FAIL"
        ok=0
    fi
    if [ -f "$txdir/file/claim-crafted.desktop" ] \
       && cmp -s "$txdir/file/claim-crafted.desktop" "$CLAIM_PRISTINE"; then
        detail="$detail backup-original-OK"
    else
        detail="$detail backup=FAIL"
        ok=0
    fi

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_claim_ondisk PASS "$detail"
    else
        record step_claim_ondisk FAIL "$detail"
    fi
}

step_claim_idem() {
    echo
    echo "── step_claim_idem: claiming the managed file again is a no-op ──"
    local ok=1 detail=""

    if [ ! -f "$CLAIM_FILE" ] || ! grep -q '^X-AppImage-Manager=true' "$CLAIM_FILE" 2>/dev/null; then
        record step_claim_idem FAIL "prerequisite: claimed file missing (previous step failed)"
        return
    fi
    if ! ensure_app keep || [ -z "$MAIN_WIN" ]; then
        record step_claim_idem FAIL "window unavailable"
        return
    fi

    local sha_before; sha_before="$(sha256sum "$CLAIM_FILE" | cut -d' ' -f1)"

    search_for "Obsidian"
    # nothing checked/selected → claim goes to the manual "认领启动器" dialog
    menu_pick "alt+e" 4
    if wait_win_by_name '^认领启动器$' 24; then
        detail="manual-dialog=OK"
        park_mouse
        grab_root "$OUT_DIR/14_claim_manual.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/14_claim_manual.png"
        local mid="$WIN_FOUND" mw mh picked=0 off
        mw="$(win_w "$mid")"; mh="$(win_h "$mid")"
        for off in 0 -15 15; do
            click_win "$mid" $((mw - 215 + off)) $((mh - 27))
            if wait_win_by_name '^选择要认领的 \.desktop 文件$' 12; then picked=1; break; fi
            # the dialog may have been closed by a mis-click; stop if so
            [ -z "$(find_win_by_name '^认领启动器$')" ] && break
        done
        if [ "$picked" = "1" ]; then
            detail="$detail filechooser=OK"
            local fid="$WIN_FOUND"
            send_key "$fid" ctrl+l
            sleep 0.4
            type_text "$fid" "$CLAIM_FILE"
            sleep 0.4
            xdotool key --clearmodifiers Return
            if wait_win_by_name '^已被管理$' 24; then
                detail="$detail managed-detected=OK"
                park_mouse
                grab_root "$OUT_DIR/14_claim_idem_result.png" >/dev/null 2>&1 || true
                add_shot "$OUT_DIR/14_claim_idem_result.png"
                local iid="$WIN_FOUND"
                send_key "$iid" Escape
                wait_win_gone_by_name '^已被管理$' 16 >/dev/null 2>&1 || true
            else
                detail="$detail managed-detected=FAIL(no dialog)"
                ok=0
                send_key "$MAIN_WIN" Escape
            fi
        else
            detail="$detail filechooser=FAIL(did not open)"
            ok=0
            [ -n "$(find_win_by_name '^认领启动器$')" ] && send_key "$(find_win_by_name '^认领启动器$')" Escape
        fi
    else
        detail="manual-dialog=FAIL"
        ok=0
    fi

    local c1 c2 c3 sha_after
    c1="$(desktop_marker_count "$CLAIM_FILE" X-AppImage-Manager=)"
    c2="$(desktop_marker_count "$CLAIM_FILE" X-AppImage-Manager-Path=)"
    c3="$(desktop_marker_count "$CLAIM_FILE" X-AppImage-Manager-Version=)"
    sha_after="$(sha256sum "$CLAIM_FILE" | cut -d' ' -f1)"
    if [ "$c1" = "1" ] && [ "$c2" = "1" ] && [ "$c3" = "1" ]; then
        detail="$detail markers-once-OK"
    else
        detail="$detail markers-once=FAIL($c1/$c2/$c3)"
        ok=0
    fi
    if [ "$sha_after" = "$sha_before" ]; then
        detail="$detail file-unchanged-OK"
    else
        detail="$detail file-unchanged=FAIL"
        ok=0
    fi

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_claim_idem PASS "$detail"
    else
        record step_claim_idem FAIL "$detail"
    fi
}

combo_next_value() { # move the filter combo one step forward (order wraps)
    click_main "$COMBO_X" "$COMBO_Y"
    sleep 0.6
    xdotool key --clearmodifiers Down
    sleep 0.2
    xdotool key --clearmodifiers Return
    sleep 0.9
}

step_filters() {
    echo
    echo "── step_filters: every filter value shows the expected row count ──"
    if ! ensure_app filters || [ -z "$MAIN_WIN" ]; then
        record step_filters FAIL "window unavailable"
        return
    fi
    local ok=1 detail="" idx=0 got want

    # Expected counts derived from the actual sandbox state; 失效 is always 0
    # because Store never assigns MatchState.BROKEN to an AppImage; 可优化 is
    # 2 because exactly Krita (E004 → CORRUPT) and Obsidian (I/C problems →
    # IMPROVABLE) are matched in this phase.
    local all matched reg ext
    all=0; matched=0; reg=0; ext=0
    local ai d mp et
    while IFS= read -r ai; do
        [ -n "$ai" ] || continue
        all=$((all + 1))
        for d in "$APPS_DIR"/*.desktop; do
            [ -e "$d" ] || continue
            mp="$(desktop_get "$d" X-AppImage-Manager-Path)"
            et="$(desktop_exec_target "$d")"
            if [ "$mp" = "$ai" ] || { [ -z "$mp" ] && [ "$et" = "$ai" ]; }; then
                matched=$((matched + 1))
                if [ -n "$mp" ]; then reg=$((reg + 1)); else ext=$((ext + 1)); fi
                break
            fi
        done
    done <<EOF
$(scan_appimages "$FIXTURES_DIR/apps")
EOF

    # values in combo order: 全部 新发现 已创建 外部创建 失效 可优化
    local expected_all expected_new expected_reg expected_ext expected_broken expected_improvable
    expected_all="$all"
    expected_new=$((all - matched))
    expected_reg="$reg"
    expected_ext="$ext"
    expected_broken=0
    expected_improvable=2

    echo "  derived: all=$all matched=$matched reg=$reg ext=$ext"

    local names=(全部 新发现 已创建 外部创建 失效 可优化)
    local expect=("$expected_all" "$expected_new" "$expected_reg" \
                  "$expected_ext" "$expected_broken" "$expected_improvable")
    local i
    for ((i = 0; i < 6; i++)); do
        if [ "$i" -gt 0 ]; then
            combo_next_value
        fi
        want="${expect[$i]}"
        got="$(wait_rows "$want" 12)"
        park_mouse
        grab_main "$OUT_DIR/15_filter_${i}_${names[$i]}.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/15_filter_${i}_${names[$i]}.png"
        if [ "$got" = "$want" ]; then
            detail="$detail ${names[$i]}=$got-OK"
        else
            detail="$detail ${names[$i]}=FAIL($got!=$want)"
            ok=0
        fi
    done

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_filters PASS "$detail"
    else
        record step_filters FAIL "$detail"
    fi
}

step_search() {
    echo
    echo "── step_search: typed query filters rows, clearing restores them ──"
    if ! ensure_app search || [ -z "$MAIN_WIN" ]; then
        record step_search FAIL "window unavailable"
        return
    fi
    local ok=1 detail="" got want
    local done_total
    done_total="$(scan_appimages "$FIXTURES_DIR/apps" | grep -c .)"
    [ "$done_total" -gt 0 ] || done_total=1

    search_for "FreeCAD"
    got="$(wait_rows 1 10)"
    if [ "$got" = "1" ]; then detail="FreeCAD=1-OK"; else detail="FreeCAD=FAIL($got)"; ok=0; fi
    park_mouse
    grab_main "$OUT_DIR/16_search_freecad.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/16_search_freecad.png"

    clear_search
    got="$(wait_rows "$done_total" 10)"
    if [ "$got" = "$done_total" ]; then detail="$detail cleared=$got-OK"; else detail="$detail cleared=FAIL($got!=$done_total)"; ok=0; fi

    search_for "Media"
    got="$(wait_rows 1 10)"
    if [ "$got" = "1" ]; then detail="$detail Media=1-OK"; else detail="$detail Media=FAIL($got)"; ok=0; fi

    search_for "zzz-no-such-app"
    got="$(wait_rows 0 10)"
    if [ "$got" = "0" ]; then detail="$detail no-match=0-OK"; else detail="$detail no-match=FAIL($got)"; ok=0; fi

    clear_search
    got="$(wait_rows "$done_total" 10)"
    if [ "$got" = "$done_total" ]; then detail="$detail restored=$got-OK"; else detail="$detail restored=FAIL($got)"; ok=0; fi
    park_mouse
    grab_main "$OUT_DIR/16_search_cleared.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/16_search_cleared.png"

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_search PASS "$detail"
    else
        record step_search FAIL "$detail"
    fi
}

step_create_icon() {
    echo
    echo "── step_create_icon: create a launcher with a picked icon (on-disk) ──"
    if ! ensure_app create || [ -z "$MAIN_WIN" ]; then
        record step_create_icon FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    search_for "GNU"
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6

    menu_pick "alt+e" 2
    if wait_win_by_name '^创建启动器 — GNU_Octave$' 24; then
        detail="create-dialog=OK"
        local did="$WIN_FOUND"
        park_mouse
        grab_root "$OUT_DIR/17_create_dialog.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/17_create_dialog.png"

        # 选择… (left icon column) → file chooser → type the icon path
        local chooser=0 off
        for off in 0 12 -12; do
            click_win "$did" 55 $((129 + off))
            if wait_win_by_name '^选择图标文件$' 12; then chooser=1; break; fi
            [ -z "$(find_win_by_name '^创建启动器 — GNU_Octave$')" ] && break
        done
        if [ "$chooser" = "1" ]; then
            detail="$detail chooser=OK"
            local cid="$WIN_FOUND"
            send_key "$cid" ctrl+l
            sleep 0.4
            type_text "$cid" "$FIXTURES_DIR/icons/perfect.png"
            sleep 0.4
            xdotool key --clearmodifiers Return
            wait_win_gone_by_name '^选择图标文件$' 16 >/dev/null 2>&1 || true
            # click 创建 (do NOT use Return: focus is still on 选择…)
            local created=0
            for off in 0 -12 12; do
                click_win "$did" $((722 + off)) 611
                for ((_i = 0; _i < 12; _i++)); do
                    sleep 0.4
                    [ -z "$(find_win_by_name '^创建启动器 — GNU_Octave$')" ] && { created=1; break; }
                done
                [ "$created" = "1" ] && break
            done
            if [ "$created" = "1" ]; then
                detail="$detail create-click=OK"
            else
                detail="$detail create-click=FAIL"
                ok=0
                send_key "$did" Escape
            fi
        else
            detail="$detail chooser=FAIL(did not open)"
            ok=0
            [ -n "$(find_win_by_name '^创建启动器 — GNU_Octave$')" ] && \
                send_key "$(find_win_by_name '^创建启动器 — GNU_Octave$')" Escape
        fi
    else
        detail="create-dialog=FAIL"
        ok=0
    fi

    # ── on-disk assertions ────────────────────────────────────────────────
    local count; count="$(list_applications | grep -c '\.desktop$')"
    if [ -f "$GNU_FILE" ] && [ "$count" = "1" ]; then
        detail="$detail created-file=OK"
    else
        detail="$detail created-file=FAIL(count=$count)"
        ok=0
    fi
    if [ -f "$GNU_FILE" ]; then
        local icon; icon="$(desktop_get "$GNU_FILE" Icon)"
        if [ -n "$icon" ] && [ -f "$icon" ]; then
            detail="$detail icon-file-exists-OK"
            case "$icon" in
                "$XDG_DATA_HOME"/*) detail="$detail icon-in-sandbox-OK" ;;
                *) detail="$detail icon-in-sandbox=FAIL($icon)"; ok=0 ;;
            esac
        else
            detail="$detail icon-file-exists=FAIL('$icon')"
            ok=0
        fi
        if grep -qxF "X-AppImage-Manager-Path=$FIXTURES_DIR/apps/GNU_Octave-9.1.0.AppImage" "$GNU_FILE"; then
            detail="$detail markers-OK"
        else
            detail="$detail markers=FAIL"
            ok=0
        fi
        if desktop-file-validate "$GNU_FILE" >/dev/null 2>&1; then
            detail="$detail validate-OK"
        else
            detail="$detail validate-FAIL"
            ok=0
        fi
    fi
    park_mouse
    grab_main "$OUT_DIR/17_create_after.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/17_create_after.png"

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_create_icon PASS "$detail"
    else
        record step_create_icon FAIL "$detail"
    fi
}

step_delete_ondisk() {
    echo
    echo "── step_delete_ondisk: 删除 removes the .desktop and keeps an undo record ──"
    if ! ensure_app delete || [ -z "$MAIN_WIN" ]; then
        record step_delete_ondisk FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    if [ ! -f "$GNU_FILE" ]; then
        detail="launcher=FAIL(missing before delete)"
        record step_delete_ondisk FAIL "$detail"
        return
    fi
    cp "$GNU_FILE" "$PRISTINE/gnu-before-delete.desktop"
    local tx_before; tx_before="$(count_manifests)"

    search_for "GNU"
    local rows; rows="$(wait_rows 1 16)"
    [ "$rows" = "1" ] || { detail="row-count=FAIL($rows)"; ok=0; }
    send_key "$MAIN_WIN" ctrl+a
    sleep 0.6

    menu_pick "alt+e" 5
    if wait_app_popup 61 20; then
        detail="$detail confirm-dialog=OK"
        park_mouse
        grab_root "$OUT_DIR/18_delete_confirm.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/18_delete_confirm.png"
        local did="$POPUP_FOUND"
        # default response is 取消; Tab moves focus to 删除
        send_key "$did" Tab
        sleep 0.3
        xdotool key --clearmodifiers Return
        local gone=0
        for ((_i = 0; _i < 20; _i++)); do
            [ ! -f "$GNU_FILE" ] && { gone=1; break; }
            sleep 0.3
        done
        if [ "$gone" = "1" ]; then
            detail="$detail file-removed-OK"
        else
            detail="$detail file-removed=FAIL"
            ok=0
        fi
    else
        detail="$detail confirm-dialog=FAIL"
        ok=0
        xdotool key --clearmodifiers Escape
    fi

    local tx_after txdir manifest backup
    tx_after="$(count_manifests)"
    txdir="$(newest_tx_dir)"
    manifest="$txdir/manifest.json"
    backup="$txdir/file/gnu_octave-9.1.0.desktop"
    if [ "$tx_after" -eq $((tx_before + 1)) ] \
       && grep -q '"operation":"delete"' "$manifest" 2>/dev/null; then
        detail="$detail tx-delete-record-OK"
    else
        detail="$detail tx-delete-record=FAIL"
        ok=0
    fi
    if [ -f "$backup" ] && cmp -s "$backup" "$PRISTINE/gnu-before-delete.desktop"; then
        detail="$detail undo-backup-OK"
    else
        detail="$detail undo-backup=FAIL"
        ok=0
    fi
    park_mouse
    grab_main "$OUT_DIR/18_delete_after.png" >/dev/null 2>&1 || true
    add_shot "$OUT_DIR/18_delete_after.png"

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_delete_ondisk PASS "$detail"
    else
        record step_delete_ondisk FAIL "$detail"
    fi
}

step_empty_state() {
    echo
    echo "── step_empty_state: no scan dirs → guidance page + 常见位置 dialog ──"
    if ! ensure_app empty || [ -z "$MAIN_WIN" ]; then
        record step_empty_state FAIL "window unavailable"
        return
    fi
    local ok=1 detail=""

    sleep 0.8
    park_mouse
    local shot="$OUT_DIR/19_empty_state.png"
    grab_main "$shot" >/dev/null 2>&1 || true
    add_shot "$shot"

    local rows; rows="$(count_list_rows "$shot")"
    if [ "$rows" = "0" ]; then
        detail="no-list-rows-OK"
    else
        detail="no-list-rows=FAIL($rows)"
        ok=0
    fi

    # The empty page offers 添加目录… / 看看常见位置; the second opens the
    # 常见位置 dialog, which proves the guidance widget really rendered.
    local opened=0 off
    for off in 0 -70 70; do
        click_main $((EMPTY_COMMON_X + off)) "$EMPTY_COMMON_Y"
        if wait_win_by_name '^常见位置$' 12; then opened=1; break; fi
    done
    if [ "$opened" = "1" ]; then
        detail="$detail guidance-button-OK"
        park_mouse
        grab_root "$OUT_DIR/19_common_locations.png" >/dev/null 2>&1 || true
        add_shot "$OUT_DIR/19_common_locations.png"
        local cid="$WIN_FOUND"
        send_key "$cid" Escape
        wait_win_gone_by_name '^常见位置$' 16 >/dev/null 2>&1 || true
    else
        detail="$detail guidance-button=FAIL(常见位置 did not open)"
        ok=0
        send_key "$MAIN_WIN" Escape
    fi

    app_alive || { detail="$detail APP-DEAD"; ok=0; }
    if [ "$ok" = "1" ]; then
        record step_empty_state PASS "$detail"
    else
        record step_empty_state FAIL "$detail"
    fi
}

step_safety() {
    echo
    echo "── step_safety: the real ~/.local/share/applications is untouched ──"
    local after count before_count
    after="$(ls -1 "$SAFE_APPS_DIR" 2>/dev/null | sort)"
    count="$(printf '%s\n' "$after" | grep -c .)"
    before_count="$(printf '%s\n' "$SAFE_APPS_BEFORE" | grep -c .)"

    echo "  real dir        : $SAFE_APPS_DIR"
    echo "  entries at start: $before_count"
    printf '%s\n' "$after" | sed 's/^/    /'

    local note=""
    if [ "$count" != "3" ] || [ "$after" != "$SAFE_EXPECTED" ]; then
        note=" [NOTE: the task's expected 3-entry list does not match this machine: found $count]"
    fi

    if [ "$after" = "$SAFE_APPS_BEFORE" ]; then
        record step_safety PASS "unchanged during the run ($count entries)$note"
    else
        record step_safety FAIL "DIRECTORY CHANGED during the run: was $before_count, now $count: $(printf '%s' "$after" | tr '\n' ' ')"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  RUN EVERYTHING — failures never stop the suite
# ═════════════════════════════════════════════════════════════════════════════

# fixtures: regenerate on demand (never write into the shared dir ourselves)
if [ ! -d "$FIXTURES_DIR/apps" ]; then
    echo "fixtures missing → running tests/make-fixtures.sh"
    bash "$SCRIPT_DIR/make-fixtures.sh" "$FIXTURES_DIR" >"$OUT_DIR/fixtures.log" 2>&1
    if [ -z "$(find "$FIXTURES_DIR/apps" -name '*.AppImage' -print -quit 2>/dev/null)" ]; then
        echo "ERROR: fixtures could not be created, see $OUT_DIR/fixtures.log"
        exit 1
    fi
fi

if [ ! -x "$APP_BIN" ]; then
    echo "ERROR: app binary missing or not executable: $APP_BIN"
    echo "       (the suite expects the known-good snapshot; set APPMGR_BIN to override)"
    exit 1
fi

step_window
step_rows
step_actionbar
step_menu_file
step_menu_edit
step_menu_view
step_menu_tools
step_menu_help
step_dialogs
step_actionbar_btns
step_context_menu
step_repair_ondisk
step_claim_ondisk
step_claim_idem
step_filters
step_search
step_create_icon
step_delete_ondisk
step_empty_state
step_safety

# ── summary ──────────────────────────────────────────────────────────────────

echo
echo "════════════════ UI TEST SUMMARY ════════════════════"
printf '%-22s %-6s %s\n' "STEP" "RESULT" "DETAIL"
printf '%-22s %-6s %s\n' "----" "------" "------"
if [ "${#RES_STEPS[@]}" -gt 0 ]; then
    for i in "${!RES_STEPS[@]}"; do
        printf '%-22s %-6s %s\n' "${RES_STEPS[$i]}" "${RES_STATUS[$i]}" "${RES_DETAIL[$i]}"
    done
fi

echo
echo "Screenshots (${#SHOTS[@]}):"
if [ "${#SHOTS[@]}" -gt 0 ]; then
    for s in "${SHOTS[@]}"; do
        echo "  $s"
    done
fi

echo
echo "Output dir : $OUT_DIR"
echo "App log    : $OUT_DIR/app.log"
if [ "$FAILURES" -eq 0 ]; then
    echo "RESULT: PASS (all steps)"
    exit 0
fi
echo "RESULT: FAIL ($FAILURES step(s))"
exit 1
