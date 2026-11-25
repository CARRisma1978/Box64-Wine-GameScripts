#!/bin/bash
# =============================================================================
#  Need for Speed: Hot Pursuit 2 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D 8 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - The Wine desktop is the TV's size. A helper watches the game's window
#     and has the Pi's display hardware zoom it to full TV height (4:3 ->
#     black side bars, 16:9 -> full screen). Whatever resolution is picked
#     in the game's options is followed automatically; the TV mode never
#     changes and Wine never sees the zoom (X reports a fixed TV-sized
#     "monitor" to it, so the zoom never limits the game's screen modes).
#     The zoom costs no GL work.
#   - The game stretches its .mad videos (e.g. the 720x496 EA logo) to fill
#     its window. While one is open, the zoom reshapes the window back to
#     MOVIE_ASPECT instead. Black panels cover whatever the TV shows beside
#     the game (Wine leaves the rest of its desktop white during videos),
#     and keep the mouse on the picture (MOUSE_FENCE).
#
#  Known issue - changing Screen Resolution in the game's options:
#   HP2 re-creates its Direct3D device, and Wine keeps the picture at the
#   size it had when the game started: squashed or stretched at first. After
#   changing Color Depth to 16 bit and back to 32 bit (a full reset), the
#   picture is the right shape but still the START resolution's shape,
#   scaled to the new height and against the left edge. The zoom follows
#   that:
#   - changed to a WIDER shape (e.g. 800x600 -> 960x540): the picture is
#     shown centred, correct shape (the old 4:3 picture until a restart)
#   - changed to a NARROWER shape (e.g. 960x540 -> 800x600): the right of
#     the picture isn't drawn at all - nothing to zoom to. Save the profile
#     and restart the game.
#   The new resolution is kept, and is right from the next launch.
#   (The change happens in the options screen because the widescreen fix,
#   scripts\HP2WSFix.asi, runs the menus at the chosen resolution; without
#   it they stay 800x600 and each race switches correctly, but 16:9 is
#   then a stretched 4:3 picture. Tried: d3d8to9 - no better.)
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfs6.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfs6\nfs6-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="nfs6"              # short name: its Wine prefix
                            #   (~/wine-prefixes/nfs6) and log
GAME_DIR="$HOME/RetroPie/roms/windows/nfs6"        # \\<pi>\roms\windows\nfs6
GAME_EXE="NFSHP2.exe"       # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# Set the resolution in the GAME's options; the zoom follows it (then
# restart the game - see "Known issue" above).
#    960x540 = 16:9, fills the TV, exactly 2x (lighter than 1280x720)
#   1280x720 = 16:9, fills the TV (picture stretched without a widescreen fix)
#   1024x768 = 4:3 with black side bars, correct shape
#    800x600 = lighter if races drop frames
MOVIE_ASPECT="720x496"      # true shape of the game's videos ("" = leave
                            #   them stretched)
MOVIE_GLOB="*.mad"          # which open files count as a video playing
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
MOUSE_FENCE=1               # 1 = keep the mouse on the picture (off the black
                            # bars and the rest of the desktop)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If car handling/physics act oddly with 0, use 1
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
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread

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

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}
# X screen bigger than the TV (the Wine desktop stays NATIVE_RES in its
# top-left), so a reshaped video's zoom never reaches past its edge
FB_RES="$(( NW * 3 / 2 ))x$(( NH * 3 / 2 ))"

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up). Wine's default
# renderer, OpenGL - Vulkan failed here (no swapchain format, no Direct3D 8
# fixed-function support).
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="1024"

