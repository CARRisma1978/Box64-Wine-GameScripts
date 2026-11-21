#!/bin/bash
# =============================================================================
#  Need for Speed: Underground - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D 9 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - The Wine desktop is the TV's size. When the game sets a screen mode
#     (menus, or the resolution picked in its Display options), Wine shrinks
#     the game's window to that size in the top-left corner. A helper watches
#     the window and has the Pi's display hardware zoom it to full TV height
#     (4:3 -> black side bars, 16:9 -> full screen), with black panels over
#     the rest of the desktop. The zoom costs no GL work, and whatever
#     resolution is picked in the game is followed automatically.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can use.
#   - Start-up: messages on screen, then black until the game is ready
#     (BOOT_LOG). With BOOT_LOG=0, the game's first window size is
#     remembered instead, and the next launch zooms to it before the game
#     appears - no visible resize at start-up.
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfsu.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfsu\nfsu-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/nfsu"        # \\<pi>\roms\windows\nfsu
GAME_EXE="Speed.exe"        # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/nfsu"
LOG_FILE="$GAME_DIR/nfsu-launch.log"

# ----- Display ----------------------------------------------------------------
# Set the resolution in the GAME's Display options; the zoom follows it.
# All shown at full TV height, 4:3 with black side bars (tested):
#    800x600 = lightest
#   1024x768 = sharper
#   1280x960 = sharpest correct-shape picture
#  1280x1024 = works, but 5:4 - the picture looks slightly too tall
# The menus are always 800x600.
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=1               # 1 = no X pointer (gamepad play)
MOUSE_FENCE=1               # 1 = keep the mouse inside the game's picture. Without
                            #   it a fast move takes the pointer off the game's
                            #   window before it reaches the edge, and the game's
                            #   cursor stops short (the game only sees moves made
                            #   inside its window). 0 = off

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = the game decides (Mesa's default)
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
VIDEO_MEM_MB=1024   # VRAM reported to the game (keep below 2048)
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

# GL 3.3 for wined3d (V3D reports 3.1) - also fixes the boxes around trees
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
    prefix_setup nfsu      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/nfsu-settings.reg" reg_old="$WINEPREFIX/nfsu-settings.applied"
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

; NFSU is a 2003 game - report Windows XP to it
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
# finding its window (find_window): shared code. The X screen stays the TV's
# size; only a window the TV's full size is shown 1:1 (so e.g. 1440x1080 is
# still centred).
ZOOM_FB="$NATIVE_RES"

# The game's first window size, remembered for the next launch's early
# zoom. Delete the file to start at 1:1 instead.
START_ZOOM_FILE="$WINEPREFIX/.nfsu_start_zoom"

# True once Wine's desktop window (explorer.exe) is on screen
wine_desktop_up() {
    xwininfo -root -tree 2>/dev/null | grep -qi '("explorer\.exe"'
}

# Background helper: an early zoom, then the game's window followed by the
# shared follow_window - the black panels over the rest of the desktop
# (Wine leaves old pictures there after a resolution change), and a window
# the TV's full size followed only if it stays 3 s (it's the game's window
# BEFORE it sets its screen mode - brief, black).
# Early zoom: once Wine's (black) desktop is up, zoom to last time's first
# window - black to black, before the game's first picture. (Waiting for
# the desktop dates from before the fixed monitor; kept as it's the tested
# order and costs nothing.) Not with BOOT_LOG=1: the start-up messages'
# black cover hides the resize instead, and the messages stay up until the
# game's window appears.
watch_game_window() {
    local start i
    START_GEO=""
    start="$(cat "$START_ZOOM_FILE" 2>/dev/null)"
    if [ "$BOOT_LOG" != "1" ] && [[ "$start" =~ ^[0-9]+\ [0-9]+\ -?[0-9]+\ -?[0-9]+$ ]]; then
        for (( i = 0; i < 120; i++ )); do        # up to 30 s
            wine_desktop_up && break
            sleep 0.25
        done
        if [ -z "$(find_window)" ]; then         # game not showing yet
            sleep 1                              # let Wine finish measuring
            echo "Early zoom to the game's first window from last time: $start"
            START_GEO="$start"
        fi
    fi
    FOLLOW_PANELS=nfsu-panels FOLLOW_FENCE="$MOUSE_FENCE" FOLLOW_HOLD_FULL=1 \
        follow_window      # (shared code)
}

# The first real (not full-size) window is remembered for the next launch
FIRST_SEEN=0
follow_window_hook() {
    [ "$2" = "1" ] && [ "$FIRST_SEEN" = "0" ] || return 0
    [ "${1% * *}" = "$NW $NH" ] && return 0
    FIRST_SEEN=1
    [ "$1" = "$(cat "$START_ZOOM_FILE" 2>/dev/null)" ] || echo "$1" > "$START_ZOOM_FILE"
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === VSYNC=$VSYNC GLTHREAD=$GLTHREAD BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        watch_game_window &
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop=nfsu,"$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    panels_stop
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
# the monitor X reports, which otherwise follows the zoom (~1067x600 in the
# 800x600 menus): the game's resolution list shrank, and switching to a
# bigger mode for a race was refused and the game hung.
if [ -n "$OUTPUT" ]; then
    fixed_monitor nfsu-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor - races above 800x600 may hang"
fi
zoom_to "$NW" "$NH"                      # 1:1 until the helper's early zoom
xsetroot -solid black 2>/dev/null
start_boot_log "$NW $NH 0 0" "$GAME_EXE"
set_governor
sound_mixer_start nfsu   # (shared code; SOUND_MIXER)
run_game
exit 0