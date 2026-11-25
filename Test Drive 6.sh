#!/bin/bash
# =============================================================================
#  Test Drive 6 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Direct3D -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - Bare X, no window manager (in a Wine desktop, Wine manages the game's
#     windows itself).
#   - The Wine desktop is the TV's size. When the game sets a screen mode
#     (640x480 menus, or the race resolution picked in its options), Wine
#     shrinks its window to that size in the top-left corner, and the Pi's
#     display hardware zooms it to full TV height (4:3 -> black side bars),
#     with black panels over the rest of the desktop. The zoom costs no GL
#     work.
#   - The launcher dialog (also in the top-left corner) is shown in the
#     menus' 640x480 area - the same view as the menus, so nothing changes
#     when they start. The mouse is fenced onto the area the TV shows
#     (MOUSE_FENCE), so the pointer starts in view on the launcher.
#   - Which size is showing is read from the game's own TD6.log ("Sound
#     Device" / "Loading Frontend" = menus, "Screen Mode WxH" = race), so
#     ANY race resolution picked in the game is followed automatically.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#
#  To close a stuck game over SSH:
#      bash "$HOME/RetroPie/roms/windows/Test Drive 6.sh" --kill
#
#  Log (overwritten each launch):
#     \\<pi>\roms\windows\Test Drive 6\td6-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="td6"               # short name: its Wine prefix
                            #   (~/wine-prefixes/td6) and log
# \\<pi>\roms\windows\Test Drive 6
GAME_DIR="$HOME/RetroPie/roms/windows/Test Drive 6"
GAME_EXE="TD6.exe"          # exactly as spelled on disk
GAME_LOG="$GAME_DIR/TD6.log"                       # written by the game itself

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg).
# Set the race resolution in the GAME's options; the zoom follows it.
# 4:3 sizes are shown at full TV height with black side bars:
#    800x600 = the old fixed setting
#   1024x768 = sharper
#   1280x960 = sharpest correct-shape picture (1280x1024 is 5:4 - too tall)
MENU_RES="640x480"          # the size the menus are drawn at
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the launcher dialog needs the mouse)
MOUSE_FENCE=1               # 1 = keep the mouse on the picture (off the black
                            # bars and the rest of the desktop) - it starts
                            # in the middle of the launcher's view

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If car handling/physics act oddly with 0, use 1
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
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread
VIDEO_MEM_MB=512    # VRAM reported to the game (a 1999 game - keep it modest)

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

# ----- Music fix (PCGamingWiki) -----------------------------------------------
# Windows Media Source Filter + DivX 3.11 codec, installed once per prefix.
# Both zips extracted inside MUSIC_FIX_DIR; drmclien.dll and strmdll.dll also
# in the game folder. Delete .td6_music_fix_done in the prefix to reinstall.
MUSIC_FIX_DIR="$GAME_DIR/music-fix"

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
# strmdll=n,b: native strmdll.dll from the game folder (Wine's stub crashes the
# game when it starts the WMA music)
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;strmdll=n,b"

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
# (3.3 also fixes the transparency around trees)
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; TD6 is a 1999 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Music fix, first run only. Does ApplyPatch.bat's job directly (its admin
# check and PAUSE fail under Wine), then registers the DivX codec. Runs
# inside X, as Register_DivX.exe may want to show a window (with the
# start-up messages stopped, so they can't cover it). Wine's files
# may be shared with the other games' prefixes: each copy replaces the file
# (--remove-destination) rather than writing into it, and the prefix gets
# its own copies first (prefix_private, shared code) - the DivX installer
# replaces Wine's l3codeca.acm by writing into it.
install_music_fix() {
    [ -f "$WINEPREFIX/.td6_music_fix_done" ] && return
    local patch_bat divx_reg
    patch_bat="$(find "$MUSIC_FIX_DIR" -iname 'ApplyPatch.bat' 2>/dev/null | head -n1)"
    divx_reg="$(find "$MUSIC_FIX_DIR" -iname 'Register_DivX.exe' 2>/dev/null | head -n1)"
    if [ -z "$patch_bat" ] || [ -z "$divx_reg" ]; then
        echo "WARNING: music fix files not found in $MUSIC_FIX_DIR - no music"
        return
    fi
    prefix_private "before the music fix installs"
    step "Installing the music fix (first run)" _install_music_fix "$(dirname "$patch_bat")" "$divx_reg" \
        && touch "$WINEPREFIX/.td6_music_fix_done"
}
_install_music_fix() {
    local src="$1" divx_reg="$2" syswow="$WINEPREFIX/drive_c/windows/syswow64" dll
    pick() { find "$src" -maxdepth 1 -iname "$1" | head -n1; }
    mkdir -p "$syswow/Windows-Media-Source-Filter"
    cp --remove-destination "$(pick msadds32.ax)" "$syswow/" || return 1
    for dll in dxmasf.dll drmclien.dll strmdll.dll; do
        cp --remove-destination "$(pick "$dll")" "$syswow/Windows-Media-Source-Filter/$dll" || return 1
    done
    wine 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\Windows-Media-Source-Filter\dxmasf.dll'
    wine 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\msadds32.ax'
    ( cd "$(dirname "$divx_reg")" && wine "$(basename "$divx_reg")" )
    wineserver -w
    STEP_RESULT="installed"
}

