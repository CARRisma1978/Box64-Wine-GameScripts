# =============================================================================
#  Shared launcher code - loaded (sourced) by each game's .sh in roms/windows
#  Named .inc, not .sh, so EmulationStation doesn't list it as a game.
#
#  Functions only: nothing happens until a script calls them. Every game
#  setting (BIGBLOCK, DYNACACHE, CPU_PERFORMANCE...) stays in the game's own
#  script; these functions read them. A setting a script leaves out gets the
#  default noted below.
#
#  A game's script sets GAME_ID (its short name, = its prefix folder),
#  GAME_DIR, GAME_EXE and its settings, loads this, then calls launch "$@"
#  (see "Launching" below) with its own in_x function.
#
#  Also loads, from this folder: settings.cfg (settings shared by all the
#  games - Wine, Box64, the TV, sound), display.inc (screen scaling and
#  zoom, black panels, mouse fence, keyboard focus, finding and following
#  the game's window), sound.inc (sound mixers, FluidSynth) and the
#  start-up messages (bootlog.inc + bootlog.py).
# =============================================================================

COMMON_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# ----- Shared settings (settings.cfg) -----------------------------------------
# Each KEY="value" line in settings.cfg, unless the game's script has already
# set that KEY itself (its value wins). Then the built-in values for anything
# still unset - the same as settings.cfg's, so a missing file changes nothing
# (start_x notes it in the game's log).
SETTINGS_NOTE=""
load_settings() {
    local file="$COMMON_DIR/settings.cfg" line key
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)= ]] || continue
            key="${BASH_REMATCH[1]}"
            [ -n "${!key+x}" ] && continue          # (set by the game's script)
            eval "$line"
        done < "$file"
    else
        SETTINGS_NOTE="NOTE: $file not found - built-in settings used"
    fi
    : "${WINE_DIR:=$HOME/wine-wow64/wine/bin}"
    : "${WINE_BIN:=$WINE_DIR/wine}"
    : "${WINESERVER_BIN:=$WINE_DIR/wineserver}"
    : "${BOX64_BIN:=$(command -v box64 || echo /usr/local/bin/box64)}"
    : "${NATIVE_RES:=1920x1080}"
    : "${SCALE_FILTER:=bilinear}"
    : "${HDMI_CARD:=vc4hdmi0}"
    : "${PA_LATENCY_MS=60}"
    : "${SOUNDFONT:=/usr/share/sounds/sf2/FluidR3_GM.sf2}"
    # (read by bootlog.py)
    [ -n "${BOOT_LOG_MIN_WINDOW:-}" ] && export BOOT_LOG_MIN_WINDOW
    return 0
}
load_settings

# ----- The game (GAME_ID) -----------------------------------------------------
# From the game's short name: its prefix (~/wine-prefixes/GAME_ID) and its
# log (GAME_DIR/GAME_ID-launch.log, overwritten each launch). A script that
# sets WINEPREFIX or LOG_FILE itself keeps its own.
if [ -n "${GAME_ID:-}" ]; then
    : "${WINEPREFIX:=$HOME/wine-prefixes/$GAME_ID}"
    : "${LOG_FILE:=$GAME_DIR/$GAME_ID-launch.log}"
fi
export WINEPREFIX

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
    start_boot_log() { echo "WARNING: $COMMON_DIR/bootlog.inc not found - no start-up messages on screen"; }
    stop_boot_log() { :; }
    boot_hold_release() { :; }
fi

# ----- Display and sound ------------------------------------------------------
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

