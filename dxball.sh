#!/bin/bash
# =============================================================================
#  DX-Ball - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/dxball.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\dxball\dxball-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/dxball"      # \\<pi>\roms\windows\dxball
GAME_EXE="Dxball.exe"                              # Linux is case-sensitive

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/dxball"
LOG_FILE="$GAME_DIR/dxball-launch.log"

# ----- Display ----------------------------------------------------------------
# DX-Ball draws 640x480. It runs in a Wine desktop of that size, the TV stays
# at NATIVE_RES and the Pi's GPU scales the picture up, centred.
GAME_RES="640x480"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_MODE="fit"            # fit     = full height (2.25x), black side bars
                            # integer = exact 2x (1280x960), small black border
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=1               # 1 = no X pointer (the paddle is the pointer)

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If physics/movement act oddly with 0, use 1
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
CPU_PERFORMANCE=0   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     game speed is uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE

# ----- Sound mixer ------------------------------------------------------------
# 0 = straight to the Pi's HDMI sound through ALSA (sound effects only -
#     no room for the music as well).
# 2 = a game-only ALSA mixer: dmix ->
#     loopback -> alsaloop -> HDMI. The HDMI sound stays open for the whole
#     game, so no sound loses its start while the TV's HDMI audio wakes up.
#     Needs alsa-utils (alsaloop) and the snd-aloop module (loaded by the
#     script).
# 1 = a private PulseAudio just for this game (no music - FluidSynth
#     needs the ALSA mixer).
# If the chosen mixer can't start, plain ALSA is used.
# ES and emulators keep plain ALSA in every case.
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=60            # SOUND_MIXER=1: sound buffered between the game and
                            # PulseAudio: higher = safer from clicks, sound
                            # slightly later

# ----- Music (MIDI) -----------------------------------------------------------
# DX-Ball's music is MIDI (the .mds files) - it needs a MIDI synth, which
# Wine doesn't have ("No software synthesizer midi port found" in the log).
# MUSIC=1 runs FluidSynth while the game plays, mixed with the sound effects
# by the ALSA mixer (needs SOUND_MIXER=2). One-off install:
#   sudo apt install fluidsynth fluid-soundfont-gm
MUSIC=1
SOUNDFONT="/usr/share/sounds/sf2/FluidR3_GM.sf2"
MIDI_GAIN=0.6               # music volume (FluidSynth gain; 1 = loud)

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

# Box64's settings file (4 cores, BIGBLOCK for the game), DYNACACHE - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# Create the prefix on first run, then (re)apply settings whenever they change
setup_prefix() {
    prefix_setup dxball      # (+ finishes a pending update after a new Wine)
    local reg_new="$WINEPREFIX/drive_c/dxball-settings.reg"
    local reg_old="$WINEPREFIX/dxball-settings.applied"
    cat > "$reg_new" <<'EOF'
REGEDIT4

; Black Wine desktop; Wine mustn't change the real screen mode
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; DirectDraw drawn in normal memory (gl = too slow, vulkan = black screen);
; no separate Direct3D thread
[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"renderer"="gdi"
"csmt"=dword:00000000
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Wine, the game, FluidSynth and the sound mixer - nothing left running
cleanup() {
    stop_boot_log
    wineserver -k 2>/dev/null
    fluidsynth_stop
    sound_mixer_stop
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: start X just for the game, on ES's console
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    NOCURSOR=""; [ "$HIDE_CURSOR" = "1" ] && NOCURSOR="-nocursor"
    # shellcheck disable=SC2086
    start_x $NOCURSOR -quiet
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null
# Keep the TV at NATIVE_RES and let the GPU scale GAME_RES up, centred
# (shared code)
display_output "no scaling" && scale_fixed "$GAME_RES"
xsetroot -solid black 2>/dev/null
start_boot_log "${GAME_RES/x/ } 0 0" "$GAME_EXE"

set_governor
setup_prefix
sound_mixer_start dxball   # (shared code; SOUND_MIXER)
# Music: FluidSynth must be running before Wine starts, so the game finds it
if [ "$MUSIC" = "1" ]; then
    if [ "$SOUND_MIXER" = "2" ]; then
        fluidsynth_start dxball    # (shared code; SOUNDFONT, MIDI_GAIN)
    else
        echo "WARNING: music needs SOUND_MIXER=2 (the ALSA mixer) - no music"
    fi
fi
cd "$GAME_DIR" || exit 1
echo "=== $(date) === GAME_RES=$GAME_RES SCALE_MODE=$SCALE_MODE BIGBLOCK=$BIGBLOCK X87DOUBLE=$X87DOUBLE CALLRET=$CALLRET DYNACACHE=$DYNACACHE SOUND_MIXER=$SOUND_MIXER MUSIC=$MUSIC"
wine explorer /desktop=dxball,"$GAME_RES" "$GAME_EXE" &
# Back as soon as Wine has finished after the game closes (shared code)
wait_for_game $! "$GAME_EXE"
exit 0
