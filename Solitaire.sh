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
#     at NATIVE_RES and the Pi's display hardware scales the picture up
#     (free - no GL work). Solitaire starts maximised to fill the desktop.
#   - Prefix setup runs BEFORE X starts, with Wine fully stopped afterwards,
#     and registry settings are imported only when they change.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/Solitaire.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\Solitaire\sol-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/Solitaire"   # \\<pi>\roms\windows\Solitaire
GAME_EXE="sol.exe"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/solitaire"
LOG_FILE="$GAME_DIR/sol-launch.log"

# ----- Display ----------------------------------------------------------------
# GAME_RES = the Wine desktop (Solitaire's playing area). Keep it 16:9 so it
# fills the TV. Cards are a fixed size, so this sets how big they look:
#    960x540 = 2x zoom, large cards
#   1024x576 = 1.875x
#   1280x720 = 1.5x, more table space
#  1920x1080 = no scaling (small cards)
GAME_RES="960x540"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth (nearest gave a vertical grain on
                            # the green table on this TV), nearest = sharp

# ----- Performance / looks (1 = on, 0 = off) ----------------------------------
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
DYNACACHE=          # Box64 keeps translated code on disk (quicker starts and loading):
                    #   empty = on, one cache shared by all games (~/.cache/box64)
                    #   1 = on, this game's own cache (box64-cache in its prefix)
                    #   0 = off
CPU_PERFORMANCE=1   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
DEBUG=0             # 1 = Wine/Box64 errors into LOG_FILE (big log, slower start)

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
# cards=n,b: the game's own cards.dll if there, else Wine's
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;cards=n,b"

# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging
box64_setup                             # Box64's settings file (4 cores) - shared code

# ===================== Helpers =====================

# Runs before X, with Wine fully stopped afterwards
setup_prefix() {
    prefix_setup sol      # (+ finishes a pending update after a new Wine)

    # All settings in ONE import, only when something changed (each import
    # is a full Box64 + Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/sol-settings.reg" reg_old="$WINEPREFIX/sol-settings.applied"
    cat > "$reg_new" <<EOF
REGEDIT4

; Every program in this prefix runs in the Wine desktop "solitaire"
; (GAME_RES), which the script starts first
[HKEY_CURRENT_USER\\Software\\Wine\\Explorer]
"Desktop"="solitaire"

[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\\Desktops]
"solitaire"="$GAME_RES"

; Wine mustn't change the TV's screen mode, or react to the GPU scaling
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"

; Black Wine desktop (shows briefly before the game window)
[HKEY_CURRENT_USER\\Control Panel\\Colors]
"Background"="0 0 0"
EOF
    import_reg "$reg_new" "$reg_old"
}

# TV stays at NATIVE_RES; the X screen is GAME_RES, scaled up to fill it
set_display() {
    display_output "no scaling" && scale_fixed "$GAME_RES" topleft     # (shared code)
}

cleanup() {
    stop_boot_log
    wineserver -k 2>/dev/null
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
    [ -n "$(find "$GAME_DIR" -maxdepth 1 -iname cards.dll -print -quit)" ] \
        || { echo "ERROR: cards.dll not found in $GAME_DIR"; sleep 5; exit 1; }
    : > "$LOG_FILE"
    setup_prefix >> "$LOG_FILE" 2>&1
    start_x -quiet
    wineserver -k 2>/dev/null       # make sure nothing is left running
    exit 0
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null   # long think = no screen blanking
set_display
xsetroot -solid black 2>/dev/null
start_boot_log "${GAME_RES%x*} ${GAME_RES#*x} 0 0" "$GAME_EXE"
set_governor

cd "$GAME_DIR" || exit 1
echo "=== $(date) === GAME_RES=$GAME_RES SCALE_FILTER=$SCALE_FILTER"
# The Wine desktop first, started by the script (Box64 0.4.5 of 2026-10-23:
# the desktop Wine starts on its own for "wine start" hung - no window,
# back to ES). Then Solitaire into it, maximised: start.exe straight from
# the shell (not via explorer), so Wine opens no console window for it.
wine explorer /desktop=solitaire,"$GAME_RES" &
DESK_PID=$!
for (( i = 0; i < 60; i++ )); do                   # its window: at most 30 s
    xwininfo -root -tree 2>/dev/null | grep -qiE 'wine desktop|\("explorer\.exe"' && break
    kill -0 "$DESK_PID" 2>/dev/null || break
    sleep 0.5
done
wine start /max "$GAME_EXE"
# The desktop stays open after the game, so Wine never finishes by itself:
# back 2 seconds after Solitaire closes (shared code; cleanup then ends it)
WINE_EXIT_WAIT=2 wait_for_game "$DESK_PID" "$GAME_EXE"
exit 0