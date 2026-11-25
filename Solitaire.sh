#!/bin/bash
# =============================================================================
#  Solitaire (Windows XP sol.exe) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#  Needs cards.dll (from XP's System32) next to sol.exe.
#
#  How it works:
#   - sol.exe draws with plain GDI (no Direct3D/OpenGL), so there are no Mesa
#     or wined3d settings to tune - the only graphics work is the scaling.
#   - Bare X, no window manager. The Wine desktop is GAME_RES; the TV stays
#     at its normal mode and the Pi's display hardware scales the picture up
#     (free - no GL work). Solitaire starts maximised to fill the desktop.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/Solitaire.sh --kill
#
#  Log (overwritten each launch):
#      \\<pi>\roms\windows\Solitaire\solitaire-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="solitaire"         # short name: its Wine prefix
                            #   (~/wine-prefixes/solitaire) and log
# \\<pi>\roms\windows\Solitaire
GAME_DIR="$HOME/RetroPie/roms/windows/Solitaire"
GAME_EXE="sol.exe"          # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop (Solitaire's playing area). Keep it 16:9 so it
# fills the TV. Cards are a fixed size, so this sets how big they look:
#    960x540 = 2x zoom, large cards
#   1024x576 = 1.875x
#   1280x720 = 1.5x, more table space
#  1920x1080 = no scaling (small cards)
GAME_RES="960x540"
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (Solitaire is played with the mouse)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
                    # (Solitaire draws without OpenGL: no counter)
VSYNC=1             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    # (no OpenGL: makes no difference here)
X87DOUBLE=          # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
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
CPU_PERFORMANCE=1   # 1 = CPU governor 'performance' while playing
                    #   (needs passwordless sudo), 0 = left as it is
RDTSC_1GHZ=0        # 1 = steadier timing on the Pi's slow counter,
                    #   0 or empty = off (Box64's default)
DEBUG=0             # 1 = Wine/Box64 errors and crash details into the log
                    #   (big log, slower start)

# ----- Sound ------------------------------------------------------------------
SOUND_MIXER=1       # 0 = a game-only ALSA mixer: dmix -> loopback ->
                    #     alsaloop -> HDMI. The HDMI sound stays open for the
                    #     whole game, so no sound loses its start while the
                    #     TV's HDMI audio wakes up. Needs alsa-utils
                    #     (alsaloop) and snd-aloop (loaded by the script)
                    # 1 = straight to the Pi's HDMI sound through ALSA
                    # 2 = a private PulseAudio just for this game
                    # If the chosen mixer can't start: straight to HDMI (1).
                    # EmulationStation and the emulators always use plain ALSA.
                    # HDMI port, PulseAudio buffering: .scripts/settings.cfg
                    # (1 here: Solitaire has no sound - nothing to mix)

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
# cards=n,b: the game's own cards.dll if there, else Wine's
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;cards=n,b"

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# Box64's settings file (4 cores), DYNACACHE - shared code
box64_setup

# ===================== Helpers =====================

# Before X starts (from launch, shared code): cards.dll must be there, in
# any upper/lower case
check_game() {
    [ -n "$(find "$GAME_DIR" -maxdepth 1 -iname cards.dll -print -quit)" ] \
        || { echo "ERROR: cards.dll not found in $GAME_DIR"; sleep 5; exit 1; }
}

# The prefix (shared code), then the registry - imported only when it
# changes (each import is a full Box64 + Wine start-up)
setup_prefix() {
    prefix_setup
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg"
    local reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    { wine_base_reg; cat <<EOF
; Every program in this prefix runs in the Wine desktop "$GAME_ID"
; (GAME_RES), which the script starts first
[HKEY_CURRENT_USER\\Software\\Wine\\Explorer]
"Desktop"="$GAME_ID"

[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\\Desktops]
"$GAME_ID"="$GAME_RES"
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"
}

# Inside X (from launch, shared code)
in_x() {
    # The TV stays at its normal mode; the X screen is GAME_RES, scaled up
    # to fill it
    display_output "no scaling" && scale_fixed "$GAME_RES" topleft
    xsetroot -solid black 2>/dev/null
    start_boot_log "${GAME_RES%x*} ${GAME_RES#*x} 0 0" "$GAME_EXE"
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings
    # The Wine desktop first, started by the script (Box64 0.4.5 of
    # 2026-10-23: the desktop Wine starts on its own for "wine start" hung -
    # no window, back to ES). Then Solitaire into it, maximised: start.exe
    # straight from the shell (not via explorer), so Wine opens no console
    # window for it.
    wine explorer /desktop="$GAME_ID","$GAME_RES" &
    local desk_pid=$! i
    for (( i = 0; i < 60; i++ )); do               # its window: at most 30 s
        xwininfo -root -tree 2>/dev/null | grep -qiE 'wine desktop|\("explorer\.exe"' && break
        kill -0 "$desk_pid" 2>/dev/null || break
        sleep 0.5
    done
    wine start /max "$GAME_EXE"
    # The desktop stays open after the game, so Wine never finishes by
    # itself: back 2 seconds after Solitaire closes (shared code; the shared
    # cleanup then ends it)
    WINE_EXIT_WAIT=2 wait_for_game "$desk_pid" "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
