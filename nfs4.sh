#!/bin/bash
# =============================================================================
#  Need for Speed: Road Challenge / High Stakes (NFS4) - Wine (WOW64) + Box64
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  The game's renderer (GAME_RENDERER below, written into nfs4.ini as
#  ThrashDriver):
#    dx7    = Direct3D 7 -> Wine's wined3d -> OpenGL on the Pi's GPU,
#             32-bit colour
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
#     the screen modes the game can switch to.
#   - Pick an in-game resolution up to 1280x960. 1600x1200 gave a blank
#     screen (sound only) before the fixed monitor - untested since.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/nfs4.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\nfs4\nfs4-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="nfs4"              # short name: its Wine prefix
                            #   (~/wine-prefixes/nfs4) and log
GAME_DIR="$HOME/RetroPie/roms/windows/nfs4"        # \\<pi>\roms\windows\nfs4
GAME_EXE="nfs4.exe"         # exactly as spelled on disk
GAME_INI="$GAME_DIR/nfs4.ini"

# ----- Display ----------------------------------------------------------------
# The Wine desktop is the TV's size (NATIVE_RES, .scripts/settings.cfg)
TV_RATE=""                  # "" = the TV's default rate, 30 = steady 30 fps
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (gamepad play)
MOUSE_FENCE=1               # 1 = keep the mouse inside the game's picture.
                            #   Without it a fast move takes the pointer off the
                            #   game's window before it reaches the edge, and
                            #   the game's cursor stops short (the game only
                            #   sees moves made inside its window). 0 = off

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (1 here: the game - or nGlide - decides)
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
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread

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
                    # (0 here: the HDMI sound stays open, so the game
                    #   re-opening its sound never finds it busy - seen as
                    #   "DSOUND_ReopenDevice ... 8889000a" in the log without
                    #   a mixer)

# ----- Renderer ---------------------------------------------------------------
# One of the folders in drivers\ (each keeps its own resolution list in the
# game's Options):  dx7 = 32-bit colour  |  nglide = 16-bit colour
# If selecting nGlide, disable Triple Buffering in the game's
# options menu first.
GAME_RENDERER="dx7"

# nGlide settings exported from nGlide's configurator on Windows (only used by
# GAME_RENDERER="nglide"). Imported when the file changes; Resolution is
# forced to "By desktop" every launch.
NGLIDE_REG="$GAME_DIR/nglide.reg"

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
# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

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

# The prefix (shared code), then the registry: Wine settings + nGlide's,
# in ONE import, only when it changes (each import is a full Box64 + Wine
# start-up). Then the renderer.
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    {
        wine_base_reg dsound
        cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="1024"

[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"

EOF
        nglide_body
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # nGlide Resolution = "By desktop" (1), edited straight in user.reg
    sed -i '/^\[Software\\\\Zeus Software\\\\nGlide2\]/I,/^\[/ s/^"Resolution"=".*"/"Resolution"="1"/' \
        "$WINEPREFIX/user.reg"

    # Renderer: ThrashDriver in nfs4.ini (keeps its Windows line endings)
    if [ -d "$GAME_DIR/drivers/$GAME_RENDERER" ] && grep -q '^ThrashDriver=' "$GAME_INI" 2>/dev/null; then
        sed -i "s|^ThrashDriver=[^[:cntrl:]]*|ThrashDriver=$GAME_RENDERER|" "$GAME_INI"
    else
        echo "WARNING: renderer '$GAME_RENDERER' not set (no drivers/$GAME_RENDERER or no ThrashDriver line in nfs4.ini)"
    fi
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1 (so e.g.
# 1440x1080 is still centred).
ZOOM_FB="$NATIVE_RES"

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - ~853x480 in
    # the 640x480 menus - and a bigger mode for a race could then be
    # refused), then 1:1 until the game shows (shared code)
    zoom_start "$NATIVE_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings GAME_RENDERER TV_RATE
    FOLLOW_FENCE="$MOUSE_FENCE" follow_start       # (shared code)
    # Wine desktop the TV's size: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
