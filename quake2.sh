#!/bin/bash
# =============================================================================
#  Quake II (v3.24, OpenGL) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works (as nfsu.sh / nfsu2.sh):
#   - ref_gl.dll -> Wine's opengl32 -> Mesa on the Pi's GPU (no wined3d, so
#     no GL 3.3 override needed).
#   - The Wine desktop is the TV's size. When the game sets a screen mode
#     (the resolution picked in its Video menu), Wine shrinks the game's
#     window to that size in the top-left corner. A helper watches the window
#     and has the Pi's display hardware zoom it to full TV height (4:3 ->
#     black side bars, 16:9 -> full screen), with black panels over the rest
#     of the desktop. The zoom costs no GL work.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#   - The last window size is remembered, and the next launch zooms to it
#     before the game appears.
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/quake2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\quake2\quake2.log
#  With CONSOLE_LOG=1, also the game's console: ...\quake2\baseq2\qconsole.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/quake2"      # \\<pi>\roms\windows\quake2
GAME_EXE="quake2.exe"       # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/quake2"
LOG_FILE="$GAME_DIR/quake2.log"

# ----- Display ----------------------------------------------------------------
# Pick the resolution in the GAME's Video menu (Apply) - the zoom follows it
# and the game remembers it for next time. CAUTION: after a resolution change
# in the game, the next cinematic (e.g. starting a new game) can freeze the
# game - a texture lock left held inside the Pi's graphics driver (Mesa
# 24.2.8). Change it, then quit and relaunch before playing - or set GAME_RES
# below and leave the game's option alone. Only Wine's standard screen sizes
# work full screen; any other drops to a window and turns Fullscreen off.
#   Tested OK:  1280x720, 1600x900 (16:9, fill the TV)
#               1280x768 (5:3, thin side bars)
#               1920x1080 (works, but too slow)
#   Also standard (4:3, black side bars): 640x480, 800x600, 1024x768, 1280x960
#   NOT:        800x480, 1024x600, 1366x768 - a saved one is replaced by
#               SAFE_RES at the next launch
# GAME_RES="" = use the game's own choice. Or force one at every launch:
# 640x480 800x600 1024x768 1280x960 1280x720 1280x768 1600x900 1920x1080
GAME_RES=""
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = no tearing (forced in Mesa; the game's own "video sync"
                    # option has no effect), 0 = off
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If movement/physics act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2) - 3 tested
CALLRET=1           # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code; empty = Box64's default (2).
                    #   3 = as 2, plus protection from random crashes (Box64
                    #   built 26 Oct 2026 or later - check: box64 --version)
                    #   Can crash some games - try 3, then 0 (1 tested)
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=1   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine errors + Box64 log into LOG_FILE (slower)
CONSOLE_LOG=0       # 1 = the game's console into baseq2\qconsole.log, written
                    #     line by line (kept even if the game freezes) - for
                    #     tracking down a problem

# ----- Sound mixer ------------------------------------------------------------
# 0 = straight to the Pi's HDMI sound through ALSA (as this game has always
#     run).
# 2 = a game-only ALSA mixer (as SeriousSam.sh / outrun.sh): dmix ->
#     loopback -> alsaloop -> HDMI. The HDMI sound stays open for the whole
#     game, so no sound loses its start while the TV's HDMI audio wakes up.
#     Needs alsa-utils (alsaloop) and the snd-aloop module (loaded by the
#     script).
# 1 = a private PulseAudio just for this game.
# If the chosen mixer can't start, plain ALSA is used.
# ES and emulators keep plain ALSA in every case.
SOUND_MIXER=0
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=60            # SOUND_MIXER=1: sound buffered between the game and
                            # PulseAudio: higher = safer from clicks, sound
                            # slightly later

# ----- Looks ------------------------------------------------------------------
FOV="auto"          # auto = 90 on 4:3, widened on 16:9 (106) so you see MORE at
                    # the sides. Worked out at launch from the resolution in use
                    # then - after switching between 4:3 and 16:9 in the menu,
                    # it's right from the next launch. Or a number, e.g. 90.
GAMMA=0.3           # vid_gamma (textures): LOWER = brighter. 1.0 = original,
                    # 0.3 = very bright (a little flat)
LIGHT_BOOST=1.5     # gl_modulate (lighting): 1 = original,
                    # 1.5-2 = brighter dark areas without washing out textures
