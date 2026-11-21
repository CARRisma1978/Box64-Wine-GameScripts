#!/bin/bash
# =============================================================================
#  Mortal Kombat 4 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  Renders through Glide (the nGlide wrapper in the game folder). Direct3D was
#  ruled out: wined3d's GPU report makes MK4 reject every Direct3D device.
#  The Wine desktop is the size of the TV and nGlide draws the game at full
#  height (1440x1080, 4:3 with black side bars).
#
#  In game: F2 = configuration menu (controls etc.)
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/mk4.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\mk4\mk4-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/mk4"         # \\<pi>\roms\windows\mk4
GAME_EXE="mk4.exe"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/mk4"
LOG_FILE="$GAME_DIR/mk4-launch.log"

# nGlide settings exported from nGlide's configurator on Windows
# (HKCU\Software\Zeus Software): Aspect ratio = Aspect correction, VSync on,
# splash off. Imported automatically whenever the file changes. nGlide's
# "Resolution" is forced to "By desktop" every launch.
NGLIDE_REG="$GAME_DIR/nglide.reg"

# ----- Display ----------------------------------------------------------------
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If anything act oddly with 0, use 1
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
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (if new problems appear)

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

# OpenGL 3.3 for Wine's Direct3D (nGlide's D3D9 backend); V3D reports 3.1
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
export vblank_mode=0                           # vsync is nGlide's job (both = slow)

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# TV at its normal mode, no scaling - nGlide fills the desktop itself
set_display() {
    display_output "no scaling" && scale_fixed "$NATIVE_RES"     # (shared code)
}

# Prefix and registry (imported only when something changes - each import
# is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup mk4      # (+ finishes a pending update after a new Wine)

    local reg="$WINEPREFIX/drive_c/mk4-settings.reg"
    cat > "$reg" <<'EOF'
REGEDIT4

; Wine mustn't change the TV's screen mode
[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"VideoMemorySize"="1024"

; Black Wine desktop (the side bars)
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed the hang on exit)
[HKEY_CURRENT_USER\Software\Wine\DirectSound]
"HardwareAcceleration"="Emulation"

; MK4's own key (normally written by its installer). 32-bit game, so it
; reads the Wow6432Node view. Path ".\" = the game folder.
[HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\GT Interactive\Mortal Kombat 4\1.00]
"Path"=".\\"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg"
    import_reg "$reg" "$WINEPREFIX/mk4-settings.applied"               # (shared code)
    [ -f "$NGLIDE_REG" ] && import_reg "$NGLIDE_REG" "$WINEPREFIX/nglide.applied"
    wineserver -w

    # nGlide Resolution = "By desktop" (1), edited straight in user.reg
    # (Wine has stopped), so it always matches the Wine desktop
    local key
    for key in nGlide nGlide2; do
        sed -i '/^\[Software\\\\Zeus Software\\\\'"$key"'\]/,/^\[/ s/^"Resolution"=".*"/"Resolution"="1"/' \
            "$WINEPREFIX/user.reg"
    done
}

run_game() {
    cd "$GAME_DIR" || exit 1
    # Wine desktop: MK4 can't switch the real screen mode
    wine explorer /desktop=mk4,"$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
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
    # it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    start_x -nocursor -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "${NATIVE_RES%x*} ${NATIVE_RES#*x} 0 0" "$GAME_EXE"
set_governor
setup_prefix
sound_mixer_start mk4   # (shared code; SOUND_MIXER)
run_game
exit 0