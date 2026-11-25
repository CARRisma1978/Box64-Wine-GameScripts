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
GAME_ID="nfs5"              # short name: its Wine prefix
                            #   (~/wine-prefixes/nfs5) and log
GAME_DIR="$HOME/RetroPie/roms/windows/nfs5"        # \\<pi>\roms\windows\nfs5
GAME_EXE="Porsche.exe"      # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# DESK_RES = the Wine desktop, and the size nGlide renders the 3D at.
# Keep it 16:9. The Pi's display hardware scales it up to the TV for free.
#   1920x1080 = sharpest, most GPU work (same as the old script)
#   1600x900  = a little lighter
#   1280x720  = noticeably lighter - try this if races drop frames
DESK_RES="1280x720"
# The game's own (Glide) resolution: sets the menus/HUD layout. nGlide
# redraws the 3D at DESK_RES whatever this is. Set again every launch.
THRASH_RES="640x480"
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (0 here: vsync is nGlide's job - both at once = ~10 fps)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If car handling/physics act oddly with 0, use 1
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
GLTHREAD=0          # Mesa's GL thread. wined3d already has its own render
                    #   thread, so off - try 1 if the CPU is the bottleneck

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

# ----- nGlide -----------------------------------------------------------------
# nGlide settings exported from nGlide's configurator on Windows
# (HKCU\Software\Zeus Software). Imported whenever the file changes.
# nGlide's "Resolution" is forced to "By desktop" every launch.
NGLIDE_REG="$GAME_DIR/nglide.reg"

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
# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# The prefix (shared code), then the registry: Wine settings + the game's
# installer keys in ONE import, only when it changes (each import is a full
# Box64 + Wine start-up). 32-bit game, so HKLM keys go under Wow6432Node.
setup_prefix() {
    prefix_setup
    local win_dir="Z:${GAME_DIR//\//\\}\\"
    win_dir="${win_dir//\\/\\\\}"                   # doubled for the .reg file
    local reg="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    { wine_base_reg dsound; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="1024"

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
    } > "$reg"
    import_reg "$reg" "$WINEPREFIX/$GAME_ID-settings.applied"
    [ -f "$NGLIDE_REG" ] && import_reg "$NGLIDE_REG" "$WINEPREFIX/nglide.applied"
    wineserver -w

    # Edited straight in the registry files (Wine has stopped), so no
    # start-up time. Case-insensitive: games sometimes rewrite key case.
    # The game's resolution: THRASH_RES every launch
    sed -i '/^\[Software\\\\Wow6432Node\\\\Electronic Arts\\\\Need For Speed - Porsche 2000\]/I,/^\[/ s/^"Thrash Resolution"=".*"/"Thrash Resolution"="'"$THRASH_RES"'"/I' \
        "$WINEPREFIX/system.reg"
    # nGlide Resolution = "By desktop" (1), so it always matches DESK_RES
    sed -i '/^\[Software\\\\Zeus Software\\\\nGlide2\?\]/,/^$/ s/^"Resolution"=".*"/"Resolution"="1"/' \
        "$WINEPREFIX/user.reg"                  # (nGlide and nGlide2)
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the X screen is DESK_RES, scaled up
    # to fill it (if scaling fails: a desktop the TV's size)
    SCALE_FALLBACK=native
    display_output "no scaling" && scale_fixed "$DESK_RES" topleft
    xsetroot -solid black 2>/dev/null
    start_boot_log "${DESK_RES%x*} ${DESK_RES#*x} 0 0" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings DESK_RES THRASH_RES
    # Wine desktop: the game can't switch the real screen mode
    wine explorer /desktop="$GAME_ID","$DESK_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
