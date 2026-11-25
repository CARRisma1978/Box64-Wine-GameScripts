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
#     desktop of GAME_RES. The TV stays at its normal mode.
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
#  Log (overwritten each launch):
#     \\<pi>\roms\windows\3DPinball\3dpinball-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="3dpinball"         # short name: its Wine prefix
                            #   (~/wine-prefixes/3dpinball) and log
# \\<pi>\roms\windows\3DPinball
GAME_DIR="$HOME/RetroPie/roms/windows/3DPinball"
GAME_EXE="PINBALL.EXE"      # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop. The XP version only has the 640x480 table
# (the 800x600 and 1024x768 tables are in Full Tilt! Pinball only); its
# window is zoomed to fill the TV (about 2.3x), so any desktop it fits in
# will do.
GAME_RES="1920x1080"
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game is played on the keyboard; menus still
                            #   work with Alt + underlined letter)
BLOCK_ESC=1                 # 1 = Esc does nothing. The game's Esc is a "boss
                            #     key": it hides (minimises) the game, and
                            #     with no taskbar there's no way to bring it
                            #     back - just a black screen. 0 = Esc goes to
                            #     the game as normal

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
                    # (the game draws without OpenGL: no counter)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (no OpenGL: makes no difference here)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If the ball moves oddly (sticks, falls through), use 1
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
                    # (try 1 if the ball's movement looks uneven)
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
                    # (0 here: the game's sound effects and FluidSynth's MIDI
                    #   music are mixed by it - the HDMI sound plays only one
                    #   stream at a time)

# ----- Music (MIDI) -----------------------------------------------------------
MUSIC=1                     # 1 = music on: PINBALL.MID on a loop through
                            #     FluidSynth (played by the script - see "Music"
                            #     above; needs SOUND_MIXER=0)
                            # 0 = sound effects only
                            # (the game's own Music menu option does
                            # nothing here)
MIDI_GAIN=1                 # music volume (FluidSynth gain; 1 = loud)

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
# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    wine_base_reg dsound > "$reg_new"
    import_reg "$reg_new" "$reg_old"
    wineserver -w
    # The game's own music never plays under Wine - kept off, so it can't
    # double up with the script's if a later Wine fixes it
    game_option Music 0             # (Wine is stopped here)
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
        # (not there yet)
        ins && $0 == "" && !done { print name "=" val; done = 1 }
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
# start_music - PINBALL.MID on a loop into FluidSynth, in the background
# (one small "$GAME_ID-music" loop; aplaymidi from alsa-utils). Started when
# the game's window first appears; ended by the shared cleanup
# (cleanup_add in in_x).
start_music() {
    [ "$MUSIC" = "1" ] || return 0
    local mid
    mid="$(find "$GAME_DIR" -maxdepth 1 -iname pinball.mid -print -quit)"
    [ -n "$mid" ] || { echo "WARNING: PINBALL.MID not found - no music"; return 0; }
    command -v aplaymidi >/dev/null || { echo "WARNING: aplaymidi not found (alsa-utils) - no music"; return 0; }
    echo "Music: $(basename "$mid") on a loop"
    # (a failed play waits 2 s before trying again, not a tight loop)
    bash -c 'while :; do aplaymidi -p "FLUID Synth ($2)" "$1" || sleep 2; sleep 0.5; done' \
        "$GAME_ID-music" "$mid" "$GAME_ID" &
}

# ----- Display ----------------------------------------------------------------
# The game's window is followed by the shared follow_window (in_x, below):
# the whole Wine desktop until the window appears, then the TV is zoomed
# onto it - as big as fits, its shape kept - and again if it moves or
# changes size. Black panels cover the TV beside the window and fence the
# mouse pointer into it. The music starts when the window first appears.
follow_window_hook() {
    [ -n "$MUSIC_ON" ] && return 0
    MUSIC_ON=1
    start_music
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

# Inside X (from launch, shared code)
in_x() {
    xsetroot -solid black 2>/dev/null
    block_esc
    zoom_start "" "$GW" "$GH"   # the whole desktop until the window shows
                                #   (shared code)
    start_boot_log "$START_GEO" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    # Music: FluidSynth before Wine starts (shared code); the loop into it
    # starts with the game's window - follow_window_hook
    if music_start; then
        # The music loop is started by the window follower (a background
        # helper), so it's added to the shared cleanup here
        cleanup_add "$GAME_ID-music"
        cleanup_add "aplaymidi -p FLUID Synth"
    fi
    cd "$GAME_DIR" || exit 1
    log_settings MUSIC BLOCK_ESC
    FOLLOW_FENCE=1 follow_start     # (shared code; starts from START_GEO)
    # In its normal window (zoomed by follow_window), in a Wine desktop the
    # script starts itself. (Box64 0.4.5 of 2026-10-23: the desktop Wine
    # starts on its own for "wine start" hung - no window, back to ES.)
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes - or 2 seconds
    # later (shared code; the shared cleanup then ends it): the desktop stays
    # open after the game, so Wine never finishes by itself
    WINE_EXIT_WAIT=2 wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
