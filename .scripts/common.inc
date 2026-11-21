# =============================================================================
#  Shared launcher code - loaded (sourced) by each game's .sh in roms/windows
#  Named .inc, not .sh, so EmulationStation doesn't list it as a game.
#
#  Functions only: nothing happens until a script calls them. Every setting
#  (BIGBLOCK, DYNACACHE, CPU_PERFORMANCE...) stays in the game's own script;
#  these functions read them. A setting a script leaves out gets the
#  default noted below.
#
#  Also loads, from this folder: display.inc (screen scaling and zoom, black
#  panels, mouse fence, keyboard focus, finding and following the game's
#  window), sound.inc (sound mixers, FluidSynth) and the start-up messages
#  (bootlog.inc + bootlog.py).
# =============================================================================

COMMON_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# While the start-up messages show, they hold the TV at 1:1 (sharp text, the
# full TV); the game's zoom waits in ZOOM_CMD_FILE until the black cover goes
# up (display.inc, bootlog.inc, bootlog.py, panels.py). One left over from a
# crash is cleared here.
_rt="${XDG_RUNTIME_DIR:-/tmp}"; [ -d "$_rt" ] && [ -w "$_rt" ] || _rt=/tmp
export BOOT_HOLD_FILE="$_rt/winegame-boot-hold-$(id -u)"
export ZOOM_CMD_FILE="$_rt/winegame-zoom-$(id -u)"
unset _rt
[ "$1" = "--in-x" ] && rm -f "$BOOT_HOLD_FILE" "$ZOOM_CMD_FILE"

# ----- Start-up messages ------------------------------------------------------
if [ -f "$COMMON_DIR/bootlog.inc" ]; then
    # shellcheck source=/dev/null
    . "$COMMON_DIR/bootlog.inc"
else
    start_boot_log() { [ "$BOOT_LOG" = "1" ] && echo "WARNING: $COMMON_DIR/bootlog.inc not found - no start-up messages on screen"; }
    stop_boot_log() { :; }
    boot_hold_release() { :; }
fi

# ----- Display and sound -------------------------------------------------------
for _inc in display.inc sound.inc; do
    if [ ! -f "$COMMON_DIR/$_inc" ]; then
        echo "ERROR: $COMMON_DIR/$_inc not found" | tee -a "${LOG_FILE:-/dev/null}"
        sleep 5; exit 1
    fi
    # shellcheck source=/dev/null
    . "$COMMON_DIR/$_inc"
done
unset _inc

# ----- Wine, run through Box64 ------------------------------------------------
# Uses BOX64_BIN, WINE_BIN and WINESERVER_BIN from the script
wine()       { "$BOX64_BIN" "$WINE_BIN" "$@"; }
wineserver() { "$BOX64_BIN" "$WINESERVER_BIN" "$@"; }

# stop_wine - ends any Wine left over from a crash, and waits (at most 5 s)
#   until it's really gone
stop_wine() {
    pgrep -f "$WINESERVER_BIN" >/dev/null || return 0
    wineserver -k 2>/dev/null
    local i
    for i in $(seq 1 25); do
        pgrep -f "$WINESERVER_BIN" >/dev/null || return 0
        sleep 0.2
    done
}

# kill_game - for "--kill" (closing a stuck game over SSH): ends Wine and
#   everything the shared code may have started (black panels and mouse
#   fence, keyboard focus helper, sound mixers, FluidSynth)
kill_game() {
    wineserver -k
    panels_stop
    focus_stop
    sound_kill
}

# Wine settings for every game. A script adds its own after loading this:
#   export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;name=setting"
#   mscoree,mshtml=        no .NET (Wine Mono) or Internet Explorer (Wine
#                          Gecko) - so no "install Mono/Gecko?" prompts
#   winemenubuilder.exe=d  no shortcuts or menu entries in the home folder
#   winedbg.exe=d          a crash just ends the game (no debugger window)
export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;winedbg.exe=d"