SHARP_TEXTURES=1    # 1 = gl_round_down 0: textures not shrunk to the size below
                    #     when their size isn't a power of two (sharper)
ANISOTROPY=8        # gl_anisotropic: textures stay sharp on floors/walls seen at
                    # an angle. 1 = off, 2/4/8/16 (16 = the Pi's maximum). Small GPU cost.

# ===================== Derived settings =====================
NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# The game's last window ("W H X Y"), remembered for the next launch's early
# zoom. Delete the file to start at 1:1 instead.
START_ZOOM_FILE="$WINEPREFIX/.quake2_last_window"

# Quake II modes Wine refuses full screen (not in Wine's list of standard
# screen sizes): the game falls back to a window and turns Fullscreen off.
# If the game's saved mode is one of these, start at SAFE_RES instead.
BAD_MODES="14 16 21"        # 800x480, 1024x600, 1366x768
SAFE_RES="1280x720"
MODE_FIXED=""
CFG="$GAME_DIR/baseq2/config.cfg"
if [ -z "$GAME_RES" ] && [ -f "$CFG" ]; then
    SAVED_MODE="$(sed -n 's/^set gl_mode "\([0-9]*\)".*/\1/p' "$CFG" | tail -n 1)"
    if [ -n "$SAVED_MODE" ] && [[ " $BAD_MODES " == *" $SAVED_MODE "* ]]; then
        MODE_FIXED="saved gl_mode $SAVED_MODE can't be full screen under Wine - using $SAFE_RES"
        GAME_RES="$SAFE_RES"
    fi
fi

# gl_mode for a forced GAME_RES (3.24's mode list)
GL_MODE=""
if [ -n "$GAME_RES" ]; then
    case "$GAME_RES" in
        640x480) GL_MODE=3 ;; 800x600) GL_MODE=4 ;; 1024x768) GL_MODE=6 ;;
        1280x960) GL_MODE=8 ;; 1280x720) GL_MODE=17 ;; 1280x768) GL_MODE=18 ;;
        1600x900) GL_MODE=23 ;; 1920x1080) GL_MODE=26 ;;
        *) echo "ERROR: GAME_RES $GAME_RES isn't one of Quake II's modes"; sleep 5; exit 1 ;;
    esac
fi

# The size the game will start at: the forced one, else last time's window
START_GEO=""
if [ -n "$GAME_RES" ]; then
    START_GEO="${GAME_RES%x*} ${GAME_RES#*x} 0 0"
else
    START_GEO="$(cat "$START_ZOOM_FILE" 2>/dev/null)"
    [[ "$START_GEO" =~ ^[0-9]+\ [0-9]+\ -?[0-9]+\ -?[0-9]+$ ]] || START_GEO=""
fi

# Horizontal FOV that keeps 4:3's 90 degrees vertical view at this shape
# (16:9 assumed until the game's size is known)
if [ "$FOV" = "auto" ]; then
    read -r SW SH _ <<< "${START_GEO:-16 9}"
    FOV=$(awk -v w="$SW" -v h="$SH" 'BEGIN {
        printf "%d", 2 * atan2(w / h * 3 / 4, 1) * 180 / 3.14159265 + 0.5 }')
fi

# vid_ref / gl_driver = OpenGL through Windows' opengl32 ("default OpenGL" -
#   undoes an accidental "3dfx OpenGL" pick in the Video menu)
# s_primary 0     = sound "maximum compatibility" (Wine can't do "maximum performance")
# s_khz 48        = sound at 48 kHz (the HDMI rate - no resampling)
# gl_ext_palettedtexture 0 = no 8-bit textures (the Pi's GPU has none anyway)
# gl_texturemode  = trilinear filtering: smoother texture transitions, no speed cost
# (+set values are re-applied after config.cfg, so these always win)
GAME_ARGS=(+set vid_ref gl +set gl_driver opengl32 +set vid_fullscreen 1
           +set s_primary 0 +set s_khz 48
           +set vid_gamma "$GAMMA" +set gl_modulate "$LIGHT_BOOST" +set fov "$FOV"
           +set gl_ext_palettedtexture 0 +set gl_texturemode GL_LINEAR_MIPMAP_LINEAR
           +set gl_anisotropic "$ANISOTROPY")
