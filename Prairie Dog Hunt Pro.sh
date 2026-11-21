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
#     windows itself). The Wine desktop is GAME_RES; the TV stays at
#     NATIVE_RES and the Pi's display hardware scales the picture up, centred
#     (free - no GL work). Centring makes the X screen a little bigger than
#     the game (747x480 for 640x480 - xrandr refuses a zoom reaching past the
#     X screen's edge); that strip is X's black background, and the mouse is
#     fenced onto the game (FENCE_POINTER, shared code).
#   - Sound: the game's sounds are mixed by ALSA (dmix -> loopback ->
#     alsaloop -> HDMI), with one stream kept open to the TV for the whole
#     game, so no sound loses its start while the TV's HDMI audio wakes up.
#     ES and emulators are untouched.
#   - Prefix setup and the sound mixer run BEFORE X starts.
#
#  To close a stuck game over SSH:
#      bash "Prairie Dog Hunt Pro.sh" --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\Prairie Dog Hunt Pro\pdh-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Prairie Dog Hunt Pro"   # \\<pi>\roms\windows\Prairie Dog Hunt Pro
GAME_EXE="PDHPRO.EXE"
OTVDM_DIR="$GAME_DIR/otvdm"     # folder holding otvdm.exe
OTVDM_EXE="otvdm.exe"           # exactly as spelled on disk - this is the process
                                # that really runs (Box64 speed settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/prairie"
LOG_FILE="$GAME_DIR/pdh-launch.log"

# Registration: put your registration name on the first line of this file
# and your code on the second (exactly as given, one per line). The game
# keeps them in pdhpro.ini in otvdm's WINDOWS folder, which is made from this
# file if it doesn't exist yet (delete pdhpro.ini to have it made again).
# Keep this file private - don't upload it to GitHub. No file = the game
# starts unregistered.
REG_FILE="$GAME_DIR/pdh-registration.txt"   # \\<pi>\roms\windows\Prairie Dog Hunt Pro\pdh-registration.txt
REG_INI="$OTVDM_DIR/WINDOWS/pdhpro.ini"

# ----- Display ----------------------------------------------------------------
GAME_RES="640x480"          # the game's size = the Wine desktop's size
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_MODE="fit"            # fit     = full height (2.25x), black side bars
                            # integer = exact 2x (1280x960), small black border
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
                            # (integer + nearest = crisp, perfectly even pixels)
FENCE_POINTER=1             # 1 = keep the mouse on the picture (off the black bars)

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
                    #   Can crash some programs - try 3, then 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=1   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     animation looks uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = verbose Box64/Wine/alsaloop logging into LOG_FILE

# ----- Sound mixer ------------------------------------------------------------
# 2 = a game-only ALSA mixer (see the top): dmix -> loopback -> alsaloop ->
#     HDMI. Needs alsa-utils (alsaloop) and the snd-aloop module (loaded by
#     the script).
# 0 = straight to ALSA.
# (1, a PulseAudio mixer as in other games, isn't used here: Wine is set to ALSA.)
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0 (next to the USB-C power), vc4hdmi1 = port 1

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
[ "$DEBUG" = "1" ] && export BOX64_DYNAREC_MISSING=1   # (debug: + code Box64 can't translate)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$OTVDM_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup pdh      # (+ finishes a pending update after a new Wine)
    [ -f "$WINEPREFIX/system.reg" ] || { echo "ERROR: prefix creation failed"; exit 1; }

    # Imported only when something changes (each import is a full Box64 +
    # Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/pdh-settings.reg" reg_old="$WINEPREFIX/pdh-settings.applied"
    cat > "$reg_new" <<'EOF'
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU scaling
[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

; Sound through ALSA only (the mixer below)
[HKEY_CURRENT_USER\Software\Wine\Drivers]
"Audio"="alsa"
EOF
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

# ----- Display ---------------------------------------------------------------
# Keep the TV at NATIVE_RES and let the display hardware scale GAME_RES up,
# centred. Centring puts part of the scaled screen at a negative x/y, so the
# X screen must reach the far edge of the picture (FB_W x FB_H).
set_display() {
    display_output "no scaling" && scale_fixed "$GAME_RES"     # (shared code)
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES X screen=${FB_W}x${FB_H} SCALE=$SCALE_MODE/$SCALE_FILTER SOUND_MIXER=$SOUND_MIXER"
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop=pdhpro,"$GAME_RES" "$OTVDM_DIR/$OTVDM_EXE" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$OTVDM_EXE"
}

cleanup() {
    stop_boot_log
    panels_stop
    wineserver -k 2>/dev/null
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: prefix setup and sound first (no X needed), then
    # X just for the game, on ES's console, so it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE" "$OTVDM_DIR/$OTVDM_EXE"
    echo "=== $(date) ===" > "$LOG_FILE"
    {
        stop_wine                   # (shared code)
        setup_prefix
    } >> "$LOG_FILE" 2>&1

    trap sound_mixer_stop EXIT          # sound stopped however this ends
    trap 'exit 1' INT TERM
    sound_mixer_start pdh >> "$LOG_FILE" 2>&1     # (shared code; exports ALSA_CONFIG_PATH for Wine)

    start_x -quiet
    wineserver -k 2>/dev/null           # make sure nothing is left running
    exit 0                              # (the EXIT trap stops the sound)
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null
set_display
xsetroot -solid black 2>/dev/null
# (the game's windows belong to otvdm, which runs the 16-bit PDHPRO.EXE)
start_boot_log "$GW $GH 0 0" "$OTVDM_EXE" "$GAME_EXE"
[ "$FENCE_POINTER" = "1" ] && fence_area pdh-panels "$GW" "$GH"     # (shared code)
set_governor
run_game
exit 0