; HP2 is a 2002 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # HP2's own keys (normally written by its installer), imported only when
    # they change - e.g. a new prefix or a moved game folder (shared code).
    # 32-bit game, so they go in both registry views (incl. Wow6432Node).
    local keys="$WINEPREFIX/drive_c/$GAME_ID-install.reg" view win_dir
    # Z:\\home\\pi\\...\\nfs6\\
    win_dir="Z:$(echo "$GAME_DIR" | sed 's|/|\\\\|g')\\\\"
    {
        echo 'REGEDIT4'
        for view in 'SOFTWARE' 'SOFTWARE\Wow6432Node'; do
            cat <<EOF

[HKEY_LOCAL_MACHINE\\$view\\EA GAMES\\Need For Speed Hot Pursuit 2]
"Installed From"="D:\\\\"
"CacheSize"=dword:00085635
"SwapSize"=dword:00000000
"DisplayName"="Need For Speed Hot Pursuit 2"
"Language"="English UK"
"CD Drive"="D:\\\\"
"Install Dir"="$win_dir"
"Product GUID"="{76F4DD9B-C246-4BE0-00B6-3DE9ABF72299}"
"Region"="en-us"
"Patch URL"="http://patches.ea.com/nfshp2/EN-US/home.html"

[HKEY_LOCAL_MACHINE\\$view\\EA GAMES\\Need For Speed Hot Pursuit 2\\1.0]
"Language"=dword:00000013
"DisplayName"="Need For Speed Hot Pursuit 2"
"LanguageName"="English UK"
EOF
        done
    } > "$keys"
    import_reg "$keys" "$WINEPREFIX/$GAME_ID-install.applied"
}

# Zooming (zoom_to - with "W H X Y AW AH", the area is shown as AW:AH), the
# black panels beside the game (panels_start) and finding its window
# (find_window): shared code. The X screen is FB_RES.
ZOOM_FB="$FB_RES"

# True while the game (or wineserver, which holds its files too) has a
# video file open. One find per process, no per-file forks.
movie_playing() {
    local p
    for p in $(pgrep -f -i "$GAME_EXE") $(pgrep -f wineserver); do
        [ -n "$(find "/proc/$p/fd" -maxdepth 1 -ilname "$MOVIE_GLOB" -print -quit 2>/dev/null)" ] \
            && return 0
    done
    return 1
}

# The game's window, followed by the shared follow_window (in_x). This
# hook reshapes it while a video plays, and after a resolution change:
# The resolution the game started at is the window size
# while its first video plays (or its first window that isn't the TV's
# size). After a change, the picture is that shape at the new height, at
# the window's left edge (see "Known issue") - zoomed to when it's narrower
# than the window.
START_W=""; START_H=""
follow_window_map() {           # ($1-$4 = the window's W H X Y)
    local movie=0 pw=$1
    [ -n "$MOVIE_ASPECT" ] && movie_playing && movie=1
    if [ -z "$START_W" ] && { [ "$movie" = "1" ] || [ "$1 $2" != "$NW $NH" ]; }; then
        START_W=$1; START_H=$2
        echo "Game started at ${1}x$2"
    fi
    if [ "$movie" = "1" ]; then
        # (video shape)
        FOLLOW_GEO="$1 $2 $3 $4 ${MOVIE_ASPECT%x*} ${MOVIE_ASPECT#*x}"
    elif [ -n "$START_W" ] && [ "$1 $2" != "$START_W $START_H" ]; then
        pw=$(( (START_W * $2 + START_H / 2) / START_H ))
        # (picture at the left)
        [ "$pw" -lt "$1" ] && FOLLOW_GEO="$pw $2 $3 $4"
    fi
}

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - a bigger
    # mode could then be refused, or missing from the game's options), then
    # 1:1 until the game shows (shared code)
    zoom_start "$NATIVE_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # Keyboard focus: with no window manager, X gives the keyboard to
    # whatever window is under the pointer - often none of the game's. The
    # keeper gives the focus to Wine's desktop whenever nothing has it
    # (shared code; stopped by the shared cleanup).
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings MOVIE_ASPECT
    FOLLOW_FENCE="$MOUSE_FENCE" follow_start       # (shared code)
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