# ----- Wine's and Box64's messages --------------------------------------------
# wine_logging [extra Wine debug channels]
#   Normally: one line per DLL Wine loads and per program / library Box64
#   loads - what the start-up messages show; cheap. Wine's "fixme" notes
#   off (some games print one every frame - hundreds of MB of log).
#   From the script's settings:
#     DEBUG=1       Wine's errors (+ crash details, +seh) and Box64's crash
#                   reports with backtraces instead - big log, slower start.
#                   Any extra channels given are added (e.g. +loaddll)
#     RDTSC_1GHZ=1  steadier timing on the Pi's slow counter
#   Box64's lines go straight to stderr, so they show as they happen.
wine_logging() {
    export WINEDEBUG="fixme-all,+loaddll" BOX64_LOG=1 BOX64_TRACE_FILE=stderr
    if [ "$DEBUG" = "1" ]; then
        export WINEDEBUG="err+all,fixme-all,+seh${1:+,$1}"
        export BOX64_SHOWSEGV=1 BOX64_SHOWBT=1
    fi
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

# ----- OpenGL (Mesa) ----------------------------------------------------------
# gl_setup [gl33] - for a game drawn with OpenGL (its own, or through Wine's
#   Direct3D / DirectDraw):
#     - Mesa skips its GL error checking (MESA_NO_ERROR)
#     - GLTHREAD (the script's setting): 1 = Mesa's GL work on its own
#       thread, 0 = off; not set = Mesa's default
#     - gl33 (or the script's GL33=1): report OpenGL 3.3 (the Pi's V3D
#       reports 3.1), for wined3d's modern GLSL path
gl_setup() {
    export MESA_NO_ERROR=1
    case "${GLTHREAD:-}" in
        1) export mesa_glthread=true ;;
        0) export mesa_glthread=false ;;
    esac
    if [ "$1" = "gl33" ] || [ "${GL33:-}" = "1" ]; then
        export MESA_GL_VERSION_OVERRIDE=3.3 MESA_GLSL_VERSION_OVERRIDE=330
    fi
    return 0
}

# ----- Set-up steps (shown by the start-up messages) --------------------------
# step "Label" command [args...]
#   Runs one set-up task in this shell (so the variables it sets are kept)
#   and logs a line when it starts and one when it ends:
#     [setup] Label...
#     [setup] Label: result (12.3s)
#   The start-up messages (bootlog.py) pin these at the top of the screen,
#   with a live counter while one runs - shown whenever one takes half a
#   second or more, or fails. The command can set STEP_RESULT for the result
#   word (default "done"; "FAILED" when it returns non-zero).
#   Use it only for work that's really being done, not "nothing to do".
step() {
    local label="$1" t r us
    shift
    STEP_RESULT=""
    echo "[setup] $label..."
    t="${EPOCHREALTIME/[.,]/}"
    "$@"
    r=$?
    us=$(( ${EPOCHREALTIME/[.,]/} - t ))
    [ "$r" -ne 0 ] && STEP_RESULT="FAILED"
    printf '[setup] %s: %s (%d.%ds)\n' "$label" "${STEP_RESULT:-done}" \
        $(( us / 1000000 )) $(( us / 100000 % 10 ))
    return "$r"
}

# setup_done - after the game's set-up (prefix, registry...) and before it
#   starts: from here on, the start-up messages time the game's own start
#   (their progress bar and what they learn for next time never include the
#   set-up, however long it took)
setup_done() { echo "[setup-done]"; }

# ----- Wine prefix ------------------------------------------------------------
# prefix_setup
#   Creates the prefix on the first run, and finishes a pending prefix
#   update here (not in the background while the game starts), once after
#   each Wine update - marker .wine_updated in the prefix. Sets
#   PREFIX_UPDATED=1 when it did. A prefix it has just created is already
#   up to date with this Wine: only the marker is written. Then shares the
#   prefix's Wine files with the other games (prefix_share).
PREFIX_UPDATED=0
prefix_setup() {
    local inf="${WINE_DIR%/bin}/share/wine/wine.inf" mark="$WINEPREFIX/.wine_updated" stamp=""
    [ -f "$inf" ] && stamp="$(stat -c %Y "$inf")"
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        mkdir -p "$WINEPREFIX"
        step "Creating Wine prefix (first run)" _wineboot -i
        [ -n "$stamp" ] && [ -f "$WINEPREFIX/system.reg" ] && echo "$stamp" > "$mark"
    fi
    if [ -n "$stamp" ] && [ "$stamp" != "$(cat "$mark" 2>/dev/null)" ]; then
        # The shared copy first, then this prefix - on its own files, so the
        # update never writes into a file other games share
        share_master "$stamp"
        prefix_unshare "before the update"
        rm -f "$WINEPREFIX/.shared"
        step "Updating Wine prefix (new Wine version)" _wineboot -u
        echo "$stamp" > "$mark"
        PREFIX_UPDATED=1
    fi
    prefix_share "$stamp"
    return 0
}

