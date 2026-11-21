#!/bin/bash
# =============================================================================
#  Age of Empires II: The Conquerors (1.0e) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works (as tanks.sh / Worms Armageddon.sh):
#   - DirectDraw (8-bit) -> Wine's own ddraw (WINE_RENDERER: OpenGL or
#     normal memory).
#   - Bare X, no window manager. The Wine desktop and the X screen are
#     GAME_RES (the biggest resolution the game offers). The game's window
#     sits in its top-left corner at whatever resolution is picked in the
#     game's Options. A helper watches the game's window and has the Pi's
#     display hardware zoom it to full TV height (free - no GL work), with
#     black panels beside it and the mouse kept on the picture (so edge
#     scrolling works).
#   - X reports a fixed GAME_RES "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#   - Sound: DirectSound only (one stream - no mixer needed). The in-game
#     music is the CD's audio track, which Wine only plays from a real CD
#     drive, so there's none; the menu and civilisation themes
#     (Sound\stream) still play.
#   - Prefix setup and all registry settings run BEFORE X starts, in ONE
#     import, only when something changed.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/aoe2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\aoe2\aoe2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/aoe2"        # \\<pi>\roms\windows\aoe2
GAME_EXE="age2_x1.exe"      # in the Age2_x1 subfolder; started from GAME_DIR,
                            # where Data, Sound and language*.dll are

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/aoe2"
LOG_FILE="$GAME_DIR/aoe2-launch.log"

