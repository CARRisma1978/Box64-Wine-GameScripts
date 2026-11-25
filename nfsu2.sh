#!/bin/bash
# =============================================================================
#  Need for Speed: Underground 2 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  Uses SPEED2_PATCHED.EXE made by nfsu2-lockfix.py (fixes the game's
#  non-thread-safe lock that crashed it in the menus on multi-core CPUs).
#
#  How it works:
#   - Direct3D 9 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - The Wine desktop is the TV's size. When the game sets a screen mode
#     (menus, or the resolution picked in its Display options), Wine shrinks
#     the game's window to that size in the top-left corner. A helper watches
#     the window and has the Pi's display hardware zoom it to full TV height
#     (4:3 -> black side bars), with black panels over the rest of the
#     desktop. The zoom costs no GL work, and whatever resolution is picked
#     in the game is followed automatically - no need to edit this script.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can use.
#   - The zoom starts at the menu size (START_RES) as soon as X starts, so
#     the first screen appears already the right size, then follows the
#     game as normal.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfsu2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfsu2\nfsu2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="nfsu2"             # short name: its Wine prefix
                            #   (~/wine-prefixes/nfsu2) and log
GAME_DIR="$HOME/RetroPie/roms/windows/nfsu2"       # \\<pi>\roms\windows\nfsu2
GAME_EXE="SPEED2_PATCHED.EXE"   # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# Set the resolution in the GAME's Display options; the zoom follows it.
# All shown at full TV height, 4:3 with black side bars:
#    640x480 = lightest (same as the menus)
#    800x600 = a good first step up
#   1024x768 = sharper
#   1280x960 = sharpest correct-shape picture (1280x1024 is 5:4 - too tall)
START_RES="640x480"         # zoom from the moment X starts, before the game
                            # appears - the size of its first (menu) screen.
                            # "" = start at 1:1.
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
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
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
STRONGMEM=3         # Box64 memory ordering 0-3. Keep >= 1: the lock fix relies
                    #   on the game's stores being seen in order. 3 = safest
                    #   (tested); try 2, then 1, for speed - back up if the menu
                    #   crashes/hangs return
VIDEO_MEM_MB=1536   # VRAM reported to the game (keep below 2048)

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
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game, STRONGMEM),
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

; NFSU2 is a 2004 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1 (so e.g.
# 1440x1080 is still centred).
ZOOM_FB="$NATIVE_RES"

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - ~853x480 in
    # the 640x480 menus - and the game's resolution list could shrink, or a
    # bigger mode for a race be refused), then straight to the menu size
    # (START_RES; 1:1 if not known), in the top-left corner where Wine puts
    # the game. The helper takes over from there. (shared code)
    local start=""
    [[ "$START_RES" =~ ^[0-9]+x[0-9]+$ ]] && start="${START_RES%x*} ${START_RES#*x}"
    # shellcheck disable=SC2086
    zoom_start "$NATIVE_RES" $start
    xsetroot -solid black 2>/dev/null
    # shellcheck disable=SC2153   # (START_GEO is set by zoom_start)
    start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows
                                                #   from the start)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # Keyboard to the game: with no window manager, X sends key presses to
    # whatever is under the (hidden) pointer, which missed the game (and
    # Matchbox didn't hand it over either). The keeper gives the focus to
    # Wine's desktop whenever nothing has it (shared code; stopped by the
    # shared cleanup).
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings START_RES VIDEO_MEM_MB
    # (shared code)
    FOLLOW_FENCE="$MOUSE_FENCE" FOLLOW_HOLD_FULL=1 follow_start
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
