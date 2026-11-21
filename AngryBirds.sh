#!/bin/bash
# =============================================================================
#  Angry Birds (PC, OpenGL) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works (based on tanks.sh / SeriousSam.sh):
#   - OpenGL -> Wine's opengl32 -> Mesa on the Pi's GPU (no wined3d).
#   - Bare X, no window manager. The game runs in a Wine desktop of GAME_RES;
#     the TV stays at NATIVE_RES and the Pi's display hardware scales the
#     picture up (free - no GL work). GAME_RES is 16:9, so it fills the TV -
#     no black bars, no mouse fence needed.
#   - Set the game to FULL SCREEN once (its own settings menu) - it then
#     fills the Wine desktop exactly, and the game remembers it. In a window
#     it shows with Wine's title bar inside the desktop.
#   - Sound fix: the game has a start-up race - it starts its sound thread
#     BEFORE setting the "sound running" flag the thread checks first. If the
#     thread gets there first it quits at once, and the game is silent until
#     it's restarted (on Windows the main thread nearly always wins; under
#     Box64 + Wine often not). SOUND_PATCH=1 changes 23 bytes in
#     AngryBirds.exe so the thread waits for the flag instead of quitting
#     (it still checks it every loop, so the game stops its sound normally).
#     The original is kept as AngryBirds.exe.orig.
#   - Sound: through a private mixer just for this game (SOUND_MIXER). Wine
#     playing straight to the Pi's HDMI through ALSA found no sound format it
#     could use ("alsa_get_mix_format Didn't recognize any available ALSA
#     formats" in the log) - no sound at all. The mixer converts for it.
#     ES and emulators keep using plain ALSA.
#   - Registration: the game keeps it (encrypted) in settings.lua and
#     bi_data.lua in the prefix's AppData\Roaming\Rovio\Angry Birds - not in
#     the registry. Copies of the registered files are kept in REG_DIR and
#     put back whenever the prefix has none (a fresh install).
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards,
#     and registry settings are imported only when they change.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/AngryBirds.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\Angry Birds\angrybirds-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Angry Birds"  # \\<pi>\roms\windows\Angry Birds
GAME_EXE="AngryBirds.exe"   # exactly as spelled on disk (Box64 settings match it)

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/angrybirds"
LOG_FILE="$GAME_DIR/angrybirds-launch.log"

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop (what the game draws at, full screen). Keep it
# 16:9 so it fills the TV:
#   1280x720  = 1.5x scaled up, lightest on the GPU
#   1600x900  = 1.2x
#   1920x1080 = no scaling (sharpest, heaviest)
GAME_RES="1280x720"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
HIDE_CURSOR=0               # 1 = no X pointer; 0 = show it (the game is played
                            #     with the mouse - drag the slingshot)

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core (top-left)
VSYNC=1             # 1 = no tearing (forced in Mesa), 0 = off
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible (faster),
                    #   1 = always double precision (more accurate), 2 = follows the
                    #   game's own precision setting; empty = Box64's default (0).
                    #   If physics/movement act oddly with 0, use 1
BIGBLOCK=           # Box64 code block size 0-3 (bigger = less translating);
                    #   empty = Box64's default (2)
CALLRET=            # Box64 call/ret optimisation (faster): 0 = off, 1 = on,
                    #   2 = on, also for changed code; empty = Box64's default (2).
                    #   3 = as 2, plus protection from random crashes (Box64
                    #   built 26 Oct 2026 or later - check: box64 --version)
                    #   Can crash some games - try 3, then 0
STRONGMEM=          # Box64 memory ordering 0-3; empty = Box64's default (0).
                    #   1 if the game crashes or freezes at random
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=0   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
GLTHREAD=0          # Mesa's GL work on its own thread - try 1 if FPS_HUD=2 shows
                    #     one core at 100%
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter - try if
                    #     animation looks uneven
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (big log, slower start)

# ----- Sound mixer ------------------------------------------------------------
# 2 = a game-only ALSA mixer (dmix -> loopback -> alsaloop -> HDMI, as
#     "Prairie Dog Hunt Pro.sh") that mixes everything into one stream to
#     the TV.
# 1 = a private PulseAudio just for this game.
#     Intermittent "DirectSoundCreate8 failed" with this game: Box64 crashed
#     in PulseAudio's library (pa_context_new) as the game opened its sound,
#     leaving Wine no sound driver.
# 0 = straight to the Pi's HDMI through ALSA - NO SOUND in this game (Wine
#     finds no sound format the HDMI device takes).
# ES and emulators keep using plain ALSA whichever is set.
SOUND_MIXER=2
SOUND_PATCH=1               # 1 = patch AngryBirds.exe's sound start-up race (see the
                            #   top of this script) - without it the sound fails at
                            #   random. 0 = put the original exe back
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
PA_LATENCY_MS=60            # PulseAudio mixer: sound buffered between the game and
                            #   PulseAudio, ms ("" = PulseAudio's default). Raise
                            #   (e.g. 100) if the sound crackles

