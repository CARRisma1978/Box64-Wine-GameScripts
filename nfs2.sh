#!/bin/bash
# =============================================================================
#  Need for Speed II: SE (NFSIISE v1.4.0) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  NFSIISE (github.com/zaps166/NFSIISE) is an open-source wrapper for the
#  original game, using SDL2 + OpenGL 2 (drawn on the Pi's GPU). It replaces
#  the original nfs2se.exe, which deadlocked under Wine + Box64.
#
#  NFSIISE's own settings (nfs2se.conf, inside the prefix) are set from the
#  "Game settings" below on EVERY launch - change them here, not in the file.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfs2.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfs2\nfs2-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/nfs2"        # \\<pi>\roms\windows\nfs2
GAME_EXE="nfs2se.exe"                              # OpenGL 2 build (faster here
                                                   # than nfs2se-gl1.exe)
CONF_TEMPLATE="$GAME_DIR/nfs2se.conf.template"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/nfs2"
LOG_FILE="$GAME_DIR/nfs2-launch.log"

# ----- Display ----------------------------------------------------------------
# GAME_RES = the size NFSIISE renders at. The Wine desktop is the TV's 16:9
# shape at the same height (960x720 -> 1280x720); the game fills it full
# screen and centres its own picture, and the Pi's display hardware scales
# the whole thing up to the TV (free - no GL work).
#    960x720 = 720p height, 4:3 picture with black side bars (KEEP_ASPECT=1)
#   1280x720 = same 720p height; with KEEP_ASPECT=0 the picture fills 16:9
#    640x480 = lightest; try SCALE_FILTER="nearest" for a sharp retro look
GAME_RES="960x720"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
TV_SIZED_SCREEN=1           # X screen kept at least the TV's size: the switch
                            # after the start-up messages is instant, so the
                            # intro video isn't cut short

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If car handling/physics act oddly with 0, use 1
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

# ----- Sound mixer ------------------------------------------------------------
# 1 = a private PulseAudio just for this game,
#     with a cushion of buffered sound so CPU spikes don't cause clicks, and
#     better intro-video sound.
# 2 = a game-only ALSA mixer instead (as SeriousSam.sh / outrun.sh): dmix ->
#     loopback -> alsaloop -> HDMI. Needs alsa-utils (alsaloop) and the
#     snd-aloop module (loaded by the script).
# 0 = straight to ALSA.
# If the chosen mixer can't start, plain ALSA is used.
# ES and emulators keep plain ALSA in every case.
SOUND_MIXER=2
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=60            # SOUND_MIXER=1: sound buffered between the game and
                            # PulseAudio: higher = safer from clicks, sound
                            # slightly later

# ----- Game settings (forced into nfs2se.conf every launch) -------------------
VSYNC=0             # 0 = off (1 made graphics jerky and menus unresponsive)
                    # >1 = vsync plus a frame-rate cap (NFSIISE option)
KEEP_ASPECT=1       # 1 = original 4:3 picture, 0 = stretch to fill GAME_RES
TEXTURE_FILTER=1    # 1 = smooth (linear) textures, 0 = blocky (nearest)
MENU_JOY_AXES=0     # 0 = gamepad sticks/triggers ignored in the menus (a
                    #     resting or drifting axis can fight the mouse on the
                    #     slider screens); 1 = sticks work in the menus

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
# Wine desktop: the TV's shape at the game's height. A plain scale with no
# offset, so the game's own centring puts the picture in the middle of the TV.
GW=${GAME_RES%x*}; GH=${GAME_RES#*x}
NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}
DH=$GH; DW=$(( (DH * NW + NH - 1) / NH ))
[ "$DW" -lt "$GW" ] && { DW=$GW; DH=$(( (DW * NH + NW - 1) / NW )); }
DESK_RES="${DW}x${DH}"

# NFSIISE draws with OpenGL directly (no wined3d), so no GL 3.3 override needed
export MESA_NO_ERROR=1                         # skip GL error checking
[ "$VSYNC" = "0" ]   && export vblank_mode=0   # Mesa can't sync behind the game's back

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# TV stays at NATIVE_RES; the X screen is DESK_RES, scaled up to fill it
set_display() {
    SCALE_FALLBACK=native           # (if scaling fails: a NATIVE_RES desktop)
    display_output "no scaling" || return
    scale_fixed "$DESK_RES" topleft                 # (shared code)
    sleep 1
}

