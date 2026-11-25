#!/bin/bash
# =============================================================================
#  Angry Birds (PC, OpenGL) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - OpenGL -> Wine's opengl32 -> Mesa on the Pi's GPU (no wined3d).
#   - Bare X, no window manager. The game runs in a Wine desktop of GAME_RES;
#     the TV stays at its normal mode and the Pi's display hardware scales
#     the picture up (free - no GL work). GAME_RES is 16:9, so it fills the
#     TV - no black bars, no mouse fence needed.
#   - Set the game to FULL SCREEN once (its own settings menu) - it then
#     fills the Wine desktop exactly, and the game remembers it. In a window
#     it shows with Wine's title bar inside the desktop.
#   - Sound fix: the game has a start-up race - it starts its sound thread
#     BEFORE setting the "sound running" flag the thread checks first. If the
#     thread gets there first it quits at once, and the game is silent until
#     it's restarted (on Windows the main thread nearly always wins; under
#     Box64 + Wine often not). The script changes 23 bytes in
#     AngryBirds.exe so the thread waits for the flag instead of quitting
#     (it still checks it every loop, so the game stops its sound normally).
#     The original is kept as AngryBirds.exe.orig.
#   - Sound: through the game-only ALSA mixer (SOUND_MIXER=0), which
#     converts the game's sound for the TV.
#   - Registration: the game keeps it (encrypted) in settings.lua and
#     bi_data.lua in the prefix's AppData\Roaming\Rovio\Angry Birds - not in
#     the registry. Copies of the registered files are kept in REG_DIR and
#     put back whenever the prefix has none (a fresh install).
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/AngryBirds.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\Angry Birds\angrybirds-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="angrybirds"        # short name: its Wine prefix
                            #   (~/wine-prefixes/angrybirds) and log
# \\<pi>\roms\windows\Angry Birds
GAME_DIR="$HOME/RetroPie/roms/windows/Angry Birds"
GAME_EXE="AngryBirds.exe"   # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop (what the game draws at, full screen). Keep it
# 16:9 so it fills the TV:
#   1280x720  = 1.5x scaled up, lightest on the GPU
#   1600x900  = 1.2x
#   1920x1080 = no scaling (sharpest, heaviest)
GAME_RES="1280x720"
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (the game is played with the mouse - drag the
                            #   slingshot)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=2             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    # If physics/movement act oddly with 0, use 1
BIGBLOCK=           # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code (3 = an extra for
                    #   LoongArch CPUs only, not the Pi); empty = Box64's
                    #   default (2). Can crash some games - if so, try 0
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and
                    #   loading): empty = on, one cache shared by all games
                    #   (~/.cache/box64); 1 = on, this game's own cache
                    #   (box64-cache in its prefix); 0 = off
CPU_PERFORMANCE=0   # 1 = CPU governor 'performance' while playing
                    #   (needs passwordless sudo), 0 = left as it is
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
                    # (try 1 if animation looks uneven)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)
GLTHREAD=0          # Mesa's GL work on its own thread - try 1 if FPS_HUD=2
                    #   shows one core at 100%

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
                    # (0 here: straight to HDMI (1) gives no sound in this
                    #   game - Wine finds no sound format the HDMI device
                    #   takes. With PulseAudio (2), Box64 crashed now and then
                    #   in PulseAudio's library as the game opened its sound:
                    #   "DirectSoundCreate8 failed")

# ----- Registration (full version) --------------------------------------------
# The game saves its registration, encrypted, in settings.lua and bi_data.lua
# (AppData\Roaming\Rovio\Angry Birds in the prefix). The key can't be written
# in as text, so registered copies are kept in REG_DIR and copied into a
# fresh prefix (when it has no settings.lua yet). An existing prefix's
# files are never overwritten.
# \\<pi>\roms\windows\Angry Birds\registration
REG_DIR="$GAME_DIR/registration"
REG_FILES="settings.lua bi_data.lua"

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
# OpenGL: no error checking, GLTHREAD - shared code
gl_setup

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging +loaddll   # (debug: + which DLLs load, e.g. the sound ones)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up) - then the
# registration files and the sound fix
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    wine_base_reg dsound > "$reg_new"
    import_reg "$reg_new" "$reg_old"
    registration_restore
    sound_patch

    # Sound libraries the game brought with it (in the log, to help if the
    # sound still doesn't work)
    local dlls
    dlls="$(find "$GAME_DIR" -maxdepth 2 -type f \( -iname 'openal32.dll' -o -iname 'wrap_oal.dll' \
            -o -iname 'fmod*.dll' -o -iname 'bass*.dll' -o -iname 'xaudio*.dll' \) -printf '%P ' 2>/dev/null)"
    echo "Sound DLLs in the game folder: ${dlls:-none}"
}

# ----- Sound fix --------------------------------------------------------------
# File offset 0xDEB49 (address 004DF749), the start of the sound thread's
# loop: "flag not set yet -> quit" becomes "wait until the flag is set":
#   push ebx / push edi / x: cmp byte [esi+0xCC],0 / pause / je x / nops
# (the two pushes the original did after its check, so the loop and its end
# are unchanged). Only patched when the exe is the version it was made for
# (size and the original bytes checked); the original is kept as
# AngryBirds.exe.orig.
sound_patch() {
    python3 - "$GAME_DIR/$GAME_EXE" <<'PY'
import os, shutil, sys
exe = sys.argv[1]
OFF, SIZE = 0xDEB49, 1830000
ORIG = bytes.fromhex("8a86cc00000084c00f842f01000053578da42400000000")
NEW  = bytes.fromhex("535780becc00000000f39074f590909090909090909090")
if os.path.getsize(exe) != SIZE:
    print("WARNING: sound patch not applied - AngryBirds.exe isn't the version it was made for (the sound may fail at random)")
    sys.exit(0)
with open(exe, "rb") as f:
    f.seek(OFF); cur = f.read(len(ORIG))
if cur == NEW:
    print("Sound patch: on")
elif cur == ORIG:
    if not os.path.exists(exe + ".orig"):
        shutil.copy2(exe, exe + ".orig")
    with open(exe, "r+b") as f:
        f.seek(OFF); f.write(NEW)
    print("Sound patch: applied (original kept as AngryBirds.exe.orig)")
else:
    print("WARNING: sound patch not applied - unexpected bytes in AngryBirds.exe (the sound may fail at random)")
PY
}

# ----- Registration (REG_DIR) -------------------------------------------------
# The game's AppData folder in the prefix (Wine names the user folder after
# the Linux user)
APPDATA_DIR="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Roaming/Rovio/Angry Birds"

# Fresh prefix (no settings.lua yet) + saved copies in REG_DIR -> copy them in
registration_restore() {
    local f
    [ -f "$APPDATA_DIR/settings.lua" ] && return 0
    if [ ! -f "$REG_DIR/settings.lua" ]; then
        echo "Registration: no saved copy in $REG_DIR - the game starts unregistered"
        return 0
    fi
    mkdir -p "$APPDATA_DIR"
    for f in $REG_FILES; do
        [ -f "$REG_DIR/$f" ] && cp "$REG_DIR/$f" "$APPDATA_DIR/$f"
    done
    echo "Registration: copied $REG_FILES from $REG_DIR into the fresh prefix"
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the X screen is GAME_RES, scaled up
    # to fill it
    display_output "no scaling" && scale_fixed "$GAME_RES"
    xsetroot -solid black 2>/dev/null
    start_boot_log "$GW $GH 0 0" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID" "no sound in this game without one"
    cd "$GAME_DIR" || exit 1
    log_settings
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop="$GAME_ID","$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
