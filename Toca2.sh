#!/bin/bash
# =============================================================================
#  TOCA 2: Touring Cars - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D -> Wine's wined3d -> OpenGL on the Pi's GPU. SilentPatch is
#     loaded by the game's own winmm.dll (Ultimate ASI Loader).
#   - The Wine desktop is DESKTOP_RES (the TV's size, so the game's options
#     list every screen mode up to it). When the game sets a screen mode
#     (640x480 for the intro videos and menus, the race resolution picked in
#     its options for races), Wine shrinks its window (TC2.exe's) to that
#     size in the top-left corner. A helper watches the window and has the
#     Pi's display hardware zoom it to full TV height (4:3 -> black side
#     bars, 16:9 -> full screen), with black panels over the rest of the
#     desktop (Wine leaves it white in the videos). The zoom costs no GL
#     work, and any resolution picked in the game is followed automatically
#     (as nfsu.sh / nfsu2.sh).
#   - X reports a fixed DESKTOP_RES "monitor" to Wine. Without it, Wine
#     measures the monitor from the zoomed menu (853x480) and squeezes races
#     to 854x480 - the game rendered at full size, then shrunk, then
#     re-enlarged (as found with NFSU).
#   - Sound: through a game-only mixer (SOUND_MIXER below).
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/Toca2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Toca2\toca2.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Toca2/Game"  # \\<pi>\roms\windows\Toca2\Game
GAME_EXE="toca2.exe"        # the launcher Wine starts...
GAME_PROC="TC2.exe"         # ...which starts the real game and closes. Both
                            # exactly as spelled on disk (Box64 settings match
                            # them; "has it quit?" checks both)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/toca2"
LOG_FILE="$HOME/RetroPie/roms/windows/Toca2/toca2.log"

# ----- Display ----------------------------------------------------------------
# Pick the race resolution in the GAME's options - the zoom follows the
# game's window, nothing to set here. 16:9 fills the TV, 4:3 gets black
# side bars:
#   1280x720 = 1.5x zoom
#   1600x900 = 1.2x zoom, sharper
#  1920x1080 = no zoom at all in races, sharpest, most GPU work
# The Wine desktop's size. Wine only offers the game screen modes that fit
# inside it (a 960x540 desktop gave just 640x480 and 960x540), so the TV's
# size makes every mode up to 1920x1080 selectable in the game's options.
DESKTOP_RES="1920x1080"
MENU_RES="640x480"          # intro videos and menus (fixed by the game) - the
                            # zoom starts at this, before the game appears
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If cars/scenery jump or physics act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=1           # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
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
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if uneven
                    #   0 or empty = off (Box64's default)
VIDEO_MEM_MB=512    # VRAM reported to the game (a 1998 game - keep it modest)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE

# ----- Sound mixer ------------------------------------------------------------
# 2 = a game-only ALSA mixer (as SeriousSam.sh / outrun.sh): dmix ->
#     loopback -> alsaloop -> HDMI. The HDMI sound stays open for the whole
#     game, so no sound loses its start while the TV's HDMI audio wakes up,
#     and the intro videos' sound is mixed with the game's. Needs alsa-utils
#     (alsaloop) and the snd-aloop module (loaded by the script).
# 1 = a private PulseAudio just for this game.
# 0 = straight to ALSA (as before).
# If the chosen mixer can't start, plain ALSA is used.
# ES and emulators keep plain ALSA in every case.
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=60            # SOUND_MIXER=1: sound buffered between the game and
                            # PulseAudio: higher = safer from clicks, sound
                            # slightly later

