#!/bin/bash
# =============================================================================
#  Microsoft Flight Simulator 98 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - The game was installed on Windows and the folder copied here; it runs
#     from that folder in its own Wine prefix.
#   - Played with mouse + keyboard. FS98 runs in a window (menus at the top)
#     or full screen (Alt+Enter), inside a Wine desktop of DESK_RES. Choose
#     any full-screen mode up to that in the game (Options > Preferences >
#     Display). The TV stays at 1920x1080; a helper watches the game's
#     window and has the Pi's display hardware zoom it to full height,
#     centred (free - no GL work) - whichever mode, or the window itself.
#     Black panels cover the rest, and the mouse is fenced to the picture
#     (FENCE_POINTER).
#   - Bare X, no window manager: Wine's desktop draws the game's window
#     frame.
#   - Full install: everything needed is in the game folder - no CD.
#     Patch Set 1 (fs98pat1) is applied.
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/FS98.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Flight Simulator\fs98-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Flight Simulator"   # \\<pi>\roms\windows\Flight Simulator
GAME_EXE="FLTSIM98.EXE"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/fs98"
LOG_FILE="$GAME_DIR/fs98-launch.log"

# ----- Display ----------------------------------------------------------------
# DESK_RES = the Wine desktop. The game sees it as the whole screen, so it
# offers full-screen modes up to this size; whichever you choose in the
# game, the TV zooms to it. 1600x1200 = the game's largest.
# Modes and how they show on the TV (1080 lines):
#   1600x1200 = shown at 0.9x - no sharper than 1440x1080; the heaviest
#   1280x960  = PREFERRED: about the TV's own sharpness (1.125x), and runs
#               well in "DirectDraw HAL"
#   1024x768  = 1.41x;  800x600 = 1.8x;  640x480 = 2.25x - lightest
DESK_RES="1600x1200"
SPLASH_VIEW="1024x768"      # the intro video and logo (small windows in the
                            # middle of the desktop) aren't zoomed to: the TV
                            # shows this much of the desktop's middle instead,
                            # as before the zoom helper (1024x768 desktop).
                            # "" = zoom to them like any other window
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
FENCE_POINTER=1             # 1 = keep the mouse on the picture (off the black
                            # panels and the rest of the desktop)
WINE_RENDERER="gdi"         # Wine's DirectDraw/Direct3D renderer:
                            #   gdi = DirectDraw in normal memory, no Direct3D
                            #         at all (Wine: "Disabling 3D support")
                            #   gl  = through OpenGL on the Pi's GPU - needed
                            #         only for Direct3D (which doesn't work -
                            #         kept, with its settings below, to
                            #         retest after Wine updates)
                            # In "DirectDraw HAL" both ran the same
# In game: Options > Preferences > Display - use "DirectDraw HAL"
# (software) at 1280x960. With gdi, choosing Direct3D just gives the same
# software picture (there's no Direct3D device to use). With gl, the
# Direct3D devices show as "NVIDIA GeForce 8800 GTX" - Wine's stand-in name
# for a GPU it doesn't know.
#
# Real Direct3D (gl) doesn't work here: the cockpit panel stays black (bits
# flash up), the ground is black or the screen is redrawn slowly from the
# top down, though the fps counter shows ~120 - all on one CPU core (100%).
# Tried without success (last tested Oct 2026, Wine 11.18, with and without
# Patch Set 1):
#   - CSMT=0, 640x480, X87DOUBLE=0 (slower), the game's own scenery/texture
#     options
#   - GL33=0 (Wine's normal OpenGL 3.1 on the Pi)
#   - Mesa's software OpenGL, llvmpipe (LIBGL_ALWAYS_SOFTWARE=1
#     GALLIUM_DRIVER=llvmpipe) - same black cockpit, so not the GPU driver
#   - renderer "vulkan" - the view out of the window is blank instead:
#     Wine's Vulkan Direct3D can't draw to the window ("Unhandled location
#     WINED3D_LOCATION_DRAWABLE")
#   - dgVoodoo2 (2.87 crashed - versions after 2.80 fail under Wine;
#     2.79.3 ran but showed the same black ground and blank cockpit)
#   - dxwrapper (dx7.games.zip, DirectDraw -> Direct3D 9; ddraw.dll
#     loaded as native for FLTSIM98.EXE) - a little more scenery, cockpit
#     still black, also with DdrawEmulateSurface + DdrawWriteToGDI
# Wine's DirectDraw and dxwrapper fail the same way, so the fault is below
# both, inside Wine - no setting fixes it. Wine's log shows "Operation
# requires 0x2 access, but texture only has 0xd" when it happens.
# DDrawCompat is for Windows' own DirectDraw only.

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
                    #   WINE_RENDERER=gl only, and shows in full-screen Direct3D only
VSYNC=0             # WINE_RENDERER=gl only: 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If the flight model acts oddly with 0, use 1. Here 1
                    #   was faster (measured in Direct3D: ~120 fps vs ~100
                    #   with 0)
