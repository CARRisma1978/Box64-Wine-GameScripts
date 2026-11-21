# =============================================================================
#  Shared display code - loaded by common.inc
#
#  The TV always stays in its own mode (NATIVE_RES); the Pi's display
#  hardware scales or zooms the X screen to it (an xrandr transform - costs
#  no GL work). Functions only; the settings they read stay in each game's
#  script:
#    NATIVE_RES     the TV's mode, e.g. 1920x1080
#    SCALE_FILTER   bilinear = smooth, nearest = sharp/blocky
#    SCALE_MODE     scale_fixed: fit (default) or integer (2x, 3x...)
#    KEEP_ASPECT    scale_fixed: 1 (default) = keep the shape, 0 = stretch
#    SCALE_FALLBACK scale_fixed: native = if scaling fails, use a TV-sized
#                   X screen (default: switch the TV to the game's size)
#    ZOOM_FB        zoom_to: smallest X screen size (default NATIVE_RES)
#    ZOOM_FB_VIEW   zoom_to: 1 = make the X screen reach the whole zoomed
#                   view, not just the game's area (no window manager:
#                   xrandr rejects a zoom reaching past the screen's edge)
#    WINDOW_EXE     find_window: the exe whose window to look for
#                   (default GAME_EXE)
#    TV_RATE        refresh rate for the TV's mode, e.g. 60 ("" = the TV's
#                   default)
#    TV_SIZED_SCREEN 1 = the X screen is never smaller than the TV's mode
#                   (see _screen_size) - for a game whose intro video starts
#                   the moment its window appears
# =============================================================================

# _display_do command
#   Runs a display change (a shell command string) - or, while the start-up
#   messages hold the TV at 1:1 (BOOT_HOLD_FILE, see bootlog.inc), only
#   keeps it: the latest one is carried out when they hand the TV back.
#   Either way it's kept in ZOOM_CMD_FILE as the latest wanted state.
#   Held: true (the change is assumed to work).
_display_do() {
    [ -n "$ZOOM_CMD_FILE" ] && printf '%s\n' "$1" > "$ZOOM_CMD_FILE" 2>/dev/null
    [ -n "$BOOT_HOLD_FILE" ] && [ -e "$BOOT_HOLD_FILE" ] && return 0
    eval "$1"
}

# _screen_size WxH - the X screen size to set for a picture needing WxH:
#   with TV_SIZED_SCREEN=1, at least the TV's size. The X screen then never
#   changes size: the switch after the start-up messages is just a change
#   of scaling, done at once. (Shrinking the X screen below the TV's mode
#   makes xrandr turn the output off and on - a second or two lost, just as
#   a game's intro video starts.)
_screen_size() {
    if [ "$TV_SIZED_SCREEN" = "1" ]; then
        awk -v a="$1" -v n="${NATIVE_RES:-1920x1080}" 'BEGIN { split(a, A, "x"); split(n, N, "x")
            printf "%dx%d", (A[1] > N[1] ? A[1] : N[1]), (A[2] > N[2] ? A[2] : N[2]) }'
    else
        echo "$1"
    fi
}

# display_output [what is lost]
#   Sets OUTPUT to the TV's connector (e.g. HDMI-1). False, with a warning,
#   if xrandr finds no connected display.
display_output() {
    OUTPUT="$(xrandr 2>/dev/null | awk '/ connected/ {print $1; exit}')"
    [ -n "$OUTPUT" ] && return 0
    echo "WARNING: no connected display found by xrandr${1:+ - $1}"
    return 1
}

