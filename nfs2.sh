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
GAME_ID="nfs2"              # short name: its Wine prefix
                            #   (~/wine-prefixes/nfs2) and log
GAME_DIR="$HOME/RetroPie/roms/windows/nfs2"        # \\<pi>\roms\windows\nfs2
GAME_EXE="nfs2se.exe"       # exactly as spelled on disk - the OpenGL 2 build
                            # (faster here than nfs2se-gl1.exe)
CONF_TEMPLATE="$GAME_DIR/nfs2se.conf.template"

# ----- Display ----------------------------------------------------------------
# GAME_RES = the size NFSIISE renders at. The Wine desktop is the TV's 16:9
# shape at the same height (960x720 -> 1280x720); the game fills it full
# screen and centres its own picture, and the Pi's display hardware scales
# the whole thing up to the TV (free - no GL work).
#    960x720 = 720p height, 4:3 picture with black side bars (KEEP_ASPECT=1)
#   1280x720 = same 720p height; with KEEP_ASPECT=0 the picture fills 16:9
#    640x480 = lightest; try SCALE_FILTER="nearest" (set it here, or for
#              every game in .scripts/settings.cfg) for a sharp retro look
GAME_RES="960x720"
TV_SIZED_SCREEN=1           # X screen kept at least the TV's size: the switch
                            # after the start-up messages is instant, so the
                            # intro video isn't cut short
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game draws its own pointer)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (0 here: Mesa can't sync behind the game's back - the
                    #   game's own vsync is GAME_VSYNC below)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If car handling/physics act oddly with 0, use 1
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
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)

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
                    # (0 here: the HDMI sound stays open, which also gives the
                    #   intro videos better sound)

# ----- Game settings (forced into nfs2se.conf every launch) -------------------
GAME_VSYNC=0        # NFSIISE's own vsync: 0 = off (1 made graphics jerky and
                    # menus unresponsive), >1 = vsync plus a frame-rate cap
KEEP_ASPECT=1       # 1 = original 4:3 picture, 0 = stretch to fill GAME_RES
TEXTURE_FILTER=1    # 1 = smooth (linear) textures, 0 = blocky (nearest)
MENU_JOY_AXES=0     # 0 = gamepad sticks/triggers ignored in the menus (a
                    #     resting or drifting axis can fight the mouse on the
                    #     slider screens); 1 = sticks work in the menus

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
# Wine desktop: the TV's shape at the game's height. A plain scale with no
# offset, so the game's own centring puts the picture in the middle of the TV.
GW=${GAME_RES%x*}; GH=${GAME_RES#*x}
NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}
DH=$GH; DW=$(( (DH * NW + NH - 1) / NH ))
[ "$DW" -lt "$GW" ] && { DW=$GW; DH=$(( (DW * NH + NW - 1) / NW )); }
DESK_RES="${DW}x${DH}"

# OpenGL: no error checking - shared code (NFSIISE draws with OpenGL
# directly, not through wined3d: no 3.3 needed)
gl_setup

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# set_conf Key=Value... - sets them all in nfs2se.conf in one pass: an
# existing Key= line is changed (keeping a Windows line ending if it has
# one), a missing one is added at the end
set_conf() {
    local tmp="$CONF_FILE.tmp"
    awk -v list="$(printf '%s\n' "$@")" '
        BEGIN {
            n = split(list, kv, "\n")
            for (i = 1; i <= n; i++) {
                e = index(kv[i], "="); key[i] = substr(kv[i], 1, e - 1)
                val[key[i]] = substr(kv[i], e + 1)
            }
        }
        {
            cr = sub(/\r$/, ""); e = index($0, "="); k = substr($0, 1, e - 1)
            if (e && (k in val)) { $0 = k "=" val[k]; done[k] = 1 }
            print $0 (cr ? "\r" : "")
        }
        END { for (i = 1; i <= n; i++) if (!(key[i] in done)) print key[i] "=" val[key[i]] }
    ' "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE" \
        || { rm -f "$tmp"; echo "WARNING: could not update $CONF_FILE"; }
}

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then NFSIISE's
# settings
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    wine_base_reg > "$reg_new"
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
    set_conf StartInFullScreen=1 \
             VSync="$GAME_VSYNC" \
             FixedRenderingSize=0 \
             WindowSize="$GAME_RES" \
             KeepAspectRatio="$KEEP_ASPECT" \
             LinearTextureFiltering="$TEXTURE_FILTER" \
             JoystickDisableAxesInMenu="$(( 1 - MENU_JOY_AXES ))"
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the X screen is DESK_RES, scaled up
    # to fill it (if scaling fails: a desktop the TV's size)
    SCALE_FALLBACK=native
    display_output "no scaling" && scale_fixed "$DESK_RES" topleft && sleep 1
    xsetroot -solid black 2>/dev/null
    start_boot_log "${DESK_RES%x*} ${DESK_RES#*x} 0 0" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # Keyboard to the game: with no window manager, X sends key presses to
    # whatever is under the (hidden) pointer. The keeper gives the focus to
    # Wine's desktop whenever nothing has it (shared code; stopped by the
    # shared cleanup).
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings DESK_RES GAME_VSYNC KEEP_ASPECT
    # Back when the game has closed and all of Wine has finished
    wine explorer /desktop="$GAME_ID","$DESK_RES" "$GAME_EXE"
    wineserver -w
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