# Every prefix is 64-bit: these WOW64 Wine builds run 32-bit games in it too
# (only matters when a prefix is created)
export WINEARCH="win64"

# ----- Wine's and Box64's messages ---------------------------------------------
# wine_logging [extra Wine debug channels]
#   From the script's settings:
#     DEBUG=1       Wine's errors (+ crash details, +seh) and Box64's crash
#                   reports with backtraces - big log, slower start. Any
#                   extra channels given are added (e.g. +loaddll)
#     BOOT_LOG=1    (DEBUG=0) one line per DLL Wine loads and per program /
#                   library Box64 loads - what the start-up messages show;
#                   cheap. Wine's "fixme" notes off (some games print one
#                   every frame - 360 MB of log once in nfs6)
#     neither       Wine and Box64 quiet
#   BOOT_LOG=1 also: Box64's lines straight to stderr, so they show as they
#   happen. RDTSC_1GHZ=1: steadier timing on the Pi's slow counter.
wine_logging() {
    export WINEDEBUG="-all" BOX64_LOG=0
    if [ "$DEBUG" = "1" ]; then
        export WINEDEBUG="err+all,fixme-all,+seh${1:+,$1}"
        export BOX64_LOG=1 BOX64_SHOWSEGV=1 BOX64_SHOWBT=1
    elif [ "$BOOT_LOG" = "1" ]; then
        export WINEDEBUG="fixme-all,+loaddll"
        export BOX64_LOG=1
    fi
    [ "$BOOT_LOG" = "1" ] && export BOX64_TRACE_FILE=stderr
    [ "$RDTSC_1GHZ" = "1" ] && export BOX64_RDTSC_1GHZ=1
    return 0
}

# check_files [file...] - Box64, Wine and the given files must all exist
check_files() {
    local f
    for f in "$BOX64_BIN" "$WINE_BIN" "$WINESERVER_BIN" "$@"; do
        [ -e "$f" ] || { echo "ERROR: not found: $f"; sleep 5; exit 1; }
    done
}

# ----- Box64 ------------------------------------------------------------------
# box64_setup [exe...]
#   /etc/box64.box64rc sets MAXCPU=64 for Wine and wins over the
#   environment, so: a copy of it (and ~/.box64rc) without that line, in the
#   prefix, with the Pi's real 4 cores. Speed settings go in it for the
#   listed exes only (not Wine's own start-up programs, where bigger blocks
#   just add translating):
#     BIGBLOCK=0-3      code block size (Box64's default: 2)
#     STRONGMEM=0-3     memory ordering: 0 = off (Box64's default)
#     X87DOUBLE=0-2     x87 maths: 0 = lower precision where possible
#                       (Box64's default), 1 = always double, 2 = follows
#                       the game's precision setting
#     CALLRET=0-3       call/ret optimisation: 0 = off, 1 = on, 2 = on, also
#                       for changed code (Box64's default since v0.4.4),
#                       3 = as 2, plus protection from random crashes (Box64
#                       built 26 Oct 2026 or later)
#     Each one left empty = not set here, so Box64's default applies.
#     (fast NaN handling and rounding are always on for them)
#   Also: DYNACACHE = translated code kept on disk (Box64's "DynaCache"):
#     empty = on, one cache shared by all games (~/.cache/box64 - Box64's
#             default since v0.4.4; Wine's own files are translated once
#             for every game)
#     1     = on, the game's own cache (box64-cache in its prefix)
#     0     = off
#   FPS_HUD=1 = fps + total CPU, 2 = fps + each core (top-left).
box64_setup() {
    local f exe
    export BOX64_NOBANNER=1
    mkdir -p "$WINEPREFIX"
    local rc="$WINEPREFIX/box64rc"
    : > "$rc"
    # (and without any DynaCache setting there when the script sets it:
    #  the rc file would win over the one below)
    local drop='^[[:space:]]*BOX64_MAXCPU'
    [ -n "$DYNACACHE" ] && drop+='|^[[:space:]]*BOX64_DYNACACHE'
    for f in /etc/box64.box64rc "$HOME/.box64rc"; do
        [ -f "$f" ] && grep -vE "$drop" "$f" >> "$rc"
    done
    for exe in "$@"; do
        echo; echo "[$exe]"
        [ -n "$BIGBLOCK" ] && echo "BOX64_DYNAREC_BIGBLOCK=$BIGBLOCK"
        echo "BOX64_DYNAREC_FASTNAN=1"
        echo "BOX64_DYNAREC_FASTROUND=1"
        [ -n "$STRONGMEM" ]    && echo "BOX64_DYNAREC_STRONGMEM=$STRONGMEM"
        [ -n "$X87DOUBLE" ]    && echo "BOX64_DYNAREC_X87DOUBLE=$X87DOUBLE"
        [ -n "$CALLRET" ]      && echo "BOX64_DYNAREC_CALLRET=$CALLRET"
    done >> "$rc"
    export BOX64_RCFILE="$rc"
    export BOX64_MAXCPU=4

    case "$DYNACACHE" in
        1)  export BOX64_DYNACACHE=1
            export BOX64_DYNACACHE_FOLDER="$WINEPREFIX/box64-cache"
            mkdir -p "$BOX64_DYNACACHE_FOLDER" ;;
        0)  export BOX64_DYNACACHE=0 ;;
    esac
    [ "$FPS_HUD" = "1" ] && export GALLIUM_HUD="simple,fps,cpu"
    [ "$FPS_HUD" = "2" ] && export GALLIUM_HUD="simple,fps,cpu0+cpu1+cpu2+cpu3"
    return 0
}

