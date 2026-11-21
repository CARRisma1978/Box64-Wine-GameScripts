#!/bin/bash
# =============================================================================
#  Star Wars Episode I: Racer - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D (DirectDraw era) -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - Racer always runs at 640x480 (no resolution option). The TV stays at
#     NATIVE_RES and the Pi's display hardware scales the picture up to full
#     height, 4:3 with black side bars (free - no GL work).
#   - Prefix setup, the EXE copy and the sound mixer (SOUND_MIXER) run
#     BEFORE X starts.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/racer.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\racer\racer-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/racer"       # \\<pi>\roms\windows\racer
GAME_EXE="SWEP1RCR_nocd.EXE"
WINE_EXE="SWEP1RCR_wine.EXE"    # copy of GAME_EXE that loads DDRAW.dll - this is
                                # what really runs (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/racer"
LOG_FILE="$GAME_DIR/racer-launch.log"

# ----- Display ----------------------------------------------------------------
GAME_RES="640x480"          # Racer's fixed resolution (no in-game choice -
                            # its full-screen mode offered none either, and
                            # flickered with buggy sound)
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
KEEP_ASPECT=1               # 1 = 4:3 with black side bars, 0 = stretch to fill
HIDE_CURSOR=1               # 1 = no X pointer (gamepad play)

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If pod handling/physics act oddly with 0, use 1
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
GL33=1              # GL 3.3 for wined3d (V3D reports 3.1) - its modern GLSL
                    # path, as every other Direct3D script here. 0 = old behaviour
RDTSC_1GHZ=1        # steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
VIDEO_MEM_MB=512    # VRAM reported to the game (512 = the old, tested value)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE

# ----- Sound mixer ------------------------------------------------------------
# Racer opens several sound streams at once and the Pi 5's HDMI takes one, so
# a mixer just for this game mixes them into one stream to the TV.
# 1 = a private PulseAudio. See the bottom of this
#     file for the install.
# 2 = the same with ALSA only (as outrun.sh / SeriousSam.sh): dmix ->
#     loopback -> alsaloop -> HDMI. Needs alsa-utils (alsaloop) and the
#     snd-aloop module (loaded by the script).
# 0 = straight to the Pi's HDMI through ALSA - no mixing, so expect missing
#     sounds.
# ES and emulators keep using plain ALSA in every case.
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=""            # SOUND_MIXER=1: "" = PulseAudio's default; 60 = a
                            # cushion against clicks during CPU spikes (as nfs2.sh)

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
# Always Wine's own DirectDraw and DirectSound (not any copies in the game folder)
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;ddraw,d3dimm=b;dsound=b"

if [ "$GL33" = "1" ]; then
    export MESA_GL_VERSION_OVERRIDE=3.3
    export MESA_GLSL_VERSION_OVERRIDE=330
fi
export MESA_NO_ERROR=1                         # skip GL error checking
export mesa_glthread=false                     # wined3d has its own render thread
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$WINE_EXE"

# ===================== Helpers =====================

# The EXE is patched to load PDRAW.dll (a Windows-only fix that crashes
# under Wine). Make a copy that loads DDRAW.dll instead - only when needed.
make_wine_exe() {
    cd "$GAME_DIR" || exit 1
    if [ ! -f "$WINE_EXE" ] || [ "$GAME_EXE" -nt "$WINE_EXE" ]; then
        echo "Making $WINE_EXE from $GAME_EXE..."
        perl -0777 -pe 's/PDRAW\.DLL/DDRAW.DLL/gi' "$GAME_EXE" > "$WINE_EXE"
    fi
}

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup racer      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/racer-settings.reg" reg_old="$WINEPREFIX/racer-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU scaling
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"
"GrabFullscreen"="Y"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; Wine's sound output: PulseAudio (the private mixer) or ALSA - named, so
; Wine doesn't try PulseAudio first when it isn't running
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$([ "$SOUND_MIXER" = "1" ] && echo '"Audio"="pulse"' || echo '"Audio"="alsa"')

; Black Wine desktop (the side bars)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$WINE_EXE]
"Version"="win7"

; Gamepads through SDL
[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\winebus]
"Enable SDL"=dword:00000001
"DisableHidraw"=dword:00000001
"DisableInput"=dword:00000001
EOF
    import_reg "$reg_new" "$reg_old"
}

# ----- Display -----
# TV stays at NATIVE_RES; the Pi's display hardware scales GAME_RES up to
# full height, centred (free - no GL work). Centring puts part of the scaled
# screen at a negative x, so the X screen (and the Wine desktop, which covers
# it, black) reaches the far edge of the picture: 747x480 for 640x480. The
# game sits in its top-left 640x480.
set_display() {
    DESK_RES="$GAME_RES"
    display_output "no scaling" && scale_fixed "$GAME_RES"     # (shared code, KEEP_ASPECT)
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === DESK_RES=$DESK_RES KEEP_ASPECT=$KEEP_ASPECT VSYNC=$VSYNC GL33=$GL33 X87DOUBLE=$X87DOUBLE BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET SOUND_MIXER=$SOUND_MIXER"
    # Wine desktop covering the whole X screen (black beside the game); the
    # game can't change the real screen mode
    wine explorer /desktop=racer,"$DESK_RES" "$WINE_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$WINE_EXE"
}

cleanup() {
    stop_boot_log
    wineserver -k 2>/dev/null
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: EXE copy, prefix setup and sound first (no X
    # needed), then X just for the game, on ES's console, so it exits
    # cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    {
        make_wine_exe
        setup_prefix
    } >> "$LOG_FILE" 2>&1

    trap sound_mixer_stop EXIT          # sound stopped however this ends
    trap 'exit 1' INT TERM
    sound_mixer_start racer >> "$LOG_FILE" 2>&1   # (shared code; exports PULSE_SERVER / ALSA_CONFIG_PATH for Wine)

    NOCURSOR=""; [ "$HIDE_CURSOR" = "1" ] && NOCURSOR="-nocursor"
    # shellcheck disable=SC2086
    start_x -quiet $NOCURSOR
    wineserver -k 2>/dev/null           # make sure nothing is left running
    exit 0                              # (the EXIT trap stops the sound)
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
set_display
start_boot_log "${GAME_RES%x*} ${GAME_RES#*x} 0 0" "$WINE_EXE"
set_governor
run_game
exit 0

# =============================================================================
#  SOUND_MIXER=1: one-off PulseAudio install (already done on this Pi). The
#  mask lines stop PulseAudio starting by itself, so EmulationStation and
#  emulators keep using plain ALSA; this script runs its own copy just for
#  Racer. (SOUND_MIXER=2 needs alsa-utils instead, already installed.)
#
#    sudo apt install --no-install-recommends pulseaudio pulseaudio-utils
#    sudo systemctl --global mask pulseaudio.socket pulseaudio.service
#    systemctl --user mask pulseaudio.socket pulseaudio.service
# =============================================================================