# ===================== Derived settings =====================
MW=${MENU_RES%x*};    MH=${MENU_RES#*x}

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
# winmm=n,b: the game's winmm.dll (Ultimate ASI Loader) so SilentPatch loads
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winmm=n,b"

# GL 3.3 for wined3d (V3D reports 3.1); wined3d has its own render thread,
# so Mesa's is off
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
export mesa_glthread=false
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the launcher and the
# game), DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE" "$GAME_PROC"

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup toca2      # (+ finishes a pending update after a new Wine)

    # Wine settings + the keys TOCA 2's installer would normally write, in ONE
    # import, only when something changed. Paths follow GAME_DIR. TOCA 2 is
    # 32-bit, so its HKLM keys go in both views (incl. Wow6432Node).
    local root win_root win_game win_data view
    local reg_new="$WINEPREFIX/drive_c/toca2.reg" reg_old="$WINEPREFIX/toca2.reg.applied"
    to_reg_path() { echo "Z:$1" | sed 's|/|\\\\|g'; }   # /home/pi/x -> Z:\\home\\pi\\x
    root="$(dirname "$GAME_DIR")"
    win_root="$(to_reg_path "$root")"
    win_game="$(to_reg_path "$GAME_DIR")"
    win_data="$(to_reg_path "$root/Data")"
    {
        cat <<EOF
Windows Registry Editor Version 5.00

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; Black Wine desktop
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$(case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac)

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; TOCA 2 is a 1998 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"

[HKEY_CURRENT_USER\\Software\\Codemasters\\Toca2]
"CardHintIndex"=dword:00000001
EOF
        for view in 'SOFTWARE' 'SOFTWARE\Wow6432Node'; do
            cat <<EOF

[HKEY_LOCAL_MACHINE\\$view\\Microsoft\\Windows\\CurrentVersion\\App Paths\\Toca2.exe]
"Path"="$win_root"
@="$win_game\\\\Toca2.exe"

[HKEY_LOCAL_MACHINE\\$view\\Codemasters\\Toca2]
"CardHintIndex"=dword:00000001
"Language"=dword:00000000
"Install"=dword:00000002
"CD_Drive"="$win_data"
"GameDirectory"="$win_game"
"CD_Letter"="Z:"
"Uninstall"="$win_root"
"Windir"="C:\\\\Windows\\\\"
"Speechdir"="$win_data"

[HKEY_LOCAL_MACHINE\\$view\\Codemasters\\Toca2\\1.00.000]
EOF
        done
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen is the Wine
# desktop's size (made bigger only if a zoomed view reaches past it -
# xrandr refuses that). The window to follow is the real game's: toca2.exe
# is only its launcher.
ZOOM_FB="$DESKTOP_RES"
ZOOM_FB_VIEW=1
WINDOW_EXE="$GAME_PROC"

set_display() {
    display_output "no zoom" || return
    # A fixed "monitor" the desktop's size, BEFORE Wine starts (Wine measures
    # it once). Otherwise it follows the menu zoom (853x480) and races are
    # squeezed to fit it.
    fixed_monitor toca2-tv "$DESKTOP_RES" \
        || echo "WARNING: could not set a fixed monitor - races may be drawn at 854x480"
    # Start at the menu size (black to black: nothing is drawn yet), in the
    # top-left corner where Wine puts the game
    zoom_to "$MW" "$MH" || { echo "WARNING: GPU scaling failed - no zoom"; OUTPUT=""; }
}

run_game() {
    cd "$GAME_DIR" || exit 1          # must start here - the game reads ..\Data
    echo "=== $(date) === DESKTOP_RES=$DESKTOP_RES VSYNC=$VSYNC BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE SOUND_MIXER=$SOUND_MIXER"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        # The game's window, followed (shared code): starts from the menu zoom
        # set_display set (the black panels are told it at once). A window the
        # TV's full size is the game's window BEFORE it sets its screen mode
        # (brief, black) - followed only if it stays 3 s (a 1920x1080 race).
        START_GEO="$MW $MH 0 0" FOLLOW_PANELS=toca2-panels FOLLOW_HOLD_FULL=1 \
            follow_window &
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the TV's size: the game can't change the real screen mode
    wine explorer /desktop=toca2,"$DESKTOP_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code).
    # Both count as the game: toca2.exe closes once TC2.exe is up.
    wait_for_game $! "$GAME_EXE" "$GAME_PROC"
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    panels_stop
    wineserver -k 2>/dev/null
    sound_mixer_stop
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code - also the black panels)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: prefix setup first (no X needed), then X just
    # for the game, on ES's console, so it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    setup_prefix >> "$LOG_FILE" 2>&1
    start_x -nocursor -quiet        # no X pointer - the game has no mouse support
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
set_display
xsetroot -solid black 2>/dev/null
# Over the menu zoom set_display starts at
start_boot_log "$MW $MH 0 0" "$GAME_EXE" "$GAME_PROC"
set_governor
sound_mixer_start toca2   # (shared code; SOUND_MIXER)
run_game
exit 0