BIGBLOCK=3          # Box64 code block size 0-3 for the game (bigger = less
                    #   translating); empty = Box64's default (2)
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
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE
GL33=1              # WINE_RENDERER=gl only: tell Wine's Direct3D the GPU has
                    #   OpenGL 3.3 (V3D reports 3.1). 0 made no difference to
                    #   the black cockpit
RDTSC_1GHZ=1        # steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
VIDEO_MEM_MB=512    # WINE_RENDERER=gl only: VRAM reported to the game

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

# ----- Intro video ------------------------------------------------------------
# The intro (mslogo.avi) uses Intel's Indeo 4.1 video codec, which Wine
# doesn't include - without it: "MCI Error", no intro, then the game starts.
# Put the codec into CODEC_DIR as ir41_32.ax, with ir41_qc.dll and
# ir41_qcx.dll: they're copied into the prefix and registered whenever they
# change. The one that works is the Windows 95/98 Indeo 4.1 codec,
# ir41_32.dll, renamed to ir41_32.ax - the later Indeo 4.5 ir41_32.ax
# loaded but refused the video. "" = none.
CODEC_DIR="$GAME_DIR/codecs"    # \\<pi>\roms\windows\Flight Simulator\codecs

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

if [ "$GL33" = "1" ]; then
    export MESA_GL_VERSION_OVERRIDE=3.3
    export MESA_GLSL_VERSION_OVERRIDE=330
fi
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

DW=${DESK_RES%x*}; DH=${DESK_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup fs98       # (+ finishes a pending update after a new Wine)

    # Imported only when something changes (each import is a full Box64 +
    # Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/fs98-settings.reg" reg_old="$WINEPREFIX/fs98-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="$WINE_RENDERER"
"VideoMemorySize"="$VIDEO_MEM_MB"
EOF
    # Indeo 4 video codec, if supplied (32-bit game: both registry views)
    if [ -n "$(codec_file ir41_32.ax)" ]; then
        local k
        for k in 'Software' 'Software\Wow6432Node'; do
            printf '\n[HKEY_LOCAL_MACHINE\\%s\\Microsoft\\Windows NT\\CurrentVersion\\Drivers32]\n"vidc.iv41"="ir41_32.ax"\n' \
                "$k"
        done >> "$reg_new"
    fi
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
    install_codecs
}

# ----- Video codecs -------------------------------------------------------------
# codec_file name - the file in CODEC_DIR with this name, any upper/lower case
codec_file() {
    [ -n "$CODEC_DIR" ] && [ -d "$CODEC_DIR" ] || return 0
    find "$CODEC_DIR" -maxdepth 1 -type f -iname "$1" | head -n1
}

# Copies every .ax / .dll in CODEC_DIR into the prefix's 32-bit system
# folder (lower-case names), when new or changed
install_codecs() {
    [ -n "$CODEC_DIR" ] && [ -d "$CODEC_DIR" ] || return 0
    local sys="$WINEPREFIX/drive_c/windows/syswow64" f dest
    while IFS= read -r f; do
        dest="$sys/$(basename "${f,,}")"
        cmp -s "$f" "$dest" && continue
        cp -f "$f" "$dest" && echo "Codec installed: $(basename "$dest")"
    done < <(find "$CODEC_DIR" -maxdepth 1 -type f \( -iname '*.ax' -o -iname '*.dll' \))
    [ -n "$(codec_file ir41_32.ax)" ] || \
        echo "WARNING: ir41_32.ax not in $CODEC_DIR - no intro video (Indeo 4.1)"
}

# Zooming (zoom_to) and finding the game's window (find_window): shared
# code. The X screen is the TV's size, made big enough for the desktop
# (1920x1200 for 1600x1200) and kept that size, so a mode change only
# changes the zoom. ZOOM_FB_VIEW=1: no window manager, so the X screen must
# reach the whole zoomed view.
ZOOM_FB="$(( DW > ${NATIVE_RES%x*} ? DW : ${NATIVE_RES%x*} ))x$(( DH > ${NATIVE_RES#*x} ? DH : ${NATIVE_RES#*x} ))"
ZOOM_FB_VIEW=1

