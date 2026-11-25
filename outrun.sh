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
#  How it works:
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
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/outrun.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\OutRun2006 Coast 2 Coast\outrun-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="outrun"            # short name: its Wine prefix
                            #   (~/wine-prefixes/outrun) and log
# \\<pi>\roms\windows\OutRun2006 Coast 2 Coast
GAME_DIR="$HOME/RetroPie/roms/windows/OutRun2006 Coast 2 Coast"
GAME_EXE="OR2006C2C_PATCHED.EXE"   # exactly as spelled on disk. Made by
                                   # outrun-lockfix.py from OR2006C2C.EXE -
                                   # see the top of this script

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
HIDE_CURSOR=1               # 1 = no mouse pointer, 0 = pointer shown
                            #   (gamepad play)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=0             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (the game is built around 60 fps with vsync on: 1 lets
                    #   it decide; 0 may tear, and the game may run too fast)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If car handling/physics act oddly with 0, use 1
BIGBLOCK=2          # Box64 code block size 0-3 (bigger = less translating);
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
RDTSC_1GHZ=1        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL thread - usually no help, as wined3d already has
                    #   its own render thread. Try 1 if FPS_HUD=2 shows a second
                    #   core at 100%
VIDEO_MEM_MB=1536   # VRAM reported to the game (keep below 2048)

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
                    # (0 here also mixes the intro videos' sound with the
                    #   game's)

# ----- OutRun2006Tweaks -------------------------------------------------------
# auto = use it if its dinput8.dll is in the game folder
# 0    = never (Wine's own dinput8, even if the file is there)
TWEAKS=auto

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
# OutRun2006Tweaks loads as dinput8.dll from the game folder
TWEAKS_ON=0
if [ "$TWEAKS" = "auto" ] && [ -n "$(find "$GAME_DIR" -maxdepth 1 -iname 'dinput8.dll' 2>/dev/null)" ]; then
    TWEAKS_ON=1
    export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;dinput8=n,b"
fi

# OpenGL: report 3.3 (V3D: 3.1), no error checking, GLTHREAD - shared code
gl_setup gl33

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

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
        if grep -qiE "^[[:space:]]*${key}[[:space:]]*=" "$ini"; then
            sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=[^\r]*|$key = $val|I" "$ini"
        else
            # (on a new line, even if the file's last line has no line ending)
            [ -s "$ini" ] && [ -n "$(tail -c1 "$ini")" ] && printf '%s\n' "$eol" >> "$ini"
            printf '%s = %s%s\n' "$key" "$val" "$eol" >> "$ini"
        fi
    done
    echo "Settings in $(basename "$ini"):"
    sed 's/\r$//; s/^/    /' "$ini"           # (the file as the game
                                              #   will read it)
}

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then the game's
# own settings file
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg dsound; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
"VideoMemorySize"="$VIDEO_MEM_MB"

; OutRun 2006 is a 2006 game - report Windows XP to it
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    set_game_ini
}

# Zooming (zoom_to), the black panels beside the game (panels_start) and
# finding its window (find_window): shared code. The X screen stays the
# TV's size; only a window the TV's full size is shown 1:1.
ZOOM_FB="$NATIVE_RES"

# Inside X (from launch, shared code)
in_x() {
    # A fixed "monitor" the TV's full size (Wine checks screen modes against
    # the monitor X reports, which otherwise follows the zoom - the game's
    # resolution list could shrink, or GAME_RES be refused), then straight
    # to GAME_RES, in the top-left corner where Wine puts the game. The
    # helper takes over from there. (shared code)
    zoom_start "$NATIVE_RES" "$GW" "$GH"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"     # (the area the TV shows
                                                #   from the start)
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    # Keyboard to the game: with no window manager, X sends key presses to
    # whatever is under the (hidden) pointer, which can miss the game. The
    # keeper gives the focus to Wine's desktop whenever nothing has it
    # (shared code; stopped by the shared cleanup).
    focus_start explorer.exe "$GAME_EXE"
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings VIDEO_MEM_MB TWEAKS="$TWEAKS_ON"
    FOLLOW_HOLD_FULL=1 follow_start     # (shared code)
    # Wine desktop the size of the TV: the game can't change the real mode
    wine explorer /desktop="$GAME_ID","$NATIVE_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
