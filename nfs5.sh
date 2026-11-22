#!/bin/bash
# =============================================================================
#  Need for Speed: Porsche 2000 / Porsche Unleashed - Wine (WOW64) + Box64
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  Renders through the game's Voodoo2 (Glide) driver -> nGlide (Glide.dll,
#  Glide2x.dll, Glide3x.dll in the game folder) -> Direct3D 9 -> Wine's
#  wined3d -> OpenGL on the Pi's GPU.
#  The game runs in a Wine desktop of DESK_RES. nGlide ("By desktop") draws
#  the 3D at that size, 4:3 with black side bars, and the Pi's display
#  hardware scales the desktop up to the TV (free - no GL work).
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfs5.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfs5\nfs5-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/nfs5"        # \\<pi>\roms\windows\nfs5
GAME_EXE="Porsche.exe"      # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/nfs5"
LOG_FILE="$GAME_DIR/nfs5-launch.log"

# nGlide settings exported from nGlide's configurator on Windows
# (HKCU\Software\Zeus Software). Imported whenever the file changes.
# nGlide's "Resolution" is forced to "By desktop" every launch.
NGLIDE_REG="$GAME_DIR/nglide.reg"

# ----- Display ----------------------------------------------------------------
# DESK_RES = the Wine desktop, and the size nGlide renders the 3D at.
# Keep it 16:9. The Pi's display hardware scales it up to the TV for free.
#   1920x1080 = sharpest, most GPU work (same as the old script)
#   1600x900  = a little lighter
#   1280x720  = noticeably lighter - try this if races drop frames
DESK_RES="1280x720"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky

# The game's own (Glide) resolution: sets the menus/HUD layout. nGlide
# redraws the 3D at DESK_RES whatever this is.
THRASH_RES="640x480"
FORCE_RES=1                 # 1 = reset to THRASH_RES every launch

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
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
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE
GLTHREAD=0          # Mesa's GL thread. wined3d already has its own render
                    # thread, so off - try 1 if the CPU is the bottleneck
HIDE_CURSOR=0       # 1 = no X pointer

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

# GL 3.3 for wined3d (V3D reports 3.1)
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
export vblank_mode=0                           # vsync is nGlide's job (both = ~10 fps)
[ "$GLTHREAD" = "1" ] && export mesa_glthread=true || export mesa_glthread=false

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup nfs5      # (+ finishes a pending update after a new Wine)

    # Wine settings + the game's installer keys, in ONE import (the old
    # script's 15 separate "reg add" calls were 15 Box64 + Wine start-ups).
    # 32-bit game, so HKLM keys go under Wow6432Node.
    local win_dir="Z:${GAME_DIR//\//\\}\\"
    win_dir="${win_dir//\\/\\\\}"                   # doubled for the .reg file
    local reg="$WINEPREFIX/drive_c/nfs5-settings.reg"
    cat > "$reg" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU scaling
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="1024"

; Black Wine desktop (the side bars)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; Porsche is a 2000 game - report Windows XP to it (no winecfg run needed)
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"

[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Electronic Arts\\Need For Speed - Porsche 2000]
"Install Dir"="$win_dir"
"Path"="$win_dir"
"CD Drive"="$win_dir"
"Language"="English"
"Thrash Driver"="voodoo2"
"Thrash Resolution"="$THRASH_RES"
"3D Card"="3Dfx Voodoo 2"
"3D Device Description"="3Dfx Voodoo 2"
"Group"="3Dfx"
"Hardware Acceleration"=dword:00000001
"D3D Device"=dword:00000000
"Triple Buffer"=dword:00000000

[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\DirectX]
"Version"="4.07.00.0700"

[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Microsoft\\DirectX]
"Version"="4.07.00.0700"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg"
    # Imported only when something changes (each import is a full Box64 +
    # Wine start-up) - shared code
    import_reg "$reg" "$WINEPREFIX/nfs5-settings.applied"
    [ -f "$NGLIDE_REG" ] && import_reg "$NGLIDE_REG" "$WINEPREFIX/nglide.applied"
    wineserver -w

    # Edited straight in the registry files (Wine has stopped), so no
    # start-up time. Case-insensitive: games sometimes rewrite key case.
    if [ "$FORCE_RES" = "1" ]; then
        sed -i '/^\[Software\\\\Wow6432Node\\\\Electronic Arts\\\\Need For Speed - Porsche 2000\]/I,/^\[/ s/^"Thrash Resolution"=".*"/"Thrash Resolution"="'"$THRASH_RES"'"/I' \
            "$WINEPREFIX/system.reg"
    fi
    # nGlide Resolution = "By desktop" (1), so it always matches DESK_RES
    sed -i '/^\[Software\\\\Zeus Software\\\\nGlide2\?\]/,/^$/ s/^"Resolution"=".*"/"Resolution"="1"/' \
        "$WINEPREFIX/user.reg"                  # (nGlide and nGlide2)
}

# TV stays at NATIVE_RES; the X screen is DESK_RES, scaled up to fill it
set_display() {
    SCALE_FALLBACK=native           # (if scaling fails: a NATIVE_RES desktop)
    display_output "no scaling" && scale_fixed "$DESK_RES" topleft     # (shared code)
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) ==="
    # Wine desktop: the game can't switch the real screen mode
    wine explorer /desktop=nfs5,"$DESK_RES" "$GAME_EXE" &
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
    # From EmulationStation: prefix setup first (no X needed), then X just
    # for the game, on ES's console, so it exits cleanly back to ES
    # (runs via bash, so the script needs no exec bit)
    check_files "$GAME_DIR/$GAME_EXE" > "$LOG_FILE" 2>&1 || exit 1
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
start_boot_log "${DESK_RES%x*} ${DESK_RES#*x} 0 0" "$GAME_EXE"
set_governor
sound_mixer_start nfs5   # (shared code; SOUND_MIXER)
run_game
exit 0