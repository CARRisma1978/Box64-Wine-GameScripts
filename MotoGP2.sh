#!/bin/bash
# =============================================================================
#  MotoGP 2 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Bare X, no window manager. The Wine desktop is always the TV's size.
#     MotoGP2 loads many minutes slower when its own resolution EXACTLY
#     equals the Wine desktop (1920x1080 and 1600x900 both tested, also with
#     OpenGL 3.3), so the game runs at a smaller 16:9 size in the desktop's
#     top-left corner.
#   - A helper watches the game's window and has the Pi's GPU zoom it to
#     fill the TV. Whatever resolution is picked in launcher.exe -> Game
#     Settings -> Advanced Video Mode Settings is followed automatically.
#     The launcher itself is shown 1:1. The TV mode never changes and Wine
#     never sees the zoom.
#   - motogp2.exe is the replacement (No-CD) exe: the original needed a fake
#     D: drive and pre-made save folders.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/MotoGP2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\MotoGP2\motogp2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/MotoGP2"     # \\<pi>\roms\windows\MotoGP2
LAUNCH_EXE="launcher.exe"   # the front end Wine starts
GAME_EXE="motogp2.exe"      # the game: its window is zoomed, and the Box64
                            # speed settings below apply to it only

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/motogp2"
LOG_FILE="$GAME_DIR/motogp2-launch.log"

# ----- Display ----------------------------------------------------------------
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
# In-game resolution: 16:9 and SMALLER than NATIVE_RES (see above)
#   1600x900 = 1.2x zoom (near-instant loading, smooth - the current choice)
#   1280x720 = 1.5x zoom, lighter on the GPU if races drop frames
#    960x540 = exactly 2x - with SCALE_FILTER="nearest", clean pixel doubling
HIDE_CURSOR=0               # 1 = no X pointer (the launcher needs the mouse)

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If bike handling/physics act oddly with 0, use 1
BIGBLOCK=2          # Box64 code block size 0-3 for the game (bigger = less
                    #   translating); empty = Box64's default (2)
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
                    #     loading) until the launcher appears. Also kept in
                    #     LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE

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
# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# OpenGL 3.3 for Wine's Direct3D (V3D reports 3.1)
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup motogp2      # (+ finishes a pending update after a new Wine)

    # Imported only when something changes (each import is a full Box64 +
    # Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/motogp2-settings.reg" reg_old="$WINEPREFIX/motogp2-settings.applied"
    cat > "$reg_new" <<'EOF'
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"VideoMemorySize"="1024"

; Black Wine desktop (round the launcher)
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to) and finding the game's window (find_window): shared
# code. The X screen stays the TV's size; an area its full size is shown
# 1:1.
ZOOM_FB="$NATIVE_RES"

set_display() {
    display_output "no zoom" || return
    zoom_to "$NW" "$NH"                         # 1:1 until the game shows
}

# Background helper: zoom to the game's window whenever it changes. With no
# game window: 1:1 if the launcher is up, otherwise keep the current zoom
# (so loading screens / mode switches don't flick it back and forth)
watch_game_window() {
    local geo last="" n=0
    while :; do
        # 4 times a second for the first 20s (start-up: quick rescaling, so
        # the start-up message cover lifts sooner), then once a second
        if [ "$n" -lt 80 ]; then sleep 0.25; n=$((n + 1)); else sleep 1; fi
        geo="$(find_window)"
        if [ -z "$geo" ]; then
            [ -n "$(WINDOW_EXE="$LAUNCH_EXE" find_window)" ] || continue
            geo="$NW $NH 0 0"
        fi
        [ "$geo" = "$last" ] && continue
        last="$geo"
        # shellcheck disable=SC2086
        zoom_to $geo
    done
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) ==="
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        watch_game_window &
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the size of the TV - deliberately bigger than the game
    wine explorer /desktop=motogp2,"$NATIVE_RES" "$LAUNCH_EXE"
    wineserver -w
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
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
    # From EmulationStation: start X just for the game, on ES's console, so
    # it can set the screen mode and exits cleanly back to ES
    check_files "$GAME_DIR/$LAUNCH_EXE" "$GAME_DIR/$GAME_EXE"
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
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$NW $NH 0 0" "$LAUNCH_EXE" "$GAME_EXE"
set_governor
sound_mixer_start motogp2   # (shared code; SOUND_MIXER)
run_game
exit 0