#!/bin/bash
# =============================================================================
#  Need for Speed: Underground - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D 9 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - The Wine desktop is the TV's size. When the game sets a screen mode
#     (menus, or the resolution picked in its Display options), Wine shrinks
#     the game's window to that size in the top-left corner. A helper watches
#     the window and has the Pi's display hardware zoom it to full TV height
#     (4:3 -> black side bars, 16:9 -> full screen), with black panels over
#     the rest of the desktop. The zoom costs no GL work, and whatever
#     resolution is picked in the game is followed automatically.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can use.
#   - Start-up: messages on screen, then black until the game is ready.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfsu.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfsu\nfsu-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="nfsu"              # short name: its Wine prefix
                            #   (~/wine-prefixes/nfsu) and log
GAME_DIR="$HOME/RetroPie/roms/windows/nfsu"        # \\<pi>\roms\windows\nfsu
GAME_EXE="Speed.exe"        # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# Set the resolution in the GAME's Display options; the zoom follows it.
# All shown at full TV height, 4:3 with black side bars (tested):
#    800x600 = lightest
#   1024x768 = sharper
#   1280x960 = sharpest correct-shape picture
#  1280x1024 = works, but 5:4 - the picture looks slightly too tall
# The menus are always 800x600.
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (gamepad play)
MOUSE_FENCE=1               # 1 = keep the mouse inside the game's picture.
                            #   Without it a fast move takes the pointer off the
                            #   game's window before it reaches the edge, and
                            #   the game's cursor stops short (the game only
                            #   sees moves made inside its window). 0 = off

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
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread. Try 1 if FPS_HUD=2 shows a second
                    #   core at 100%
VIDEO_MEM_MB=1024   # VRAM reported to the game (keep below 2048)

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
# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
# (3.3 also fixes the boxes around trees)
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
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; NFSU is a 2003 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the TV's
# size; only a window the TV's full size is shown 1:1 (so e.g. 1440x1080 is
# still centred).
ZOOM_FB="$NATIVE_RES"

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - ~1067x600 in
    # the 800x600 menus: the game's resolution list shrank, and switching to
    # a bigger mode for a race was refused and the game hung), then 1:1
    # until the game shows (shared code)
    zoom_start "$NATIVE_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings VIDEO_MEM_MB
    # The game's window, followed (shared code): the black panels cover the
    # rest of the desktop (Wine leaves old pictures there after a resolution
    # change); a window the TV's full size is the game's window BEFORE it
    # sets its screen mode (brief, black) - followed only if it stays 3 s
    FOLLOW_FENCE="$MOUSE_FENCE" FOLLOW_HOLD_FULL=1 follow_start
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
