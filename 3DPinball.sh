#!/bin/bash
# =============================================================================
#  3D Pinball for Windows - Space Cadet (Windows XP PINBALL.EXE)
#  Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - PINBALL.EXE draws with plain GDI (no Direct3D/OpenGL), so there are no
#     Mesa or wined3d settings to tune - the only graphics work is the zoom.
#   - Bare X, no window manager. Every program in the prefix runs in a Wine
#     desktop of GAME_RES. The TV stays at NATIVE_RES.
#   - The game runs in its normal window (title bar and menu). A helper finds
#     that window and has the Pi's display hardware zoom it to fill the TV,
#     keeping its shape (free - no GL work). Black panels cover the TV beside
#     it, and the mouse pointer is always fenced into the window: with no
#     window manager the keyboard follows the pointer, and the game stops
#     responding properly if it wanders onto the blank area (tested).
#   - Sound: the game's sound effects and FluidSynth's MIDI music are mixed
#     by ALSA (dmix -> loopback -> alsaloop -> HDMI), as the Pi's HDMI only
#     plays one stream at a time. ES and emulators are untouched.
#   - Music: the game asks Windows to play PINBALL.MID in a way Wine doesn't
#     support (the file name given as the device type - Wine's MCI looks
#     for a driver called "PINBALL.MID" and gives up). So the script plays
#     PINBALL.MID itself, on a loop, into FluidSynth (aplaymidi), and keeps
#     the game's own Music option off. It plays on through pauses (F3).
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards,
#     and registry settings are imported only when they change.
#
#  Keys: Z / / = flippers, Space = plunger, X . Up = nudge, F2 = new game,
#        F3 = pause, F8 = player controls, Alt+F4 = quit back to
#        EmulationStation. Esc is blocked (BLOCK_ESC). F4 = the game's own
#        full screen - not needed: the window is already zoomed to fill
#        the TV.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/3DPinball.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\3DPinball\pinball-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/3DPinball"   # \\<pi>\roms\windows\3DPinball
GAME_EXE="PINBALL.EXE"                             # Linux is case-sensitive

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/3dpinball"
LOG_FILE="$GAME_DIR/pinball-launch.log"

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop. The XP version only has the 640x480 table
# (the 800x600 and 1024x768 tables are in Full Tilt! Pinball only); its
# window is zoomed to fill the TV (about 2.3x), so any desktop it fits in
# will do.
GAME_RES="1920x1080"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=0               # 1 = no X pointer (the game is played on the keyboard;
                            #     menus still work with Alt + underlined letter)
BLOCK_ESC=1                 # 1 = Esc does nothing. The game's Esc is a "boss key":
                            #     it hides (minimises) the game, and with no taskbar
                            #     there's no way to bring it back - just a black
                            #     screen. 0 = Esc goes to the game as normal

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If the ball moves oddly (sticks, falls through), use 1
BIGBLOCK=           # Box64 code block size 0-3 (bigger = less translating);
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
CPU_PERFORMANCE=0   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     the ball's movement looks uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (big log, slower start)

# ----- Sound ------------------------------------------------------------------
MUSIC=1                     # 1 = music on: PINBALL.MID on a loop through FluidSynth
                            #     (played by the script - see "Music" above)
                            # 0 = sound effects only (plain ALSA, no mixer)
                            # (the game's own Music menu option does nothing here)
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
SOUNDFONT="/usr/share/sounds/sf2/FluidR3_GM.sf2"
MIDI_GAIN=1

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

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup pinball      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/pinball-settings.reg" reg_old="$WINEPREFIX/pinball-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop (shows briefly before the game window)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Sound through ALSA (the mixer below, when MUSIC=1)
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
"Audio"="alsa"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"
EOF
    import_reg "$reg_new" "$reg_old"
}

# game_option name 0|1 - sets one of the game's own options (a dword in
# its registry key, next to its key settings such as "Left Flippper key" -
# the game's own spelling). Written straight into the prefix's user.reg -
# no Wine start-up, so it's done on every launch (Wine must be stopped).
# The game creates its key the first time it closes; until then this
# just notes it in the log.
game_option() {
    local name="$1" val reg="$WINEPREFIX/user.reg" tmp
    val="$(printf 'dword:%08x' "$2")"
    [ -f "$reg" ] || return 0
    tmp="$reg.pinball-tmp"
    awk -v name="\"$name\"" -v val="$val" '
        # 1st pass: the line number of the game key header
        FNR == NR { if (/^\[/) h = FNR; if (index($0, "\"Left Flippper key\"=") == 1) sec = h; next }
        FNR == 1 && !sec { exit 3 }
        /^\[/ { ins = (FNR == sec) }
        ins && index($0, name "=") == 1 { $0 = name "=" val; done = 1 }
        ins && $0 == "" && !done { print name "=" val; done = 1 }   # (not there yet)
        { print }
        END { if (ins && !done) print name "=" val }
    ' "$reg" "$reg" > "$tmp"
    case $? in
        0) if cmp -s "$reg" "$tmp"; then rm -f "$tmp"
           else mv "$tmp" "$reg" && echo "Game option set: $name = $2"; fi ;;
        3) rm -f "$tmp"
           echo "Game options not saved by the game yet - $name set from the next launch" ;;
        *) rm -f "$tmp"; echo "WARNING: could not set the game's $name option" ;;
    esac
}

