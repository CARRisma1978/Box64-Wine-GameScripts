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
#     Display). The TV stays at its normal mode; a helper watches the game's
#     window and has the Pi's display hardware zoom it to full height,
#     centred (free - no GL work) - whichever mode, or the window itself.
#     Black panels cover the rest, and the mouse is fenced to the picture
#     (MOUSE_FENCE).
#   - Bare X, no window manager: Wine's desktop draws the game's window
#     frame.
#   - Full install: everything needed is in the game folder - no CD.
#     Patch Set 1 (fs98pat1) is applied.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/FS98.sh --kill
#
#  Log (overwritten each launch):
#     \\<pi>\roms\windows\Flight Simulator\fs98-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="fs98"              # short name: its Wine prefix
                            #   (~/wine-prefixes/fs98) and log
# \\<pi>\roms\windows\Flight Simulator
GAME_DIR="$HOME/RetroPie/roms/windows/Flight Simulator"
GAME_EXE="FLTSIM98.EXE"     # exactly as spelled on disk

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
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (played with mouse + keyboard)
MOUSE_FENCE=1               # 1 = keep the mouse on the picture (off the black
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

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
                    # (WINE_RENDERER=gl only, and full-screen Direct3D only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (WINE_RENDERER=gl only)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If the flight model acts oddly with 0, use 1. Here 1
                    #   was faster (measured in Direct3D: ~120 fps vs ~100
                    #   with 0)
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
GL33=1              # WINE_RENDERER=gl only: tell Wine's Direct3D the GPU has
                    #   OpenGL 3.3 (V3D reports 3.1). 0 made no difference to
                    #   the black cockpit
VIDEO_MEM_MB=512    # WINE_RENDERER=gl only: VRAM reported to the game

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
# OpenGL: GL33, no error checking - shared code
gl_setup

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

DW=${DESK_RES%x*}; DH=${DESK_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then the codecs
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    {
        wine_base_reg dsound
        cat <<EOF
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
            done
        fi
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
    install_codecs
}

# ----- Video codecs -----------------------------------------------------------
# codec_file name - the file in CODEC_DIR with this name, any upper/lower case
codec_file() {
    [ -n "$CODEC_DIR" ] && [ -d "$CODEC_DIR" ] || return 0
    find "$CODEC_DIR" -maxdepth 1 -type f -iname "$1" | head -n1
}

# Copies every .ax / .dll in CODEC_DIR into the prefix's 32-bit system
# folder (lower-case names), when new or changed. Each copy replaces the
# file (--remove-destination) rather than writing into it: Wine's files may
# be shared with the other games' prefixes.
install_codecs() {
    [ -n "$CODEC_DIR" ] && [ -d "$CODEC_DIR" ] || return 0
    local sys="$WINEPREFIX/drive_c/windows/syswow64" f dest
    while IFS= read -r f; do
        dest="$sys/$(basename "${f,,}")"
        cmp -s "$f" "$dest" && continue
        cp --remove-destination "$f" "$dest" && echo "Codec installed: $(basename "$dest")"
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

# splash_geo - the splash view, "W H X Y": SPLASH_VIEW in the middle of
# the desktop, or the whole desktop if it's not set
splash_geo() {
    if [ -n "$SPLASH_VIEW" ]; then
        local sw=${SPLASH_VIEW%x*} sh=${SPLASH_VIEW#*x}
        echo "$sw $sh $(( (DW - sw) / 2 )) $(( (DH - sh) / 2 ))"
    else
        echo "$DW $DH 0 0"
    fi
}

# splash_view - zooms to the splash view
splash_view() {
    # shellcheck disable=SC2046
    zoom_to $(splash_geo)
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
# Black panels beside it, and the mouse fenced to it with MOUSE_FENCE=1
# (shared code - started here, in the same process as zoom_to). Checks 4
# times a second for the first 20 s, then twice a second.
watch_game_window() {
    local main geo last="" n=0
    panels_start "$GAME_ID-panels" "$MOUSE_FENCE"
    while :; do
        if [ "$n" -lt 80 ]; then sleep 0.25; n=$((n + 1)); else sleep 0.5; fi
        main="$(find_window)"           # the game's largest window,
                                        #   300x200 or more
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

# Inside X (from launch, shared code)
in_x() {
    # A fixed DESK_RES "monitor" for Wine (shared code), then the splash
    # view until the game's window shows. Without the fixed monitor, X
    # reports one that follows the zoom (1366x768 in the splash view), so
    # Wine centred the intro and logo on that - not on the desktop - and
    # they were zoomed to.
    # shellcheck disable=SC2046
    zoom_start "$DESK_RES" $(splash_geo)     # (shared code)
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # Keyboard to the game: with no window manager, keys go to whatever is
    # under the pointer. The keeper gives the focus to Wine's desktop
    # whenever nothing has it (shared code; stopped by the shared cleanup).
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings DESK_RES SPLASH_VIEW WINE_RENDERER
    follow_start watch_game_window
    # Wine desktop of DESK_RES: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$DESK_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