# _wineboot -i|-u - creates / updates the prefix (WINEPREFIX), waits for Wine
_wineboot() {
    wine wineboot "$1"
    wineserver -w
    [ -f "$WINEPREFIX/system.reg" ]
}

# ----- Sharing Wine's files between the game prefixes -------------------------
# Every prefix holds its own ~600 MB copy of Wine's files (drive_c/windows/
# system32 and syswow64) - nearly all identical. With sharing on, each
# prefix's identical files are hard links to one copy, kept in a plain
# prefix of their own: ~/wine-prefixes/.master (made and kept up to date by
# the wine module, or here if it's missing). Only files at the same place
# with the same contents are shared; anything a game changes or adds stays
# its own.
#   - On/off: the wine module's "Share identical Wine files between game
#     prefixes" (share_prefixes in WINE_SETUP_CFG).
#   - PREFIX_LINK=0 in a game's script: that game never shares (it gets its
#     own copies back if it did); marker .nolink in its prefix, so the wine
#     module's "Share now" leaves it out too.
#   - A prefix is never updated while it shares (Wine writes its new files
#     into the existing ones): it gets its own copies first, and is shared
#     again afterwards.
#   - A script that puts its own file into system32 / syswow64 must replace
#     the file, not write into it: cp --remove-destination. A Windows
#     program that does (e.g. an installer) writes into it - call
#     prefix_private before running it.
#   Markers: .shared in a prefix = shared with this Wine version's master;
#   .wine_updated in the master = the Wine version it's up to date with.
#   Needs hardlink (util-linux).
WINE_SETUP_CFG="${WINE_SETUP_CFG:-/opt/retropie/configs/all/wine-setup.cfg}"
SHARE_MASTER="$(dirname "$WINEPREFIX")/.master"

