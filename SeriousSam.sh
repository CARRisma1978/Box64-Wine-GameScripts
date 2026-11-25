#!/bin/bash
# =============================================================================
#  Serious Sam: The First Encounter (v1.05, OpenGL) - Wine (WOW64) +
#  Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  Note: the original v1.00 CD's exe has SafeDisc (a disc check), which
#  doesn't run under Wine - a v1.05 exe that runs without the disc works.
#
#  How it works:
#   - OpenGL -> Wine's opengl32 -> Mesa on the Pi's GPU (no wined3d, so no
#     GL 3.3 override needed). The game's Direct3D option is never used.
#   - The game's options are kept in Scripts\PersistentSymbols.ini (the game
#     saves them there when it quits). Pick the resolution in the GAME's
#     Options > Video menu - the zoom follows it, and the game keeps it for
#     next time. Full screen, OpenGL and DirectSound are written into the
#     file on every launch. A saved resolution that can't be full screen
#     under Wine is replaced by SAFE_RES. Or set GAME_RES below to force one.
#   - The Wine desktop is the TV's size. When the game sets its screen mode,
#     Wine shrinks the game's window to that size in the top-left corner. A
#     helper watches the window and has the Pi's display hardware zoom it to
#     full TV height (4:3 -> black side bars, 16:9 -> full screen), with
#     black panels over the rest of the desktop. The zoom costs no GL work.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can use.
#   - The zoom starts at the game's saved resolution as soon as X starts, so
#     the first screen appears already the right size, then follows the game
#     as normal.
#   - NEEDS THE PATCHED Engine.dll (one byte changed - the original kept as
#     Bin\Engine.dll.orig). The engine reads its files through memory that
#     is filled in when first touched (an access-violation handler). Box64
#     reports a fault during a "rep movs" copy as a WRITE even when the copy
#     is READING that memory, and the original Engine.dll then stops with
#     "Write attempted on read-only file stream!". The patch skips that one
#     check (Engine.dll offset 0x1D577: 75 -> EB) - the page is then filled
#     in as for any read. The check only ever told reads from writes for that
#     message; nothing else uses it. (Interpreter, BIGBLOCK=0, CALLRET=0,
#     STRONGMEM=1 - all tested, none help.) The script warns in the log if
#     the original Engine.dll is in place.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/SeriousSam.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\Serious Sam\serioussam-launch.log
#  The game's own log (what the engine did, errors):
#      \\<pi>\roms\windows\Serious Sam\SeriousSam.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="serioussam"        # short name: its Wine prefix
                            #   (~/wine-prefixes/serioussam) and log
# \\<pi>\roms\windows\Serious Sam
GAME_DIR="$HOME/RetroPie/roms/windows/Serious Sam"
GAME_EXE="SeriousSam.exe"   # exactly as spelled on disk
GAME_EXE_DIR="Bin"          # where the exe is (the game is started from there)

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# Pick the resolution in the GAME's Video menu - the zoom follows it and the
# game remembers it. Only Wine's standard screen sizes work full screen; any
# other drops to a window (a saved one is replaced by SAFE_RES at the next
# launch).
#
# 4:3 - everything the right shape, black side bars (as the game was made):
#    640x480, 800x600, 1024x768, 1280x960 (sharpest)
#
# 16:9 - fills the TV. The game keeps its 90 degree side-to-side view, so
# you see the same width but LESS at the top and bottom:
#   1280x720, 1600x900, 1920x1080 (heaviest)
#
# 5:3 - 1280x768 (thin side bars)
#
# GAME_RES="" = the game's own choice. Or force one at every launch (the
# game's menu choice is then put back each time), e.g. GAME_RES="1024x768"
GAME_RES=""
SAFE_RES="1024x768"         # used when the game's saved size can't
                            #   be full screen