# ----- Wine prefix ------------------------------------------------------------
# prefix_setup [name]
#   Creates the prefix on the first run. With a name, also finishes a
#   pending prefix update here (not in the background while the game
#   starts), once after each Wine update - marker .<name>_wine_updated in the
#   prefix. Sets PREFIX_UPDATED=1 when it did. A prefix it has just created
#   is already up to date with this Wine: only the marker is written.
PREFIX_UPDATED=0
prefix_setup() {
    local inf="${WINE_DIR%/bin}/share/wine/wine.inf" mark="$WINEPREFIX/.$1_wine_updated"
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        echo "Creating Wine prefix (first run - this takes a while)..."
        mkdir -p "$WINEPREFIX"
        wine wineboot -i
        wineserver -w
        [ -n "$1" ] && [ -f "$inf" ] && [ -f "$WINEPREFIX/system.reg" ] && stat -c %Y "$inf" > "$mark"
    fi
    [ -n "$1" ] || return 0
    if [ -f "$inf" ] && [ "$(stat -c %Y "$inf")" != "$(cat "$mark" 2>/dev/null)" ]; then
        echo "Updating Wine prefix (once)..."
        wine wineboot -u
        wineserver -w
        stat -c %Y "$inf" > "$mark"
        PREFIX_UPDATED=1
    fi
    return 0
}

# import_reg file applied-copy
#   Imports a .reg file only when it differs from the copy saved after the
#   last import (each import is a full Box64 + Wine start-up)
import_reg() {
    local reg="$1" old="$2" win
    cmp -s "$reg" "$old" && return 0
    case "$reg" in
        "$WINEPREFIX/drive_c/"*) win="C:\\${reg#"$WINEPREFIX/drive_c/"}" ;;
        *)                       win="Z:$reg" ;;
    esac
    win="${win//\//\\}"
    echo "Applying registry settings ($(basename "$reg"))..."
    wine regedit /S "$win" && cp "$reg" "$old"
    wineserver -w
}