share_enabled() {
    [ "$(grep -oP '^share_prefixes\s*=\s*"\K[^"]*' "$WINE_SETUP_CFG" 2>/dev/null | tail -n1)" = "on" ]
}

# share_master stamp - makes sure the master is up to date with this Wine
#   (stamp = wine.inf's time); false if sharing is off or it can't be
share_master() {
    share_enabled && [ -n "$1" ] || return 1
    [ "$(cat "$SHARE_MASTER/.wine_updated" 2>/dev/null)" = "$1" ] && return 0
    step "Preparing the shared Wine files (once per Wine version)" _share_master_update "$1"
}
_share_master_update() (
    export WINEPREFIX="$SHARE_MASTER"
    rm -f "$WINEPREFIX/.wine_updated"
    if [ -f "$WINEPREFIX/system.reg" ]; then
        _unshare_files "$WINEPREFIX"
        _wineboot -u
    else
        mkdir -p "$WINEPREFIX"
        _wineboot -i
    fi || return 1
    echo "$1" > "$WINEPREFIX/.wine_updated"
)

# prefix_share stamp - shares this prefix's Wine files (when sharing is on,
#   PREFIX_LINK isn't 0 and they aren't shared with this Wine's master yet)
prefix_share() {
    local stamp="$1"
    [ -f "$WINEPREFIX/system.reg" ] || return 0
    if [ "${PREFIX_LINK:-1}" = "0" ]; then
        touch "$WINEPREFIX/.nolink"
        prefix_unshare "PREFIX_LINK=0"
        rm -f "$WINEPREFIX/.shared"
        return 0
    fi
    rm -f "$WINEPREFIX/.nolink"
    share_enabled && [ -n "$stamp" ] || return 0
    [ "$(cat "$WINEPREFIX/.shared" 2>/dev/null)" = "$stamp" ] && return 0
    if ! command -v hardlink >/dev/null; then
        echo "WARNING: hardlink not found (util-linux) - Wine files not shared"
        return 0
    fi
    share_master "$stamp" || return 0
    step "Sharing Wine files with the other games" _share_files "$stamp"
}

# _share_files stamp - links this prefix's identical files to the master's:
#   same place (folder and name) and same contents only
_share_files() {
    local d out opts=(-p -o -t -f -m) files=0 kib=0
    hardlink --help 2>&1 | grep -q -- '--respect-dir' && opts+=(-d)
    for d in system32 syswow64; do
        [ -d "$SHARE_MASTER/drive_c/windows/$d" ] && [ -d "$WINEPREFIX/drive_c/windows/$d" ] || continue
        out="$(hardlink "${opts[@]}" "$SHARE_MASTER/drive_c/windows/$d" "$WINEPREFIX/drive_c/windows/$d" 2>&1)" \
            || { echo "$out"; return 1; }
        read -r files kib < <(echo "$out" | awk -v f="$files" -v k="$kib" '
            /^Linked:/ { f += $2 }
            /^Saved:/  { m = ($3 == "B") ? 1/1024 : ($3 == "KiB") ? 1 : ($3 == "MiB") ? 1024 : ($3 == "GiB") ? 1048576 : 0
                         k += $2 * m }
            END { printf "%d %d\n", f, k }')
    done
    echo "$1" > "$WINEPREFIX/.shared"
    STEP_RESULT="$files files, $(( kib / 1024 )) MB saved"
}

# prefix_private why - before running a Windows program that may write
#   into Wine's files (an installer, say): this prefix gets its own copy of
#   every file it shares, and is shared again (identical files only) on the
#   game's next start
prefix_private() {
    prefix_unshare "$1"
    rm -f "$WINEPREFIX/.shared"
}

# prefix_unshare why - gives this prefix its own copy of every Wine file it
#   shares (nothing to do if it shares none)
prefix_unshare() {
    [ -n "$(find "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64" \
            -type f -links +1 -print -quit 2>/dev/null)" ] || return 0
    step "Unsharing Wine files ($1)" _unshare_files "$WINEPREFIX"
}
_unshare_files() {
    local f n=0
    while IFS= read -r -d '' f; do
        cp -p "$f" "$f.unshare" && mv -f "$f.unshare" "$f" && n=$((n + 1))
    done < <(find "$1/drive_c/windows/system32" "$1/drive_c/windows/syswow64" \
                 -type f -links +1 -print0 2>/dev/null)
    STEP_RESULT="$n files"
}

# import_reg file applied-copy
#   Imports a .reg file only when it differs from the copy saved after the
#   last import (each import is a full Box64 + Wine start-up)
import_reg() {
    cmp -s "$1" "$2" && return 0
    step "Registry settings ($(basename "$1"))" _import_reg "$1" "$2"
}
_import_reg() {
    local reg="$1" old="$2" win r
    case "$reg" in
        "$WINEPREFIX/drive_c/"*) win="C:\\${reg#"$WINEPREFIX/drive_c/"}" ;;
        *)                       win="Z:$reg" ;;
    esac
    win="${win//\//\\}"
    wine regedit /S "$win" && cp "$reg" "$old"
    r=$?
    wineserver -w
    STEP_RESULT="imported"
    return "$r"
}

