#!/bin/bash
# =============================================================================
#  Age of Empires II: The Conquerors (1.0e) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - DirectDraw (8-bit) -> Wine's own ddraw, drawn through OpenGL on the
#     Pi's GPU.
#   - Bare X, no window manager. The Wine desktop and the X screen are
#     GAME_RES (the biggest resolution the game offers). The game's window
#     sits in its top-left corner at whatever resolution is picked in the
#     game's Options. A helper watches the game's window and has the Pi's
#     display hardware zoom it to full TV height (free - no GL work), with
#     black panels beside it and the mouse kept on the picture (so edge
#     scrolling works).
#   - X reports a fixed GAME_RES "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#   - All registry settings are imported only when something changed.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/aoe2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\aoe2\aoe2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="aoe2"              # short name: its Wine prefix
                            #   (~/wine-prefixes/aoe2) and log
GAME_DIR="$HOME/RetroPie/roms/windows/aoe2"        # \\<pi>\roms\windows\aoe2
GAME_EXE="age2_x1.exe"      # exactly as spelled on disk; in the GAME_EXE_DIR
GAME_EXE_DIR="Age2_x1"      # subfolder, but started from GAME_DIR, where Data,
                            # Sound and language*.dll are

# Product IDs (PID) from your own Windows install, as written by the game's
# installers: Age of Kings on the first line, The Conquerors on the second,
# e.g. 12345-123-1234567-12345 (copy them from the registry of a PC where
# the game is installed). Only digits and dashes are kept. A missing file or
# line = 00000-000-0000000-00000 (Age of Kings already runs with that;
# The Conquerors is untested without its own PID).
# Keep this file private - don't upload it to GitHub.
# \\<pi>\roms\windows\aoe2\aoe2-pid.txt
PID_FILE="$GAME_DIR/aoe2-pid.txt"

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop: the BIGGEST resolution the game offers (1.0e:
# 800x600, 1024x768, 1280x1024). Whichever one is picked in the game's
# Options is followed automatically (zoomed to full TV height, black bars
# beside it, mouse kept on it). The menus are always 800x600.
#    800x600  = biggest units/buildings (1.8x zoom)
#   1024x768  = more of the map (1.41x zoom) - a good balance
#   1280x1024 = most of the map (slightly shrunk to fit the TV)
GAME_RES="1280x1024"
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (AoE II is played with the mouse)
MOUSE_FENCE=1               # 1 = keep the mouse on the picture (needed for edge
                            #     scrolling, and a click on the hidden part of
                            #     the desktop loses focus)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # Recorded games rely on exact maths - 1 if replays go wrong
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
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
                    # (big late-game armies are CPU-heavy)
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
                    # (try 1 if game speed or scrolling look uneven)
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
                    # (The game plays DirectSound only. Its in-game music is the
                    #   CD's audio track, which Wine only plays from a real CD
                    #   drive, so there's none; the menu and civilisation
                    #   themes (Sound\stream) still play.)

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
  # "MSYNC"             # Sound timing fix (meant for old
                        #   SoundBlaster AWE cards)
  # "NOMUSIC"           # No music at all (the menu and civilisation themes too)
  # "NOSOUND"           # No sound at all
  # "NOTERRAINSOUND"    # No background sounds (waves, birds, wind)
)

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
    { wine_base_reg dsound; cat <<EOF
; DirectDraw through OpenGL; no separate Direct3D thread
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="gl"
"csmt"=dword:00000000
EOF
    } > "$reg_new"
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
    reg_new="$WINEPREFIX/drive_c/$GAME_ID-install.reg"; reg_old="$WINEPREFIX/$GAME_ID-install.applied"
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

# ----- Display ----------------------------------------------------------------
# Zooming (zoom_to) and the black panels beside the game, with the mouse
# fence (panels_start): shared code. The X screen is GAME_RES; the panels
# hide once the game fills it. ZOOM_FB_VIEW=1: no window manager, so the X
# screen must reach the whole zoomed view (the 1280x1024 desktop shown at
# full TV height is wider than itself - xrandr refused it).
ZOOM_FB="$GAME_RES"
ZOOM_FB_VIEW=1

# The game's window (top-left corner of the desktop), followed by the shared
# follow_window - the menus or a match, at whatever resolution:
#   narrower than 640 (a dialog box, e.g. the licence agreements on a new
#   prefix)               -> the whole desktop
#   any other size        -> that size, from the top-left corner
follow_window_map() {           # ($1 $2 = the window's size)
    if (( $1 < 640 )); then FOLLOW_GEO="$GW $GH 0 0"; else FOLLOW_GEO="$1 $2 0 0"; fi
}

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the game's full size (Wine checks screen modes
    # against the monitor X reports, which otherwise follows the zoom - the
    # switch to a bigger resolution for a match could then be refused), then
    # the whole desktop until the game's window shows (shared code)
    zoom_start "$GAME_RES" "$GW" "$GH"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"     # (over the starting zoom, or
                                                #   the whole TV)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings OPTIONS="${GAME_OPTIONS[*]}"
    FOLLOW_FENCE="$MOUSE_FENCE" follow_start 320 200    # (shared code; starts
                                                        #   from START_GEO)
    # Wine desktop of GAME_RES: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE_DIR\\$GAME_EXE" "${GAME_OPTIONS[@]}" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
