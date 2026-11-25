#!/bin/bash
# =============================================================================
#  Half-Life (retail WON, not Steam) - Wine (WOW64) + Box64 launcher
#  Raspberry Pi 5 / RetroPie / Bookworm Lite 64-bit
#  Launch from EmulationStation (starts its own X session).
#
#  How it works:
#   - Bare X, no window manager, no Wine desktop. hl.exe runs windowed; its
#     windows are centred by the game on a 16:9 X screen.
#   - The menus are always 640x480 windows; the game itself is GAME_RES. A
#     helper watches which is on top and has the Pi's GPU zoom it to full TV
#     height (4:3, black side bars). The TV mode itself never changes.
#   - Direct3D is never used (GoldSrc's D3D path hangs the display here).
#
#  To close a stuck game over SSH:
#      bash ~/RetroPie/roms/windows/hl.sh --kill
#
#  Log (overwritten each launch): \\<pi>\roms\windows\half-life\hl-launch.log
# =============================================================================

# ===================== Settings =====================
GAME_ID="hl"                # short name: its Wine prefix
                            #   (~/wine-prefixes/hl) and log
# \\<pi>\roms\windows\half-life
GAME_DIR="$HOME/RetroPie/roms/windows/half-life"
GAME_EXE="hl.exe"           # exactly as spelled on disk

# ----- Display ----------------------------------------------------------------
# gl = OpenGL, soft = software renderer (set in the registry as EngineType).
# Set here - the in-game Video menu choice is overridden every launch
# (don't use that menu).
GAME_RENDERER="gl"
# The game's resolution - one of the game's own modes only (anything else
# falls back to 640x480):
#   640x480, 800x600, 1024x768, 1152x864, 1280x960  (soft: 640x480 is smoothest)
GAME_RES="1280x960"
HIDE_CURSOR=0               # 1 = no mouse pointer, 0 = pointer shown
                            #   (either way it's fenced into the picture - it
                            #   can't reach the black bars)

# ----- Performance ------------------------------------------------------------
FPS_HUD=0           # 0 = off, 1 = fps + total CPU, 2 = fps + each CPU core
                    #   (top-left; games drawn with OpenGL only)
VSYNC=2             # 0 = off (smoother below 60 fps, may tear)
                    # 1 = the game decides (Mesa's default)
                    # 2 = always on (no tearing)
                    #   (gl: HL never asks for vsync itself - 2 stops tearing)
X87DOUBLE=1         # Box64 x87 maths: 0 = lower precision where possible
                    #   (faster), 1 = always double precision (more accurate),
                    #   2 = follows the game's own precision setting;
                    #   empty = Box64's default (0)
                    #   If physics/movement act oddly with 0, use 1
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
BOOT_LOG_FULL=0     # start-up messages over the zoomed screen, not the whole
                    #   TV at 1:1: no Wine desktop here, so the X screen must
                    #   stay its size
FPS_MAX=72          # frame cap. With vsync on, the TV's 60 Hz paces the game;
                    # 72 keeps the cap out of the way (exactly 60 can stutter)
GLTHREAD=1          # gl: Mesa's GL work on its own thread
COMPOSITOR=1        # xcompmgr: stops flicker where the menus overlap the game
DYN_LIGHTS=1        # dynamic lights (muzzle flash, flashlight):
                    #   0 = off, saves CPU

# Game arguments. OpenGL only:
#   gl_ztrick 0     = no flickering walls (a 1998 depth trick that breaks on
#                     modern GL)
#   gl_texturemode  = trilinear filtering (smooth texture transitions)
EXTRA_ARGS="+r_dynamic $DYN_LIGHTS"
GL_ARGS="+gl_ztrick 0 +gl_texturemode GL_LINEAR_MIPMAP_LINEAR"

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

