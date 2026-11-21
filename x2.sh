#!/bin/bash
# =============================================================================
#  X2: The Threat - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works (as nfsu.sh / quake2.sh):
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
#     the screen modes the game can switch to (as found with NFSU).
#   - Start-up: messages on screen, then black until the game is ready
#     (BOOT_LOG). With BOOT_LOG=0, the first window's size is remembered
#     instead, and the next launch zooms to it before anything appears - no
#     visible jump at start-up.
#   - Prefix setup, registry, LAV Filters and the DirectShow DLLs are all
#     done BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/x2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\X2 - The Threat\x2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/X2 - The Threat"   # \\<pi>\roms\windows\X2 - The Threat
GAME_EXE="X2.EXE"           # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/x2"
LOG_FILE="$GAME_DIR/x2-launch.log"

# Microsoft's 32-bit DirectShow DLLs, from dxnt.cab in directx_feb2010_redist.exe
# (the Windows 10/11 copies don't work in Wine): videos and station chatter.
NATIVE_DIR="$GAME_DIR/native-dshow"     # \\<pi>\roms\windows\X2 - The Threat\native-dshow
NATIVE_DLLS="quartz amstream devenum qasf"

# 32-bit LAV Filters (LAVFilters-x.xx-x86.zip): MP3 music and WMA speech.
# To reinstall (e.g. a newer version): delete .lavfilters_installed in the prefix.
LAV_DIR="$GAME_DIR/LAVFilters"          # \\<pi>\roms\windows\X2 - The Threat\LAVFilters

# ----- Display ----------------------------------------------------------------
# Set the resolution in the GAME's options; the zoom follows it. 16:9 fills
# the TV:
#    960x540 = exactly 2x - lightest; SCALE_FILTER="nearest" = crisp pixels
#   1280x720 = 1.5x (the tested setting)
#   1600x900 = 1.2x, sharper, more GPU work
#  1920x1080 = no zoom, sharpest, most GPU work
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=0               # 1 = no X pointer (the launcher needs the mouse)
LOADING_RES="1024x768"      # the "Loading..." picture the game draws (top-left
                            # of a TV-sized window) after the launcher

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If physics/flight act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=1           # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code; empty = Box64's default (2).
                    #   3 = as 2, plus protection from random crashes (Box64
                    #   built 26 Oct 2026 or later - check: box64 --version)
                    #   Can crash some games - try 3, then 0 (1 = as the old script)
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=1   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    # its own render thread. Try 1 if FPS_HUD=2 shows a second
                    # core at 100%.
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if uneven
                    #   0 or empty = off (Box64's default)
VIDEO_MEM_MB=1024   # VRAM reported to the game (keep below 2048)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE

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
# No Mono/Gecko prompts or menu entries; a crash just ends the game;
# winegstreamer off: its DirectShow parser deadlocks with X2's music;
# Microsoft's DirectShow DLLs first
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winegstreamer=d"
for d in $NATIVE_DLLS; do WINEDLLOVERRIDES="$WINEDLLOVERRIDES;$d=n,b"; done

# GL 3.3 for wined3d (V3D reports 3.1)
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$GLTHREAD" = "1" ] && export mesa_glthread=true || export mesa_glthread=false
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# Marker in the prefix folder (delete it to redo that step)
NATIVE_MARKER="$WINEPREFIX/.x2_native_dshow_done"
# The game's first window ("W H X Y"), remembered for the next launch's
# early zoom. Delete the file to start at 1:1 instead.
START_ZOOM_FILE="$WINEPREFIX/.x2_start_zoom"

# ===================== Helpers =====================

# ----- Prefix setup (runs before X, with Wine fully stopped afterwards) -----
setup_prefix() {
    prefix_setup x2      # (+ finishes a pending update after a new Wine)
    [ "$PREFIX_UPDATED" = "1" ] && rm -f "$NATIVE_MARKER"

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/x2-settings.reg" reg_old="$WINEPREFIX/x2-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; Black Wine desktop (the side bars)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

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
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # LAV Filters (shared code): installed once. LAV Splitter's priority
    # (merit 0x00400000) is below Microsoft's MPEG-1 splitter, so Microsoft's
    # opens the videos (LAV's made mov\00006.dat freeze) and LAV only opens
    # what Microsoft's can't (the MP3 music, the WMA speech).
    lav_setup "$LAV_DIR" 00400000 "no music or speech"
    setup_native_dshow
}

