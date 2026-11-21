#!/bin/bash
# =============================================================================
#  Star Wars Galactic Battlegrounds: Saga - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - DirectDraw (the 8-bit Genie engine) -> Wine's wined3d -> OpenGL on the
#     Pi's GPU (renderer "gl": the palette conversion runs on the GPU).
#   - The Wine desktop and the X screen are GAME_RES (1280x720 - fixed by
#     the widescreen patch). The game shows its 480x360 intro videos inside a
#     640x480 screen, and its 800x600 menus, in the desktop's top-left
#     corner. A helper watches the game's window and has the Pi's display
#     hardware zoom whatever is showing (for the videos, their 640x480
#     screen) to full TV height, centred (free - no GL work), with black panels beside
#     it and the mouse kept on the picture.
#   - X reports a fixed GAME_RES "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to (as found with NFSU).
#   - Prefix setup and the player-profile fix run BEFORE X starts, with Wine
#     fully stopped afterwards. Registry settings are imported in ONE go, and
#     only when they change.
#
#  Quit in game: F10 > Quit.   To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/starwarsgbs.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\starwarsgbs\starwarsgbs.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/starwarsgbs/Game"   # \\<pi>\roms\windows\starwarsgbs\Game
GAME_EXE="battlegrounds_cc.exe"   # Clone Campaigns (All-In-One Patch version) -
                                  # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/starwarsgbs"
LOG_FILE="$HOME/RetroPie/roms/windows/starwarsgbs/starwarsgbs.log"

# Player profile - the game keeps its screen size here (not in the Wine
# prefix). Set to GAME_RES before and after every session.
PROFILE="$GAME_DIR/player.nf1"

# ----- Display ----------------------------------------------------------------
# The in-game resolution is fixed at 1280x720 by the widescreen patch (see
# "Environment" below) - there's nothing to set here for it.
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
TV_SIZED_SCREEN=1           # X screen kept at least the TV's size: the switch
                            # after the start-up messages is instant, so the
                            # intro video isn't cut short
INTRO_HOLD=10               # seconds the start zoom waits for the videos: the
                            # game's brief black 800x600 screen before them is
                            # ignored (no flick). Menus follow at most this
                            # late if the videos are skipped or missing.
FENCE_POINTER=1             # 1 = keep the mouse on the picture in the
                            #     videos / 800x600 menus (a click on the hidden
                            #     part of the desktop can lose the game's focus)

WINE_RENDERER="gl"          # gl  = DirectDraw through OpenGL on the GPU
                            # gdi = DirectDraw on the CPU (as tanks.sh) - try if
                            #       gl shows glitches
CSMT=1                      # wined3d's own render thread: 1 = on (Wine's default)
                            # 0 = off (as tanks.sh) - try if scrolling stutters
