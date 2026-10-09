#!/usr/bin/env bash
#
# ui-test.sh — UI smoke test for AppImage Manager (GTK3).
#
# Drives the app inside a PRIVATE Xvfb display with xdotool, captures
# screenshots and reports PASS/FAIL for a few structural UI states.
# The real user config/home is never touched: everything runs against a
# sandboxed HOME plus XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME.
#
# Usage:
#     tests/ui-test.sh [output-dir]          # default: /tmp/appmgr-uitest
#
# Steps implemented:
#     step_window     — main window exists, is mapped, geometry readable
#     step_rows       — list/TreeView area is not a single flat colour
#                       (flat ⇒ rows never rendered)
#     step_actionbar  — capture the strip just below the directory chips
#                       (where a persistent action bar is expected) for
#                       manual review; also captures the bottom strip
#     step_create     — click the first list row, then capture before/after
#
# Environment overrides (all optional):
#     APPMGR_BIN        app binary        (default: <repo>/appimage-manager)
#     APPMGR_FIXTURES   fixture root      (default: /tmp/appmgr-fixtures)
#     APPMGR_UITEST_OUT default output dir (used when no positional arg)
#     APPMGR_DISPLAY    first Xvfb display number to try (default: 99)
#     APPMGR_CLICK_CREATE=1  also click the create button after selecting a row
#
#   Geometry (pixels, relative to the window origin):
#     ROW1_X, ROW1_Y               first list row      (default 300, 185)
#     CREATE_BTN_X, CREATE_BTN_Y   create button       (default 760, 646)
#     LIST_TOP, LIST_HEIGHT        list-area crop      (default 170, 220)
#     ACTIONBAR_Y, ACTIONBAR_HEIGHT  action-bar strip  (default 100, 80)
#
# Exit status:
#     0 — all steps passed, or required tools are missing (test skipped)
#     1 — setup failed (no Xvfb / no window) or at least one step FAILed
#
# NOTE: the app's process comm is truncated to "appimage-manage" (15 chars),
#       so cleanup uses `pkill -x appimage-manage` (NOT `pkill -f name`).
#
set -u
set -o pipefail

# ── paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_BIN="${APPMGR_BIN:-$PROJECT_DIR/appimage-manager}"
FIXTURES_DIR="${APPMGR_FIXTURES:-/tmp/appmgr-fixtures}"
OUT_DIR="${1:-${APPMGR_UITEST_OUT:-/tmp/appmgr-uitest}}"

# ── required external tools: skip (exit 0), do not fail ─────────────────────

missing_tools=()
for tool in Xvfb xdotool import convert identify; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools+=("$tool")
    fi
done
if [ "${#missing_tools[@]}" -gt 0 ]; then
    echo "SKIP: required tool(s) not found: ${missing_tools[*]}"
    echo "      install with: sudo apt-get install xvfb xdotool imagemagick"
    exit 0
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
mkdir -p "$OUT_DIR"

# ── state / results ──────────────────────────────────────────────────────────

APP_PID=""
XVFB_PID=""
WINDOW_ID=""
DISPLAY_NUM=""
CLEANUP_DONE=0

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

# ── cleanup: always kill app + Xvfb ──────────────────────────────────────────

