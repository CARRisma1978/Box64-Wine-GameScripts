#!/bin/bash
# =============================================================================
#  Lemmings (Windows) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Bare X, no window manager, no Wine desktop. The X screen is a 16:9
#     area GAME_RES high; the TV mode never changes.
#   - The game's window is followed and the Pi's GPU zooms it to fill the
#     TV, with the mouse pointer fenced onto it (shared code). A small helper
#     presses OK on the game's start-up "colour display" warning (harmless -
#     X can't do 256 colours), maximises the window and gives dialogs the
#     keyboard.
#   - Sound: the game's sound effects and FluidSynth's MIDI music are mixed
#     by ALSA (dmix -> loopback -> alsaloop -> HDMI), as the Pi's HDMI only
#     plays one stream at a time. ES and emulators are untouched.
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/lemmings.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\lemmings\lemmings-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_DIR="$HOME/RetroPie/roms/windows/lemmings"     # \\<pi>\roms\windows\lemmings
GAME_EXE="LEMMINGS.EXE"

WINE_DIR="$HOME/wine-wow64/wine/bin"
WINE_BIN="$WINE_DIR/wine"
WINESERVER_BIN="$WINE_DIR/wineserver"
BOX64_BIN="$(command -v box64 || echo /usr/local/bin/box64)"

export WINEPREFIX="$HOME/wine-prefixes/lemmings"
LOG_FILE="$GAME_DIR/lemmings-launch.log"

# ----- Display ----------------------------------------------------------------
# The game's own setting: Low resolution = 640x480, High = 800x600
GAME_RES="800x600"
NATIVE_RES="1920x1080"      # the TV's normal mode
SCALE_FILTER="bilinear"     # bilinear = smooth, nearest = sharp/blocky
MAXIMISE=1                  # 1 = maximise the game window (wider view of the
                            # level, fills the TV's width - not stretched)

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
CPU_PERFORMANCE=0   # CPU governor 'performance' while playing (needs passwordless sudo)
BOOT_LOG=1          # 1 = start-up messages on screen (what Box64 and Wine are
                    #     loading), then black until the game is ready. Also
                    #     kept in LOG_FILE. 0 = black screen while starting
BOOT_LOG_FULL=0     # messages over the zoomed screen, not the whole TV at 1:1:
                    # no Wine desktop here, so the X screen must stay its size
DEBUG=0             # 1 = Wine/Box64 errors and crash details into LOG_FILE

# ----- Sound ------------------------------------------------------------------
HDMI_CARD="vc4hdmi0"        # vc4hdmi0 = HDMI port 0, vc4hdmi1 = port 1
SOUNDFONT="/usr/share/sounds/sf2/FluidR3_GM.sf2"
MIDI_GAIN=1

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
# Wine's and Box64's messages (DEBUG, BOOT_LOG, RDTSC_1GHZ) - shared code
wine_logging
box64_setup                             # Box64's settings file (4 cores) - shared code

