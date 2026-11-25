#!/bin/bash
# =============================================================================
#  Jazz Jackrabbit 2 (v1.23) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - JJ2 draws DirectDraw at 640x480 (8 or 16-bit colour). Wine's own
#     DirectDraw is used (through wined3d and OpenGL on the Pi's GPU) -
#     tested over full levels. The flashing and noise bands seen with it at
#     first came from the FPU memory copy (below), not from Wine.
#     cnc-ddraw is optional: put its ddraw.dll (+ ddraw.ini) in the game
#     folder and it's used instead (see below).
#   - Runs Jazz2-pi.exe, a patched copy of Jazz2.exe made ONCE by
#     jj2-patch.py (in the game folder - details in it):
#      - FPU memory copy: on a Pentium or later, JJ2 copies memory 8 bytes
#        at a time through the x87 FPU (FILD/FISTP QWORD). Box64 does x87
#        maths in 64-bit doubles (53 bits), so the low byte of every 8 got
#        damaged: noise bands / thin vertical lines and a crash on exit.
#        Switched off.
#      - Sound shutdown: the sound timer and the shutdown raced for the
#        sound lock (slowed down by emulation): an Access Violation or a
#        hang on exit. Reordered so they can't collide.
#     To make it (again after updating the .py, or if Jazz2.exe changes),
#     over SSH:
#         python3 ~/RetroPie/roms/windows/Jazz2/jj2-patch.py
#   - Bare X, no window manager. The game runs full screen in a Wine desktop
#     of GAME_RES; the TV stays at its normal mode and the Pi's display
#     hardware scales the picture up, centred (free - no GL work).
#   - Keyboard: with no window manager, X sends key presses to whatever is
#     under the (hidden) pointer, which can miss the game. X starts with the
#     pointer mid-screen; shrinking the X screen for the scaling left it at
#     the right edge, beside the 640x480 game - intro videos sometimes
#     couldn't be skipped. So the pointer is fenced onto the game's area,
#     and a helper gives the focus to Wine's desktop whenever nothing has it
#     (shared code).
#   - Ambient Lighting (video options) is only available with the game's
#     Hardware Acceleration option off.
#   - Video modes: JJ2 lists the modes DirectDraw reports. The Wine desktop
#     is fixed at 640x480 and Wine may not change the screen mode, so Wine's
#     DirectDraw offers just 640x480 (8 and 16-bit). cnc-ddraw also offers
#     the lower, low-detail modes (stretched to fill the picture, blockier);
#     with it, the log's "ChangeDisplaySettings returned -2" lines are
#     expected.
#
#  Keys: JJ2 1.23 is keyboard only (menus and game) - no mouse support.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/Jazz2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Jazz2\jazz2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="jazz2"             # short name: its Wine prefix
                            #   (~/wine-prefixes/jazz2) and log
GAME_DIR="$HOME/RetroPie/roms/windows/Jazz2"       # \\<pi>\roms\windows\Jazz2
GAME_EXE="Jazz2-pi.exe"     # exactly as spelled on disk
                            #   Jazz2-pi.exe = patched copy (jj2-patch.py)
                            #   Jazz2.exe    = the original (vertical lines,
                            #                  exit crash/hang)

# ----- Display ----------------------------------------------------------------
# JJ2 draws 640x480. It runs in a Wine desktop of that size; the TV stays at
# its normal mode and the Pi's GPU scales the picture up, centred.
GAME_RES="640x480"
SCALE_MODE="fit"            # fit     = full height (2.25x), black side bars
                            # integer = exact 2x (1280x960), small black border
                            #   (integer + SCALE_FILTER="nearest" - set here or
                            #   in .scripts/settings.cfg - = crisp pixel art)
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game is played on the keyboard)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
                    # (with cnc-ddraw: renderer=opengl in ddraw.ini only)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If physics/movement act oddly with 0, use 1