# ----- LAV Filters (DirectShow) -----------------------------------------------
# lav_setup folder merit [what's lost without it]
#   For a 32-bit game whose DirectShow needs LAV Filters (the contents of the
#   LAVFilters-x.xx-x86 zip, in folder):
#   - Once: copied into the prefix as C:\LAVFilters, and LAV Splitter and
#     LAV Audio registered (LAV Video deliberately not - it crashes under
#     Box64). Marker .lavfilters_installed in the prefix - delete it to
#     reinstall.
#   - LAV Splitter re-registered with a wildcard output type (its own
#     registration has an output pin with no media types, which Wine skips)
#     and priority merit (8 hex digits, e.g. 00600000 = normal). Redone when
#     merit changes, after a Wine update (PREFIX_UPDATED) and after a
#     reinstall. Marker .lavsplitter_merit.
#   Wine must be stopped (runs Wine itself). LAV_INSTALLED=1 if LAV Filters
#   are in the prefix; false (with a warning) if they aren't.
LAV_INSTALLED=0
lav_setup() {
    local dir="$1" merit="$2" lost="${3:+ - $3}" src ax le
    local installed="$WINEPREFIX/.lavfilters_installed" fixed="$WINEPREFIX/.lavsplitter_merit"
    if [ ! -f "$installed" ]; then
        src="$(find "$dir" -iname 'LAVSplitter.ax' 2>/dev/null | head -n1)"
        if [ -z "$src" ]; then
            echo "WARNING: LAVSplitter.ax not found in $dir$lost"
            return 1
        fi
        echo "Installing LAV Filters from $(dirname "$src") (first run only)..."
        mkdir -p "$WINEPREFIX/drive_c/LAVFilters"
        cp -rf "$(dirname "$src")"/. "$WINEPREFIX/drive_c/LAVFilters/"
        for ax in LAVSplitter.ax LAVAudio.ax; do
            wine 'C:\windows\syswow64\regsvr32.exe' /s "C:\\LAVFilters\\$ax"
        done
        wineserver -w
        touch "$installed"
        rm -f "$fixed"
    fi
    LAV_INSTALLED=1
    [ "$PREFIX_UPDATED" = "1" ] && rm -f "$fixed"
    if [ "$(cat "$fixed" 2>/dev/null)" != "$merit" ]; then
        echo "Re-registering LAV Splitter (merit $merit)..."
        le="${merit:6:2}${merit:4:2}${merit:2:2}${merit:0:2}"      # (little-endian)
        wine reg add \
            'HKCR\CLSID\{083863F1-70DE-11d0-BD40-00A0C911CE86}\Instance\{171252A0-8820-4AFE-9DF8-5C92B2D66B04}' \
            /v FilterData /t REG_BINARY /f /reg:32 /d \
            "02000000${le}0200000000000000307069330C0000000100000001000000000000000000000030747933000000006000000060000000317069330000000001000000010000000000000000000000307479330000000070000000600000000000000000000000000000000000000083EB36E44F52CE119F530020AF0BA770" \
            && echo "$merit" > "$fixed"
        wineserver -w
    fi
    return 0
}

# ----- CPU governor -----------------------------------------------------------
# CPU_PERFORMANCE=1: 'performance' while playing (needs passwordless sudo)
OLD_GOVERNOR=""
set_governor() {
    [ "$CPU_PERFORMANCE" = "1" ] || return 0
    OLD_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo performance | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 \
        || echo "WARNING: could not set CPU governor (sudo needs a password?)"
}

restore_governor() {
    [ -n "$OLD_GOVERNOR" ] || return 0
    echo "$OLD_GOVERNOR" | sudo -n tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
}

# ----- X ----------------------------------------------------------------------
# start_x [X server options...]
#   From EmulationStation: start X just for the game, on ES's console, so it
#   exits cleanly back to ES. Runs this same script again inside X with
#   --in-x; returns when X has closed. Output goes to LOG_FILE.
start_x() {
    local vt
    vt="$(tty 2>/dev/null | sed -n 's|^/dev/tty\([0-9][0-9]*\)$|\1|p')"
    vt="${XDG_VTNR:-${vt:-1}}"
    xinit /bin/bash "$(readlink -f "$0")" --in-x -- :0 vt"$vt" \
        -nolisten tcp -keeptty "$@" >> "$LOG_FILE" 2>&1
    stamp "X closed" >> "$LOG_FILE"
    # When this copy of the script ends - added to any EXIT trap it has
    # (some stop their sound mixer that way)
    local t
    t="$(trap -p EXIT | sed "s/^trap -- '\(.*\)' EXIT$/\1/")"
    # shellcheck disable=SC2064
    trap "${t:+$t; }"'stamp "Script ended - back to EmulationStation" >> "$LOG_FILE"' EXIT
}