# Microsoft's DirectShow DLLs: copied into syswow64 (Wine's own copies kept
# as *.dll.wine) and registered - once, and again after a Wine update
setup_native_dshow() {
    [ "$(cat "$NATIVE_MARKER" 2>/dev/null)" = "$NATIVE_DLLS" ] && return
    local syswow="$WINEPREFIX/drive_c/windows/syswow64" d src
    for d in $NATIVE_DLLS; do
        [ -n "$(find "$NATIVE_DIR" -maxdepth 1 -iname "$d.dll" 2>/dev/null)" ] || {
            echo "WARNING: $d.dll not found in $NATIVE_DIR - videos/chatter may not play"
            return; }
    done
    echo "Installing Microsoft's DirectShow DLLs..."
    for d in $NATIVE_DLLS; do
        [ -f "$syswow/$d.dll.wine" ] || cp -f "$syswow/$d.dll" "$syswow/$d.dll.wine"
        src="$(find "$NATIVE_DIR" -maxdepth 1 -iname "$d.dll" | head -n1)"
        cp -f "$src" "$syswow/$d.dll"
    done
    for d in $NATIVE_DLLS; do
        wine 'C:\windows\syswow64\regsvr32.exe' /s "C:\\windows\\syswow64\\$d.dll"
    done
    wineserver -w
    echo "$NATIVE_DLLS" > "$NATIVE_MARKER"
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1 (so e.g.
# 1440x1080 is still centred).
ZOOM_FB="$NATIVE_RES"

# The game's window: followed by the shared follow_window (run_game). The
# first real one (not the TV's full size) is remembered for the next launch.
FIRST_SEEN=0
follow_window_hook() {
    [ "$FIRST_SEEN" = "0" ] || return 0
    [ "${1% * *}" = "$NW $NH" ] && return 0
    FIRST_SEEN=1
    [ "$1" = "$START_GEO" ] || echo "$1" > "$START_ZOOM_FILE"
}

# Called by follow_window for every window it finds, before its 3-second
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

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === START=${START_GEO:-1:1} VSYNC=$VSYNC GLTHREAD=$GLTHREAD BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=x2-panels FOLLOW_HOLD_FULL=1 follow_window 100 0 &      # (shared code)
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop=x2,"$NATIVE_RES" "$GAME_EXE" &
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
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
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
xset s off -dpms s noblank 2>/dev/null   # gamepad/keyboard input doesn't reset blanking
display_output "no zoom"
# A fixed "monitor" the TV's full size. Wine checks screen modes against
# the monitor X reports, which otherwise follows the zoom - the game's
# resolution list could shrink, or a bigger mode be refused.
if [ -n "$OUTPUT" ]; then
    fixed_monitor x2-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor - resolution changes may fail"
fi
# Start at last time's first window straight away (black to black: nothing
# is drawn yet). Safe this early because of the fixed monitor above.
# With BOOT_LOG=1, start at 1:1 instead: the start-up messages show at their
# usual size (a small launcher's zoom would enlarge them), and their black
# cover hides the zoom to the launcher.
START_GEO="$(cat "$START_ZOOM_FILE" 2>/dev/null)"
[[ "$START_GEO" =~ ^[0-9]+\ [0-9]+\ -?[0-9]+\ -?[0-9]+$ ]] || START_GEO=""
[ "$BOOT_LOG" = "1" ] && START_GEO=""
echo "Starting zoom: ${START_GEO:-1:1}"
# shellcheck disable=SC2086
zoom_to ${START_GEO:-$NW $NH}
start_boot_log "${START_GEO:-$NW $NH 0 0}" "$GAME_EXE"   # (the area the TV shows from the start)
set_governor
sound_mixer_start x2   # (shared code; SOUND_MIXER)
run_game
exit 0