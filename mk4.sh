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
GAME_ID="mk4"               # short name: its Wine prefix
                            #   (~/wine-prefixes/mk4) and log
GAME_DIR="$HOME/RetroPie/roms/windows/mk4"         # \\<pi>\roms\windows\mk4
GAME_EXE="mk4.exe"          # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg)
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    #   (0 here: vsync is nGlide's job - both at once = slow)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    #   If anything acts oddly with 0, use 1
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

# ----- nGlide -----------------------------------------------------------------
# nGlide settings exported from nGlide's configurator on Windows
# (HKCU\Software\Zeus Software): Aspect ratio = Aspect correction, VSync on,
# splash off. Imported automatically whenever the file changes. nGlide's
# "Resolution" is forced to "By desktop" every launch.
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
# (for nGlide's Direct3D 9 backend)
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    { wine_base_reg dsound; cat <<'EOF'
[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"VideoMemorySize"="1024"

; MK4's own key (normally written by its installer). 32-bit game, so it
; reads the Wow6432Node view. Path ".\" = the game folder.
[HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\GT Interactive\Mortal Kombat 4\1.00]
"Path"=".\\"
EOF
    } > "$reg"
    import_reg "$reg" "$WINEPREFIX/$GAME_ID-settings.applied"
    [ -f "$NGLIDE_REG" ] && import_reg "$NGLIDE_REG" "$WINEPREFIX/nglide.applied"
    wineserver -w

    # nGlide Resolution = "By desktop" (1), edited straight in user.reg
    # (Wine has stopped), so it always matches the Wine desktop
    sed -i '/^\[Software\\\\Zeus Software\\\\nGlide2\?\]/,/^$/ s/^"Resolution"=".*"/"Resolution"="1"/' \
        "$WINEPREFIX/user.reg"                  # (nGlide and nGlide2)
}

# Inside X (from launch, shared code)
in_x() {
    # The TV at its normal mode, no scaling - nGlide fills the desktop itself
    display_output "no scaling" && scale_fixed "$NATIVE_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "${NATIVE_RES%x*} ${NATIVE_RES#*x} 0 0" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings
    # Wine desktop: MK4 can't switch the real screen mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
