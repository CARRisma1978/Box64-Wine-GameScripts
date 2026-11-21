#!/bin/bash
# =============================================================================
#  Test Drive 6 - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#  SCRIPT VERSION: 3
#
#  How it works (as nfs4.sh / nfsu.sh):
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
#     when they start.
#   - Which size is showing is read from the game's own TD6.log ("Sound
#     Device" / "Loading Frontend" = menus, "Screen Mode WxH" = race), so
#     ANY race resolution picked in the game is followed automatically.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to (as found with NFSU).
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash "$HOME/RetroPie/roms/windows/Test Drive 6.sh" --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Test Drive 6\td6-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Test Drive 6"   # \\<pi>\roms\windows\Test Drive 6
GAME_EXE="TD6.exe"          # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/td6"
LOG_FILE="$GAME_DIR/td6-launch.log"
GAME_LOG="$GAME_DIR/TD6.log"                       # written by the game itself

# ----- Display ----------------------------------------------------------------
# Set the race resolution in the GAME's options; the zoom follows it.
# 4:3 sizes are shown at full TV height with black side bars:
#    800x600 = the old fixed setting
#   1024x768 = sharper
#   1280x960 = sharpest correct-shape picture (1280x1024 is 5:4 - too tall)
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
MENU_RES="640x480"          # the size the menus are drawn at
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=0               # 1 = no X pointer (the launcher dialog needs the mouse)

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=0             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If car handling/physics act oddly with 0, use 1
BIGBLOCK=3          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=1           # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
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
                    #     loading), then black until the launcher is ready.
                    #     Also kept in LOG_FILE. 0 = black screen while starting
RDTSC_1GHZ=1        # steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
VIDEO_MEM_MB=512    # VRAM reported to the game (a 1999 game - keep it modest)
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

# ----- Music fix (PCGamingWiki) -----------------------------------------------
# Windows Media Source Filter + DivX 3.11 codec, installed once per prefix.
# Both zips extracted inside MUSIC_FIX_DIR; drmclien.dll and strmdll.dll also
# in the game folder. Delete .td6_music_fix_done in the prefix to reinstall.
MUSIC_FIX_DIR="$GAME_DIR/music-fix"

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
# No Mono/Gecko prompts or menu entries; a crash just ends the game.
# strmdll=n,b: native strmdll.dll from the game folder (Wine's stub crashes the
# game when it starts the WMA music)
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;strmdll=n,b"

# GL 3.3 for wined3d (V3D reports 3.1) - also fixes transparency around trees.
# wined3d has its own render thread, so Mesa's is off.
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1                         # skip GL error checking
export mesa_glthread=false
[ "$VSYNC" = "0" ]   && export vblank_mode=0

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup td6      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/td6-settings.reg" reg_old="$WINEPREFIX/td6-settings.applied"
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

; TD6 is a 1999 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Music fix, first run only. Does ApplyPatch.bat's job directly (its admin
# check and PAUSE fail under Wine), then registers the DivX codec. Runs
# inside X, as Register_DivX.exe may want to show a window.
install_music_fix() {
    [ -f "$WINEPREFIX/.td6_music_fix_done" ] && return
    local patch_bat divx_reg src syswow dll
    patch_bat="$(find "$MUSIC_FIX_DIR" -iname 'ApplyPatch.bat' 2>/dev/null | head -n1)"
    divx_reg="$(find "$MUSIC_FIX_DIR" -iname 'Register_DivX.exe' 2>/dev/null | head -n1)"
    if [ -z "$patch_bat" ] || [ -z "$divx_reg" ]; then
        echo "WARNING: music fix files not found in $MUSIC_FIX_DIR - no music"
        return
    fi
    echo "Installing music fix..."
    src="$(dirname "$patch_bat")"
    syswow="$WINEPREFIX/drive_c/windows/syswow64"
    pick() { find "$src" -maxdepth 1 -iname "$1" | head -n1; }
    mkdir -p "$syswow/Windows-Media-Source-Filter"
    cp -f "$(pick msadds32.ax)" "$syswow/"
    for dll in dxmasf.dll drmclien.dll strmdll.dll; do
        cp -f "$(pick "$dll")" "$syswow/Windows-Media-Source-Filter/$dll"
    done
    wine 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\Windows-Media-Source-Filter\dxmasf.dll'
    wine 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\msadds32.ax'
    ( cd "$(dirname "$divx_reg")" && wine "$(basename "$divx_reg")" )
    wineserver -w
    touch "$WINEPREFIX/.td6_music_fix_done"
}

# Zooming (zoom_to) and the black panels beside the game (panels_start):
# shared code. The X screen stays the TV's size; only an area the TV's full
# size is shown 1:1.
ZOOM_FB="$NATIVE_RES"

# Background helper: follows TD6.log as the game writes it (tail -F - no
# re-reading the whole file) and zooms to match:
#   "Sound Device" (game started, launcher closed) / "Loading Frontend" -> MENU_RES
#   "Screen Mode WxH" (race) -> WxH
# Before that, the launcher dialog is looked for 4 times a second. Once it
# appears, the TV shows the MENU_RES area at 0,0 - the menus' view - and
# the menus starting needs no zoom of their own.
watch_game_log() {
    local line buf="" size last="" geo
    # Black panels over the rest of the desktop (Wine leaves old pictures
    # there after a resolution change)
    panels_start td6-panels
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

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === VSYNC=$VSYNC BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET DYNACACHE=$DYNACACHE FILTER=$SCALE_FILTER"
    if [ -n "$OUTPUT" ]; then
        rm -f "$GAME_LOG"           # fresh log, so old lines can't mislead the helper
        watch_game_log &
        WATCH_PID=$!
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop=td6,"$NATIVE_RES" "$GAME_EXE" &
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
MAIN_PID=$$                         # the log follower stops when this script does
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
display_output "no zoom"
# A fixed "monitor" the TV's full size. Wine checks screen modes against
# the monitor X reports, which otherwise follows the zoom (~853x480 in the
# 640x480 menus) - a bigger mode for a race could then be refused.
if [ -n "$OUTPUT" ]; then
    fixed_monitor td6-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor - races above 640x480 may fail"
fi
zoom_to "$NW" "$NH"                      # 1:1 until the launcher dialog appears
xsetroot -solid black 2>/dev/null       # black until Wine's desktop appears
set_governor
install_music_fix
# After the music fix (first run only), so the messages can't cover a window
# its codec installer shows
start_boot_log "$NW $NH 0 0" "$GAME_EXE"
sound_mixer_start td6   # (shared code; SOUND_MIXER)
run_game
exit 0