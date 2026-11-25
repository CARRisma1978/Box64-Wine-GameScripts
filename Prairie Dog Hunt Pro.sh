#!/bin/bash
# =============================================================================
#  Prairie Dog Hunt Pro - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - PDHPRO.EXE is a 16-bit Windows 3.x program, which Box64 can't run
#     directly: otvdm (winevdm, a 32-bit Windows program) emulates it.
#   - Bare X, no window manager (in a Wine desktop, Wine manages the game's
#     windows itself). The Wine desktop is GAME_RES; the TV stays at its
#     normal mode and the Pi's display hardware scales the picture up,
#     centred (free - no GL work). Centring makes the X screen a little
#     bigger than the game (747x480 for 640x480 - xrandr refuses a zoom
#     reaching past the X screen's edge); that strip is X's black
#     background, and the mouse is fenced onto the game (MOUSE_FENCE,
#     shared code).
#   - Sound: the game's sounds are mixed by the game-only ALSA mixer, with
#     one stream kept open to the TV for the whole game, so no sound loses
#     its start while the TV's HDMI audio wakes up.
#
#  To close a stuck game over SSH:
#      bash "Prairie Dog Hunt Pro.sh" --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\Prairie Dog Hunt Pro\prairie-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="prairie"           # short name: its Wine prefix
                            #   (~/wine-prefixes/prairie) and log
# \\<pi>\roms\windows\Prairie Dog Hunt Pro
GAME_DIR="$HOME/RetroPie/roms/windows/Prairie Dog Hunt Pro"
GAME_EXE="PDHPRO.EXE"       # exactly as spelled on disk
OTVDM_DIR="$GAME_DIR/otvdm"     # folder holding otvdm.exe
OTVDM_EXE="otvdm.exe"           # exactly as spelled on disk - this is the
                                # process that really runs (Box64 speed
                                # settings match it)

# Registration: put your registration name on the first line of this file
# and your code on the second (exactly as given, one per line). The game
# keeps them in pdhpro.ini in otvdm's WINDOWS folder, which is made from this
# file if it doesn't exist yet (delete pdhpro.ini to have it made again).
# Keep this file private - don't upload it to GitHub. No file = the game
# starts unregistered.
# \\<pi>\roms\windows\Prairie Dog Hunt Pro\pdh-registration.txt
REG_FILE="$GAME_DIR/pdh-registration.txt"
REG_INI="$OTVDM_DIR/WINDOWS/pdhpro.ini"

# ----- Display ----------------------------------------------------------------
GAME_RES="640x480"          # the game's size = the Wine desktop's size
SCALE_MODE="fit"            # fit     = full height (2.25x), black side bars
                            # integer = exact 2x (1280x960), small black border
                            #   (integer + SCALE_FILTER="nearest" - set here or
                            #   in .scripts/settings.cfg - = crisp, perfectly
                            #   even pixels)
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game is played with the mouse)
MOUSE_FENCE=1               # 1 = keep the mouse on the picture (off
                            #     the black bars)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
                    # (the game draws without OpenGL: no counter)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (no OpenGL: makes no difference here)
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
                    # (try 1 if animation looks uneven)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
                    #   (+ the code Box64 can't translate)

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
# otvdm must be there too (checked before X starts - shared launch)
CHECK_FILES=("$OTVDM_DIR/$OTVDM_EXE")

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging
[ "$DEBUG" = "1" ] && export BOX64_DYNAREC_MISSING=1   # (debug: + code Box64
                                                       #   can't translate)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$OTVDM_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then the
# registration
setup_prefix() {
    prefix_setup
    [ -f "$WINEPREFIX/system.reg" ] || { echo "ERROR: prefix creation failed"; exit 1; }
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    wine_base_reg > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # Registration (first run only): pdhpro.ini made from REG_FILE - line 1
    # the name, line 2 the code (Windows line endings removed). The details
    # themselves are never logged.
    if [ ! -f "$REG_INI" ] && [ -f "$REG_FILE" ]; then
        local reg_name reg_code
        { IFS= read -r reg_name; IFS= read -r reg_code; } < <(tr -d '\r' < "$REG_FILE")
        if [ -n "$reg_name" ] && [ -n "$reg_code" ]; then
            echo "Creating $REG_INI from $(basename "$REG_FILE")"
            mkdir -p "$(dirname "$REG_INI")"
            printf '[Prairie Dog Hunt PRO]\nNAME=%s\nCODE=%s\n' "$reg_name" "$reg_code" > "$REG_INI" \
                || echo "WARNING: could not create $REG_INI (folder owned by root?)"
        else
            echo "WARNING: $(basename "$REG_FILE") needs the name on line 1 and the code on line 2 - not registered"
        fi
    fi
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the display hardware scales GAME_RES
    # up, centred (SCALE_MODE)
    display_output "no scaling" && scale_fixed "$GAME_RES"
    xsetroot -solid black 2>/dev/null
    # (the game's windows belong to otvdm, which runs the 16-bit PDHPRO.EXE)
    start_boot_log "$GW $GH 0 0" "$OTVDM_EXE" "$GAME_EXE"
    [ "$MOUSE_FENCE" = "1" ] && fence_area "$GAME_ID-panels" "$GW" "$GH"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings SCALE_MODE
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$OTVDM_DIR/$OTVDM_EXE" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$OTVDM_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