NW=${NATIVE_RES%x*}; NH=${NATIVE_RES#*x}
# X screen: 16:9 at the game's height, plus a few pixels (xrandr rejects a
# zoom reaching even part of a pixel past the edge)
CANVAS_H=${GAME_RES#*x}
CANVAS_W=$(( (CANVAS_H * NW + NH - 1) / NH ))
FB_W=$((CANVAS_W + 4)); FB_H=$((CANVAS_H + 4))
# Zooming (zoom_to, shared code): the X screen is at least FB_W x FB_H, and
# always reaches the whole zoomed view
ZOOM_FB="${FB_W}x${FB_H}"
ZOOM_FB_VIEW=1

# ===================== Helpers =====================

# Runs before X
setup_prefix() {
    prefix_setup lemmings      # (+ finishes a pending update after a new Wine)
    # Imported only when something changes (each import is a full Box64 +
    # Wine start-up)
    local reg_new="$WINEPREFIX/drive_c/lemmings-settings.reg"
    local reg_old="$WINEPREFIX/lemmings-settings.applied"
    cat > "$reg_new" <<'EOF'
REGEDIT4

; Wine mustn't change the TV's screen mode. Managed=N: Wine draws the
; windows' own title bars (there's no window manager to do it), so the game
; window has its maximise button and can be maximised
[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"UseXRandR"="N"
"UseXVidMode"="N"
"Managed"="N"

[HKEY_CURRENT_USER\Software\Wine\Drivers]
"Audio"="alsa"
EOF
    import_reg "$reg_new" "$reg_old"
}

# ----- Sound -----------------------------------------------------------------
#  The game's sound effects and FluidSynth's music, mixed by ALSA (dmix ->
#  loopback -> alsaloop -> HDMI) - shared code.
start_sound() {
    alsa_mixer_start lem                # (exports ALSA_CONFIG_PATH for Wine)
    fluidsynth_start Lemmings
}

stop_sound() {
    fluidsynth_stop
    alsa_mixer_stop
}

# ----- Display ---------------------------------------------------------------
# The game's main window (500x300 or more) is followed by the shared
# follow_window (main, below): the Pi's GPU zooms it to fill the TV, black
# panels cover the rest, and the mouse pointer is fenced onto it. Maximised
# (MAXIMISE), the window hangs a few pixels off the X screen's edges - only
# the part on the screen is zoomed to (FOLLOW_CLIP: the X screen can't be
# resized mid-game - BadMatch).

# Background helper for the game's dialogs (one Python process, X11 via
# ctypes - nothing to install). Every 0.5s (0.25s for the first 20s):
#   - presses OK (Return) on the start-up "colour display" warning
#     (harmless - X can't do 256 colours)
#   - maximises the main window once (double-click on its title bar -
#     needs libXtst; the game remembers it, so normally only on the first
#     run of a new Wine prefix)
#   - gives a new dialog (e.g. "enter your name") the keyboard, and the
#     pointer if it's on the picture
dialog_helper() {
    python3 -I - lemmings-dialog-helper "$GAME_EXE" "$CANVAS_W" "$MAXIMISE" <<'EOF' &
import ctypes as c, ctypes.util, sys, time
_, exe, cw, maximise = sys.argv[1:5]
exe, cw = exe.lower().encode(), int(cw)

def lib(name, so):
    try:
        return c.CDLL(c.util.find_library(name) or so)
    except OSError:
        return None
x11 = lib("X11", "libX11.so.6")
xtst = lib("Xtst", "libXtst.so.6")        # pressing OK, maximising (optional)

class XWindowAttributes(c.Structure):
    _fields_ = [("x", c.c_int), ("y", c.c_int), ("width", c.c_int), ("height", c.c_int),
                ("border_width", c.c_int), ("depth", c.c_int), ("visual", c.c_void_p),
                ("root", c.c_ulong), ("class_", c.c_int), ("bit_gravity", c.c_int),
                ("win_gravity", c.c_int), ("backing_store", c.c_int),
                ("backing_planes", c.c_ulong), ("backing_pixel", c.c_ulong),
                ("save_under", c.c_int), ("colormap", c.c_ulong),
                ("map_installed", c.c_int), ("map_state", c.c_int),
                ("all_event_masks", c.c_long), ("your_event_mask", c.c_long),
                ("do_not_propagate_mask", c.c_long), ("override_redirect", c.c_int),
                ("screen", c.c_void_p)]
class XClassHint(c.Structure):
    _fields_ = [("res_name", c.c_void_p), ("res_class", c.c_void_p)]
W = c.c_ulong
I = c.POINTER(c.c_int)
x11.XOpenDisplay.restype = c.c_void_p
x11.XOpenDisplay.argtypes = [c.c_char_p]
x11.XDefaultRootWindow.restype = W
x11.XDefaultRootWindow.argtypes = [c.c_void_p]
x11.XQueryTree.argtypes = [c.c_void_p, W, c.POINTER(W), c.POINTER(W),
                           c.POINTER(c.POINTER(W)), c.POINTER(c.c_uint)]
x11.XGetWindowAttributes.argtypes = [c.c_void_p, W, c.POINTER(XWindowAttributes)]
x11.XGetClassHint.argtypes = [c.c_void_p, W, c.POINTER(XClassHint)]
x11.XTranslateCoordinates.argtypes = [c.c_void_p, W, W, c.c_int, c.c_int, I, I, c.POINTER(W)]
x11.XWarpPointer.argtypes = [c.c_void_p, W, W, c.c_int, c.c_int, c.c_uint, c.c_uint,
                             c.c_int, c.c_int]
x11.XFree.argtypes = [c.c_void_p]
x11.XFlush.argtypes = [c.c_void_p]
x11.XFetchName.argtypes = [c.c_void_p, W, c.POINTER(c.c_char_p)]
x11.XKeysymToKeycode.restype = c.c_ubyte
x11.XKeysymToKeycode.argtypes = [c.c_void_p, W]
x11.XSetInputFocus.argtypes = [c.c_void_p, W, c.c_int, W]
if xtst:
    xtst.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
    xtst.XTestFakeButtonEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
HANDLER = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)
ignore = HANDLER(lambda d, e: 0)       # windows can vanish mid-query - ignore
x11.XSetErrorHandler(ignore)

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit("dialog helper: cannot open X display")
root = x11.XDefaultRootWindow(dpy)

def children(w):
    r, p, ch, n = W(), W(), c.POINTER(W)(), c.c_uint()
    if not x11.XQueryTree(dpy, w, c.byref(r), c.byref(p), c.byref(ch), c.byref(n)):
        return []
    out = [ch[i] for i in range(n.value)]
    if ch:
        x11.XFree(ch)
    return out

def all_windows(w, depth=0):
    # Wine's windows aren't always direct children of the root window
    for ch in children(w):
        yield ch
        if depth < 3:
            yield from all_windows(ch, depth + 1)

def attrs(w):
    a = XWindowAttributes()
    return a if x11.XGetWindowAttributes(dpy, w, c.byref(a)) else None

def is_game(w):
    h = XClassHint()
    if not x11.XGetClassHint(dpy, w, c.byref(h)):
        return False
    name = c.string_at(h.res_name).lower() if h.res_name else b""
    for p in (h.res_name, h.res_class):
        if p:
            x11.XFree(p)
    return name == exe

def abs_pos(w):
    x, y, ch = c.c_int(), c.c_int(), W()
    x11.XTranslateCoordinates(dpy, w, root, 0, 0, c.byref(x), c.byref(y), c.byref(ch))
    return x.value, y.value

def title(w):
    p = c.c_char_p()
    if not x11.XFetchName(dpy, w, c.byref(p)) or not p.value:
        return b""
    t = p.value
    x11.XFree(p)
    return t

# Keyboard focus to window w. With no window manager X sends key presses to
# whatever is under the pointer; RevertToPointerRoot (1) goes back to that
# when w closes.
def focus(w):
    x11.XSetInputFocus(dpy, w, 1, 0)        # RevertToPointerRoot, CurrentTime
    x11.XFlush(dpy)

# A new dialog: pointer into its middle (the shared mouse fence puts it
# back if that's off the picture) and the keyboard to it
def focus_dialog(w, a):
    x, y = abs_pos(w)
    x11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0, x + a.width // 2, y + a.height // 2)
    focus(w)

# The start-up "colour display" warning: press Return on it
def press_ok(w):
    focus(w)
    time.sleep(0.2)
    k = x11.XKeysymToKeycode(dpy, 0xFF0D)   # Return
    xtst.XTestFakeKeyEvent(dpy, k, 1, 0)
    xtst.XTestFakeKeyEvent(dpy, k, 0, 0)
    x11.XFlush(dpy)

# Maximise the main window: double-click its title bar
def maximise_window(w, h, x, y):
    x11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0, x + w // 2, y + 12)
    x11.XFlush(dpy)
    time.sleep(0.2)
    for _ in range(2):
        xtst.XTestFakeButtonEvent(dpy, 1, 1, 0)
        xtst.XTestFakeButtonEvent(dpy, 1, 0, 0)
        x11.XFlush(dpy)
        time.sleep(0.05)

ok_done, start, seen = xtst is None, time.time(), set()
max_done = xtst is None or maximise != "1"
while True:
    time.sleep(0.25 if time.time() - start < 20 else 0.5)
    main, best, dialogs = None, 0, []
    for w in all_windows(root):
        a = attrs(w)
        if not a or a.map_state != 2 or a.width < 150 or a.height < 60 or not is_game(w):
            continue
        if a.width >= 500 and a.height >= 300:          # the main window
            if a.width * a.height > best:
                main, best = (a.width, a.height) + abs_pos(w), a.width * a.height
        elif w not in seen:                             # a new dialog
            seen.add(w)
            dialogs.append((w, a))
    for w, a in dialogs:
        if (not ok_done and time.time() - start < 60 and a.width < 500 and a.height < 250
                and title(w).upper() == b"WARNING"):
            time.sleep(0.5)
            press_ok(w)
        else:
            focus_dialog(w, a)
        ok_done = True
    if main:
        ok_done = True                       # main window up - no warning to close
        if not max_done:
            max_done = True
            if main[0] < cw - 16:            # narrower than the screen
                maximise_window(*main)
EOF
}

cleanup() {
    stop_boot_log
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    pkill -f lemmings-dialog-helper 2>/dev/null
    panels_stop
    wineserver -k 2>/dev/null
    restore_governor
}

# ===================== Main =====================
if [ "$1" = "--kill" ]; then
    kill_game                       # (shared code)
    exit 0
fi

if [ "$1" != "--in-x" ]; then
    # From EmulationStation: start X just for the game, on ES's console, so
    # it exits cleanly back to ES
    check_files "$GAME_DIR/$GAME_EXE"
    echo "=== $(date) ===" > "$LOG_FILE"
    {
        stop_wine                   # (shared code)
        setup_prefix
    } >> "$LOG_FILE" 2>&1

    trap stop_sound EXIT
    trap 'exit 1' INT TERM
    start_sound >> "$LOG_FILE" 2>&1

    start_x -quiet
    exit 0                              # (the EXIT trap stops the sound)
fi

# ----- Inside X -----
exec >> "$LOG_FILE" 2>&1
trap cleanup EXIT INT TERM
xset s off -dpms s noblank 2>/dev/null
xsetroot -solid black 2>/dev/null

if display_output "no zooming"; then
    zoom_to "$CANVAS_W" "$CANVAS_H" 0 0     # whole screen until the game shows
    if command -v xwininfo >/dev/null; then
        # The game's main window, followed (shared code - see Display above)
        START_GEO="$CANVAS_W $CANVAS_H 0 0" FOLLOW_PANELS=lemmings-panels FOLLOW_FENCE=1 \
            FOLLOW_CLIP="$CANVAS_W $CANVAS_H" follow_window 500 300 &
        WATCH_PID=$!
    else
        echo "WARNING: xwininfo not found (sudo apt install x11-utils) - no zoom"
    fi
fi
if command -v python3 >/dev/null; then
    dialog_helper
else
    echo "WARNING: python3 not found - start-up warning not closed, window not maximised"
fi
start_boot_log "$CANVAS_W $CANVAS_H 0 0" "$GAME_EXE"
set_governor

cd "$GAME_DIR" || exit 1
wine "$GAME_EXE"
exit 0