# wine_base_reg [dsound] - the start of a game's .reg file: the Wine
#   settings every game uses. A script writes this, then its own keys:
#       { wine_base_reg; cat <<EOF ... EOF; } > "$reg"
#   - Wine mustn't change the TV's screen mode (the scripts zoom and scale
#     the picture themselves)
#   - a black Wine desktop (beside / around the game's picture)
#   - Wine's sound output for SOUND_MIXER: the ALSA mixer (0) and plain ALSA
#     (1) = "alsa", PulseAudio (2) = "pulse"
#   - dsound: software-mixed DirectSound (fixed hangs in several games)
wine_base_reg() {
    cat <<'EOF'
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the scripts' zoom
[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

[HKEY_CURRENT_USER\Control Panel\Desktop]
"Wallpaper"=""

; Wine's sound output (SOUND_MIXER)
[HKEY_CURRENT_USER\Software\Wine\Drivers]
EOF
    if [ "$SOUND_MIXER" = "2" ]; then echo '"Audio"="pulse"'; else echo '"Audio"="alsa"'; fi
    if [ "$1" = "dsound" ]; then
        printf '\n; Software-mixed DirectSound\n[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]\n"HardwareAcceleration"="Emulation"\n'
    fi
    echo
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
    local dir="$1" merit="$2" lost="${3:+ - $3}" src
    local installed="$WINEPREFIX/.lavfilters_installed" fixed="$WINEPREFIX/.lavsplitter_merit"
    if [ ! -f "$installed" ]; then
        src="$(find "$dir" -iname 'LAVSplitter.ax' 2>/dev/null | head -n1)"
        if [ -z "$src" ]; then
            echo "WARNING: LAVSplitter.ax not found in $dir$lost"
            return 1
        fi
        echo "LAV Filters from $(dirname "$src")"
        step "Installing LAV Filters (first run)" _lav_install "$(dirname "$src")" || return 1
        touch "$installed"
        rm -f "$fixed"
    fi
    LAV_INSTALLED=1
    [ "$PREFIX_UPDATED" = "1" ] && rm -f "$fixed"
    if [ "$(cat "$fixed" 2>/dev/null)" != "$merit" ]; then
        step "Registering LAV Splitter (merit $merit)" _lav_merit "$merit" && echo "$merit" > "$fixed"
    fi
    return 0
}
_lav_install() {
    local ax
    mkdir -p "$WINEPREFIX/drive_c/LAVFilters"
    cp -rf "$1"/. "$WINEPREFIX/drive_c/LAVFilters/" || return 1
    for ax in LAVSplitter.ax LAVAudio.ax; do
        wine 'C:\windows\syswow64\regsvr32.exe' /s "C:\\LAVFilters\\$ax"
    done
    wineserver -w
    STEP_RESULT="installed"
}
_lav_merit() {
    local le="${1:6:2}${1:4:2}${1:2:2}${1:0:2}" r       # (little-endian)
    wine reg add \
        'HKCR\CLSID\{083863F1-70DE-11d0-BD40-00A0C911CE86}\Instance\{171252A0-8820-4AFE-9DF8-5C92B2D66B04}' \
        /v FilterData /t REG_BINARY /f /reg:32 /d \
        "02000000${le}0200000000000000307069330C0000000100000001000000000000000000000030747933000000006000000060000000317069330000000001000000010000000000000000000000307479330000000070000000600000000000000000000000000000000000000083EB36E44F52CE119F530020AF0BA770"
    r=$?
    wineserver -w
    return "$r"
}

# ----- Settings into the environment ------------------------------------------
# vsync_setup - VSYNC for Mesa: 0 = off (vblank_mode=0), 1 or empty = the
#   game decides (Mesa's default), 2 = always on (vblank_mode=3)
vsync_setup() {
    case "$VSYNC" in
        0) export vblank_mode=0 ;;
        2) export vblank_mode=3 ;;
    esac
    return 0
}