# ----- Registration (full version) --------------------------------------------
# The game saves its registration, encrypted, in settings.lua and bi_data.lua
# (AppData\Roaming\Rovio\Angry Birds in the prefix). The key can't be written
# in as text, so registered copies are kept in REG_DIR and copied into a
# fresh prefix (when it has no settings.lua yet). An existing prefix's
# files are never overwritten.
REG_DIR="$GAME_DIR/registration"    # \\<pi>\roms\windows\Angry Birds\registration
REG_FILES="settings.lua bi_data.lua"

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

export MESA_NO_ERROR=1                         # skip GL error checking
[ "$VSYNC" = "1" ] && export vblank_mode=3 || export vblank_mode=0   # 3 = always sync
[ "$GLTHREAD" = "1" ] && export mesa_glthread=true || export mesa_glthread=false

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging +loaddll   # (debug: + which DLLs load, e.g. the sound ones)

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

GW=${GAME_RES%x*}; GH=${GAME_RES#*x}

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup angrybirds     # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/angrybirds-settings.reg" reg_old="$WINEPREFIX/angrybirds-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Wine mustn't change the TV's screen mode, or react to the GPU scaling
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop (shows briefly before the game window)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"

; Software-mixed DirectSound (fixed hangs in mk4, quake2 and nfs6)
[HKEY_CURRENT_USER\\Software\\Wine\\DirectSound]
"HardwareAcceleration"="Emulation"

; Wine's sound output: PulseAudio (mixer 1), ALSA (mixer 2) or the default
[HKEY_CURRENT_USER\\Software\\Wine\\Drivers]
$(case "$SOUND_MIXER" in 1) echo '"Audio"="pulse"' ;; 2) echo '"Audio"="alsa"' ;; *) echo '"Audio"=-' ;; esac)
EOF
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

# TV stays at NATIVE_RES; the X screen is GAME_RES, scaled up to fill it
set_display() {
    display_output "no scaling" && scale_fixed "$GAME_RES"     # (shared code)
}

run_game() {
    cd "$GAME_DIR" || exit 1
    echo "=== $(date) === GAME_RES=$GAME_RES X screen=${FB_W}x${FB_H} VSYNC=$VSYNC GLTHREAD=$GLTHREAD BIGBLOCK=$BIGBLOCK X87DOUBLE=$X87DOUBLE CALLRET=$CALLRET STRONGMEM=$STRONGMEM DYNACACHE=$DYNACACHE RDTSC_1GHZ=$RDTSC_1GHZ SOUND_MIXER=$SOUND_MIXER"
    # Wine desktop the game's size: the game can't change the real screen mode
    wine explorer /desktop=angrybirds,"$GAME_RES" "$GAME_EXE" &
    # Back as soon as Wine has finished after the game closes (shared code)
    wait_for_game $! "$GAME_EXE"
}

cleanup() {
    stop_boot_log
    wineserver -k 2>/dev/null
    sound_mixer_stop
    restore_governor
}

# ----- Sound fix (SOUND_PATCH) -----
# File offset 0xDEB49 (address 004DF749), the start of the sound thread's
# loop: "flag not set yet -> quit" becomes "wait until the flag is set":
#   push ebx / push edi / x: cmp byte [esi+0xCC],0 / pause / je x / nops
# (the two pushes the original did after its check, so the loop and its end
# are unchanged). Only patched when the exe is the version it was made for
# (size and the original bytes checked).
sound_patch() {
    python3 - "$GAME_DIR/$GAME_EXE" "$SOUND_PATCH" <<'PY'
import os, shutil, sys
exe, want = sys.argv[1], sys.argv[2] == "1"
OFF, SIZE = 0xDEB49, 1830000
ORIG = bytes.fromhex("8a86cc00000084c00f842f01000053578da42400000000")
NEW  = bytes.fromhex("535780becc00000000f39074f590909090909090909090")
if os.path.getsize(exe) != SIZE:
    print("WARNING: sound patch not applied - AngryBirds.exe isn't the version it was made for (the sound may fail at random)")
    sys.exit(0)
with open(exe, "rb") as f:
    f.seek(OFF); cur = f.read(len(ORIG))
target = NEW if want else ORIG
if cur == target:
    print("Sound patch: " + ("on" if want else "off"))
elif cur in (ORIG, NEW):
    if want and not os.path.exists(exe + ".orig"):
        shutil.copy2(exe, exe + ".orig")
    with open(exe, "r+b") as f:
        f.seek(OFF); f.write(target)
    print("Sound patch: " + ("applied (original kept as AngryBirds.exe.orig)" if want else "removed (original bytes back)"))
else:
    print("WARNING: sound patch not applied - unexpected bytes in AngryBirds.exe (the sound may fail at random)")
PY
}

# ----- Registration (REG_DIR) -----
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
xset s off -dpms s noblank 2>/dev/null   # mouse-only play doesn't reset blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "$GW $GH 0 0" "$GAME_EXE"
set_governor
sound_mixer_start angrybirds "no sound in this game without one"   # (shared code; SOUND_MIXER)
run_game
exit 0
