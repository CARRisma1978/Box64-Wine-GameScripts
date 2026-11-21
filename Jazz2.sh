#!/bin/bash
# =============================================================================
#  Jazz Jackrabbit 2 (v1.23) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works (based on dxball.sh / AngryBirds.sh):
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
#     of GAME_RES; the TV stays at NATIVE_RES and the Pi's display hardware
#     scales the picture up, centred (free - no GL work).
#   - Keyboard: with no window manager, X sends key presses to whatever is
#     under the (hidden) pointer, which can miss the game. X starts with the
#     pointer mid-screen; shrinking the X screen for the scaling left it at
#     the right edge, beside the 640x480 game - intro videos sometimes
#     couldn't be skipped. So the pointer is fenced onto the game's area
#     (panels.py, as 3DPinball.sh), and a helper gives the focus to Wine's
#     desktop whenever nothing has it (focus.py, as nfs2.sh / SeriousSam.sh).
#   - Ambient Lighting (video options) is only available with the game's
#     Hardware Acceleration option off.
#   - Video modes: JJ2 lists the modes DirectDraw reports. The Wine desktop
#     is fixed at 640x480 and Wine may not change the screen mode, so Wine's
#     DirectDraw offers just 640x480 (8 and 16-bit). cnc-ddraw also offers
#     the lower, low-detail modes (stretched to fill the picture, blockier);
#     with it, the log's "ChangeDisplaySettings returned -2" lines are
#     expected.
#   - Sound: straight to the Pi's HDMI (SOUND_MIXER=0) works for JJ2 (the
#     log's "alsa_get_mix_format" line is just Wine's first try). The
#     private mixers (as AngryBirds.sh / SeriousSam.sh) are kept as options.
#     JJ2's music is its own module (.j2b) files, mixed by the game into
#     the same DirectSound stream - no MIDI/FluidSynth needed.
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards,
#     and registry settings are imported only when they change.
#
#  Keys: JJ2 1.23 is keyboard only (menus and game) - no mouse support.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/Jazz2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Jazz2\jazz2-launch.log
# =============================================================================

# ===================== Settings =====================
SCRIPT_VERSION="2026-10-23 r17 (Wine DirectDraw, cnc-ddraw optional)"     # shown in the log - which copy ran
GAME_DIR="$HOME/RetroPie/roms/windows/Jazz2"       # \\<pi>\roms\windows\Jazz2
GAME_EXE="Jazz2-pi.exe"     # exactly as spelled on disk (Box64 settings match it)
                            #   Jazz2-pi.exe = patched copy (jj2-patch.py)
                            #   Jazz2.exe    = the original (vertical lines, exit
                            #                  crash/hang)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/jazz2"
LOG_FILE="$GAME_DIR/jazz2-launch.log"

# ----- Display ----------------------------------------------------------------
# JJ2 draws 640x480. It runs in a Wine desktop of that size, the TV stays at
# NATIVE_RES and the Pi's GPU scales the picture up, centred.
GAME_RES="640x480"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_MODE="fit"            # fit     = full height (2.25x), black side bars
                            # integer = exact 2x (1280x960), small black border
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
                            #   (nearest + SCALE_MODE="integer" = crisp pixel art)
HIDE_CURSOR=1               # 1 = no X pointer (the game is played on the keyboard)
                            # 0 = pointer shown

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
                    #   (with cnc-ddraw: renderer=opengl in ddraw.ini only)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If physics/movement act oddly with 0, use 1
BIGBLOCK=           # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code; empty = Box64's default (2).
                    #   3 = as 2, plus protection from random crashes (Box64
                    #   built 26 Oct 2026 or later - check: box64 --version)
                    #   Can crash some games - try 3, then 0
STRONGMEM=          # Box64 memory ordering 0-3; empty = Box64's default (0).
                    #   1 if the game crashes or freezes at random
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=0   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
GLTHREAD=0          # Mesa's GL work on its own thread - try 1 if FPS_HUD=2 shows
                    #     one core at 100%
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     scrolling looks uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (big log, slower start)

