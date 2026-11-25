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
#     screen) to full TV height, centred (free - no GL work), with black
#     panels beside it and the mouse kept on the picture.
#   - X reports a fixed GAME_RES "monitor" to Wine, so the zoom never limits
#     the screen modes the game can switch to.
#   - The player profile's screen size is set to GAME_RES before and after
#     every session. Registry settings are imported in ONE go, and only when
#     they change.
#
#  Quit in game: F10 > Quit.   To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/starwarsgbs.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\starwarsgbs\starwarsgbs-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="starwarsgbs"       # short name: its Wine prefix
                            #   (~/wine-prefixes/starwarsgbs) and log
# \\<pi>\roms\windows\starwarsgbs\Game
GAME_DIR="$HOME/RetroPie/roms/windows/starwarsgbs/Game"
GAME_EXE="battlegrounds_cc.exe"   # Clone Campaigns (All-In-One Patch version) -
                                  # exactly as spelled on disk
# (in starwarsgbs, not Game)
LOG_FILE="$HOME/RetroPie/roms/windows/starwarsgbs/$GAME_ID-launch.log"

# Player profile - the game keeps its screen size here (not in the Wine
# prefix). Set to GAME_RES before and after every session.
PROFILE="$GAME_DIR/player.nf1"

# ----- Display ----------------------------------------------------------------
# The in-game resolution is fixed at 1280x720 by the widescreen patch (see
# "Environment" below) - there's nothing to set here for it.
TV_SIZED_SCREEN=1           # X screen kept at least the TV's size: the switch
                            # after the start-up messages is instant, so the
                            # intro video isn't cut short
INTRO_HOLD=10               # seconds the start zoom waits for the videos: the
                            # game's brief black 800x600 screen before them is
                            # ignored (no flick). Menus follow at most this
                            # late if the videos are skipped or missing.
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game is played with the mouse)
MOUSE_FENCE=1               # 1 = keep the mouse on the picture in the
                            #     videos / 800x600 menus (a click on the hidden
                            #     part of the desktop can lose the game's focus)
VIDEO_MEM_MB=512            # VRAM reported to the game

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If units/pathing act oddly with 0, use 1
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
                    # (try 1 if game speed/scrolling looks uneven)
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
# NOT a setting. The widescreen patch (wide_on.exe) replaced the game's
# "800x600" option with 1280x720, baked into its interface graphics
# (Data\wide0800.drs). The Wine desktop and X screen must be exactly this
# size: bigger (tested 1600x900, 1920x1080) gives a bigger window but the
# game still draws 1280x720 in its top-left corner, the rest magenta. The
# other menu sizes (1024x768, 1280x1024) are greyed out - Wine offers no
# screen mode bigger than its desktop.
GAME_RES="1280x720"
GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
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

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
; DirectDraw through OpenGL on the GPU, with wined3d's own render thread
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"renderer"="gl"
"csmt"=dword:00000001
"VideoMemorySize"="$VIDEO_MEM_MB"

; SWGB is a 2001 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Zooming (zoom_to) and the black panels beside the game, with the mouse
# fence (panels_start): shared code. The X screen is GAME_RES; the panels
# hide once the game fills it.
ZOOM_FB="$GAME_RES"

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

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the game's full size (Wine checks screen modes
    # against the monitor X reports, which otherwise follows the zoom -
    # ~1067x600 in the 800x600 menus - and a bigger mode could then be
    # refused), then straight to the intro videos' 640x480 screen (Wine puts
    # it in the top-left corner). (shared code)
    local rc=0
    zoom_start "$GAME_RES" 640 480 || rc=$?
    # If the zoom failed: the TV switched to GAME_RES instead (no zoom)
    if [ "$rc" = "2" ] && display_output; then
        echo "WARNING: switching the TV to $GAME_RES instead"
        xrandr --output "$OUTPUT" --mode "$GAME_RES"
        OUTPUT=""
        START_GEO="$GW $GH 0 0"
    fi
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows
                                                #   from the start)
    set_governor
    setup_prefix
    fix_profile_res
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings VIDEO_MEM_MB
    FOLLOW_FENCE="$MOUSE_FENCE" follow_start       # (shared code; starts
                                                   #   from START_GEO)
    # Wine desktop of GAME_RES: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
    fix_profile_res                 # a profile created this session is
                                    #   right next time
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
