#!/bin/bash
# =============================================================================
#  Colin McRae Rally 04 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - The game runs in a Wine desktop the TV's size, so its Options offer
#     every screen mode up to the TV's (4:3 up to 1440x1080). When it
#     switches mode, Wine shrinks its window to that size in the top-left
#     corner; a helper follows the window and has the Pi's display hardware
#     zoom it to full TV height (4:3 -> black side bars). The zoom costs no
#     GL work, and the X screen never changes size.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the modes the game can switch to (as nfs4.sh / NFSU).
#   - Sound and the videos' soundtracks through a game-only mixer
#     (SOUND_MIXER); the videos through LAV Filters (VIDEOS).
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/cmr04.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Colin McRae Rally 04\cmr04-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Colin McRae Rally 04"   # \\<pi>\roms\windows\Colin McRae Rally 04
GAME_EXE="cmr4.exe"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/cmr04"
LOG_FILE="$GAME_DIR/cmr04-launch.log"

# ----- Display ----------------------------------------------------------------
# The game's render resolution:
#   ""       = the game's own choice, picked in its Options (kept between
#              launches). A new prefix starts at FIRST_RES.
#   e.g. "1024x768" = forced every launch (the Options' choice is then
#              overwritten at the next launch).
# Heaviest to lightest (4:3): 1440x1080, 1280x960, 1152x864, 1024x768,
# 960x720 (scales exactly 1.5x to the TV), 800x600, 640x480. 1600x1200 was
# too slow (and is bigger than the TV, so not offered). The game is mostly
# limited by the CPU, so lower resolutions gain less than you might expect.
GAME_RES=""
FIRST_RES="1024x768"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=0             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If handling/physics act oddly with 0, use 1
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
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading) until the game's window appears. Also kept
                    #     in LOG_FILE. 0 = black screen while starting
GL33=1              # tell Wine's Direct3D the GPU has OpenGL 3.3 (V3D reports 3.1)
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (if new problems appear)
VIDEO_MEM_MB=1024   # VRAM reported to the game

# ----- Sound mixer ------------------------------------------------------------
# The Pi's HDMI sound plays one stream at a time, and the game's own sound
# already holds it, so the videos' soundtracks couldn't open. A sound mixer
# just for this game mixes both into one stream to the TV:
# 1 = a private PulseAudio.
# 2 = the same with ALSA only (as SeriousSam.sh / outrun.sh): dmix ->
#     loopback -> alsaloop -> HDMI. Needs alsa-utils (alsaloop) and the
#     snd-aloop module (loaded by the script).
# 0 = no mixer, straight to ALSA - no sound in the videos.
# If the chosen mixer can't start, plain ALSA is used (no video sound).
# ES and emulators keep using plain ALSA in every case.
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1

# ----- Intro / menu videos ----------------------------------------------------
# The game plays its .wmv videos through DirectShow. Wine's own file reader
# hands it one combined stream, so the soundtrack never got connected. With
# VIDEOS=1, 32-bit LAV Filters (contents of the LAVFilters-x.xx-x86 zip,
# copied into LAV_DIR) are installed into the prefix once:
#   LAV Splitter - reads the .wmv, separate picture and sound outputs
#   Wine's own WMV decoder - the picture (LAV Video crashes under Box64:
#                            the Microsoft thread library built into it)
#   LAV Audio    - the sound, played through the sound mixer above
# 0 = no videos at all (also stops the menus' looping background video).
# To reinstall LAV Filters: delete .lavfilters_installed in the prefix folder.
VIDEOS=1
LAV_DIR="$GAME_DIR/LAVFilters"     # \\<pi>\roms\windows\Colin McRae Rally 04\LAVFilters

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
# Direct3D/DirectDraw: always Wine's own DLLs
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;d3d8,d3d9,dxgi,d3d11,ddraw,wined3d=b"

if [ "$GL33" = "1" ]; then
    export MESA_GL_VERSION_OVERRIDE=3.3
    export MESA_GLSL_VERSION_OVERRIDE=330
fi
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging
# (empty = Box64's default; fast NaN/rounding are Box64's defaults too)
[ -n "$BIGBLOCK" ]  && export BOX64_DYNAREC_BIGBLOCK="$BIGBLOCK"
[ -n "$X87DOUBLE" ] && export BOX64_DYNAREC_X87DOUBLE="$X87DOUBLE"
[ -n "$CALLRET" ]   && export BOX64_DYNAREC_CALLRET="$CALLRET"

