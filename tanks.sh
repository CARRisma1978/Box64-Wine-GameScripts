#!/bin/bash
# =============================================================================
#  Pocket Tanks Deluxe - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - ptanks.exe is a launcher: it starts game.exe (the real game) and closes.
#   - Wine's own DirectDraw, drawn in normal memory (renderer "gdi"). The
#     game always runs at 800x600, in a Wine desktop of that size. The TV
#     stays at its normal mode and the Pi's display hardware scales the
#     picture up 1.8x to full height, centred (free - no GL work).
#   - Bare X, no window manager (matchbox showed through beside the game).
#     Centring makes the X screen a little wider than the game (934x600);
#     that strip is X's black background, and the mouse pointer is
#     fenced onto the game (shared code).
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/tanks.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\tanks\tanks-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="tanks"             # short name: its Wine prefix
                            #   (~/wine-prefixes/tanks) and log
GAME_DIR="$HOME/RetroPie/roms/windows/tanks"       # \\<pi>\roms\windows\tanks
GAME_EXE="ptanks.exe"       # the launcher Wine starts...
GAME_PROC="game.exe"        # ...which starts the real game (Box64 speed
                            # settings and "has it quit?" use this)

# ----- Display ----------------------------------------------------------------
GAME_RES="800x600"          # the game's fixed resolution = the Wine
                            #   desktop size
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game uses the mouse - kept on the picture)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
                    # (the game draws without OpenGL: no counter)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If physics/movement act oddly with 0, use 1
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
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
                    # (try 1 if shots/animation look uneven)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)

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
# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE" "$GAME_PROC"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
; DirectDraw in normal memory; no separate Direct3D thread
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="gdi"
"csmt"=dword:00000000
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the Pi's display hardware scales
    # GAME_RES up to full height, centred
    display_output "no scaling" && scale_fixed "$GAME_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$GW $GH 0 0" "$GAME_EXE" "$GAME_PROC"
    fence_area "$GAME_ID-panels" "$GW" "$GH"   # mouse kept on the picture
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE" "$GAME_PROC"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