# ----- Sound mixer ------------------------------------------------------------
# 2 = a game-only ALSA mixer (dmix -> loopback -> alsaloop -> HDMI, as
#     AngryBirds.sh / 3DPinball.sh) that converts the game's sound for the TV.
# 1 = a private PulseAudio just for this game.
# 0 = straight to the Pi's HDMI through ALSA - works for JJ2 (tested); try 2
#     if the sound ever goes missing or crackles.
# ES and emulators keep using plain ALSA whichever is set.
SOUND_MIXER=0
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=60            # PulseAudio mixer: sound buffered between the game and
                            #   PulseAudio, ms ("" = PulseAudio's default). Raise
                            #   (e.g. 100) if the sound crackles

# ----- DirectDraw (optional cnc-ddraw) ----------------------------------------
# Normally Wine's own DirectDraw. To use cnc-ddraw instead (lower resolutions
# too, its own shader/vsync options):
# https://github.com/FunkyFr3sh/cnc-ddraw/releases (cnc-ddraw.zip) - put
# ddraw.dll and ddraw.ini from it in \\<pi>\roms\windows\Jazz2. Its options
# are set in that ddraw.ini (edit it in Notepad++); the script just loads it
# and notes the renderer, shader and vsync in the log. Remove (or rename)
# ddraw.dll to go back to Wine's own.

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

# cnc-ddraw's ddraw.dll from the game folder (if there) instead of Wine's own
DDRAW_ON=0
if [ -n "$(find "$GAME_DIR" -maxdepth 1 -iname ddraw.dll -print -quit)" ]; then
    export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;ddraw=n,b"
    DDRAW_ON=1
fi

export MESA_NO_ERROR=1                         # skip GL error checking
[ "$GLTHREAD" = "1" ] && export mesa_glthread=true || export mesa_glthread=false

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging +loaddll   # (debug: + which DLLs load, e.g. cnc-ddraw's)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

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

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup jazz2          # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/jazz2-settings.reg" reg_old="$WINEPREFIX/jazz2-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU scaling
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop (shows briefly before the game)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$(case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac)
EOF
    import_reg "$reg_new" "$reg_old"
    log_ddraw
}

# TV stays at NATIVE_RES; GAME_RES scaled up to fit it, centred (shared code)
set_display() {
    display_output "no scaling" && scale_fixed "$GAME_RES"
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === EXE=$GAME_EXE GAME_RES=$GAME_RES X screen=${FB_W}x${FB_H} CNC_DDRAW=$DDRAW_ON GLTHREAD=$GLTHREAD BIGBLOCK=$BIGBLOCK X87DOUBLE=$X87DOUBLE CALLRET=$CALLRET STRONGMEM=$STRONGMEM DYNACACHE=$DYNACACHE RDTSC_1GHZ=$RDTSC_1GHZ SOUND_MIXER=$SOUND_MIXER"
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop=jazz2,"$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
    panels_stop
    focus_stop
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
    echo "Jazz2.sh version: $SCRIPT_VERSION" > "$LOG_FILE"
    if [ ! -f "$GAME_DIR/$GAME_EXE" ] && [ "$GAME_EXE" = "Jazz2-pi.exe" ]; then
        echo "ERROR: $GAME_EXE not found - make it once with:" | tee -a "$LOG_FILE"
        echo "    python3 $GAME_DIR/jj2-patch.py" | tee -a "$LOG_FILE"
        sleep 5; exit 1
    fi
    check_files "$GAME_DIR/$GAME_EXE"
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
xset s off -dpms s noblank 2>/dev/null   # no screen blanking (keyboard-only play)
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$GW $GH 0 0" "$GAME_EXE"
# Keyboard to the game: with no window manager, X sends key presses to
# whatever is under the (hidden) pointer. The pointer is fenced onto the
# game, and the keeper gives the focus to Wine's desktop whenever nothing
# has it (shared code).
fence_area jazz2-panels "$GW" "$GH"     # (shared code)
focus_start explorer.exe "$GAME_EXE"
set_governor
sound_mixer_start jazz2   # (shared code; SOUND_MIXER)
run_game
exit 0