# fixed_monitor name WxH
#   A fixed "monitor" of this size for Wine. Wine checks the screen modes a
#   game asks for against the monitor X reports, which otherwise follows the
#   zoom (e.g. ~1067x600 in 800x600 menus) - bigger modes were then refused,
#   or races squeezed to fit. Must be set before Wine starts.
fixed_monitor() {
    local w=${2%x*} h=${2#*x}
    [ -n "$OUTPUT" ] || return 1
    xrandr --setmonitor "$1" "${w}/${w}x${h}/${h}+0+0" "$OUTPUT"
}

# scale_fixed WxH [centre|topleft]
#   For a game with one fixed size: the X screen shows WxH, scaled up to the
#   TV once.
#     centre  (default) - fit to the TV (SCALE_MODE fit/integer), centred.
#             Centring puts part of the scaled screen at a negative x/y, so
#             the X screen reaches the far edge of the picture (e.g. 747x480
#             for 640x480, not 640x480).
#     topleft - the X screen IS WxH, in the top-left; zoomed so the TV shows
#             no more than it.
#   Sets FB_W, FB_H and DESK_RES to the X screen's size. If the GPU scaling
#   fails: warns, switches the TV to WxH instead and returns false - or,
#   with SCALE_FALLBACK=native, keeps the TV's mode and makes the X screen
#   the TV's size, shown 1:1 (DESK_RES = NATIVE_RES).
scale_fixed() {
    local res="$1" align="${2:-centre}" t fb rate=()
    [ -n "$OUTPUT" ] || return 1
    [ -n "$TV_RATE" ] && rate=(--rate "$TV_RATE")
    if [ "$res" = "$NATIVE_RES" ]; then
        t="none"; fb="$NATIVE_RES"
    else
        read -r t fb < <(awk -v g="$res" -v n="$NATIVE_RES" -v m="${SCALE_MODE:-fit}" \
                             -v ka="${KEEP_ASPECT:-1}" -v al="$align" 'BEGIN {
            split(g, G, "x"); split(n, N, "x")
            if (al == "topleft") {
                s = G[2] / N[2]; if (G[1] / N[1] < s) s = G[1] / N[1]   # stays inside
                printf "%.6f,0,0,0,%.6f,0,0,0,1 %dx%d\n", s, s, G[1], G[2]
                exit
            }
            if (ka == 0) {
                sx = G[1] / N[1]; sy = G[2] / N[2]; tx = ty = 0        # stretch
            } else {
                k = N[2] / G[2]; if (N[1] / G[1] < k) k = N[1] / G[1]  # fit
                if (m == "integer" && int(k) >= 1) k = int(k)          # 2x, 3x...
                sx = sy = 1 / k; tx = G[1]/2 - sx*N[1]/2; ty = G[2]/2 - sy*N[2]/2
            }
            fw = tx + sx*N[1]; fh = ty + sy*N[2]
            fw = (fw == int(fw)) ? fw : int(fw) + 1; if (fw < G[1]) fw = G[1]
            fh = (fh == int(fh)) ? fh : int(fh) + 1; if (fh < G[2]) fh = G[2]
            printf "%.6f,0,%.6f,0,%.6f,%.6f,0,0,1 %dx%d\n", sx, tx, sy, ty, fw, fh }')
    fi
    local filter=(--filter "${SCALE_FILTER:-bilinear}") cmd back
    [ "$t" = "none" ] && filter=()
    cmd="$(printf '%q ' xrandr --fb "$(_screen_size "$fb")" --output "$OUTPUT" --mode "$NATIVE_RES" \
                          "${rate[@]}" --transform "$t" "${filter[@]}")"
    if [ "$SCALE_FALLBACK" = "native" ]; then
        back="echo 'WARNING: GPU scaling failed - using a $NATIVE_RES desktop instead'; "
        back+="$(printf '%q ' xrandr --output "$OUTPUT" --mode "$NATIVE_RES" "${rate[@]}" \
                               --fb "$NATIVE_RES" --transform none)"
    else
        back="echo 'WARNING: GPU scaling failed - switching the TV to $res instead'; "
        back+="$(printf '%q ' xrandr --output "$OUTPUT" --mode "$res")"
    fi
    if _display_do "$cmd || { $back; false; }"; then
        FB_W=${fb%x*}; FB_H=${fb#*x}; DESK_RES="$fb"
        return 0
    fi
    [ "$SCALE_FALLBACK" = "native" ] && res="$NATIVE_RES"
    FB_W=${res%x*}; FB_H=${res#*x}; DESK_RES="$res"
    return 1
}

# zoom_to W H [X Y [AW AH]]
#   Shows the area W x H at X,Y of the X screen as big as fits the TV,
#   centred. Its shape is kept - or shown as AW:AH (e.g. 4 3) if given. An
#   area the TV's full size (and no AW AH) is shown 1:1.
#   With the black panels running (panels_start), tells them what to cover
#   (nothing, once the area fills the whole X screen).
#   The X screen is ZOOM_FB, made bigger if the area (or, with
#   ZOOM_FB_VIEW=1, the zoomed view) reaches past it.
#   False if the zoom failed.
zoom_to() {
    local w=$1 h=$2 x=${3:-0} y=${4:-0} aw=${5:-0} ah=${6:-0}
    local nw=${NATIVE_RES%x*} nh=${NATIVE_RES#*x} t fb panels fw fh rate=() rc=0
    [ -n "$OUTPUT" ] || return 1
    [ -n "$TV_RATE" ] && rate=(--rate "$TV_RATE")
    fb="${ZOOM_FB:-$NATIVE_RES}"
    if [ "$aw" = "0" ] && [ "$w" -ge "$nw" ] && [ "$h" -ge "$nh" ]; then
        fw=${fb%x*}; fh=${fb#*x}
        (( x + w > fw )) && fw=$(( x + w ))
        (( y + h > fh )) && fh=$(( y + h ))
        _display_do "$(printf '%q ' xrandr --fb "$(_screen_size "${fw}x${fh}")" --output "$OUTPUT" \
                            --mode "$NATIVE_RES" "${rate[@]}" --transform none) \
                     || { echo 'WARNING: GPU zoom to ${w}x${h}+${x}+${y} failed'; false; }" || rc=1
        [ -n "$PANEL_FD" ] && echo hide >&"$PANEL_FD"     # (nothing beside it)
        return $rc
    fi
    # The transform, the X screen's size, then the area the TV shows (left
    # top right bottom) and the game's area - for the black panels
    read -r t fb panels < <(awk -v w="$w" -v h="$h" -v x="$x" -v y="$y" -v aw="$aw" -v ah="$ah" \
            -v nw="$nw" -v nh="$nh" -v fb="$fb" -v view="${ZOOM_FB_VIEW:-0}" 'BEGIN {
        a = (aw > 0 && ah > 0) ? aw / ah : w / h      # shape to show
        dh = nh; dw = nh * a                          # size on the TV
        if (dw > nw) { dw = nw; dh = nw / a }
        sx = w / dw; sy = h / dh
        tx = x - (nw - dw) / 2 * sx; ty = y - (nh - dh) / 2 * sy
        # An area within 0.5% of the TV shape (e.g. 1366x768) fills
        # the TV exactly - kept "in shape", the picture reached a fraction
        # of a pixel past it, and xrandr refused it if the X screen ends there
        r = (w / h) / (nw / nh)
        if (aw == 0 && r > 0.995 && r < 1.005) { sx = w / nw; sy = h / nh; tx = x; ty = y }
        split(fb, F, "x")
        if (x + w > F[1]) F[1] = x + w                # X screen holds the area...
        if (y + h > F[2]) F[2] = y + h
        if (view == 1) {                              # ...and the whole view
            r = int(tx + nw * sx) + 1; if (r > F[1]) F[1] = r
            b = int(ty + nh * sy) + 1; if (b > F[2]) F[2] = b
        }
        printf "%.6f,0,%.6f,0,%.6f,%.6f,0,0,1 %dx%d ", sx, tx, sy, ty, F[1], F[2]
        if (x <= 0 && y <= 0 && x + w >= F[1] && y + h >= F[2]) print "hide"
        else printf "%d %d %d %d %d %d %d %d\n", int(tx) - 2, int(ty) - 2,
                    int(tx + nw * sx) + 2, int(ty + nh * sy) + 2, x, y, w, h }')
    _display_do "$(printf '%q ' xrandr --fb "$(_screen_size "$fb")" --output "$OUTPUT" \
                        --mode "$NATIVE_RES" "${rate[@]}" --transform "$t" \
                        --filter "${SCALE_FILTER:-bilinear}") \
                 || { echo 'WARNING: GPU zoom to ${w}x${h}+${x}+${y} failed'; false; }" || rc=1
    [ -n "$PANEL_FD" ] && echo "$panels" >&"$PANEL_FD"
    return $rc
}

# panels_start name [fence]
#   Black panels over everything the TV shows beside the game's area (Wine
#   leaves old pictures, or white, there), kept on top of Wine's windows.
#   zoom_to tells them what to cover. One Python process (panels.py, this
#   folder; X11 via ctypes, nothing to install). name = a tag in its
#   command line, e.g. nfsu-panels. fence=1: also pointer barriers round
#   the game's area, so the mouse stays on the picture. Start it in the
#   same (background) process that calls zoom_to.
panels_start() {
    PANEL_FD=""
    trap '' PIPE                    # a dead panel helper mustn't end the caller
    if ! command -v python3 >/dev/null; then
        echo "WARNING: python3 not found - no black panels beside the game"
        return 1
    fi
    local fb
    fb="$(_screen_size "${ZOOM_FB:-$NATIVE_RES}")"      # (the whole X screen, for the fence)
    coproc PANELS { exec python3 -I "$COMMON_DIR/panels.py" "$1" "${fb%x*}" "${fb#*x}" "${2:-0}"; }
    PANEL_FD="${PANELS[1]}"
}

# panels_stop - ends the panel helper (whichever process started it)
panels_stop() {
    pkill -f "$COMMON_DIR/panels.py" 2>/dev/null
}

# focus_start program...
#   Keeps the keyboard with the game: whenever no window has the keyboard
#   focus, it's given to the largest visible window of these programs (e.g.
#   explorer.exe = Wine's desktop, which passes keys on to the game). Never
#   takes the focus from a window that has it. One Python process
#   (focus.py, this folder). Messages into the log.
focus_start() {
    command -v python3 >/dev/null || { echo "WARNING: python3 not found - keyboard focus not kept"; return 1; }
    python3 -I "$COMMON_DIR/focus.py" keep-focus "$@" &
}

# focus_stop - ends it
focus_stop() {
    pkill -f "$COMMON_DIR/focus.py" 2>/dev/null
}

# fence_area tag W H [X Y]
#   Keeps the mouse pointer on the area W x H at X,Y (default 0,0) of the X
#   screen - for a game scaled up with scale_fixed, whose X screen is a
#   little bigger than the game (that strip is X's black background).
#   Pointer barriers round the area, plus a black panel over the rest
#   (panels.py, fence on). tag = a name in its command line, e.g.
#   tanks-panels. Start it in the main (Inside X) process; panels_stop ends it.
fence_area() {
    local w=$2 h=$3 x=${4:-0} y=${5:-0}
    [ -n "$OUTPUT" ] || return 0
    panels_start "$1" 1 || return 0
    echo "0 0 ${FB_W:-$w} ${FB_H:-$h} $x $y $w $h" >&"$PANEL_FD"
}

# find_window [min-w [min-h]]
#   The game's largest visible window at least min-w x min-h (default
#   300x200): prints "W H X Y", or nothing. The game = WINDOW_EXE (default
#   GAME_EXE), any upper/lower case.
find_window() {
    local exe="${WINDOW_EXE:-$GAME_EXE}" id w h x y
    xwininfo -root -tree 2>/dev/null | awk -v exe="(\"${exe,,}\"" -v mw="${1:-300}" -v mh="${2:-200}" '
        index(tolower($0), exe) {
            size = ""
            for (i = 2; i < NF; i++) if ($i ~ /^[0-9]+x[0-9]+[+-]/) { size = $i; break }
            if (size == "") next
            split(size, d, /[x+-]/); w = d[1]; h = d[2]
            if (w < mw || h < mh) next
            a = $NF; n = match(substr(a, 2), /[+-]/)          # absolute "+X+Y"
            x = substr(a, 1, n) + 0; y = substr(a, n + 1) + 0
            print $1, w, h, x, y, w * h
        }' | sort -k6 -nr |
    while read -r id w h x y _; do
        if xwininfo -id "$id" 2>/dev/null | grep -q 'IsViewable'; then
            echo "$w $h $x $y"
            break
        fi
    done
}

# follow_window [min-w [min-h]]
#   Background helper (start it with &): zooms the TV to the game's window
#   (find_window, at least min-w x min-h) whenever its size or position
#   changes, and says so in the log. No game window (loading, a mode
#   switch): the zoom stays as it is. Checks 4 times a second for the first
#   20 s (quick rescaling at start-up, so the start-up message cover lifts
#   sooner), then twice a second. Optional settings:
#     START_GEO        "W H X Y" - the zoom set when X started. The black
#                      panels are told it at once (otherwise they'd wait for
#                      the first change, which may never come), and a first
#                      window that size is no change at all
#     FOLLOW_PANELS    name for the black panels beside the game
#                      (panels_start); empty = no panels
#     FOLLOW_FENCE     1 = the panels also fence the mouse onto the game
#     FOLLOW_HOLD_FULL 1 = a window the TV's full size is followed only if
#                      it stays 3 s: it's the game's window BEFORE it sets
#                      its screen mode (brief), and the zoom would jump to
#                      1:1 and back
#     FOLLOW_CLIP      "W H" - only the part of the window inside 0,0 - W,H
#                      (the X screen) is zoomed to: for a window hanging off
#                      the screen's edges (e.g. maximised, with no window
#                      manager). Less than 100x50 left = ignored
#   follow_window_map W H X Y - if the script defines it: called with each
#   window found (after FOLLOW_CLIP), it sets FOLLOW_GEO to the area to zoom
#   to instead ("W H X Y [AW AH]", as zoom_to), or to "" to skip this
#   window. It runs in this helper's own process, so it can keep state in
#   variables between calls (e.g. the menu window seen first).
#   follow_window_hook "W H X Y" changed - if the script defines it: called
#   for every window found (after the full-size check), changed = 1 if it's
#   a different one (before zooming to it). E.g. remembering it for the next
#   launch.
follow_window() {
    local geo last="$START_GEO" full=0 n=0 q changed
    local tv="${NATIVE_RES%x*} ${NATIVE_RES#*x}"
    if [ -n "$FOLLOW_PANELS" ] && panels_start "$FOLLOW_PANELS" "${FOLLOW_FENCE:-0}"; then
        # shellcheck disable=SC2086
        [ -n "$START_GEO" ] && zoom_to $START_GEO
    fi
    while :; do
        if [ "$n" -lt 80 ]; then q=1; n=$((n + 1)); sleep 0.25; else q=2; sleep 0.5; fi
        geo="$(find_window "$@")"
        [ -n "$geo" ] || continue
        if [ -n "$FOLLOW_CLIP" ]; then
            geo="$(_clip_geo $geo $FOLLOW_CLIP)"
            [ -n "$geo" ] || continue
        fi
        if declare -F follow_window_map >/dev/null; then
            FOLLOW_GEO="$geo"
            # shellcheck disable=SC2086
            follow_window_map $geo
            geo="$FOLLOW_GEO"
            [ -n "$geo" ] || continue
        fi
        if [ "$FOLLOW_HOLD_FULL" = "1" ] && [ "${geo% * *}" = "$tv" ]; then
            full=$(( full + q ))                # (in quarter seconds)
            [ "$full" -lt 12 ] && continue
        else
            full=0
        fi
        changed=0; [ "$geo" = "$last" ] || changed=1
        declare -F follow_window_hook >/dev/null && follow_window_hook "$geo" "$changed"
        [ "$changed" = "1" ] || continue
        last="$geo"
        echo "Game window: $geo"
        # shellcheck disable=SC2086
        zoom_to $geo
    done
}

# _clip_geo W H X Y CW CH - the part of area W x H at X,Y inside 0,0 - CW,CH:
#   prints "W H X Y", or nothing if less than 100x50 is left
_clip_geo() {
    local x0=$3 y0=$4 x1=$(( $3 + $1 )) y1=$(( $4 + $2 ))
    (( x0 < 0 )) && x0=0;   (( y0 < 0 )) && y0=0
    (( x1 > $5 )) && x1=$5; (( y1 > $6 )) && y1=$6
    (( x1 - x0 >= 100 && y1 - y0 >= 50 )) && echo "$(( x1 - x0 )) $(( y1 - y0 )) $x0 $y0"
}
