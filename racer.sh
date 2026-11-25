#!/bin/bash
# =============================================================================
#  Star Wars Episode I: Racer - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D (DirectDraw era) -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - Racer always runs at 640x480 (no resolution option). The TV stays at
#     its normal mode and the Pi's display hardware scales the picture up to
#     full height, 4:3 with black side bars (free - no GL work).
#   - Centring puts part of the scaled screen at a negative x, so the X
#     screen (and the Wine desktop, which covers it, black) reaches the far
#     edge of the picture: 747x480 for 640x480. The game sits in its
#     top-left 640x480.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/racer.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\racer\racer-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="racer"             # short name: its Wine prefix
                            #   (~/wine-prefixes/racer) and log
GAME_DIR="$HOME/RetroPie/roms/windows/racer"       # \\<pi>\roms\windows\racer
GAME_EXE="SWEP1RCR_nocd.EXE"    # exactly as spelled on disk
WINE_EXE="SWEP1RCR_wine.EXE"    # copy of GAME_EXE that loads DDRAW.dll - this
                                # is what really runs (Box64 settings match it)

# ----- Display ----------------------------------------------------------------
GAME_RES="640x480"          # Racer's fixed resolution (no in-game choice -
                            # its full-screen mode offered none either, and
                            # flickered with buggy sound)
KEEP_ASPECT=1               # 1 = 4:3 with black side bars, 0 = stretch to fill
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (gamepad play)

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
                    # If pod handling/physics act oddly with 0, use 1
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
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread
VIDEO_MEM_MB=512    # VRAM reported to the game (512 = the old, tested value)

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
                    # (Racer opens several sound streams at once and the Pi's
                    #   HDMI takes one - straight to HDMI (1) means missing
                    #   sounds)

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
# Always Wine's own DirectDraw and DirectSound (not any copies in the
# game folder)
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;ddraw,d3dimm=b;dsound=b"

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
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

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"GrabFullscreen"="Y"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$WINE_EXE]
"Version"="win7"

; Gamepads through SDL
[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\winebus]
"Enable SDL"=dword:00000001
"DisableHidraw"=dword:00000001
"DisableInput"=dword:00000001
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the Pi's display hardware scales
    # GAME_RES up to full height, centred (KEEP_ASPECT). DESK_RES = the X
    # screen's size (shared code sets it)
    DESK_RES="$GAME_RES"
    display_output "no scaling" && scale_fixed "$GAME_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "${GAME_RES%x*} ${GAME_RES#*x} 0 0" "$WINE_EXE"
    set_governor
    make_wine_exe
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings DESK_RES KEEP_ASPECT VIDEO_MEM_MB
    # Wine desktop covering the whole X screen (black beside the game); the
    # game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$DESK_RES" "$WINE_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$WINE_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
