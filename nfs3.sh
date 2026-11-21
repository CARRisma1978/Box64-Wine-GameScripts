#!/bin/bash
#
# nfs3.sh — Launch Need for Speed 3: Hot Pursuit via the native ARM64
# recompiled build (motor-dev/nfs-recompiled static recompilation).
#
# Target: Raspberry Pi 5 (16GB) / RetroPie 4.8.12 / Bookworm Lite 64-bit
#
# This REPLACES the old Wine + Box64 launcher. The native build needs
# no Wine, no Box64, and no X server at all -- it talks to the display
# directly via SDL3's KMSDRM backend, exactly the way any other
# RetroPie emulator does. Everything the game needs (FEDATA, GAMEDATA,
# install.win, and the nfs3hp binary itself) lives together in the
# nfs3/ subfolder next to this script, so nothing outside
# ~/RetroPie/roms/windows/nfs3 is required to play.
#
# Install: copy this file to ~/RetroPie/roms/windows/nfs3.sh
# (overwriting the old launch-nfs3.sh-based version), then:
#   chmod +x ~/RetroPie/roms/windows/nfs3.sh
#
# gamelist.xml should keep pointing at this same path/filename, so no
# changes are needed there.

set -uo pipefail

GAME_DIR="$HOME/RetroPie/roms/windows/nfs3"
BINARY="$GAME_DIR/nfs3hp"
# LOG_FILE="$GAME_DIR/nfs3-launch.log"   # \\<pi>\roms\windows\nfs3\nfs3-launch.log
                                         # (overwritten each launch). Log off:
                                         # LOG_FILE="" or this line commented
                                         # out (#) - remove the # to turn it on

# ============================================================
#  SANITY CHECKS
# ============================================================

if [ ! -d "$GAME_DIR" ]; then
    echo "Error: game folder not found at $GAME_DIR" >&2
    exit 1
fi

# Everything from here on (messages, errors, the game's own output) goes
# into the log - the game folder exists now, so it can be written
if [ -n "${LOG_FILE:-}" ]; then          # (unset = no log)
    exec > "$LOG_FILE" 2>&1
fi
echo "=== $(date) === Starting nfs3hp"

if [ ! -e "$BINARY" ]; then
    echo "Error: nfs3hp not found at $BINARY" >&2
    echo "Build it in the nfs-recompiled tree and copy it in with:" >&2
    echo "  cp build/nfs3hp \"$GAME_DIR/\"" >&2
    exit 1
fi

# The binary can lose its execute bit when it is restored from a backup
# or copied over from a PC / FAT / exFAT drive / network share. Restore
# it automatically rather than failing.
if [ ! -x "$BINARY" ]; then
    chmod +x "$BINARY" 2>/dev/null
    if [ ! -x "$BINARY" ]; then
        echo "Error: nfs3hp is not executable and chmod +x failed at $BINARY" >&2
        echo "(If the folder is on a FAT/exFAT drive, copy it to the Pi's own SD card/SSD.)" >&2
        exit 1
    fi
fi

# ============================================================
#  LAUNCH THE GAME
#
#  Must run with the game folder as the working directory -- nfs3hp
#  reads all its data (GAMEDATA, FEDATA, install.win, ...) via
#  relative paths from wherever it's launched.
# ============================================================

cd "$GAME_DIR" || exit 1
./nfs3hp
rc=$?
echo "=== $(date) === nfs3hp ended (exit code $rc)"
exit "$rc"
