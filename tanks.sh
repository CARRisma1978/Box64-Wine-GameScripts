#!/bin/bash
# =============================================================================
#  Pocket Tanks Deluxe - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - ptanks.exe is a launcher: it starts game.exe (the real game) and closes.
#   - Wine's own DirectDraw, drawn in normal memory (renderer "gdi"), as in
#     dxball.sh. The game always runs at 800x600, in a Wine desktop of that
#     size. The TV stays at 1920x1080 and the Pi's display hardware scales
#     the picture up 1.8x to full height, centred (free - no GL work).
#   - Bare X, no window manager (matchbox showed through beside the game).
#     Centring makes the X screen a little wider than the game (934x600);
#     that strip is X's black background, and the mouse pointer is
#     fenced onto the game (shared code).
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/tanks.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\tanks\tanks-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/tanks"       # \\<pi>\roms\windows\tanks
GAME_EXE="ptanks.exe"       # the launcher Wine starts...
GAME_PROC="game.exe"        # ...which starts the real game (Box64 speed settings
                            # and "has it quit?" use this)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/tanks"
LOG_FILE="$GAME_DIR/tanks-launch.log"

# ----- Display ----------------------------------------------------------------
GAME_RES="800x600"          # the game's fixed resolution = the Wine desktop size
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
WINE_RENDERER="gdi"         # gdi = DirectDraw in normal memory (tested - runs fine)
                            # gl  = through OpenGL

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If physics/movement act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
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
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     shots/animation look uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE

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

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE" "$GAME_PROC"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup ptanks      # (+ finishes a pending update after a new Wine)

    # Imported only when something changes (each import is a full Box64 +
    # Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/ptanks-settings.reg" reg_old="$WINEPREFIX/ptanks-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; DirectDraw renderer; no separate Direct3D thread (as dxball.sh)
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="$WINE_RENDERER"
"csmt"=dword:00000000
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# TV at NATIVE_RES, GAME_RES scaled up to full height by the Pi's display
# hardware, centred. Centring puts part of the scaled screen at a negative
# x, so the X screen must reach the far edge of the picture (934x600 for
# 800x600) - FB_W x FB_H.
set_display() {
    display_output "no scaling" && scale_fixed "$GAME_RES"     # (shared code)
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES X screen=${FB_W}x${FB_H} WINE_RENDERER=$WINE_RENDERER"
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop=ptanks,"$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE" "$GAME_PROC"
}

cleanup() {
    stop_boot_log
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
    start_x -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # mouse-only turns don't reset blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$GW $GH 0 0" "$GAME_EXE" "$GAME_PROC"
fence_area tanks-panels "$GW" "$GH"     # mouse kept on the picture (shared code)
set_governor
sound_mixer_start tanks   # (shared code; SOUND_MIXER)
run_game
exit 0