GOOD_RES="640x480 800x600 1024x768 1280x960 1280x720 1280x768 1600x900 1920x1080"
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game draws its own pointer in the menus)
MOUSE_FENCE=1               # 1 = the mouse is kept inside the game's picture.
                            #     The game's window sits in the top-left of a
                            #     TV-sized X screen, so without this the
                            #     (hidden) pointer can wander off its right or
                            #     bottom edge onto the black panels, and the
                            #     game's menu cursor sticks there. 0 = off

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=2             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If movement/physics act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code (3 = an extra for
                    #   LoongArch CPUs only, not the Pi); empty = Box64's
                    #   default (2). Can crash some games - if so, try 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and
                    #   loading): empty = on, one cache shared by all games
                    #   (~/.cache/box64); 1 = on, this game's own cache
                    #   (box64-cache in its prefix); 0 = off
CPU_PERFORMANCE=1   # 1 = CPU governor 'performance' while playing
                    #   (needs passwordless sudo), 0 = left as it is
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
                    # (the engine times everything from it - 0 if the game
                    #   runs at the wrong speed)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL work on its own thread. The game does all its GL
                    #   on one thread - try 1 if FPS_HUD=2 shows one
                    #   core at 100%
BOOT_LOG_MIN_WINDOW="640x480"   # the game's windows smaller than this don't
                    #   count for the start-up messages: the game's splash
                    #   picture (shown while it loads) otherwise ended them
                    #   early and the TV sat zoomed in on black for a while

# ----- Sound ------------------------------------------------------------------
SOUND_MIXER=0       # 0 = a game-only ALSA mixer: dmix -> loopback ->
                    #     alsaloop -> HDMI. The HDMI sound stays open for the
                    #     whole game, so no sound loses its start while the
                    #     TV's HDMI audio wakes up. Needs alsa-utils
                    #     (alsaloop) and snd-aloop (loaded by the script)
                    # 1 = straight to the Pi's HDMI sound through ALSA
                    # 2 = a private PulseAudio just for this game
                    # If the chosen mixer can't start: straight to HDMI (1).
                    # EmulationStation and the emulators always use plain ALSA.
                    # HDMI port, PulseAudio buffering: .scripts/settings.cfg

# ===================== Shared code =====================
# In the ".scripts" folder next to this script: common.inc (settings.cfg,
# Box64, the Wine prefix, starting X, waiting for the game to close...),
# which also loads display.inc (screen scaling and zoom, black panels, mouse
# fence, keyboard focus, finding the game's window), sound.inc (sound
# mixers, FluidSynth) and the start-up messages on screen (bootlog.inc,
# bootlog.py)
COMMON_INC="$(dirname "$(readlink -f "$0")")/.scripts/common.inc"
if [ ! -f "$COMMON_INC" ]; then
    echo "ERROR: $COMMON_INC not found" | tee "${LOG_FILE:-$GAME_DIR/$GAME_ID-launch.log}"
    sleep 5; exit 1
fi
# shellcheck source=/dev/null
. "$COMMON_INC"

# ===================== Environment =====================
# The 2001 engine overflows a buffer on long GL extension strings - only
# report old ones
export MESA_EXTENSION_MAX_YEAR=2002
# OpenGL: no error checking, GLTHREAD - shared code
gl_setup

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# The game's options file (Scripts\PersistentSymbols.ini, any case)
GAME_INI="$(find "$GAME_DIR" -maxdepth 2 -ipath '*/scripts/persistentsymbols.ini' 2>/dev/null | head -n1)"

# The resolution the game will start at: GAME_RES if set, else the one the
# game saved (sam_iScreenSizeI x sam_iScreenSizeJ). One that isn't a standard
# full-screen size -> SAFE_RES (written into the file by set_game_ini).
# RES_SOURCE says which, RES_WRITE=1 = write it into the file.
RES_WRITE=0
if [ -n "$GAME_RES" ]; then
    START_RES="$GAME_RES"; RES_SOURCE="forced (GAME_RES)"; RES_WRITE=1
else
    _w="$(sed -n 's/.*[[:space:]]sam_iScreenSizeI=(INDEX)\([0-9]*\);.*/\1/p' "$GAME_INI" 2>/dev/null | tail -n1)"
    _h="$(sed -n 's/.*[[:space:]]sam_iScreenSizeJ=(INDEX)\([0-9]*\);.*/\1/p' "$GAME_INI" 2>/dev/null | tail -n1)"
    if [ -n "$_w" ] && [ -n "$_h" ] && [[ " $GOOD_RES " == *" ${_w}x${_h} "* ]]; then
        START_RES="${_w}x${_h}"; RES_SOURCE="from the game"
    elif [ -n "$_w" ] && [ -n "$_h" ]; then
        START_RES="$SAFE_RES"; RES_WRITE=1
        RES_SOURCE="saved ${_w}x${_h} can't be full screen under Wine - using SAFE_RES"
    else
        START_RES="$SAFE_RES"; RES_WRITE=1; RES_SOURCE="none saved yet - using SAFE_RES"
    fi
    unset _w _h
fi
GW=${START_RES%x*}; GH=${START_RES#*x}

# ===================== Helpers =====================

# The script's settings into Scripts\PersistentSymbols.ini (no Wine needed):
#   sam_iScreenSizeI, sam_iScreenSizeJ = the start resolution - only when
#                              forced (GAME_RES) or replacing a bad/missing one
#   sam_bFullScreenActive = 1  full screen (in the Wine desktop, zoomed)
#   sam_iGfxAPI           = 0  OpenGL (1 = Direct3D: slower through wined3d)
#   snd_iInterface        = 1  DirectSound (0 = WaveOut, 2 = EAX: none in Wine)
# Only these lines are changed; everything else in the file is kept, as are
# its line endings. Missing lines are added, written the way the game
# writes its own:  persistent extern user INDEX name=(INDEX)value;
set_game_ini() {
    local ini="$GAME_INI" eol="" kv key val list
    if [ -z "$ini" ]; then
        ini="$(find "$GAME_DIR" -maxdepth 1 -type d -iname 'scripts' 2>/dev/null | head -n1)"
        ini="${ini:-$GAME_DIR/Scripts}/PersistentSymbols.ini"
        echo "PersistentSymbols.ini not found (game not run yet?) - creating one"
        mkdir -p "$(dirname "$ini")"
        : > "$ini"
    fi
    grep -q $'\r$' "$ini" && eol=$'\r'
    list="sam_bFullScreenActive=1 sam_iGfxAPI=0 snd_iInterface=1"
    [ "$RES_WRITE" = "1" ] && list="sam_iScreenSizeI=$GW sam_iScreenSizeJ=$GH $list"
    echo "Resolution: $START_RES ($RES_SOURCE)"
    for kv in $list; do
        key="${kv%%=*}"; val="${kv#*=}"
        if grep -qE "[[:space:]]$key=" "$ini"; then
            sed -i -E "s|([[:space:]]$key=)[^;]*;|\1(INDEX)$val;|" "$ini"
        else
            # (on a new line, even if the file's last line has no line ending)
            [ -s "$ini" ] && [ -n "$(tail -c1 "$ini")" ] && printf '%s\n' "$eol" >> "$ini"
            printf 'persistent extern user INDEX %s=(INDEX)%s;%s\n' "$key" "$val" "$eol" >> "$ini"
        fi
    done
    echo "Settings in $(basename "$ini"):"
    grep -E "[[:space:]](sam_iScreenSize[IJ]|sam_bFullScreenActive|sam_iGfxAPI|snd_iInterface)=" "$ini" \
        | sed 's/\r$//; s/^/    /'
}

# Is the patched Engine.dll in place? (byte at offset 0x1D577: EB = patched,
# 75 = original) - a warning in the log if not
check_engine_patch() {
    local dll b
    dll="$(find "$GAME_DIR/$GAME_EXE_DIR" -maxdepth 1 -iname 'engine.dll' 2>/dev/null | head -n1)"
    b="$(od -An -tx1 -j $((0x1D577)) -N1 "$dll" 2>/dev/null | tr -d ' ')"
    case "$b" in
        eb) echo "Engine.dll: patched" ;;
        75) echo "WARNING: original Engine.dll - expect \"Write attempted on read-only file stream!\" (use the patched one)" ;;
        *)  echo "WARNING: Engine.dll not recognised (byte at 0x1D577 = '${b:-none}') - not the v1.05 one?" ;;
    esac
}

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then the game's
# own settings
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
; Serious Sam is a 2001 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    check_engine_patch
    set_game_ini
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1.
ZOOM_FB="$NATIVE_RES"

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - the game's
    # resolution could then be refused), then straight to the game's
    # resolution, in the top-left corner where Wine puts the game. The
    # helper takes over from there. (shared code)
    zoom_start "$NATIVE_RES" "$GW" "$GH"
    xsetroot -solid black 2>/dev/null
    # shellcheck disable=SC2153   # (START_GEO is set by zoom_start)
    start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows
                                                #   from the start)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # Keyboard to the game: with no window manager, X sends key presses to
    # whatever is under the (hidden) pointer, which can miss the game. The
    # keeper gives the focus to Wine's desktop whenever nothing has it
    # (shared code; stopped by the shared cleanup).
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR/$GAME_EXE_DIR" || exit 1
    log_settings RES="$START_RES ($RES_SOURCE)"
    FOLLOW_FENCE="$MOUSE_FENCE" FOLLOW_HOLD_FULL=1 \
        follow_start 640 480    # (smaller = the start-up splash picture)
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
