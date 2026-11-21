#!/bin/bash
# =============================================================================
#  OutRun 2006: Coast 2 Coast - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  The retail OR2006C2C.EXE has SecuROM 7 (disc check), which doesn't run
#  under Wine - use an exe that doesn't need the disc.
#
#  Uses OR2006C2C_PATCHED.EXE made by outrun-lockfix.py (version 2 - fixes
#  three races in the game's file loader, which under Box64 crashed it at
#  0x4245B4 / 0x4245C8 or froze it on a black screen, 0% CPU, at start-up
#  or when loading). Make it once, in the game folder:
#      python3 outrun-lockfix.py
#
#  How it works (based on nfsu2.sh):
#   - Direct3D 9 -> Wine's wined3d -> OpenGL on the Pi's GPU.
#   - The game's resolution lives in outrun2006.ini (DX/RES/WIDTH and
#     DX/RES/HEIGHT) in the game folder. GAME_RES below is written into it
#     on every launch - change it HERE, not in the ini or Config.exe.
#   - The Wine desktop is the TV's size. When the game sets its screen mode,
#     Wine shrinks the game's window to that size in the top-left corner. A
#     helper watches the window and has the Pi's display hardware zoom it to
#     full TV height, shape kept (4:3 -> black side bars; 16:9 -> full screen,
#     but the game stretches its own menus/HUD), with black
#     panels over the rest of the desktop. The zoom costs no GL work.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can use.
#   - The zoom starts at GAME_RES as soon as X starts, so the first screen
#     appears already the right size, then follows the game as normal.
#   - OutRun2006Tweaks (optional): if its dinput8.dll is in the game folder,
#     Wine is told to load it (TWEAKS=auto). Its own settings stay in
#     OutRun2006Tweaks.ini; the script still writes full screen and
#     antialiasing off into outrun2006.ini, so Tweaks' defaults don't apply.
#   - Antialiasing is always off (DX/ANTIALIASING = 0) - not a setting:
#     any level above 0 (tested: 1, and 2 = Tweaks' default) stops the game
#     at start-up with "The Direct3D device is not currently available"
#     (Wine's Direct3D on the Pi's GPU can't give the game the multisampling
#     it asks for).
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/outrun.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\OutRun2006 Coast 2 Coast\outrun-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/OutRun2006 Coast 2 Coast"   # \\<pi>\roms\windows\OutRun2006 Coast 2 Coast
GAME_EXE="OR2006C2C_PATCHED.EXE"   # exactly as spelled on disk (Box64 settings
                                   # match it). Made by outrun-lockfix.py from
                                   # OR2006C2C.EXE - see the top of this script

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/outrun"
LOG_FILE="$GAME_DIR/outrun-launch.log"

# ----- Display ----------------------------------------------------------------
# The game's render resolution - written into outrun2006.ini on every launch.
# The shape of GAME_RES is the shape on the TV (the zoom always keeps it).
#
# 4:3 - everything the right shape, black side bars (as the Xbox original):
#    800x600  = lightest
#   1024x768  = sharper - the default
#   1280x960  = sharpest
#
# 16:9 - fills the TV and the road view is wider, BUT the game itself
# stretches its menus, HUD, text and videos sideways to fit (its own
# limitation - OutRun2006Tweaks fixes that, if the exe supports it):
#    960x540, 1280x720, 1600x900, 1920x1080 (heaviest)
GAME_RES="960x540"
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop size
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=1               # 1 = no X pointer (gamepad play); 0 = show it

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=0             # 1 = the game decides (Mesa's default). The game is built
                    #     around 60 fps with V-sync on - keep 1
                    # 0 = force off: may tear, and the game may run too fast
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If car handling/physics act oddly with 0, use 1
BIGBLOCK=2          # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code; empty = Box64's default (2).
                    #   3 = as 2, plus protection from random crashes (Box64
                    #   built 26 Oct 2026 or later - check: box64 --version)
                    #   Can crash some games - try 3, then 0
STRONGMEM=0         # Box64 memory ordering 0-3; empty = Box64's default (0).
                    #   The crashes/black screens it was set for were the
                    #   loading-queue bug (fixed by OR2006C2C_PATCHED.EXE).
                    #   1 = safe choice; try empty (faster) once the patched
                    #   exe has proved reliable
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
VIDEO_MEM_MB=1536   # VRAM reported to the game (keep below 2048)
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE
                    #     (only if new problems appear - big log, slower)

# ----- Sound mixer ------------------------------------------------------------
# 0 = the game plays straight to the Pi's HDMI sound through ALSA. The HDMI
#     sound only starts when the game opens it, so the TV may drop the first
#     moment of sound while it locks on (a short gap just after the start).
# 1 = a private PulseAudio just for this game that
#     mixes everything into one stream to the TV. Its HDMI stream runs from
#     before the game starts - no gap.
# 2 = the same with ALSA only (as SeriousSam.sh / lemmings.sh): dmix ->
#     loopback -> alsaloop -> HDMI. alsaloop keeps the HDMI stream running
#     from before the game starts (silence until it plays), so no gap
#     either. Needs alsa-utils (alsaloop) and the snd-aloop module (loaded
#     by the script).
# 1 and 2 also mix the intro videos' sound with the game's.
# ES and emulators keep using plain ALSA in every case.
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1

