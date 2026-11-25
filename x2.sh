#!/bin/bash
# =============================================================================
#  X2: The Threat - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D 8 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - Bare X, no window manager (in a Wine desktop, Wine manages the game's
#     windows itself).
#   - Videos, music and station chatter go through DirectShow: Microsoft's
#     own 32-bit DLLs (native-dshow) + LAV Filters (MP3 music, WMA speech).
#   - The Wine desktop is the TV's size (required: without it the game can't
#     set its resolution and reports "Error opening video"). When a window is
#     smaller (the resolution picked in the game), a helper has the Pi's
#     display hardware zoom it to full TV height, centred, with black panels
#     over the rest of the desktop. The zoom costs no GL work, and whatever
#     resolution is picked in the game is followed automatically.
#   - The launcher is shown at the same zoom as the "Loading..." picture
#     after it, and that picture straight away, so it's seen whole.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#   - Start-up: messages on screen, then black until the game is ready.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/x2.sh --kill
#
#  Log (overwritten each launch):
#     \\<pi>\roms\windows\X2 - The Threat\x2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="x2"                # short name: its Wine prefix
                            #   (~/wine-prefixes/x2) and log
# \\<pi>\roms\windows\X2 - The Threat
GAME_DIR="$HOME/RetroPie/roms/windows/X2 - The Threat"
GAME_EXE="X2.EXE"           # exactly as spelled on disk

# Microsoft's 32-bit DirectShow DLLs, from dxnt.cab in
# directx_feb2010_redist.exe (the Windows 10/11 copies don't work in Wine):
# videos and station chatter.
# \\<pi>\roms\windows\X2 - The Threat\native-dshow
NATIVE_DIR="$GAME_DIR/native-dshow"
NATIVE_DLLS="quartz amstream devenum qasf"

# 32-bit LAV Filters (LAVFilters-x.xx-x86.zip): MP3 music and WMA speech.
# To reinstall (e.g. a newer version): delete .lavfilters_installed
# in the prefix.
# \\<pi>\roms\windows\X2 - The Threat\LAVFilters
LAV_DIR="$GAME_DIR/LAVFilters"

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# Set the resolution in the GAME's options; the zoom follows it. 16:9 fills
# the TV:
#    960x540 = exactly 2x - lightest; SCALE_FILTER="nearest" (set it here,
#              or for every game in .scripts/settings.cfg) = crisp pixels
#   1280x720 = 1.5x (the tested setting)
#   1600x900 = 1.2x, sharper, more GPU work
#  1920x1080 = no zoom, sharpest, most GPU work
LOADING_RES="1024x768"      # the "Loading..." picture the game draws (top-left
                            # of a TV-sized window) after the launcher
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the launcher needs the mouse)

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
                    # If physics/flight act oddly with 0, use 1
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
                    #   its own render thread. Try 1 if FPS_HUD=2 shows a second
                    #   core at 100%
VIDEO_MEM_MB=1024   # VRAM reported to the game (keep below 2048)

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
# winegstreamer off: its DirectShow parser deadlocks with X2's music;
# Microsoft's DirectShow DLLs first
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winegstreamer=d"
for d in $NATIVE_DLLS; do WINEDLLOVERRIDES="$WINEDLLOVERRIDES;$d=n,b"; done

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# Marker in the prefix folder (delete it to redo that step)
NATIVE_MARKER="$WINEPREFIX/.${GAME_ID}_native_dshow_done"

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then LAV Filters
# and the DirectShow DLLs
setup_prefix() {
    prefix_setup
    [ "$PREFIX_UPDATED" = "1" ] && rm -f "$NATIVE_MARKER"
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; LAV Audio: 16-bit output only (a switch to float gives white noise)
[HKEY_CURRENT_USER\\Software\\LAV\\Audio]
"SampleFormats"=hex:01,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00
"OutputFormats"=hex:01,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00

; LAV Audio: WMA decoders on (the speech is WMA)
[HKEY_CURRENT_USER\\Software\\LAV\\Audio\\Formats]
"wma"=dword:00000001
"wmapro"=dword:00000001
"wmalossless"=dword:00000001
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # LAV Filters (shared code): installed once. LAV Splitter's priority
    # (merit 0x00400000) is below Microsoft's MPEG-1 splitter, so Microsoft's
    # opens the videos (LAV's made mov\00006.dat freeze) and LAV only opens
    # what Microsoft's can't (the MP3 music, the WMA speech).
    lav_setup "$LAV_DIR" 00400000 "no music or speech"
    setup_native_dshow
}