# splash_view - zooms to SPLASH_VIEW in the middle of the desktop, or the
# whole desktop if it's not set
splash_view() {
    if [ -n "$SPLASH_VIEW" ]; then
        local sw=${SPLASH_VIEW%x*} sh=${SPLASH_VIEW#*x}
        zoom_to "$sw" "$sh" $(( (DW - sw) / 2 )) $(( (DH - sh) / 2 ))
    else
        zoom_to "$DW" "$DH" 0 0
    fi
}

# is_splash W H X Y - true for the intro video / logo: smaller than
# SPLASH_VIEW and centred on the desktop (the game's own window and its
# full-screen modes aren't centred)
is_splash() {
    [ -n "$SPLASH_VIEW" ] || return 1
    local w=$1 h=$2 x=$3 y=$4 dx dy
    [ "$w" -le "${SPLASH_VIEW%x*}" ] && [ "$h" -le "${SPLASH_VIEW#*x}" ] || return 1
    dx=$(( 2 * x + w - DW )); dy=$(( 2 * y + h - DH ))
    [ "${dx#-}" -le 4 ] && [ "${dy#-}" -le 4 ]
}

# A fixed DESK_RES "monitor" for Wine (shared code), then the splash view
# until the game's window shows. Without the fixed monitor, X reports one
# that follows the zoom (1366x768 in the splash view), so Wine centred the
# intro and logo on that - not on the desktop - and they were zoomed to.
set_display() {
    display_output "no zoom" || return
    fixed_monitor fs98 "$DESK_RES" || echo "WARNING: fixed monitor not set"
    splash_view
}

# wine_windows - "W H X Y" for each visible Wine window with a title - the
# game's window, its dialogs, the help viewer (Help > Pilot Training: text
# only - Wine's viewer can't show its pictures/videos) and its dialogs, and
# the small title bars minimised windows become, bottom-left of the desktop
# (double-click one to restore it) - not the desktop. Untitled ones - menus,
# tooltips - are left out, so opening a menu doesn't move the zoom.
wine_windows() {
    xwininfo -root -tree 2>/dev/null | awk '
        /\("[^"]*\.exe" / && !/\(has no name\)/ {
            match($0, /\("[^"]*"/); cls = tolower(substr($0, RSTART + 2, RLENGTH - 3))
            if (cls == "explorer.exe") next
            size = ""
            for (i = 2; i < NF; i++) if ($i ~ /^[0-9]+x[0-9]+[+-]/) { size = $i; break }
            if (size == "") next
            split(size, d, /[x+-]/); if (d[1] < 100 || d[2] < 15) next
            a = $NF; n = match(substr(a, 2), /[+-]/)          # absolute "+X+Y"
            print $1, d[1], d[2], substr(a, 1, n) + 0, substr(a, n + 1) + 0 }' |
    while read -r id w h x y; do
        xwininfo -id "$id" 2>/dev/null | grep -q IsViewable && echo "$w $h $x $y"
    done
}

# game_area [main] - "W H X Y": the game's window (main) plus any titled
# window beside it (a dialog the game or its help opens outside its
# window, a minimised window), kept within the desktop. Without main (the
# game minimised): just the titled windows. Empty if there are none.
game_area() {
    { [ -n "$1" ] && echo "$1"; wine_windows; } | awk -v dw="$DW" -v dh="$DH" '
        NF == 4 { if (!n++ || $3 < l) l = $3; if (n == 1 || $4 < t) t = $4
                  if (n == 1 || $3 + $1 > r) r = $3 + $1; if (n == 1 || $4 + $2 > b) b = $4 + $2 }
        END { if (!n) exit
              if (l < 0) l = 0; if (t < 0) t = 0; if (r > dw) r = dw; if (b > dh) b = dh
              print r - l, b - t, l, t }'
}

# Background helper: zooms the TV to the game's window whenever its size or
# position changes - a full-screen mode, or the window with its menus (the
# intro video and logo: the splash view instead). If the game - or its
# help - opens a dialog outside its window, the zoom widens to show both,
# so the black panels and the mouse fence never cover it.
# Black panels beside it, and the mouse fenced to it with FENCE_POINTER=1
# (shared code - started here, in the same process as zoom_to). Checks 4
# times a second for the first 20 s, then twice a second.
watch_game_window() {
    local main geo last="" n=0
    panels_start fs98-panels "$FENCE_POINTER"
    while :; do
        if [ "$n" -lt 80 ]; then sleep 0.25; n=$((n + 1)); else sleep 0.5; fi
        main="$(find_window)"           # the game's largest window, 300x200 or more
        # shellcheck disable=SC2086
        if [ -n "$main" ] && is_splash $main; then
            geo="splash $main"
        else
            geo="$(game_area "$main")"
            [ -n "$geo" ] || continue
        fi
        [ "$geo" = "$last" ] && continue
        last="$geo"
        if [ "${geo%% *}" = "splash" ]; then
            echo "Game window: $main (intro/logo - splash view)"
            splash_view
        else
            if [ "$geo" = "$main" ]; then
                echo "Game window: $geo"
            else
                echo "Game window: ${main:-none} + other windows -> area $geo"
            fi
            # shellcheck disable=SC2086
            zoom_to $geo
        fi
    done
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === DESK_RES=$DESK_RES SPLASH_VIEW=$SPLASH_VIEW WINE_RENDERER=$WINE_RENDERER VSYNC=$VSYNC X87DOUBLE=$X87DOUBLE BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE DEBUG=$DEBUG"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        watch_game_window &
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop of DESK_RES: the game can't change the real screen mode
    wine explorer /desktop=fs98,"$DESK_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
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
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    setup_prefix >> "$LOG_FILE" 2>&1
    start_x -quiet                      # (pointer shown: mouse + keyboard game)
    wineserver -k 2>/dev/null           # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # mouse-only flying doesn't reset blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$DW $DH 0 0" "$GAME_EXE"
# Keyboard to the game: with no window manager, keys go to whatever is
# under the pointer. The keeper gives the focus to Wine's desktop whenever
# nothing has it (shared code).
focus_start explorer.exe "$GAME_EXE"
set_governor
sound_mixer_start fs98   # (shared code; SOUND_MIXER)
run_game
exit 0