# log_settings [VAR | NAME=text]... - the line that starts the game's part
#   of the log: the date, then the standard settings the script has (in this
#   order), then the given ones (a variable's name, or text to show as it is)
log_settings() {
    local v line="=== $(date) ==="
    for v in GAME_RES VSYNC GLTHREAD BIGBLOCK X87DOUBLE CALLRET STRONGMEM DYNACACHE \
             RDTSC_1GHZ CPU_PERFORMANCE SOUND_MIXER MOUSE_FENCE "$@"; do
        if [[ "$v" == *=* ]]; then
            line+=" $v"
        elif [ -n "${!v+x}" ]; then
            line+=" $v=${!v}"
        fi
    done
    echo "$line"
}

# ----- Launching --------------------------------------------------------------
# launch "$@" - the end of every game's script:
#   --kill          close a stuck game over SSH (kill_game)
#   (no argument)   from EmulationStation: the script's own check_game
#                   function if it has one (it exits, with its own message,
#                   if something is missing), then checks Box64, Wine, the
#                   game's exe (in GAME_DIR, or its GAME_EXE_DIR subfolder
#                   if the script sets one) and CHECK_FILES (an array of any
#                   more files it needs), empties the log, then starts X
#                   just for the game, on EmulationStation's console
#                   (HIDE_CURSOR=1: no mouse pointer), and runs the script
#                   again inside it
#   --in-x          (inside X) output to the log, no terminal as input (or
#                   Wine starts a console helper for it), the shared cleanup
#                   when it ends, no screen blanking (a gamepad doesn't
#                   reset it), Mesa's vsync (VSYNC) - then the script's in_x
#                   function: the display, the start-up messages, the
#                   set-up, the sound and the game
CHECK_FILES=()
launch() {
    if [ "$1" = "--kill" ]; then
        kill_game
        exit 0
    fi
    if [ "$1" != "--in-x" ]; then
        declare -F check_game >/dev/null && check_game
        check_files "$GAME_DIR/${GAME_EXE_DIR:+$GAME_EXE_DIR/}$GAME_EXE" "${CHECK_FILES[@]}"
        : > "$LOG_FILE"
        local opts=(-quiet)
        [ "$HIDE_CURSOR" = "1" ] && opts+=(-nocursor)
        start_x "${opts[@]}"
        wineserver -k 2>/dev/null       # (nothing left running)
        exit 0
    fi
    exec < /dev/null >> "$LOG_FILE" 2>&1
    MAIN_PID=$$                         # (helpers can stop when this does)
    trap cleanup EXIT INT TERM
    xset s off -dpms s noblank 2>/dev/null
    vsync_setup
    in_x
    exit 0
}

# ----- Cleaning up ------------------------------------------------------------
# cleanup - when the script ends inside X (set up by launch): stops the
#   start-up messages, the window watcher (WATCH_PID), the black panels, the
#   focus helper, Wine, the sound mixer and FluidSynth, everything added with
#   cleanup_add, and puts the CPU governor back. Each step does nothing if
#   that part wasn't started.
# cleanup_add pattern|PID - also stop this when the script ends: a PID, or a
#   pattern matched against command lines (pkill -f) - for a game's own
#   background helpers. Added where the helper is started.
CLEANUP_ITEMS=()
cleanup_add() { CLEANUP_ITEMS+=("$1"); }
cleanup() {
    local item
    stop_boot_log
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
    for item in "${CLEANUP_ITEMS[@]}"; do
        if [[ "$item" =~ ^[0-9]+$ ]]; then
            kill "$item" 2>/dev/null
        else
            pkill -u "$(id -u)" -f "$item" 2>/dev/null
        fi
    done
    panels_stop
    focus_stop
    wineserver -k 2>/dev/null
    fluidsynth_stop
    sound_mixer_stop
    restore_governor
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
    [ -n "$SETTINGS_NOTE" ] && echo "$SETTINGS_NOTE" >> "$LOG_FILE"
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
        # (gone)
        GAME_CMDLINE="$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline")" || continue
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