# stamp text - a log line with the time (to 1/1000 s), to see where time goes
stamp() { echo "[$(date +%T.%3N)] $*"; }

# ----- Waiting for the game to close ------------------------------------------
# game_running exe... - true while one of these runs, found by its process
#   name: Wine names each process after its exe (cut to 15 characters,
#   upper/lower case ignored; a path given is ignored too). Wine's own
#   wrappers (start.exe, explorer.exe), Box64 while Wine starts ("wine"),
#   this script and its python helpers have other names, even when the
#   game's exe is in their command line. The game's command line (or its
#   name, if Wine has blanked that) is left in GAME_CMDLINE.
game_running() {
    local p exe name names=" "
    for exe in "$@"; do
        exe="${exe##*[/\\]}"
        names+="${exe:0:15} "
    done
    names="${names,,}"
    while read -r p name; do
        [[ "$names" == *" ${name,,} "* ]] || continue
        GAME_CMDLINE="$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline")" || continue   # (gone)
        [ -n "${GAME_CMDLINE// /}" ] || GAME_CMDLINE="$name"
        return 0
    done < <(ps -u "$(id -u)" -o pid=,comm=)
    return 1
}

# wait_for_game launch-pid exe...
#   Returns once Wine (launch-pid) has finished. Normally Wine exits by
#   itself just after the game does - carry on the moment it does. If the
#   game has closed but Wine hangs on, return after WINE_EXIT_WAIT seconds
#   (default 10) so the script can end it. WINE_EXIT_WAIT=0: never end it
#   early - for a game started directly (wine game.exe), whose launch-pid
#   (Wine's start.exe) ends with the game. No time limit while the game
#   runs. Checked every 0.5 s (a ps - no Wine start-up).
#   The game counts as running once seen on 2 checks in a row (1 s), and as
#   closed once missing on 3 in a row (1.5 s).
wait_for_game() {
    _wait_for_game "$@"
    stamp "Wine finished - closing down"
}
_wait_for_game() {
    local pid="$1" seen=0 hits=0 misses=0 i
    shift
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.5
        if game_running "$@"; then
            misses=0
            hits=$((hits + 1))
            if [ "$seen" = "0" ] && [ "$hits" -ge 2 ]; then
                seen=1
                stamp "Game running: $GAME_CMDLINE"
            fi
        else
            hits=0
            [ "$seen" = "1" ] || continue
            misses=$((misses + 1))
            [ "$misses" = "1" ] && stamp "Game no longer seen"
            [ "$misses" -ge 3 ] || continue
            stamp "Game closed - waiting for Wine to finish"
            if [ "${WINE_EXIT_WAIT:-10}" = "0" ]; then
                while kill -0 "$pid" 2>/dev/null; do sleep 0.25; done
                return 0
            fi
            for (( i = 1; i <= ${WINE_EXIT_WAIT:-10} * 4; i++ )); do
                kill -0 "$pid" 2>/dev/null || return 0
                sleep 0.25
                # Safety net: if the game is there after all, carry on
                # watching rather than end it
                if (( i % 4 == 0 )) && game_running "$@"; then
                    echo "Game still running after all ($GAME_CMDLINE) - carrying on"
                    misses=0
                    continue 2
                fi
            done
            echo "Wine still running ${WINE_EXIT_WAIT:-10} s after the game closed - ending it."
            echo "Wine's processes at this point (in case the game was missed):"
            ps -u "$(id -u)" -o pid=,comm=,args= 2>/dev/null | grep -iE 'wine|box64|\.exe' \
                | grep -v grep | cut -c1-200 | head -20
            return 0
        fi
    done
    return 0
}
