# =============================================================================
#  Start-up messages on screen - shared by the Wine launchers in roms/windows
#  Loaded by common.inc; the window itself is bootlog.py in this folder.
#  Named .inc / .py, not .sh, so EmulationStation doesn't list them as games.
#
#  Shown for every game; the loading messages shown are switched on by
#  wine_logging (common.inc). Learned timings are kept
#  per game, in its Wine prefix (.boot_log_time).
# =============================================================================

BOOTLOG_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Holding the TV at 1:1 while the messages show (BOOT_LOG_FULL=1, the
# default): sharp text over the whole TV in every game, whatever its zoom.
# The X screen is made at least the TV's size and shown unscaled; the
# script's zoom (set before, or asked for meanwhile - display.inc keeps it
# in ZOOM_CMD_FILE) is carried out when the black cover goes up, out of
# sight. Wine is told a fixed "monitor" of the size it would otherwise see
# meanwhile (unless the script set one), so it notices nothing.
# BOOT_LOG_FULL=0: messages over the script's zoomed area (for a game
# without a Wine desktop - the X screen size is the game's screen).
boot_hold_start() {
    local cur fb mon rate=()
    [ -n "$OUTPUT" ] && [ -n "$BOOT_HOLD_FILE" ] || return 1
    [ -n "$TV_RATE" ] && rate=(--rate "$TV_RATE")
    cur="$(xrandr 2>/dev/null | sed -n 's/.*current \([0-9]*\) x \([0-9]*\).*/\1 \2/p' | head -n1)"
    [ -n "$cur" ] || return 1
    fb="$(awk -v c="$cur" -v n="${NATIVE_RES:-1920x1080}" 'BEGIN {
        split(c, C, " "); split(n, N, "x")
        printf "%dx%d", (C[1] > N[1] ? C[1] : N[1]), (C[2] > N[2] ? C[2] : N[2]) }')"
    # Wine's monitor: pinned at what it is now, if the script didn't fix one
    mon="$(xrandr --listmonitors 2>/dev/null | awk 'NR == 2 && $2 ~ /^\+/ {print $3}')"
    [ -n "$mon" ] && xrandr --setmonitor bootlog-tv "$mon" "$OUTPUT" >/dev/null 2>&1
    : > "$BOOT_HOLD_FILE"
    if ! xrandr --fb "$fb" --output "$OUTPUT" --mode "${NATIVE_RES:-1920x1080}" "${rate[@]}" \
                --transform none; then
        echo "WARNING: could not show the start-up messages at 1:1 - over the game's zoom instead"
        boot_hold_release
        return 1
    fi
    echo "Start-up messages at 1:1 (game's zoom after them)"
    return 0
}

# Hands the TV back: carries out the zoom the script wants now. (bootlog.py
# does this itself when its cover goes up; this is for when it's stopped.)
boot_hold_release() {
    [ -n "$BOOT_HOLD_FILE" ] && [ -e "$BOOT_HOLD_FILE" ] || return 0
    rm -f "$BOOT_HOLD_FILE"
    xset q >/dev/null 2>&1 || return 0                  # (X has gone)
    [ -s "$ZOOM_CMD_FILE" ] && eval "$(cat "$ZOOM_CMD_FILE")"
    xrandr --delmonitor bootlog-tv >/dev/null 2>&1
    return 0
}

# $1 = the area the TV shows when X starts, "W H X Y" (the window covers it -
#      with the TV held at 1:1, the whole TV instead)
# $2... = the game's exe names - it watches for their windows
# Text size: BOOT_LOG_SCALE (default 2.25) times the font's size, on the TV
start_boot_log() {
    command -v python3 >/dev/null || { echo "WARNING: python3 not found - no start-up messages on screen"; return; }
    [ -f "$BOOTLOG_DIR/bootlog.py" ] || { echo "WARNING: $BOOTLOG_DIR/bootlog.py not found - no start-up messages on screen"; return; }
    local area="$1"; shift
    if [ "${BOOT_LOG_FULL:-1}" = "1" ] && boot_hold_start; then
        local n="${NATIVE_RES:-1920x1080}"
        area="${n%x*} ${n#*x} 0 0"
    fi
    # shellcheck disable=SC2086
    python3 -I "$BOOTLOG_DIR/bootlog.py" boot-log-overlay "$LOG_FILE" "$(basename "$0" .sh)" \
        "${NATIVE_RES:-1920x1080}" "${BOOT_LOG_SCALE:-2.25}" $area \
        "$WINEPREFIX/.boot_log_time" "$@" &
}

stop_boot_log() {
    pkill -f boot-log-overlay 2>/dev/null
    boot_hold_release
}