# Box64's settings file (4 cores), DYNACACHE, FPS_HUD - shared code. The
# speed settings above are for every program here, so none listed.
box64_setup

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen and the Wine
# desktop stay the TV's size all the time, so rescaling only changes the
# GPU transform, never the screen size (changing the screen size failed
# with "BadMatch" for the game's start-up window). Only a window the TV's
# full size is shown 1:1.
ZOOM_FB="$NATIVE_RES"

# A fixed "monitor" the TV's full size (shared code). Wine checks screen
# modes against the monitor X reports, which otherwise follows the zoom
# (~1024x576 for a 1024x768 window) - bigger modes would then be refused.
# 1:1 until the game shows.
set_display() {
    display_output "no scaling" || return
    fixed_monitor cmr04-tv "$NATIVE_RES" || echo "WARNING: could not set a fixed monitor"
    zoom_to "$NW" "$NH"
}

setup_prefix() {
    prefix_setup cmr04      # (+ finishes a pending update after a new Wine)

    # Virtual D: drive. The game hardcodes "D:\cmr4_pc_data\..." (old CD path);
    # the font loader crashes if it's missing. D: -> folder holding a
    # "cmr4_pc_data" symlink to the game folder. Safe to redo every launch.
    local d_root="$HOME/wine_d_root"
    mkdir -p "$d_root" "$WINEPREFIX/dosdevices"
    ln -sfn "$GAME_DIR" "$d_root/cmr4_pc_data"
    ln -sfn "$d_root" "$WINEPREFIX/dosdevices/d:"

    # Videos: LAV Filters (shared code) - installed once, before the registry
    # below (which then includes their settings); LAV Splitter at normal
    # priority (merit 0x00600000), so it opens the game's .wmv videos
    [ "$VIDEOS" = "1" ] && lav_setup "$LAV_DIR" 00600000 "videos stay silent"

    # Registry - the settings below, plus the videos' when LAV Filters are
    # installed. Imported only when something changed (each import is a full
    # Box64 + Wine start-up, several seconds) - one import for both.
    local reg_new="$WINEPREFIX/drive_c/cmr04-settings.reg"
    local reg_old="$WINEPREFIX/cmr04-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; GLX rather than EGL (crash avoidance); Wine mustn't change the screen mode
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"
"UseEGL"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; Black Wine desktop (beside the game's window)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

[HKEY_CURRENT_USER\\Control Panel\\Desktop]
"Wallpaper"=""

; The game's own settings key (its resolution, Width/Height, is set below).
; Copied from the working prefix: without the ADAPTER/SPEC_SELECTION values
; the game runs its first-time hardware detection and resets the
; resolution on the very first launch.
[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Codemasters\\Colin McRae Rally 04]
"INSTALL_PATH"="D:\\\\cmr4_pc_data"
"LANGUAGE"="E"
"ADAPTER_VID"=dword:000010de
"ADAPTER_PID"=dword:00000191
"SPEC_SELECTION1"=dword:88809e76
"SPEC_SELECTION2"=dword:01017530

; Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$(case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac)
EOF
    if [ "$VIDEOS" = "1" ] && [ "$LAV_INSTALLED" = "1" ]; then
        local mt='Media Type\{e436eb83-524f-11ce-9f53-0020af0ba770}\{3DB80F90-9412-11D1-ADED-0000F8754B99}'
        cat >> "$reg_new" <<EOF

; Videos: .wmv / .asf opened by LAV Splitter Source (separate picture and
; sound outputs, like Windows' own ASF reader). Matched by the ASF header
; bytes at the start of the file - NOT by file extension: in Wine an
; "Extensions\\.wmv" key makes AddSourceFilter fall back to the plain file
; reader without reading its "Source Filter". In both registry views: the
; 64-bit one and the 32-bit game's (Wow6432Node).
[HKEY_LOCAL_MACHINE\\Software\\Classes\\$mt]
"0"="0,16,FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,3026B2758E66CF11A6D900AA0062CE6C"
"Source Filter"="{B98D13E7-55DB-4385-A33D-09FD1BA26338}"

[HKEY_LOCAL_MACHINE\\Software\\Classes\\Wow6432Node\\$mt]
"0"="0,16,FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,3026B2758E66CF11A6D900AA0062CE6C"
"Source Filter"="{B98D13E7-55DB-4385-A33D-09FD1BA26338}"

[HKEY_CURRENT_USER\\Software\\LAV\\Splitter\\Formats]
"asf"=dword:00000001

; LAV Audio: 16-bit output only (float gave white noise in X2)
[HKEY_CURRENT_USER\\Software\\LAV\\Audio]
"SampleFormats"=hex:01,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00
"OutputFormats"=hex:01,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00

[HKEY_CURRENT_USER\\Software\\LAV\\Audio\\Formats]
"wma"=dword:00000001
"wmapro"=dword:00000001
"wmalossless"=dword:00000001
EOF
    fi
    import_reg "$reg_new" "$reg_old"

    game_res_setup
}

# The game's resolution (Width/Height in its settings key), edited straight
# in system.reg (Wine isn't running here - no start-up time). The game
# writes its Options' choice there itself. GAME_RES set: forced every
# launch. GAME_RES="": left alone - FIRST_RES only if the game has none yet
# (a new prefix). Case-insensitive: the game writes CODEMASTERS / WIDTH /
# HEIGHT itself. Sets CUR_RES (for the log).
game_res_setup() {
    local reg="$WINEPREFIX/system.reg" tmp w h
    [ -f "$reg" ] || return 0
    tmp="$reg.cmr04-tmp"
    # (the key name via the environment: awk -v would halve its \\)
    KEY='[software\\wow6432node\\codemasters\\colin mcrae rally 04]' \
    awk -v force="$GAME_RES" -v first="$FIRST_RES" '
        function val(i,   r) { split(force != "" ? force : first, r, "x"); return sprintf("dword:%08x", r[i]) }
        function add() {                     # missing ones: FIRST_RES (or GAME_RES)
            if (!w) print "\"Width\"=" val(1)
            if (!h) print "\"Height\"=" val(2)
            w = h = 1
        }
        /^\[/ { if (sec) add(); sec = (index(tolower($0), ENVIRON["KEY"]) == 1); w = h = 0 }
        sec && tolower($0) ~ /^"width"=dword:/  { w = 1; if (force != "") $0 = "\"Width\"=" val(1) }
        sec && tolower($0) ~ /^"height"=dword:/ { h = 1; if (force != "") $0 = "\"Height\"=" val(2) }
        sec && $0 == "" { add() }
        { print }
        END { if (sec) add() }
    ' "$reg" > "$tmp" || { rm -f "$tmp"; echo "WARNING: could not set the game's resolution"; return 0; }
    if cmp -s "$reg" "$tmp"; then rm -f "$tmp"; else mv "$tmp" "$reg"; fi
    # The resolution the game will start at (hex in the file)
    read -r w h < <(KEY='[software\\wow6432node\\codemasters\\colin mcrae rally 04]' awk '
        /^\[/ { sec = (index(tolower($0), ENVIRON["KEY"]) == 1) }
        sec && tolower($0) ~ /^"width"=dword:/  { sub(/^[^:]*:/, ""); w = $0 }
        sec && tolower($0) ~ /^"height"=dword:/ { sub(/^[^:]*:/, ""); h = $0 }
        END { print w, h }' "$reg")
    [ -n "$w" ] && [ -n "$h" ] && CUR_RES="$((16#$w))x$((16#$h))"
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=${GAME_RES:-from the game} (${CUR_RES:-?}) VSYNC=$VSYNC X87DOUBLE=$X87DOUBLE BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE SOUND_MIXER=$SOUND_MIXER"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=cmr04-panels follow_window 100 0 &      # (shared code)
        WATCH_PID=$!
    else
        echo "WARNING: xwininfo not found (sudo apt install x11-utils) - no rescaling"
    fi
    wine explorer /desktop=cmr04,"$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    stop_boot_log
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
    # From EmulationStation: start X just for the game, on ES's console, so
    # it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    start_x -quiet -nocursor
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # no blanking (gamepad input doesn't reset it)
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$NW $NH 0 0" "$GAME_EXE"
set_governor
sound_mixer_start cmr04   # (shared code; SOUND_MIXER)
setup_prefix
run_game
exit 0