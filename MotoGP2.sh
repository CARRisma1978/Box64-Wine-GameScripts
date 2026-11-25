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
GAME_ID="motogp2"           # short name: its Wine prefix
                            #   (~/wine-prefixes/motogp2) and log
GAME_DIR="$HOME/RetroPie/roms/windows/MotoGP2"     # \\<pi>\roms\windows\MotoGP2
LAUNCH_EXE="launcher.exe"   # the front end Wine starts
GAME_EXE="motogp2.exe"      # the game: its window is zoomed, and the Box64
                            # speed settings below apply to it only

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# In-game resolution: 16:9 and SMALLER than the TV's mode (see above)
#   1600x900 = 1.2x zoom (near-instant loading, smooth - the current choice)
#   1280x720 = 1.5x zoom, lighter on the GPU if races drop frames
#    960x540 = exactly 2x - with SCALE_FILTER="nearest" (set it here, or for
#              every game in .scripts/settings.cfg), clean pixel doubling
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the launcher needs the mouse)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If bike handling/physics act oddly with 0, use 1
BIGBLOCK=2          # Box64 code block size 0-3 (bigger = less translating);
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
# The launcher must be there too (checked before X starts - shared launch)
CHECK_FILES=("$GAME_DIR/$LAUNCH_EXE")

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg; cat <<'EOF'
[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"VideoMemorySize"="1024"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to) and finding the game's window (find_window): shared
# code. The X screen stays the TV's size; an area its full size is shown
# 1:1.
ZOOM_FB="$NATIVE_RES"

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

# Inside X (from launch, shared code)
in_x() {
    # The TV at its normal mode, shown 1:1 until the game's window appears
    zoom_start ""               # (shared code)
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$LAUNCH_EXE" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings
    follow_start watch_game_window
    # Wine desktop the size of the TV - deliberately bigger than the game.
    # Back when the launcher has closed and all of Wine has finished.
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$LAUNCH_EXE"
    wineserver -w
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