# Microsoft's DirectShow DLLs: copied into syswow64 (Wine's own copies kept
# as *.dll.wine) and registered - once, and again after a Wine update.
# Each copy replaces the file (--remove-destination) rather than writing
# into it: Wine's files may be shared with the other games' prefixes.
setup_native_dshow() {
    [ "$(cat "$NATIVE_MARKER" 2>/dev/null)" = "$NATIVE_DLLS" ] && return
    local d
    for d in $NATIVE_DLLS; do
        [ -n "$(find "$NATIVE_DIR" -maxdepth 1 -iname "$d.dll" 2>/dev/null)" ] || {
            echo "WARNING: $d.dll not found in $NATIVE_DIR - videos/chatter may not play"
            return; }
    done
    step "Installing Microsoft's DirectShow DLLs" _install_native_dshow \
        && echo "$NATIVE_DLLS" > "$NATIVE_MARKER"
}
_install_native_dshow() {
    local syswow="$WINEPREFIX/drive_c/windows/syswow64" d src
    for d in $NATIVE_DLLS; do
        [ -f "$syswow/$d.dll.wine" ] || cp --remove-destination "$syswow/$d.dll" "$syswow/$d.dll.wine"
        src="$(find "$NATIVE_DIR" -maxdepth 1 -iname "$d.dll" | head -n1)"
        cp --remove-destination "$src" "$syswow/$d.dll" || return 1
    done
    for d in $NATIVE_DLLS; do
        wine 'C:\windows\syswow64\regsvr32.exe' /s "C:\\windows\\syswow64\\$d.dll"
    done
    wineserver -w
    STEP_RESULT="installed"
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1 (so e.g.
# 1440x1080 is still centred).
ZOOM_FB="$NATIVE_RES"

# The game's window: followed by the shared follow_window (in_x), which
# calls follow_window_map for every window it finds, before its 3-second
# hold on a TV-sized window:
#  - The launcher (and any window from it that fits) is shown in a
#    LOADING_RES-sized area centred on it - the same zoom as the picture
#    after it, so going to the picture is only a move, not a rescale.
#  - After the launcher, the game opens a TV-sized window with the
#    "Loading..." picture in its top-left corner for about 3 s, then
#    switches to its own mode: that window is zoomed to the picture straight
#    away, so it's seen whole. Only that once - any later TV-sized window
#    still waits for the hold.
LOADING_STATE=""        # "" -> launcher (a smaller window seen) -> on -> done
LW=${LOADING_RES%x*}; LH=${LOADING_RES#*x}
follow_window_map() {
    local x y
    if [ "$1 $2" = "$NW $NH" ]; then
        case "$LOADING_STATE" in launcher|on)
            LOADING_STATE=on; FOLLOW_GEO="$LW $LH 0 0" ;;
        esac
    else
        case "$LOADING_STATE" in "") LOADING_STATE=launcher ;; on) LOADING_STATE=done ;; esac
        if [ "$LOADING_STATE" = "launcher" ] && [ "$1" -le "$LW" ] && [ "$2" -le "$LH" ]; then
            x=$(( $3 + $1 / 2 - LW / 2 )); y=$(( $4 + $2 / 2 - LH / 2 ))
            (( x < 0 )) && x=0; (( x > NW - LW )) && x=$(( NW - LW ))
            (( y < 0 )) && y=0; (( y > NH - LH )) && y=$(( NH - LH ))
            FOLLOW_GEO="$LW $LH $x $y"
        fi
    fi
}

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - the game's
    # resolution list could shrink, or a bigger mode be refused), then 1:1
    # until the launcher shows (shared code)
    zoom_start "$NATIVE_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows
                                                #   from the start)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings VIDEO_MEM_MB
    FOLLOW_HOLD_FULL=1 follow_start 100 0          # (shared code)
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