VIDEO_MEM_MB=512            # VRAM reported to the game

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = the game decides (Mesa's default)
                    # 0 = force off: smoother below 60 fps, may tear
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If units/pathing act oddly with 0, use 1
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
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
STRONGMEM=0         # Box64 memory ordering 0-3: try 1 if you see random crashes
                    #     or freezes (slower)
                    #   0 or empty = off (Box64's default)
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     game speed/scrolling looks uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (big log, slower)

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
SOUND_MIXER=2
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
# NOT a setting. The widescreen patch (wide_on.exe) replaced the game's
# "800x600" option with 1280x720, baked into its interface graphics
# (Data\wide0800.drs). The Wine desktop and X screen must be exactly this
# size: bigger (tested 1600x900, 1920x1080) gives a bigger window but the
# game still draws 1280x720 in its top-left corner, the rest magenta. The
# other menu sizes (1024x768, 1280x1024) are greyed out - Wine offers no
# screen mode bigger than its desktop.
GAME_RES="1280x720"
GW=${GAME_RES%x*}; GH=${GAME_RES#*x}
NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# GL 3.3 for wined3d (V3D reports 3.1); wined3d has its own render thread,
# so Mesa's is off
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

# ===================== Helpers =====================

# Set the screen size stored in the player profile (a compressed file) to
# GAME_RES. Only touches it if the layout is recognised. No Wine needed.
fix_profile_res() {
    [ -f "$PROFILE" ] || return
    command -v python3 >/dev/null || { echo "WARNING: python3 not found - profile not checked"; return; }
    python3 -I - "$PROFILE" "$GW" "$GH" <<'EOF'
import sys, zlib, struct
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = bytearray(zlib.decompress(open(path, 'rb').read(), -15))
pos = len(data) - 12                      # screen width/height near the end
cw, ch = struct.unpack_from('<HH', data, pos)
if not (640 <= cw <= 3840 and 480 <= ch <= 2160):
    sys.exit("Profile layout not recognised - left unchanged")
if (cw, ch) != (w, h):
    struct.pack_into('<HH', data, pos, w, h)
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    open(path, 'wb').write(z.compress(bytes(data)) + z.flush())
    print(f"Profile screen size {cw}x{ch} -> {w}x{h}")
EOF
}

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup swgb      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (the old
    # script's 4 "reg add" calls were 4 Box64 + Wine start-ups)
    local reg_new="$WINEPREFIX/drive_c/swgb-settings.reg" reg_old="$WINEPREFIX/swgb-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; DirectDraw renderer ("gl" = GPU, "gdi" = CPU) and wined3d's render thread
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="$WINE_RENDERER"
"csmt"=dword:0000000$CSMT
"VideoMemorySize"="$VIDEO_MEM_MB"

; Black Wine desktop (beside the zoomed menus)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; SWGB is a 2001 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac
    } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to) and the black panels beside the game, with the mouse
# fence (panels_start): shared code. The X screen is GAME_RES; the panels
# hide once the game fills it.
ZOOM_FB="$GAME_RES"

set_display() {
    display_output "no zoom" || return
    # A fixed "monitor" the game's full size. Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom (~1067x600 in
    # the 800x600 menus) - a bigger mode could then be refused.
    fixed_monitor swgb-tv "$GAME_RES" \
        || echo "WARNING: could not set a fixed monitor"
    # Start at the intro videos' 640x480 screen straight away (black to
    # black: nothing is drawn yet - Wine puts it in the top-left corner).
    # With BOOT_LOG=1, start at the whole GAME_RES instead: the start-up
    # messages show there (at their usual size - the video zoom would enlarge
    # them), and their black cover hides the switch to the video zoom.
    START_GEO="640 480 0 0"
    [ "$BOOT_LOG" = "1" ] && START_GEO="$GW $GH 0 0"
    echo "Starting zoom: $START_GEO"
    # shellcheck disable=SC2086
    if ! zoom_to $START_GEO; then
        echo "WARNING: GPU scaling failed - switching the TV to $GAME_RES instead (no zoom)"
        xrandr --output "$OUTPUT" --mode "$GAME_RES"
        OUTPUT=""
    fi
}

# The game's window, followed by the shared follow_window (the 640x480
# video screen, the 800x600 menus, GAME_RES in game). It starts from the
# video zoom set when X started (START_GEO), and holds it until the videos
# appear (up to INTRO_HOLD seconds after the game's first window).
INTRO=1; INTRO_T0=""
follow_window_map() {           # ($1 $2 = the window's size)
    [ -n "$INTRO_T0" ] || INTRO_T0=$SECONDS
    if [ "$1" = "640" ] && [ "$2" = "480" ]; then
        INTRO=0                 # the videos
    elif [ "$INTRO" = "1" ]; then
        if (( SECONDS - INTRO_T0 < INTRO_HOLD )); then FOLLOW_GEO=""; return; fi
        INTRO=0
    fi
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES RENDERER=$WINE_RENDERER CSMT=$CSMT VSYNC=$VSYNC BIGBLOCK=$BIGBLOCK CALLRET=$CALLRET STRONGMEM=$STRONGMEM"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=swgb-panels FOLLOW_FENCE="$FENCE_POINTER" \
            follow_window &              # (shared code; starts from START_GEO)
        WATCH_PID=$!
    else
        echo "WARNING: no display/zoom or no xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    # Wine desktop of GAME_RES: the game can't change the real screen mode
    wine explorer /desktop=swgb,"$GAME_RES" "$GAME_EXE" &
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
    # From EmulationStation: prefix setup and profile fix first (no X
    # needed), then X just for the game, on ES's console, so it exits
    # cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    {
        setup_prefix
        fix_profile_res
    } >> "$LOG_FILE" 2>&1
    start_x -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    fix_profile_res >> "$LOG_FILE" 2>&1   # a profile created this session is right next time
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # long think = no screen blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows from the start)
set_governor
sound_mixer_start swgb   # (shared code; SOUND_MIXER)
run_game
exit 0