# Zooming (zoom_to) and the black panels beside the game, with the mouse
# fence (panels_start): shared code. The X screen stays the TV's size; only
# an area the TV's full size is shown 1:1.
ZOOM_FB="$NATIVE_RES"

# Background helper: follows TD6.log as the game writes it (tail -F - no
# re-reading the whole file) and zooms to match:
#   "Sound Device" (game started, launcher closed) / "Loading
#   Frontend" -> MENU_RES
#   "Screen Mode WxH" (race) -> WxH
# Before that, the launcher dialog is looked for 4 times a second. Once it
# appears, the TV shows the MENU_RES area at 0,0 - the menus' view - and
# the menus starting needs no zoom of their own.
watch_game_log() {
    local line buf="" size last="" geo
    # Black panels over the rest of the desktop (Wine leaves old pictures
    # there after a resolution change), and the mouse fenced onto the
    # picture (MOUSE_FENCE)
    panels_start "$GAME_ID-panels" "$MOUSE_FENCE"
    while :; do
        if IFS= read -r -t 0.25 line; then
            line="$buf${line%$'\r'}"; buf=""
        else
            (( $? > 128 )) || break             # (tail ended)
            buf+="$line"                        # (part of a line so far)
            [ -z "$last" ] || continue
            geo="$(find_window 100 50)"
            geo="${geo% * *}"                   # "W H"
            # (a TV-sized one is the game's window, before its mode)
            [ -n "$geo" ] && [ "$geo" != "$NW $NH" ] || continue
            echo "Launcher: ${geo/ /x} - shown in the menus' $MENU_RES area"
            last="$MENU_RES"
            zoom_to "${MENU_RES%x*}" "${MENU_RES#*x}"
            continue
        fi
        case "$line" in
            *"Sound Device"*|*"Loading Frontend"*) size="$MENU_RES" ;;
            *"Screen Mode"*)
                [[ "$line" =~ ([0-9]+)x([0-9]+) ]] || continue
                size="${BASH_REMATCH[1]}x${BASH_REMATCH[2]}" ;;
            *) continue ;;
        esac
        [ "$size" = "$last" ] && continue
        last="$size"
        echo "Game screen: $size"
        zoom_to "${size%x*}" "${size#*x}"
    done < <(exec tail --pid="$MAIN_PID" -n +1 -F "$GAME_LOG" 2>/dev/null)
}

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - ~853x480 in
    # the 640x480 menus - and a bigger mode for a race could then be
    # refused), then 1:1 until the launcher dialog appears (shared code)
    zoom_start "$NATIVE_RES"
    xsetroot -solid black 2>/dev/null   # black until Wine's desktop appears
    start_boot_log "$START_GEO" "$GAME_EXE"
    set_governor
    setup_prefix
    # The music fix (first run only): the start-up messages stop first, so
    # they can't cover a window its codec installer shows
    if [ ! -f "$WINEPREFIX/.td6_music_fix_done" ]; then
        stop_boot_log
        install_music_fix
    fi
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings MENU_RES VIDEO_MEM_MB
    if [ -n "$OUTPUT" ]; then
        rm -f "$GAME_LOG"           # fresh log, so old lines can't
                                    #   mislead the helper
        watch_game_log &
        WATCH_PID=$!                # (stopped by the shared cleanup)
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