[ -n "$GL_MODE" ] && GAME_ARGS+=(+set gl_mode "$GL_MODE")
[ "$SHARP_TEXTURES" = "1" ] && GAME_ARGS+=(+set gl_round_down 0)

# ===================== Shared code =====================
# In the ".scripts" folder next to this script: common.inc (Box64, the Wine
# prefix, starting X, waiting for the game to close...), which also loads
# display.inc (screen scaling and zoom, black panels, mouse fence, keyboard
# focus, finding the game's window), sound.inc (sound mixers, FluidSynth)
# and the start-up messages on screen (bootlog.inc, bootlog.py)
COMMON_INC="$(dirname "$(readlink -f "$0")")/.scripts/common.inc"
if [ ! -f "$COMMON_INC" ]; then
    echo "ERROR: $COMMON_INC not found" | tee -a "$LOG_FILE"
    sleep 5; exit 1
fi
# shellcheck source=/dev/null
. "$COMMON_INC"

# ===================== Environment =====================

# Quake II's GL code overflows a buffer on long GL extension strings - only report old ones
export MESA_EXTENSION_MAX_YEAR=2002
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$VSYNC" = "1" ] && export vblank_mode=3 || export vblank_mode=0   # 3 = always sync
# Mesa's GL thread stays off: with it on, changing resolution in the game
# crashed Mesa while it reloaded the textures (no speed difference seen)
export mesa_glthread=false

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging
# logfile 2 = written line by line (1 is buffered - lost if the game freezes)
[ "$CONSOLE_LOG" = "1" ] && GAME_ARGS+=(+set logfile 2)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup quake2      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/quake2-settings.reg" reg_old="$WINEPREFIX/quake2-settings.applied"
    cat > "$reg_new" <<'EOF'
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound: avoids hangs when the game restarts its sound system
[HKEY_CURRENT_USER\Software\Wine\DirectSound]
"HardwareAcceleration"="Emulation"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1 (so e.g.
# 1440x1080 is still centred).
ZOOM_FB="$NATIVE_RES"

# The game's window: followed by the shared follow_window (run_game), and
# remembered for next time whenever it changes
follow_window_hook() {
    [ "$2" = "1" ] && echo "$1" > "$START_ZOOM_FILE"
}

run_game() {
    cd "$GAME_DIR" || exit 1
    [ -n "$MODE_FIXED" ] && echo "WARNING: $MODE_FIXED"
    echo "=== $(date) === GAME_RES=${GAME_RES:-from game} START=${START_GEO:-1:1} FOV=$FOV ANISOTROPY=$ANISOTROPY VSYNC=$VSYNC BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=quake2-panels follow_window &      # (shared code)
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop=quake2,"$NATIVE_RES" "$GAME_EXE" "${GAME_ARGS[@]}" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    panels_stop
    wineserver -k 2>/dev/null
    focus_stop
    sound_mixer_stop
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: prefix setup first (no X needed), then X just
    # for the game, on ES's console, so it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    setup_prefix >> "$LOG_FILE" 2>&1
    start_x -nocursor -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
display_output "no zoom"
# A fixed "monitor" the TV's full size. Wine checks screen modes against
# the monitor X reports, which otherwise follows the zoom - a mode change
# could then be refused (as found with NFSU).
if [ -n "$OUTPUT" ]; then
    fixed_monitor quake2-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor - resolution changes may fail"
fi
# Start at last time's size straight away (black to black: nothing is drawn
# yet), in the top-left corner where Wine puts the game. Safe this early
# because of the fixed monitor above. The helper takes over from here.
echo "Starting zoom: ${START_GEO:-1:1}"
# shellcheck disable=SC2086
zoom_to ${START_GEO:-$NW $NH}
xsetroot -solid black 2>/dev/null
start_boot_log "${START_GEO:-$NW $NH 0 0}" "$GAME_EXE"   # (the area the TV shows from the start)
# Keyboard to the game: with no window manager, X sends key presses to
# whatever is under the (hidden) pointer. The keeper gives the focus to
# Wine's desktop whenever nothing has it (shared code - replaces Matchbox).
focus_start explorer.exe "$GAME_EXE"
set_governor
sound_mixer_start quake2   # (shared code; SOUND_MIXER)
run_game
exit 0