# ----- OutRun2006Tweaks -------------------------------------------------------
# auto = use it if its dinput8.dll is in the game folder
# 0    = never (Wine's own dinput8, even if the file is there)
TWEAKS=auto

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
# OutRun2006Tweaks loads as dinput8.dll from the game folder
TWEAKS_ON=0
if [ "$TWEAKS" = "auto" ] && [ -n "$(find "$GAME_DIR" -maxdepth 1 -iname 'dinput8.dll' 2>/dev/null)" ]; then
    TWEAKS_ON=1
    export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;dinput8=n,b"
fi

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

GW=${GAME_RES%x*};   GH=${GAME_RES#*x}
NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# The script's display settings into outrun2006.ini (no Wine needed):
#   DX/RES/WIDTH, DX/RES/HEIGHT = GAME_RES
#   DX/WINDOWED     = 0  full screen (inside the Wine desktop - zoomed as usual)
#   DX/ANTIALIASING = 0  off - always: levels 1 and 2 both gave "The Direct3D
#                        device is not currently available" at start-up
# Written every launch, so a line missing from the file can't be filled in
# by OutRun2006Tweaks' own defaults (windowed, antialiasing 2).
# Only these lines are changed; everything else in the file is kept, as
# are its Windows (CRLF) line endings. Missing lines are added.
# Written as "KEY = value", spaces round the "=", the way the game's own
# lines are (LANGUAGE = 0): "DX/RES/WIDTH=1280" with no spaces was ignored -
# the game stayed at its default 640x480.
set_game_ini() {
    local ini eol="" kv key val
    ini="$(find "$GAME_DIR" -maxdepth 1 -iname 'outrun2006.ini' 2>/dev/null | head -n1)"
    if [ -z "$ini" ]; then
        ini="$GAME_DIR/outrun2006.ini"
        echo "WARNING: outrun2006.ini not found - creating one"
        : > "$ini"
    fi
    grep -q $'\r$' "$ini" && eol=$'\r'
    for kv in "DX/RES/WIDTH=$GW" "DX/RES/HEIGHT=$GH" "DX/WINDOWED=0" \
              "DX/ANTIALIASING=0"; do
        key="${kv%%=*}"; val="${kv#*=}"
        if grep -qiE "^[[:space:]]*$key[[:space:]]*=" "$ini"; then
            sed -i -E "s|^[[:space:]]*$key[[:space:]]*=[^\r]*|$key = $val|I" "$ini"
        else
            # (on a new line, even if the file's last line has no line ending)
            [ -s "$ini" ] && [ -n "$(tail -c1 "$ini")" ] && printf '%s\n' "$eol" >> "$ini"
            printf '%s = %s%s\n' "$key" "$val" "$eol" >> "$ini"
        fi
    done
    echo "Settings in $(basename "$ini"):"
    sed 's/\r$//; s/^/    /' "$ini"           # (the file as the game will read it)
}

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup outrun     # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/outrun-settings.reg" reg_old="$WINEPREFIX/outrun-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; Black Wine desktop (beside the zoomed game)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; Wine's sound output: PulseAudio (the private mixer) or ALSA - named, so
; Wine doesn't try PulseAudio first when it isn't running
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$([ "$SOUND_MIXER" = "1" ] && echo '"Audio"="pulse"' || echo '"Audio"="alsa"')

; OutRun 2006 is a 2006 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    import_reg "$reg_new" "$reg_old"

    set_game_ini
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1.
ZOOM_FB="$NATIVE_RES"

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES VSYNC=$VSYNC GLTHREAD=$GLTHREAD STRONGMEM=$STRONGMEM BIGBLOCK=$BIGBLOCK X87DOUBLE=$X87DOUBLE CALLRET=$CALLRET DYNACACHE=$DYNACACHE TWEAKS=$TWEAKS_ON SOUND_MIXER=$SOUND_MIXER"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=outrun-panels FOLLOW_HOLD_FULL=1 follow_window &      # (shared code)
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop=outrun,"$NATIVE_RES" "$GAME_EXE" &
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
    NOCURSOR=""; [ "$HIDE_CURSOR" = "1" ] && NOCURSOR="-nocursor"
    # shellcheck disable=SC2086
    start_x -quiet $NOCURSOR
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
display_output "no zoom"
# A fixed "monitor" the TV's full size. Wine checks screen modes against
# the monitor X reports, which otherwise follows the zoom - the game's
# resolution list could shrink, or GAME_RES be refused (as found with NFSU).
if [ -n "$OUTPUT" ]; then
    fixed_monitor outrun-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor - GAME_RES may be refused"
fi
# Start at GAME_RES straight away (black to black: nothing is drawn yet), in
# the top-left corner where Wine puts the game. Safe this early because of
# the fixed monitor above - the zoom can't change what Wine measures. The
# helper takes over from here.
START_GEO="$GW $GH 0 0"
echo "Starting zoom: $START_GEO"
# shellcheck disable=SC2086
zoom_to $START_GEO
xsetroot -solid black 2>/dev/null
start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows from the start)
# Keyboard to the game: with no window manager, X sends key presses to
# whatever is under the (hidden) pointer, which can miss the game. The
# keeper gives the focus to Wine's desktop whenever nothing has it (shared
# code).
focus_start explorer.exe "$GAME_EXE"
set_governor
sound_mixer_start outrun   # (shared code; SOUND_MIXER)
run_game
exit 0