# Set Key=Value in nfs2se.conf (keeps a Windows line ending if the file has them)
set_conf() {
    if grep -q "^$1=" "$CONF_FILE"; then
        sed -i "s|^$1=[^[:cntrl:]]*|$1=$2|" "$CONF_FILE"
    else
        echo "$1=$2" >> "$CONF_FILE"
    fi
}

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup nfs2      # (+ finishes a pending update after a new Wine)

    # Imported only when it changes (each import is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/nfs2-settings.reg" reg_old="$WINEPREFIX/nfs2-settings.applied"
    cat > "$reg_new" <<'EOF'
REGEDIT4

; Black Wine desktop; Wine mustn't change the real screen mode
[HKEY_CURRENT_USER\Control Panel\Colors]
"Background"="0 0 0"

[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"
EOF
    # Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default (ALSA)
    { echo; echo '[HKEY_CURRENT_USER\Software\Wine\Drivers]'
      case "$SOUND_MIXER" in
          1) echo '"Audio"="pulse"' ;;
          2) echo '"Audio"="alsa"' ;;
          *) echo '"Audio"=-' ;;
      esac; } >> "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # NFSIISE's config: created from the template if missing, settings forced.
    # FixedRenderingSize=0: the game draws straight to its window (no extra
    # off-screen copy every frame) - the Pi's display hardware does the scaling.
    local user_dir="$WINEPREFIX/drive_c/users/$USER"
    [ -d "$user_dir" ] || user_dir="$(find "$WINEPREFIX/drive_c/users" -mindepth 1 -maxdepth 1 \
                                       -type d ! -iname public | head -n1)"
    CONF_FILE="$user_dir/AppData/Roaming/.nfs2se/nfs2se.conf"
    if [ ! -f "$CONF_FILE" ]; then
        [ -f "$CONF_TEMPLATE" ] || { echo "WARNING: $CONF_TEMPLATE not found"; return; }
        mkdir -p "$(dirname "$CONF_FILE")"
        cp "$CONF_TEMPLATE" "$CONF_FILE"
        echo "Created $CONF_FILE from template"
    fi
    set_conf StartInFullScreen         1
    set_conf VSync                     "$VSYNC"
    set_conf FixedRenderingSize        0
    set_conf WindowSize                "$GAME_RES"
    set_conf KeepAspectRatio           "$KEEP_ASPECT"
    set_conf LinearTextureFiltering    "$TEXTURE_FILTER"
    set_conf JoystickDisableAxesInMenu "$(( 1 - MENU_JOY_AXES ))"
}

cleanup() {
    stop_boot_log
    wineserver -k 2>/dev/null
    focus_stop
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
    # it exits cleanly back to ES (no exec bit needed - runs via bash)
    check_files "$GAME_DIR/$GAME_EXE"
    : > "$LOG_FILE"
    setup_prefix >> "$LOG_FILE" 2>&1
    # -nocursor: no X pointer (the game draws its own)
    start_x -nocursor -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # gamepad input doesn't reset blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "${DESK_RES%x*} ${DESK_RES#*x} 0 0" "$GAME_EXE"
# Keyboard to the game: with no window manager, X sends key presses to
# whatever is under the (hidden) pointer. The keeper gives the focus to
# Wine's desktop whenever nothing has it (shared code - replaces Matchbox).
focus_start explorer.exe "$GAME_EXE"
set_governor
sound_mixer_start nfs2   # (shared code; SOUND_MIXER)

cd "$GAME_DIR" || exit 1
echo "=== $(date) === GAME_RES=$GAME_RES DESK_RES=$DESK_RES VSYNC=$VSYNC SOUND_MIXER=$SOUND_MIXER DEBUG=$DEBUG"
wine explorer /desktop=nfs2,"$DESK_RES" "$GAME_EXE"
wineserver -w
exit 0