BIGBLOCK=           # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code (3 = an extra for
                    #   LoongArch CPUs only, not the Pi); empty = Box64's
                    #   default (2). Can crash some games - if so, try 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and
                    #   loading): empty = on, one cache shared by all games
                    #   (~/.cache/box64); 1 = on, this game's own cache
                    #   (box64-cache in its prefix); 0 = off
CPU_PERFORMANCE=0   # 1 = CPU governor 'performance' while playing
                    #   (needs passwordless sudo), 0 = left as it is
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
                    # (try 1 if scrolling looks uneven)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL work on its own thread - try 1 if FPS_HUD=2
                    #   shows one core at 100%

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
                    # (JJ2's music is its own module (.j2b) files, mixed by the
                    #   game into the same sound - no MIDI/FluidSynth needed)

# ----- DirectDraw (optional cnc-ddraw) ----------------------------------------
# Normally Wine's own DirectDraw. To use cnc-ddraw instead (lower resolutions
# too, its own shader/vsync options):
# https://github.com/FunkyFr3sh/cnc-ddraw/releases (cnc-ddraw.zip) - put
# ddraw.dll and ddraw.ini from it in \\<pi>\roms\windows\Jazz2. Its options
# are set in that ddraw.ini (edit it in Notepad++); the script just loads it
# and notes the renderer, shader and vsync in the log. Remove (or rename)
# ddraw.dll to go back to Wine's own.

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
# cnc-ddraw's ddraw.dll from the game folder (if there) instead of Wine's own
DDRAW_ON=0
if [ -n "$(find "$GAME_DIR" -maxdepth 1 -iname ddraw.dll -print -quit)" ]; then
    export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;ddraw=n,b"
    DDRAW_ON=1
fi

# OpenGL: no error checking, GLTHREAD - shared code
gl_setup

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging +loaddll   # (debug: + which DLLs load, e.g. cnc-ddraw's)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# Before X starts (from launch, shared code): the patched exe must have
# been made
check_game() {
    if [ ! -f "$GAME_DIR/$GAME_EXE" ] && [ "$GAME_EXE" = "Jazz2-pi.exe" ]; then
        echo "ERROR: $GAME_EXE not found - make it once with:"
        echo "    python3 $GAME_DIR/jj2-patch.py"
        sleep 5; exit 1
    fi
}

# Which DirectDraw - and with cnc-ddraw, (from ddraw.ini, read only) the
# renderer, shader and vsync it will use - for the log
log_ddraw() {
    if [ "$DDRAW_ON" != "1" ]; then
        echo "DirectDraw: Wine's own (no cnc-ddraw ddraw.dll in the game folder)"
        return 0
    fi
    local ini
    ini="$(find "$GAME_DIR" -maxdepth 1 -iname ddraw.ini -print -quit)"
    if [ -z "$ini" ]; then
        echo "DirectDraw: cnc-ddraw (no ddraw.ini - its built-in defaults)"
        return 0
    fi
    echo "DirectDraw: cnc-ddraw - $(tr -d '\r' < "$ini" | awk '
        /^[[:space:]]*\[/ { s = tolower($0); gsub(/[][[:space:]]/, "", s) }
        s == "ddraw" && /^[[:space:]]*(renderer|shader|vsync)[[:space:]]*=/ {
            sub(/[[:space:]]*=[[:space:]]*/, "="); printf "%s ", $0 }')(ddraw.ini [ddraw])"
}

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    wine_base_reg dsound > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the GPU scales GAME_RES up, centred
    display_output "no scaling" && scale_fixed "$GAME_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$GW $GH 0 0" "$GAME_EXE"
    # Keyboard to the game: with no window manager, X sends key presses to
    # whatever is under the (hidden) pointer. The pointer is fenced onto the
    # game (shared code)
    fence_area "$GAME_ID-panels" "$GW" "$GH"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # ...and the keeper gives the focus to Wine's desktop whenever nothing
    # has it (shared code; stopped by the shared cleanup)
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_ddraw
    log_settings GAME_EXE SCALE_MODE CNC_DDRAW="$DDRAW_ON"
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
