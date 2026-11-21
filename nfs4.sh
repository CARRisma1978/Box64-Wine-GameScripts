#!/bin/bash
# =============================================================================
#  Need for Speed: Road Challenge / High Stakes (NFS4) - Wine (WOW64) + Box64
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#  SCRIPT VERSION: 24
#
#  Renderer (RENDERER below, written into nfs4.ini as ThrashDriver):
#    dx7    = Direct3D 7 -> Wine's wined3d -> OpenGL on the Pi's GPU, 32-bit colour
#    nglide = 3dfx (Glide) -> nGlide -> Direct3D 9 -> wined3d -> OpenGL, 16-bit
#
#  How it works:
#   - The game runs in a Wine desktop the TV's size. When it switches screen
#     mode (640x480 menus, the race resolution picked in its Options), Wine
#     shrinks the game's window to that size in the top-left corner.
#   - A helper watches the game's window and has the Pi's display hardware
#     zoom it to full TV height (4:3 -> black side bars), with black panels
#     over the rest of the desktop. The zoom costs no GL work.
#   - X reports a fixed TV-sized "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to (as found with NFSU).
#   - Pick an in-game resolution up to 1280x960. 1600x1200 gave a blank
#     screen (sound only) before the fixed monitor - untested since.
#   - Sound: through a game-only mixer (SOUND_MIXER below), so the game
#     re-opening its sound never finds the TV's HDMI sound busy.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfs4.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfs4\nfs4-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/nfs4"        # \\<pi>\roms\windows\nfs4
GAME_EXE="nfs4.exe"         # exactly as spelled on disk (Box64 settings match it)
GAME_INI="$GAME_DIR/nfs4.ini"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/nfs4"
LOG_FILE="$GAME_DIR/nfs4-launch.log"

# One of the folders in drivers\ (each keeps its own resolution list in the
# game's Options):  dx7 = 32-bit colour  |  nglide = 16-bit colour
# If selecting nGlide, disable Tripple Buffering in the game's options menu first.
RENDERER="dx7"

# nGlide settings exported from nGlide's configurator on Windows (only used by
# RENDERER="nglide"). Imported when the file changes; Resolution is forced to
# "By desktop" every launch.
NGLIDE_REG="$GAME_DIR/nglide.reg"

# ----- Display ----------------------------------------------------------------
NATIVE_RES="1920x1080"      # the TV's mode, and the Wine desktop's size
TV_RATE=""                  # "" = the TV's default rate, 30 = steady 30 fps
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
MOUSE_FENCE=1               # 1 = keep the mouse inside the game's picture. Without
                            #   it a fast move takes the pointer off the game's
                            #   window before it reaches the edge, and the game's
                            #   cursor stops short (the game only sees moves made
                            #   inside its window). 0 = off

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
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
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE
VSYNC_MODE=1        # Mesa vblank_mode: 1 = the game/nGlide decides, 0 = never sync
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter
                    #   0 or empty = off (Box64's default)

# ----- Sound mixer ------------------------------------------------------------
# 2 = a game-only ALSA mixer (as SeriousSam.sh / outrun.sh): dmix ->
#     loopback -> alsaloop -> HDMI. The HDMI sound stays open for the whole
#     game, so the game re-opening its sound device never finds it busy
#     (seen as "DSOUND_ReopenDevice ... 8889000a" in the log with 0). Needs
#     alsa-utils (alsaloop) and the snd-aloop module (loaded by the script).
# 1 = a private PulseAudio just for this game.
# 0 = straight to ALSA (as before).
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
# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# GL 3.3 for wined3d (V3D reports 3.1); wined3d has its own render thread
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export MESA_NO_ERROR=1
export mesa_glthread=false
export vblank_mode="$VSYNC_MODE"

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}

# ===================== Helpers =====================

# nglide.reg as REGEDIT4 text (UTF-16 exports converted)
nglide_body() {
    [ -f "$NGLIDE_REG" ] || return
    if [ "$(head -c2 "$NGLIDE_REG" | od -An -tx1 | tr -d ' \n')" = "fffe" ]; then
        iconv -f UTF-16 -t UTF-8 "$NGLIDE_REG"
    else
        cat "$NGLIDE_REG"
    fi | tr -d '\r' | grep -viE '^(REGEDIT4|Windows Registry Editor)'
}

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup nfs4      # (+ finishes a pending update after a new Wine)

    # Wine settings + nGlide's, in one import, only when something changed
    local reg_new="$WINEPREFIX/drive_c/nfs4-settings.reg" reg_old="$WINEPREFIX/nfs4-settings.applied"
    {
        cat <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU zoom
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="1024"

[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"

; Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$(case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac)

EOF
        nglide_body
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # nGlide Resolution = "By desktop" (1), edited straight in user.reg
    sed -i '/^\[Software\\\\Zeus Software\\\\nGlide2\]/I,/^\[/ s/^"Resolution"=".*"/"Resolution"="1"/' \
        "$WINEPREFIX/user.reg"

    # Renderer: ThrashDriver in nfs4.ini (keeps its Windows line endings)
    if [ -d "$GAME_DIR/drivers/$RENDERER" ] && grep -q '^ThrashDriver=' "$GAME_INI" 2>/dev/null; then
        sed -i "s|^ThrashDriver=[^[:cntrl:]]*|ThrashDriver=$RENDERER|" "$GAME_INI"
    else
        echo "WARNING: renderer '$RENDERER' not set (no drivers/$RENDERER or no ThrashDriver line in nfs4.ini)"
    fi
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1 (so e.g.
# 1440x1080 is still centred).
ZOOM_FB="$NATIVE_RES"

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === RENDERER=$RENDERER VSYNC_MODE=$VSYNC_MODE SOUND_MIXER=$SOUND_MIXER"
    if [ -n "$OUTPUT" ] && command -v xwininfo >/dev/null; then
        FOLLOW_PANELS=nfs4-panels FOLLOW_FENCE="$MOUSE_FENCE" follow_window &      # (shared code)
        WATCH_PID=$!
    else
        echo "WARNING: no display or xwininfo (sudo apt install x11-utils) - no zoom"
    fi
    wine explorer /desktop=nfs4,"$NATIVE_RES" "$GAME_EXE" &
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
    start_x -nocursor -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
display_output "no zoom"
# A fixed "monitor" the TV's full size. Wine checks screen modes against
# the monitor X reports, which otherwise follows the zoom (~853x480 in the
# 640x480 menus) - a bigger mode for a race could then be refused.
if [ -n "$OUTPUT" ]; then
    fixed_monitor nfs4-tv "$NATIVE_RES" \
        || echo "WARNING: could not set a fixed monitor"
fi
zoom_to "$NW" "$NH"                      # 1:1 until the game shows
xsetroot -solid black 2>/dev/null
start_boot_log "$NW $NH 0 0" "$GAME_EXE"
set_governor
sound_mixer_start nfs4   # (shared code; SOUND_MIXER)
run_game
exit 0