# CD key: put it on the first line of this file (just the key - with or
# without the dashes, e.g. 1234-56789-0123 or 1234567890123). It's imported
# into the registry once (again if it changes), so a new Wine prefix doesn't
# ask for it.
# Keep this file private - don't upload it to GitHub. No file = the game
# asks for the key as normal.
# \\<pi>\roms\windows\half-life\hl-cdkey.txt
CDKEY_FILE="$GAME_DIR/hl-cdkey.txt"

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
# Position of GAME_RES in the game's mode list - this ("EngineMode") is what
# really picks the resolution (0 = 320x240)
case "$GAME_RES" in
    640x480) MODE_IDX=3 ;; 800x600) MODE_IDX=4 ;; 1024x768) MODE_IDX=5 ;;
    1152x864) MODE_IDX=6 ;; 1280x960) MODE_IDX=7 ;;
    *) GAME_RES="640x480"; MODE_IDX=3 ;;
esac
GW=${GAME_RES%x*}; GH=${GAME_RES#*x}
# The launcher picks the engine from the registry: EngineType 2 = OpenGL,
# 0 = software
[ "$GAME_RENDERER" = "gl" ] && ENGINE_TYPE=2 || ENGINE_TYPE=0

# Wine's and Box64's messages (DEBUG, RDTSC_1GHZ) - shared code
wine_logging

# GoldSrc misreads long GL extension strings - report only 1999-era ones
export MESA_EXTENSION_MAX_YEAR=1999
# OpenGL: no error checking, GLTHREAD (gl renderer only) - shared code
[ "$GAME_RENDERER" = "gl" ] || unset GLTHREAD
gl_setup

# Box64's settings file (4 cores, speed settings for the game),
# DYNACACHE, FPS_HUD - shared code
box64_setup "$GAME_EXE"

# ===================== Helpers =====================

# Wine works out the "monitor" size once, at start-up, from the area the TV
# is showing at that moment, and keeps windows inside it. So until the first
# window appears the TV shows a 16:9 area a little TALLER than the game
# (GH + 80: room for the game window's title bar - without it the picture
# was squeezed, leaving a grey bar at the bottom). The X screen is that area
# plus a few pixels (xrandr rejects a zoom reaching even part of a pixel
# past the edge), so it never needs resizing mid-game.
CANVAS_H=$((GH + 80))
CANVAS_W=$(( (CANVAS_H * ${NATIVE_RES%x*} + ${NATIVE_RES#*x} - 1) / ${NATIVE_RES#*x} ))
FB_W=$((CANVAS_W + 4)); FB_H=$((CANVAS_H + 4))
MENU_W=640; MENU_H=480      # WON Half-Life's menus are always this size

# Zooming (zoom_to, shared code): the X screen is at least FB_W x FB_H, and
# always reaches the whole zoomed view. TV at 60 Hz.
ZOOM_FB="${FB_W}x${FB_H}"
ZOOM_FB_VIEW=1
TV_RATE=60

# Background helper (one Python process, X11 via ctypes - nothing to
# install). Every 0.5s (0.25s for the first 20s, so start-up rescaling is
# quick and the start-up message cover lifts sooner) it finds the TOPMOST
# visible hl.exe window (menu, game or intro video) and, inside the game
# window's title bar and border, its GW x GH drawing area. When that changes
# it prints "W H X Y" for zoom_to, which also tells the shared black panels
# (panels.py) what to cover - so the side bars are black and the title
# bar/border never show - and fences the pointer into that area (it can't go
# onto the black bars or off the TV). No game window for 2s (exiting):
# prints "gone" - panels and fence off, so the pointer is free while the
# game closes.
watch_windows() {
    python3 -I - hl-zoom-helper "$GAME_EXE" "$GW" "$GH" "$MENU_W" "$MENU_H" <<'EOF' |
import ctypes as c, ctypes.util, sys, time
_, exe, gw, gh, mw, mh = sys.argv[1:7]
exe = exe.lower().encode(); gw, gh, mw, mh = map(int, (gw, gh, mw, mh))
INNER = {(gw, gh), (mw, mh)}           # drawing-area sizes worth zooming to

x11 = c.CDLL(c.util.find_library("X11") or "libX11.so.6")
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
x11.XOpenDisplay.restype = c.c_void_p
x11.XOpenDisplay.argtypes = [c.c_char_p]
x11.XDefaultRootWindow.restype = W
x11.XDefaultRootWindow.argtypes = [c.c_void_p]
x11.XQueryTree.argtypes = [c.c_void_p, W, c.POINTER(W), c.POINTER(W),
                           c.POINTER(c.POINTER(W)), c.POINTER(c.c_uint)]
x11.XGetWindowAttributes.argtypes = [c.c_void_p, W, c.POINTER(XWindowAttributes)]
x11.XGetClassHint.argtypes = [c.c_void_p, W, c.POINTER(XClassHint)]
x11.XTranslateCoordinates.argtypes = [c.c_void_p, W, W, c.c_int, c.c_int,
                                      c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(W)]
x11.XFree.argtypes = [c.c_void_p]
HANDLER = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)
ignore = HANDLER(lambda d, e: 0)       # windows can vanish mid-query - ignore
x11.XSetErrorHandler(ignore)

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit("zoom helper: cannot open X display")
root = x11.XDefaultRootWindow(dpy)

def children(w):
    r, p, ch, n = W(), W(), c.POINTER(W)(), c.c_uint()
    if not x11.XQueryTree(dpy, w, c.byref(r), c.byref(p), c.byref(ch), c.byref(n)):
        return []
    out = [ch[i] for i in range(n.value)]          # bottom to top
    if ch:
        x11.XFree(ch)
    return out

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

def inner_area(w, area, depth=0):
    # the drawing area inside a framed window: a visible child of a known
    # size, else the biggest visible child covering most of the window
    best, best_a = None, area // 2
    for ch in reversed(children(w)):
        a = attrs(ch)
        if not a or a.map_state != 2:
            continue
        if (a.width, a.height) in INNER:
            return (a.width, a.height) + abs_pos(ch)
        if a.width * a.height > best_a:
            best, best_a = (a.width, a.height) + abs_pos(ch), a.width * a.height
        if depth < 3:
            r = inner_area(ch, area, depth + 1)
            if r and r[:2] in INNER:
                return r
    return best

def topdown(w, depth=0):
    # every window, topmost first (a window's children are above it). Wine's
    # windows aren't always direct children of the root window.
    for ch in reversed(children(w)):
        if depth < 3:
            yield from topdown(ch, depth + 1)
        yield ch

last, warned, t0, gone = None, False, time.time(), None
while True:
    time.sleep(0.25 if time.time() - t0 < 20 else 0.5)
    target = None
    for w in topdown(root):
        a = attrs(w)
        if not a or a.map_state != 2 or a.width < 300 or a.height < 200:
            continue
        if not is_game(w):
            continue
        target = inner_area(w, a.width * a.height) or ((a.width, a.height) + abs_pos(w))
        break
    if not target and not last and not warned and time.time() - t0 >= 20:
        warned = True               # 20s and nothing to zoom to: list
                                    #   what's there
        print("WARNING: zoom helper found no game window. Windows:", file=sys.stderr)
        for w in topdown(root):
            a = attrs(w)
            if a and a.width * a.height >= 10000:
                print("  0x%x %dx%d+%d+%d map_state=%d hl.exe=%s"
                      % ((w, a.width, a.height) + abs_pos(w) + (a.map_state, is_game(w))),
                      file=sys.stderr)
        sys.stderr.flush()
    if target:
        gone = None
        if target != last:
            last = target
            print("%d %d %d %d" % target, flush=True)
    elif last:
        gone = gone or time.time()
        if time.time() - gone >= 2:     # no game window for 2s: exiting
            print("gone", flush=True)
            last = None                 # (a window coming back is zoomed again)
EOF
    {
        # Black panels + pointer fence (shared code), in this same process
        # as zoom_to
        panels_start "$GAME_ID-panels" 1
        while read -r geo; do
            if [ "$geo" = "gone" ]; then
                [ -n "$PANEL_FD" ] && echo hide >&"$PANEL_FD"
                continue
            fi
            # shellcheck disable=SC2086
            zoom_to $geo
        done
    }
}

# Before the game starts, with Wine fully stopped afterwards
setup_prefix() {
    # A pending prefix update must finish here, not in the background while
    # the game starts (that stopped Wine's display starting - no game window)
    prefix_setup

    # Wine settings + starting values for the game's video settings, and the
    # CD key from CDKEY_FILE (the game keeps it as "Key", the bare 13 digits -
    # only letters and digits are kept). Imported only when they change (each
    # import is a full Box64 + Wine start-up). The key itself is never logged.
    local reg_new="$WINEPREFIX/drive_c/$GAME_ID-settings.reg" reg_old="$WINEPREFIX/$GAME_ID-settings.applied"
    local cdkey=""
    [ -f "$CDKEY_FILE" ] && cdkey="$(head -n 1 "$CDKEY_FILE" | tr -cd 'A-Za-z0-9')"
    { wine_base_reg; cat <<EOF
[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\$GAME_EXE]
"Version"="winxp"

; No window manager: Wine places the game's windows itself
[HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
"Managed"="N"

[HKEY_CURRENT_USER\\Software\\Valve\\Half-Life\\Settings]
"EngineD3D"=dword:00000000
"EngineType"=dword:0000000$ENGINE_TYPE
"EngineModeW"=dword:$(printf '%08x' "$GW")
"EngineModeH"=dword:$(printf '%08x' "$GH")
"EngineModeBPP"=dword:00000020
"EngineModeWindowed"=dword:00000001
${cdkey:+\"Key\"=\"$cdkey\"}
EOF
    } > "$reg_new"
    import_reg "$reg_new" "$reg_old"

    # The game's Video menu saves its own choices over these. Put ours back
    # every launch - edited straight in user.reg, so no start-up time.
    local key='^\[Software\\\\Valve\\\\Half-Life\\\\Settings\]'
    local add="\"EngineMode\"=dword:$(printf '%08x' "$MODE_IDX")\n\"EngineType\"=dword:0000000$ENGINE_TYPE"
    sed -i "/$key/I,/^\[/ {
        s/^\(\"EngineD3D\"\)=dword:.*/\1=dword:00000000/I
        s/^\(\"EngineModeW\"\)=dword:.*/\1=dword:$(printf '%08x' "$GW")/I
        s/^\(\"EngineModeH\"\)=dword:.*/\1=dword:$(printf '%08x' "$GH")/I
        s/^\(\"EngineModeBPP\"\)=dword:.*/\1=dword:00000020/I
        s/^\(\"EngineModeWindowed\"\)=dword:.*/\1=dword:00000001/I
        /^\"EngineMode\"=/Id
        /^\"EngineType\"=/Id
        /^\"EngineModeW\"=/I a $add
    }" "$WINEPREFIX/user.reg"

    # The .cfg files must be writable (config.cfg was read-only, so settings
    # never saved), and mustn't hold a video mode ("vid_mode 0" = 320x240)
    local cfg
    for cfg in "$GAME_DIR"/valve/config.cfg "$GAME_DIR"/valve/userconfig.cfg; do
        [ -f "$cfg" ] || continue
        chmod u+w "$cfg"
        sed -i '/^[[:space:]]*\(vid_mode\|fullscreen\|width\|height\)[[:space:]]/Id' "$cfg"
    done
}

# Inside X (from launch, shared code)
in_x() {
    zoom_start "" "$CANVAS_W" "$CANVAS_H"   # whole area until a window shows
                                            #   (shared code)
    xsetroot -solid black 2>/dev/null
    start_boot_log "$START_GEO" "$GAME_EXE"
    if [ "$COMPOSITOR" = "1" ] && command -v xcompmgr >/dev/null; then
        xcompmgr &
        cleanup_add $!
    fi
    set_governor
    setup_prefix
    setup_done              # (the start-up messages time the game from here)
    sound_mixer_start "$GAME_ID"
    cd "$GAME_DIR" || exit 1
    log_settings GAME_RENDERER FPS_MAX DYN_LIGHTS
    watch_windows &
    cleanup_add hl-zoom-helper
    # shellcheck disable=SC2086,SC2046
    wine "$GAME_EXE" -windowed \
        +fps_max "$FPS_MAX" $EXTRA_ARGS $([ "$GAME_RENDERER" = "gl" ] && echo "$GL_ARGS") &
    # Back as soon as Wine has finished after the game closes (shared code)
    WINE_EXIT_WAIT=0        # started directly: Wine's launcher (start.exe)
                            # ends with the game - never end it early
    wait_for_game $! "$GAME_EXE"
}

# ===================== Main =====================
launch "$@"                 # (shared code: --kill, X, then in_x)
