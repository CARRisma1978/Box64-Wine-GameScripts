#!/bin/bash
# =============================================================================
#  Need for Speed: Underground 2 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  Uses SPEED2_PATCHED.EXE made by nfsu2-lockfix.py (fixes the game's
#  non-thread-safe lock that crashed it in the menus on multi-core CPUs).
#
#  How it works (based on nfsu.sh):
#   - Direct3D 9 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - The Wine desktop is the TV's size. When the game sets a screen mode
#     (menus, or the resolution picked in its Display options), Wine shrinks
#     the game's window to that size in the top-left corner. A helper watches
#     the window and has the Pi's display hardware zoom it to full TV height
#     (4:3 -> black side bars), with black panels over the rest of the
#     desktop. The zoom costs no GL work, and whatever resolution is picked
#     in the game is followed automatically - no need to edit this script.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can use.
#   - The zoom starts at the menu size (START_RES) as soon as X starts, so
#     the first screen appears already the right size, then follows the
#     game as normal.
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfsu2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfsu2\nfsu2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/nfsu2"       # \\<pi>\roms\windows\nfsu2
GAME_EXE="SPEED2_PATCHED.EXE"   # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/nfsu2"
LOG_FILE="$GAME_DIR/nfsu2-launch.log"

# ----- Display ----------------------------------------------------------------
# Set the resolution in the GAME's Display options; the zoom follows it.
# All shown at full TV height, 4:3 with black side bars:
#    640x480 = lightest (same as the menus)
#    800x600 = a good first step up
#   1024x768 = sharper
#   1280x960 = sharpest correct-shape picture (1280x1024 is 5:4 - too tall)
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
START_RES="640x480"         # zoom from the moment X starts, before the game
                            # appears - the size of its first (menu) screen.
                            # "" = start at 1:1.
HIDE_CURSOR=1               # 1 = no X pointer (gamepad play); 0 = show it
MOUSE_FENCE=1               # 1 = keep the mouse inside the game's picture. Without
                            #   it a fast move takes the pointer off the game's
                            #   window before it reaches the edge, and the game's
                            #   cursor stops short (the game only sees moves made
                            #   inside its window). 0 = off

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=0             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If car handling/physics act oddly with 0, use 1
BIGBLOCK=2          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code; empty = Box64's default (2).
                    #   3 = as 2, plus protection from random crashes (Box64
                    #   built 26 Oct 2026 or later - check: box64 --version)
                    #   Can crash some games - try 3, then 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=1   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    # its own render thread. Try 1 if FPS_HUD=2 shows a second
                    # core at 100%.
STRONGMEM=3         # Box64 memory ordering 0-3. Keep >= 1: the lock fix relies
                    # on the game's stores being seen in order. 3 = safest
                    # (tested); try 2, then 1, for speed - back up if the menu
                    # crashes/hangs return.
VIDEO_MEM_MB=1536   # VRAM reported to the game (keep below 2048)
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE
                    #     (only if new problems appear - big log, slower)

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

# GL 3.3 for wined3d (V3D reports 3.1)
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$GLTHREAD" = "1" ] && export mesa_glthread=true || export mesa_glthread=false
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup nfsu2      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/nfsu2-settings.reg" reg_old="$WINEPREFIX/nfsu2-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; Black Wine desktop (the side bars)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; NFSU2 is a 2004 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
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

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === VSYNC=$VSYNC GLTHREAD=$GLTHREAD STRONGMEM=$STRONGMEM BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=nfsu2-panels FOLLOW_FENCE="$MOUSE_FENCE" FOLLOW_HOLD_FULL=1 \
            follow_window &      # (shared code)
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop=nfsu2,"$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    panels_stop
    focus_stop
    wineserver -k 2>/dev/null
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
    NOCURSOR=""; [ "$HIDE_CURSOR" = "1" ] && NOCURSOR="-nocursor"
    # shellcheck disable=SC2086
    start_x -quiet $NOCURSOR
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
display_output "no zoom"
# A fixed "monitor" the TV's full size. Wine checks screen modes against
# the monitor X reports, which otherwise follows the zoom (~853x480 in the
# 640x480 menus) - the game's resolution list could shrink, or a bigger
# mode for a race be refused (as found with NFSU).
if [ -n "$OUTPUT" ]; then
    fixed_monitor nfsu2-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor - races above 640x480 may hang"
fi
# Start at the menu size straight away (black to black: nothing is drawn
# yet), in the top-left corner where Wine puts the game. Safe this early
# because of the fixed monitor above - the zoom can't change what Wine
# measures. The helper takes over from here.
START_GEO="$NW $NH 0 0"
[[ "$START_RES" =~ ^[0-9]+x[0-9]+$ ]] && START_GEO="${START_RES%x*} ${START_RES#*x} 0 0"
echo "Starting zoom: $START_GEO"
# shellcheck disable=SC2086
zoom_to $START_GEO
xsetroot -solid black 2>/dev/null
start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows from the start)
# Keyboard to the game: with no window manager, X sends key presses to
# whatever is under the (hidden) pointer, which missed the game (and
# Matchbox didn't hand it over either). The keeper gives the focus to Wine's
# desktop whenever nothing has it (shared code).
focus_start explorer.exe "$GAME_EXE"
set_governor
sound_mixer_start nfsu2   # (shared code; SOUND_MIXER)
run_game
exit 0