cleanup() {
    if [ "$CLEANUP_DONE" = "1" ]; then
        return
    fi
    CLEANUP_DONE=1
    echo
    echo "── cleanup ──"

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

    if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
        kill "$XVFB_PID" 2>/dev/null
        for ((_i = 0; _i < 20; _i++)); do
            kill -0 "$XVFB_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$XVFB_PID" 2>/dev/null
    fi

    echo "cleanup done (app pid=${APP_PID:-none}, Xvfb pid=${XVFB_PID:-none}, display=:${DISPLAY_NUM:-?})"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── overridable geometry (pixels relative to the window's top-left) ──────────

ROW1_X="${ROW1_X:-300}"                    # first list row
ROW1_Y="${ROW1_Y:-185}"
CREATE_BTN_X="${CREATE_BTN_X:-760}"        # create button (for APPMGR_CLICK_CREATE=1)
CREATE_BTN_Y="${CREATE_BTN_Y:-646}"
LIST_TOP="${LIST_TOP:-170}"                # list-area crop (below header/dir/filter bars)
LIST_HEIGHT="${LIST_HEIGHT:-220}"
ACTIONBAR_Y="${ACTIONBAR_Y:-100}"          # strip just below directory chips
ACTIONBAR_HEIGHT="${ACTIONBAR_HEIGHT:-80}"

to_int() { # to_int <value> <fallback>
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}
ROW1_X="$(to_int "$ROW1_X" 300)"
ROW1_Y="$(to_int "$ROW1_Y" 185)"
CREATE_BTN_X="$(to_int "$CREATE_BTN_X" 760)"
CREATE_BTN_Y="$(to_int "$CREATE_BTN_Y" 646)"
LIST_TOP="$(to_int "$LIST_TOP" 170)"
LIST_HEIGHT="$(to_int "$LIST_HEIGHT" 220)"
ACTIONBAR_Y="$(to_int "$ACTIONBAR_Y" 100)"
ACTIONBAR_HEIGHT="$(to_int "$ACTIONBAR_HEIGHT" 80)"

# ── helpers ──────────────────────────────────────────────────────────────────

ensure_window() { # locate the visible toplevel; sets WINDOW_ID
    WINDOW_ID="$(xdotool search --onlyvisible --name "AppImage Manager" 2>/dev/null | tail -n 1)"
    if [ -n "$WINDOW_ID" ]; then
        return 0
    fi
    WINDOW_ID=""
    return 1
}

refresh_geometry() { # sets WIN_X/WIN_Y/WIN_W/WIN_H from the current WINDOW_ID
    local out
    out="$(xdotool getwindowgeometry --shell "$WINDOW_ID" 2>/dev/null)" || {
        WIN_W=0; WIN_H=0
        return 1
    }
    local WINDOW X Y WIDTH HEIGHT SCREEN
    eval "$out"
    WIN_X="${X:-0}"
    WIN_Y="${Y:-0}"
    WIN_W="${WIDTH:-0}"
    WIN_H="${HEIGHT:-0}"
    [ "$WIN_W" -gt 0 ] && [ "$WIN_H" -gt 0 ]
}

grab() { # grab <png> — full-window screenshot (fallback: full root)
    local out="$1"
    if import -window "$WINDOW_ID" "$out" 2>>"$OUT_DIR/import.log"; then
        [ -s "$out" ] && return 0
    fi
    import -window root "$out" 2>>"$OUT_DIR/import.log" || return 1
    [ -s "$out" ]
}

crop() { # crop <src> <dst> <WxH+X+Y>
    convert "$1" -crop "$3" +repage "$2" 2>>"$OUT_DIR/import.log"
}

unique_colors() { # unique_colour count of an image (flat colour ⇒ 1)
    local n
    n="$(identify -format '%k' "$1" 2>/dev/null)"
    case "$n" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$n" ;;
    esac
}

image_sig() { # content signature (used to see whether a click changed the UI)
    identify -format '%#' "$1" 2>/dev/null
}

click_at() { # click_at <screen-x> <screen-y>
    xdotool mousemove --sync "$1" "$2" >/dev/null 2>&1 || return 1
    sleep 0.2
    xdotool click 1 >/dev/null 2>&1 || return 1
    return 0
}

# ── private Xvfb ─────────────────────────────────────────────────────────────

DISPLAY_BASE="$(to_int "${APPMGR_DISPLAY:-99}" 99)"
for ((n = DISPLAY_BASE; n < DISPLAY_BASE + 20; n++)); do
    # guard: lock file OR a live server answering on that display
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

Xvfb ":$DISPLAY_NUM" -screen 0 1280x800x24 -nolisten tcp >"$OUT_DIR/xvfb.log" 2>&1 &
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

# ── sandboxed HOME / XDG + generated config (real config is untouched) ──────

export HOME="$OUT_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_RUNTIME_DIR="$OUT_DIR/runtime"
export GDK_BACKEND=x11
export NO_AT_BRIDGE=1
# avoid remote activation of a real user instance through the session bus
unset DBUS_SESSION_BUS_ADDRESS

mkdir -p "$XDG_CONFIG_HOME/appimage-manager" \
         "$XDG_DATA_HOME" \
         "$XDG_CACHE_HOME" \
         "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null

# Layout matches what GLib.KeyFile writes (see src/config.vala seed_defaults()
# and ~/.config/appimage-manager/config.ini): no spaces, "true"/"false".
cat > "$XDG_CONFIG_HOME/appimage-manager/config.ini" <<EOF
[general]
configured=true
icon_size=256

[scan]
recursive=true
auto_on_startup=false
ignore_system_dirs=true
dirs=$FIXTURES_DIR/apps

[icons]
custom_icon_dir=false
custom_icon_dir_path=

[sync]
update_desktop_database=true
update_icon_cache=true
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
echo "config     : $XDG_CONFIG_HOME/appimage-manager/config.ini"

# ── fixtures ─────────────────────────────────────────────────────────────────

if [ ! -d "$FIXTURES_DIR/apps" ]; then
    echo "fixtures missing → running tests/make-fixtures.sh"
    bash "$SCRIPT_DIR/make-fixtures.sh" "$FIXTURES_DIR" >"$OUT_DIR/fixtures.log" 2>&1
    # make-fixtures.sh may return non-zero if the optional icon step fails;
    # as long as the AppImages exist we can continue.
    if [ -z "$(find "$FIXTURES_DIR/apps" -name '*.AppImage' -print -quit 2>/dev/null)" ]; then
        echo "ERROR: fixtures could not be created, see $OUT_DIR/fixtures.log"
        exit 1
    fi
fi

# ── launch app ───────────────────────────────────────────────────────────────

if [ ! -x "$APP_BIN" ]; then
    echo "ERROR: app binary missing or not executable: $APP_BIN"
    echo "       build it first, e.g.: make -C \"$PROJECT_DIR\""
    exit 1
fi

( cd "$PROJECT_DIR" && exec "$APP_BIN" ) >"$OUT_DIR/app.log" 2>&1 &
APP_PID=$!

for ((i = 0; i < 60; i++)); do  # up to ~15 s
    kill -0 "$APP_PID" 2>/dev/null || break
    ensure_window && break
    sleep 0.25
done

if [ -n "$WINDOW_ID" ] && refresh_geometry; then
    echo "window     : id=$WINDOW_ID geometry=${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y}"
else
    echo "WARNING    : no visible 'AppImage Manager' window after 15 s"
    echo "app.log tail:"
    tail -n 30 "$OUT_DIR/app.log" 2>/dev/null | sed 's/^/  /'
fi

# ── steps ────────────────────────────────────────────────────────────────────

step_window() {
    echo
    echo "── step_window: main window exists and is mapped ──"
    if ! ensure_window; then
        record step_window FAIL "no visible window matching 'AppImage Manager'"
        return
    fi
    if ! refresh_geometry; then
        record step_window FAIL "window $WINDOW_ID has no usable geometry"
        return
    fi

    echo "  window id : $WINDOW_ID"
    echo "  geometry  : ${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y} (display :$DISPLAY_NUM)"

    local shot="$OUT_DIR/01_step_window.png"
    if grab "$shot"; then
        add_shot "$shot"
        record step_window PASS "mapped ${WIN_W}x${WIN_H}+${WIN_X}+${WIN_Y}, display :$DISPLAY_NUM"
    else
        record step_window FAIL "window mapped but screenshot failed (see import.log)"
    fi
}

step_rows() {
    echo
    echo "── step_rows: TreeView contains rows ──"
    if ! ensure_window || ! refresh_geometry; then
        record step_rows FAIL "window unavailable"
        return
    fi

    local full="$OUT_DIR/02_step_rows_full.png"
    if ! grab "$full"; then
        record step_rows FAIL "screenshot failed (see import.log)"
        return
    fi

    local top="$LIST_TOP" h="$LIST_HEIGHT"
    local max_h=$((WIN_H - top - 20))
    if [ "$max_h" -lt 30 ]; then
        top=$((WIN_H / 3))
        max_h=$((WIN_H - top - 10))
    fi
    if [ "$h" -gt "$max_h" ]; then h="$max_h"; fi
    if [ "$h" -lt 30 ]; then h=30; fi

    local area="$OUT_DIR/02_step_rows_listarea.png"
    if ! crop "$full" "$area" "${WIN_W}x${h}+0+${top}"; then
        record step_rows FAIL "list-area crop failed"
        return
    fi

    # A populated TreeView is never one flat colour. Poll: the first scan may
    # still be running right after the window appears.
    local colors=0 tries
    for ((tries = 0; tries < 20; tries++)); do
        colors="$(unique_colors "$area")"
        if [ "$colors" -gt 1 ]; then break; fi
        sleep 0.5
        grab "$full" >/dev/null 2>&1 || true
        crop "$full" "$area" "${WIN_W}x${h}+0+${top}" >/dev/null 2>&1 || true
    done

    add_shot "$full"
    add_shot "$area"
    echo "  list-area crop: y=$top h=$h  unique-colours=$colors"

    if [ "$colors" -gt 1 ]; then
        record step_rows PASS "list area not flat (unique colours=$colors, crop y=$top h=$h)"
    else
        record step_rows FAIL "list area is a flat colour (unique colours=$colors) — no rows?"
    fi
}

step_actionbar() {
    echo
    echo "── step_actionbar: capture action-bar region for manual review ──"
    if ! ensure_window || ! refresh_geometry; then
        record step_actionbar FAIL "window unavailable"
        return
    fi

    local full="$OUT_DIR/03_step_actionbar_full.png"
    if ! grab "$full"; then
        record step_actionbar FAIL "screenshot failed (see import.log)"
        return
    fi
    add_shot "$full"

    local top="$ACTIONBAR_Y" h="$ACTIONBAR_HEIGHT"
    local max_h=$((WIN_H - top - 10))
    if [ "$h" -gt "$max_h" ]; then h="$max_h"; fi
    if [ "$h" -lt 20 ]; then h=20; fi

    local strip="$OUT_DIR/03_step_actionbar_region.png"
    if ! crop "$full" "$strip" "${WIN_W}x${h}+0+${top}"; then
        record step_actionbar FAIL "crop failed"
        return
    fi
    add_shot "$strip"

    # Bonus context: the current build floats the action overlay bottom-right.
    local bottom="$OUT_DIR/03_step_actionbar_bottom.png"
    local btop=$((WIN_H - 110))
    if [ "$btop" -lt 0 ]; then btop=0; fi
    crop "$full" "$bottom" "${WIN_W}x100+0+${btop}" >/dev/null 2>&1 || true
    add_shot "$bottom"

    local colors
    colors="$(unique_colors "$strip")"
    echo "  intended region: y=$top h=$h  unique-colours=$colors"
    echo "  adjust with ACTIONBAR_Y/ACTIONBAR_HEIGHT if misaligned"
    record step_actionbar PASS "captured y=$top h=$h (unique colours=$colors) — manual review"
}

step_create() {
    echo
    echo "── step_create: click first row then capture ──"
    if ! ensure_window || ! refresh_geometry; then
        record step_create FAIL "window unavailable"
        return
    fi

    local before="$OUT_DIR/04_step_create_before.png"
    local after="$OUT_DIR/04_step_create_after.png"
    grab "$before" >/dev/null 2>&1 || true
    local sig_before
    sig_before="$(image_sig "$before")"

    local ax=$((WIN_X + ROW1_X))
    local ay=$((WIN_Y + ROW1_Y))
    echo "  click row #1 at screen (${ax},${ay}) = window + (${ROW1_X},${ROW1_Y})"
    echo "  override with ROW1_X/ROW1_Y if the first row is elsewhere"

    local clicked=0
    if click_at "$ax" "$ay"; then clicked=1; fi
    sleep 0.6
    grab "$after" >/dev/null 2>&1 || true

    add_shot "$before"
    add_shot "$after"

    local changed="unknown"
    local sig_after
    sig_after="$(image_sig "$after")"
    if [ -n "$sig_before" ] && [ -n "$sig_after" ]; then
        if [ "$sig_before" = "$sig_after" ]; then
            changed="no"
        else
            changed="yes"
        fi
    fi

    if [ "$clicked" = "1" ] && [ -s "$after" ]; then
        record step_create PASS "clicked (${ax},${ay}); image changed: $changed"
    else
        record step_create FAIL "click or screenshot failed (clicked=$clicked)"
    fi

    # Optional: actually hit the create button (off by default so the smoke
    # test stays read-only; the sandbox makes it safe if enabled).
    if [ "${APPMGR_CLICK_CREATE:-0}" = "1" ]; then
        local bx=$((WIN_X + CREATE_BTN_X))
        local by=$((WIN_Y + CREATE_BTN_Y))
        echo "  APPMGR_CLICK_CREATE=1 → clicking create button at (${bx},${by})"
        click_at "$bx" "$by" || true
        sleep 1.0
        local result="$OUT_DIR/04_step_create_button_result.png"
        grab "$result" >/dev/null 2>&1 || true
        add_shot "$result"
    fi
}

# ── run everything, keep going on failures ──────────────────────────────────

step_window
step_rows
step_actionbar
step_create

# ── summary ──────────────────────────────────────────────────────────────────

echo
echo "════════════════════ UI TEST SUMMARY ════════════════════"
printf '%-16s %-6s %s\n' "STEP" "RESULT" "DETAIL"
printf '%-16s %-6s %s\n' "----" "------" "------"
if [ "${#RES_STEPS[@]}" -gt 0 ]; then
    for i in "${!RES_STEPS[@]}"; do
        printf '%-16s %-6s %s\n' "${RES_STEPS[$i]}" "${RES_STATUS[$i]}" "${RES_DETAIL[$i]}"
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