# Product IDs (PID) from your own Windows install, as written by the game's
# installers: Age of Kings on the first line, The Conquerors on the second,
# e.g. 12345-123-1234567-12345 (copy them from the registry of a PC where
# the game is installed). Only digits and dashes are kept. A missing file or
# line = 00000-000-0000000-00000 (Age of Kings already runs with that;
# The Conquerors is untested without its own PID).
# Keep this file private - don't upload it to GitHub.
PID_FILE="$GAME_DIR/aoe2-pid.txt"                # \\<pi>\roms\windows\aoe2\aoe2-pid.txt

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop: the BIGGEST resolution the game offers (1.0e:
# 800x600, 1024x768, 1280x1024). Whichever one is picked in the game's
# Options is followed automatically (zoomed to full TV height, black bars
# beside it, mouse kept on it). The menus are always 800x600.
#    800x600  = biggest units/buildings (1.8x zoom)
#   1024x768  = more of the map (1.41x zoom) - a good balance
#   1280x1024 = most of the map (slightly shrunk to fit the TV)
GAME_RES="1280x1024"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
FENCE_POINTER=1             # 1 = keep the mouse on the picture (needed for edge
                            #     scrolling, and a click on the hidden part of
                            #     the desktop loses focus)
WINE_RENDERER="gl"          # gl  = DirectDraw through OpenGL
                            # gdi = DirectDraw in normal memory (best for
                            #       dxball/tanks) - compare with FPS_HUD=1

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   Recorded games rely on exact maths - 1 if replays go wrong
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
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
                    #   (big late-game armies are CPU-heavy)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     game speed or scrolling look uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (big log, slower)

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

# ----- Game options -----------------------------------------------------------
# The game's own start-up switches (the same as the shortcuts in its Support
# folder). Uncommented lines are passed to the game; comment a line out to
# turn it off.
GAME_OPTIONS=(
  # "NOSTARTUP"         # Skip the intro logos/videos at start-up
  # "NORMALMOUSE"       # Windows' own mouse pointer instead of the game's -
                        #   try if the pointer lags
  # "MFILL"             # Fix for horizontal lines on the screen (meant for some
                        #   old graphics cards)
  # "MSYNC"             # Sound timing fix (meant for old SoundBlaster AWE cards)
  # "NOMUSIC"           # No music at all (the menu and civilisation themes too)
  # "NOSOUND"           # No sound at all
  # "NOTERRAINSOUND"    # No background sounds (waves, birds, wind)
)

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
GW=${GAME_RES%x*};   GH=${GAME_RES#*x}
NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup aoe2      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/aoe2-settings.reg" reg_old="$WINEPREFIX/aoe2-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop (beside the zoomed game)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; DirectDraw renderer; no separate Direct3D thread (as dxball.sh)
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="$WINE_RENDERER"
"csmt"=dword:00000000
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # The game's own install keys (as on the laptop, where the game was
    # installed): without them single-player games ask for the Conquerors
    # CD. The paths point at GAME_DIR (Z: = the Pi's / in Wine). Imported
    # once - again only if this text (or GAME_DIR) changes. 32-bit game, so
    # under Wow6432Node.
    local reg_dir="Z:${GAME_DIR//\//\\\\}"
    # The Product IDs from PID_FILE (line 1 Age of Kings, line 2 The
    # Conquerors), or all zeros. Never logged.
    local zero="00000-000-0000000-00000" pid_aok="" pid_aoc=""
    if [ -f "$PID_FILE" ]; then
        { IFS= read -r pid_aok; IFS= read -r pid_aoc; } < <(tr -cd '0-9\n-' < "$PID_FILE")
    fi
    pid_aok="${pid_aok:-$zero}"; pid_aoc="${pid_aoc:-$zero}"
    local key='HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Microsoft Games'
    reg_new="$WINEPREFIX/drive_c/aoe2-install.reg"; reg_old="$WINEPREFIX/aoe2-install.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Age of Kings
[$key\\Age of Empires\\2.0]
"CDPath"="$reg_dir"
"PID"="$pid_aok"
"InstallType"="1"
"InstallationDirectory"="$reg_dir"
"Zone"="http://www.zone.com/asp/aoe2redir.asp"
"Version"="2"
"Launched"="1"
"EXE Path"="$reg_dir"
"VersionType"="RetailVersion"
"InstalledGroup"="1"
"LangID"=dword:00000009
"Processor Speed"=dword:0000010a
"Custom Mouse"=dword:00000000

[$key\\Age of Empires\\2.0\\EULA]
"FIRSTRUN"=dword:00000001

; The Conquerors
[$key\\Age of Empires II: The Conquerors Expansion\\1.0]
"Zone"="http://www.zone.com/conquerors"
"Version"="1.0C"
"Launched"="1"
"PID"="$pid_aoc"
"EXE Path"="$reg_dir"
"CDPath"="$reg_dir"
"VersionType"="RetailVersion"
"InstalledGroup"="3"
"LangID"=dword:00000009

[$key\\Age of Empires II: The Conquerors Expansion\\1.0\\EULA]
"FIRSTRUN"=dword:00000001
EOF
    import_reg "$reg_new" "$reg_old"
}

# ----- Display -----
# Zooming (zoom_to) and the black panels beside the game, with the mouse
# fence (panels_start): shared code. The X screen is GAME_RES; the panels
# hide once the game fills it. ZOOM_FB_VIEW=1: no window manager, so the X
# screen must reach the whole zoomed view (the 1280x1024 desktop shown at
# full TV height is wider than itself - xrandr refused it).
ZOOM_FB="$GAME_RES"
ZOOM_FB_VIEW=1

set_display() {
    display_output "no zoom" || return
    # A fixed "monitor" the game's full size. Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - the switch to
    # a bigger resolution for a match could then be refused.
    fixed_monitor aoe2-tv "$GAME_RES" \
        || echo "WARNING: could not set a fixed monitor"
    # The whole desktop until the game's window shows
    START_GEO="$GW $GH 0 0"
    echo "Starting zoom: $START_GEO"
    # shellcheck disable=SC2086
    if ! zoom_to $START_GEO; then
        echo "WARNING: GPU scaling failed - no zoom"
        OUTPUT=""
    fi
}

# The game's window (top-left corner of the desktop), followed by the shared
# follow_window - the menus or a match, at whatever resolution:
#   narrower than 640 (a dialog box, e.g. the licence agreements on a new
#   prefix)               -> the whole desktop
#   any other size        -> that size, from the top-left corner
follow_window_map() {           # ($1 $2 = the window's size)
    if (( $1 < 640 )); then FOLLOW_GEO="$GW $GH 0 0"; else FOLLOW_GEO="$1 $2 0 0"; fi
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES WINE_RENDERER=$WINE_RENDERER BIGBLOCK=$BIGBLOCK X87DOUBLE=$X87DOUBLE CALLRET=$CALLRET DYNACACHE=$DYNACACHE OPTIONS=${GAME_OPTIONS[*]}"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=aoe2-panels FOLLOW_FENCE="$FENCE_POINTER" \
            follow_window 320 200 &      # (shared code; starts from START_GEO)
        WATCH_PID=$!
    else
        echo "WARNING: no display/zoom or no xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop of GAME_RES: the game can't change the real screen mode
    wine explorer /desktop=aoe2,"$GAME_RES" "Age2_x1\\$GAME_EXE" "${GAME_OPTIONS[@]}" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
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
    kill_game                       # (shared code)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: prefix setup first (no X needed), then X just
    # for the game, on ES's console, so it exits cleanly back to ES
    check_files "$GAME_DIR/Age2_x1/$GAME_EXE"
    : > "$LOG_FILE"
    setup_prefix >> "$LOG_FILE" 2>&1
    # (no -nocursor: AoE II is played with the mouse)
    start_x -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # long games = no screen blanking
set_display
xsetroot -solid black 2>/dev/null
# Over the starting zoom (or the whole TV if that failed)
if [ -n "$OUTPUT" ]; then
    start_boot_log "$START_GEO" "$GAME_EXE"
else
    start_boot_log "$NW $NH 0 0" "$GAME_EXE"
fi
set_governor
sound_mixer_start aoe2   # (shared code; SOUND_MIXER)
run_game
exit 0
