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
#     work, and any resolution picked in the game is followed automatically.
#   - X reports a fixed DESKTOP_RES "monitor" to Wine. Without it, Wine
#     measures the monitor from the zoomed menu (853x480) and squeezes races
#     to 854x480 - the game rendered at full size, then shrunk, then
#     re-enlarged.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/Toca2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Toca2\toca2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="toca2"             # short name: its Wine prefix
                            #   (~/wine-prefixes/toca2) and log
# \\<pi>\roms\windows\Toca2\Game
GAME_DIR="$HOME/RetroPie/roms/windows/Toca2/Game"
GAME_EXE="toca2.exe"        # the launcher Wine starts...
GAME_PROC="TC2.exe"         # ...which starts the real game and closes. Both
                            # exactly as spelled on disk (Box64 settings match
                            # them; "has it quit?" checks both)
# (in Toca2, not Game)
LOG_FILE="$HOME/RetroPie/roms/windows/Toca2/$GAME_ID-launch.log"

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
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game has no mouse support)

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
                    # If cars/scenery jump or physics act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=1           # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code (3 = an extra for
                    #   LoongArch CPUs only, not the Pi); empty = Box64's
                    #   default (2). Can crash some games - if so, try 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and
                    #   loading): empty = on, one cache shared by all games
                    #   (~/.cache/box64); 1 = on, this game's own cache
                    #   (box64-cache in its prefix); 0 = off
CPU_PERFORMANCE=1   # 1 = CPU governor 'performance' while playing
                    #   (needs passwordless sudo), 0 = left as it is
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
                    # (try 1 if the game's speed is uneven)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread
VIDEO_MEM_MB=512    # VRAM reported to the game (a 1998 game - keep it modest)

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
                    # (0 here also mixes the intro videos' sound with the
                    #   game's)

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
# winmm=n,b: the game's winmm.dll (Ultimate ASI Loader) so SilentPatch loads
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winmm=n,b"

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the launcher and the
# game), DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE" "$GAME_PROC"

MW=${MENU_RES%x*}; MH=${MENU_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry: Wine settings + the keys
# TOCA 2's installer would normally write, in ONE import, only when it
# changes (each import is a full Box64 + Wine start-up). Paths follow
# GAME_DIR. TOCA 2 is 32-bit, so its HKLM keys go in both views (incl.
# Wow6432Node).
setup_prefix() {
    prefix_setup
    local root win_root win_game win_data view
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    to_reg_path() { echo "Z:$1" | sed 's|/|\\\\|g'; }   # /home/pi/x ->
                                                        #   Z:\\home\\pi\\x
    root="$(dirname "$GAME_DIR")"
    win_root="$(to_reg_path "$root")"
    win_game="$(to_reg_path "$GAME_DIR")"
    win_data="$(to_reg_path "$root/Data")"
    {
        wine_base_reg dsound
        cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

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

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the desktop's size, BEFORE Wine starts (Wine
    # measures it once - otherwise it follows the menu zoom, 853x480, and
    # races are squeezed to fit it), then the menu size, in the top-left
    # corner where Wine puts the game (shared code)
    zoom_start "$DESKTOP_RES" "$MW" "$MH"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE" "$GAME_PROC"     # (over the
                                                             #   menu zoom)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1          # must start here - the game reads ..\Data
    log_settings DESKTOP_RES VIDEO_MEM_MB
    # The game's window, followed (shared code): starts from the menu
    # zoom set above (START_GEO - the black panels are told it at once). A
    # window the TV's full size is the game's window BEFORE it sets its screen
    # mode (brief, black) - followed only if it stays 3 s (a 1920x1080 race).
    FOLLOW_HOLD_FULL=1 follow_start
    # Wine desktop the TV's size: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$DESKTOP_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code).
    # Both count as the game: toca2.exe closes once TC2.exe is up.
    wait_for_game $! "$GAME_EXE" "$GAME_PROC"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