# ----- Sound ------------------------------------------------------------------
#  The game's sound effects and FluidSynth's music, mixed by ALSA (dmix ->
#  loopback -> alsaloop -> HDMI) - shared code.
start_sound() {
    [ "$MUSIC" = "1" ] || return 0
    alsa_mixer_start pinball            # (exports ALSA_CONFIG_PATH for Wine)
    fluidsynth_start Pinball
}

# start_music - PINBALL.MID on a loop into FluidSynth, in the background
# (one small "pinball-music" loop; aplaymidi from alsa-utils). Started when
# the game's window first appears; ended by cleanup.
start_music() {
    [ "$MUSIC" = "1" ] || return 0
    local mid
    mid="$(find "$GAME_DIR" -maxdepth 1 -iname pinball.mid -print -quit)"
    [ -n "$mid" ] || { echo "WARNING: PINBALL.MID not found - no music"; return 0; }
    command -v aplaymidi >/dev/null || { echo "WARNING: aplaymidi not found (alsa-utils) - no music"; return 0; }
    echo "Music: $(basename "$mid") on a loop"
    # (a failed play waits 2 s before trying again, not a tight loop)
    bash -c 'while :; do aplaymidi -p "FLUID Synth (Pinball)" "$1" || sleep 2; sleep 0.5; done' \
        pinball-music "$mid" &
}

stop_music() {
    pkill -u "$(id -u)" -f pinball-music 2>/dev/null
    pkill -u "$(id -u)" -x aplaymidi 2>/dev/null
}

stop_sound() {
    fluidsynth_stop
    alsa_mixer_stop
}

# ----- Display ----------------------------------------------------------------
# The game's window is followed by the shared follow_window (Inside X,
# below): the whole Wine desktop until the window appears, then the TV is
# zoomed onto it - as big as fits, its shape kept - and again if it moves or
# changes size. Black panels cover the TV beside the window and fence the
# mouse pointer into it. The music starts when the window first appears.
follow_window_hook() {
    [ -n "$MUSIC_ON" ] && return 0
    MUSIC_ON=1
    start_music
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES MUSIC=$MUSIC"
    # In its normal window (zoomed by follow_window), in a Wine desktop the
    # script starts itself. (Box64 0.4.5 of 2026-10-23: the desktop Wine
    # starts on its own for "wine start" hung - no window, back to ES.)
    wine explorer /desktop=pinball,"$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes - or 2 seconds
    # later (shared code; cleanup then ends it): the desktop stays open
    # after the game, so Wine never finishes by itself
    WINE_EXIT_WAIT=2 wait_for_game $! "$GAME_EXE"
}

# BLOCK_ESC=1: the Esc key gives no key at all in this X session (just
# for the game - X, and its key map, close with it). Done before Wine
# starts: Wine reads the key map once, when it starts.
block_esc() {
    [ "$BLOCK_ESC" = "1" ] || return 0
    command -v xmodmap >/dev/null || { echo "WARNING: xmodmap not found - Esc not blocked"; return 0; }
    local kc found=0
    for kc in $(xmodmap -pke 2>/dev/null | awk '$4 == "Escape" {print $2}'); do
        xmodmap -e "keycode $kc =" && echo "Esc blocked (keycode $kc)" && found=1
    done
    [ "$found" = "1" ] || echo "WARNING: Esc not found in X's key map - not blocked"
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    stop_music
    panels_stop
    wineserver -k 2>/dev/null
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code)
    stop_music
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: prefix setup and sound first (no X needed), then
    # X just for the game, on ES's console, so it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    trap stop_sound EXIT
    trap 'exit 1' INT TERM
    {
        stop_wine                   # (shared code)
        start_sound
        setup_prefix
        # The game's own music never plays under Wine - kept off, so it
        # can't double up with the script's if a later Wine fixes it
        game_option Music 0             # (Wine is stopped here)
    } >> "$LOG_FILE" 2>&1

    NOCURSOR=""; [ "$HIDE_CURSOR" = "1" ] && NOCURSOR="-nocursor"
    # shellcheck disable=SC2086
    start_x $NOCURSOR -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0                          # (the EXIT trap stops the sound)
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # no screen blanking (the demo/attract
                                         # mode runs with no key pressed)
xsetroot -solid black 2>/dev/null
block_esc
if display_output "no zooming"; then
    START_GEO="$GW $GH 0 0" FOLLOW_PANELS=pinball-panels FOLLOW_FENCE=1 \
        follow_window &                 # (shared code)
    WATCH_PID=$!
fi
start_boot_log "$GW $GH 0 0" "$GAME_EXE"
set_governor
run_game
exit 0
