#!/usr/bin/env python3
# =============================================================================
#  Start-up messages on screen - shared by the Wine launchers in roms/windows
#  Started by start_boot_log (bootlog.inc, same folder). Not run by itself.
#
#  One Python process (X11 via ctypes, nothing to install): a black window
#  over the area the TV shows, above Wine's desktop, with the newest lines of
#  LOG_FILE and the seconds since X started. The text is the same size on the
#  TV in every game: X's built-in "fixed" font, enlarged to BOOT_LOG_SCALE
#  times its size on the TV (2.25 = how it looks in DX-Ball) whatever zoom the
#  script is using.
#  Ending: GAP seconds before the game is due, the text goes and the window
#  becomes a black cover over the whole screen. It lifts the moment the
#  screen looks exactly as the game's real start did last time - the game's
#  window size and position, the X screen size and the TV's scaling - so
#  start-up windows, resolution changes and rescaling all happen out of
#  sight. You see: messages -> black -> the game.
#  The game's real start = the first picture that stays unchanged for STEADY
#  seconds. Each launch notes when that was and what it looked like (in the
#  prefix, .boot_log_time), out of sight, for next time.
#  Progress bar (green, along the bottom): how far through the messages,
#  measured by the lines written against the last launch's count. None on a
#  first launch.
#  First launch / new layout (nothing learned): black from the moment the
#  game's window appears until the picture has been unchanged for STEADY
#  seconds. The cover never stays more than 10 s after the game shows, or
#  GAP + 15 s if it doesn't show at all. It also closes when X ends.
#  A dialog box of the game's still waiting after 2.5 s (e.g. "enter your
#  name" on a first run) gets the screen until it's closed.
#  BOOT_LOG_MIN_WINDOW (environment, "WxH", default 100x40): the game's
#  windows smaller than this are ignored altogether - for a game whose
#  start-up splash picture would otherwise end the messages early and be
#  taken for a dialog (e.g. Serious Sam: 640x480).
#
#  TV held at 1:1 (BOOT_HOLD_FILE exists - set up by start_boot_log): the
#  script's zoom waits in ZOOM_CMD_FILE; it's carried out when the cover goes
#  up (or a dialog steps in, or this ends), and the hold file removed.
#
#  Arguments: tag log title TVmode scale W H X Y timefile exe...
# =============================================================================
import atexit, ctypes as c, ctypes.util, os, subprocess, sys, time
from collections import deque
log, title = sys.argv[2], sys.argv[3].encode()         # argv[1] = tag
nw, nh = map(int, sys.argv[4].split("x"))               # the TV's mode
scale = float(sys.argv[5])                              # text size on the TV
w, h, x0, y0 = map(int, sys.argv[6:10])                 # area the TV shows
tfile = sys.argv[10]                                    # last launch's start-up time
exes = {e.lower().encode() for e in sys.argv[11:]}
try:                # smallest window of the game's that counts (BOOT_LOG_MIN_WINDOW)
    MIN_W, MIN_H = map(int, os.environ.get("BOOT_LOG_MIN_WINDOW", "100x40").lower().split("x"))
except ValueError:
    MIN_W, MIN_H = 100, 40
STEADY = 3          # seconds unchanged = the game's picture is ready (learning)
GAP = 0.0           # extra black before the game, in seconds. 0 = messages until
                    # the game's first window appears, then black only while the
                    # game gets its picture ready

x11 = c.CDLL(c.util.find_library("X11") or "libX11.so.6")
class XSetWindowAttributes(c.Structure):
    _fields_ = [("background_pixmap", c.c_ulong), ("background_pixel", c.c_ulong),
                ("border_pixmap", c.c_ulong), ("border_pixel", c.c_ulong),
                ("bit_gravity", c.c_int), ("win_gravity", c.c_int),
                ("backing_store", c.c_int), ("backing_planes", c.c_ulong),
                ("backing_pixel", c.c_ulong), ("save_under", c.c_int),
                ("event_mask", c.c_long), ("do_not_propagate_mask", c.c_long),
                ("override_redirect", c.c_int), ("colormap", c.c_ulong),
                ("cursor", c.c_ulong)]
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
class XCharStruct(c.Structure):
    _fields_ = [("lbearing", c.c_short), ("rbearing", c.c_short), ("width", c.c_short),
                ("ascent", c.c_short), ("descent", c.c_short), ("attributes", c.c_ushort)]
class XFontStruct(c.Structure):
    _fields_ = [("ext_data", c.c_void_p), ("fid", c.c_ulong), ("direction", c.c_uint),
                ("min_char_or_byte2", c.c_uint), ("max_char_or_byte2", c.c_uint),
                ("min_byte1", c.c_uint), ("max_byte1", c.c_uint),
                ("all_chars_exist", c.c_int), ("default_char", c.c_uint),
                ("n_properties", c.c_int), ("properties", c.c_void_p),
                ("min_bounds", XCharStruct), ("max_bounds", XCharStruct),
                ("per_char", c.c_void_p), ("ascent", c.c_int), ("descent", c.c_int)]
class XImage(c.Structure):
    _fields_ = [("width", c.c_int), ("height", c.c_int), ("xoffset", c.c_int),
                ("format", c.c_int), ("data", c.c_void_p), ("byte_order", c.c_int),
                ("bitmap_unit", c.c_int), ("bitmap_bit_order", c.c_int),
                ("bitmap_pad", c.c_int), ("depth", c.c_int),
                ("bytes_per_line", c.c_int), ("bits_per_pixel", c.c_int)]
W = c.c_ulong
P = c.c_void_p
x11.XOpenDisplay.restype = P
x11.XOpenDisplay.argtypes = [c.c_char_p]
x11.XDefaultRootWindow.restype = W
x11.XDefaultRootWindow.argtypes = [P]
x11.XDefaultScreen.argtypes = [P]
x11.XDefaultDepth.argtypes = [P, c.c_int]
x11.XCreateWindow.restype = W
x11.XCreateWindow.argtypes = [P, W, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_uint,
                              c.c_int, c.c_uint, P, c.c_ulong,
                              c.POINTER(XSetWindowAttributes)]
for f in ("XMapRaised", "XRaiseWindow", "XUnmapWindow", "XClearWindow"):
    getattr(x11, f).argtypes = [P, W]
x11.XMoveResizeWindow.argtypes = [P, W, c.c_int, c.c_int, c.c_uint, c.c_uint]
x11.XTranslateCoordinates.argtypes = [P, W, W, c.c_int, c.c_int, c.POINTER(c.c_int),
                                      c.POINTER(c.c_int), c.POINTER(W)]
x11.XCreatePixmap.restype = W
x11.XCreatePixmap.argtypes = [P, W, c.c_uint, c.c_uint, c.c_uint]
x11.XCreateGC.restype = P
x11.XCreateGC.argtypes = [P, W, c.c_ulong, P]
x11.XSetForeground.argtypes = [P, P, c.c_ulong]
x11.XSetBackground.argtypes = [P, P, c.c_ulong]
x11.XLoadQueryFont.restype = c.POINTER(XFontStruct)
x11.XLoadQueryFont.argtypes = [P, c.c_char_p]
x11.XSetFont.argtypes = [P, P, W]
x11.XDrawString.argtypes = [P, W, P, c.c_int, c.c_int, c.c_char_p, c.c_int]
x11.XDrawImageString.argtypes = [P, W, P, c.c_int, c.c_int, c.c_char_p, c.c_int]
x11.XFillRectangle.argtypes = [P, W, P, c.c_int, c.c_int, c.c_uint, c.c_uint]
x11.XCopyArea.argtypes = [P, W, W, P, c.c_int, c.c_int, c.c_uint, c.c_uint,
                          c.c_int, c.c_int]
x11.XGetImage.restype = c.POINTER(XImage)
x11.XGetImage.argtypes = [P, W, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_ulong, c.c_int]
x11.XDestroyImage.argtypes = [c.POINTER(XImage)]
x11.XQueryTree.argtypes = [P, W, c.POINTER(W), c.POINTER(W),
                           c.POINTER(c.POINTER(W)), c.POINTER(c.c_uint)]
x11.XGetWindowAttributes.argtypes = [P, W, c.POINTER(XWindowAttributes)]
x11.XGetClassHint.argtypes = [P, W, c.POINTER(XClassHint)]
x11.XFree.argtypes = [P]
x11.XFlush.argtypes = [P]
x11.XSync.argtypes = [P, c.c_int]
HANDLER = c.CFUNCTYPE(c.c_int, P, P)
ignore = HANDLER(lambda d, e: 0)        # windows can vanish mid-query - ignore
x11.XSetErrorHandler(ignore)
# The TV's scaling (xrandr --transform), so the cover can wait for rescaling
class XRRScreenResources(c.Structure):
    _fields_ = [("timestamp", W), ("configTimestamp", W), ("ncrtc", c.c_int),
                ("crtcs", c.POINTER(W)), ("noutput", c.c_int), ("outputs", P),
                ("nmode", c.c_int), ("modes", P)]
class XRRCrtcTransformAttributes(c.Structure):
    _fields_ = [("pending", c.c_int * 9), ("pending_filter", P), ("pending_n", c.c_int),
                ("pending_params", P), ("current", c.c_int * 9),
                ("current_filter", P), ("current_n", c.c_int), ("current_params", P)]
try:
    xrr = c.CDLL(c.util.find_library("Xrandr") or "libXrandr.so.2")
    xrr.XRRGetScreenResourcesCurrent.restype = c.POINTER(XRRScreenResources)
    xrr.XRRGetScreenResourcesCurrent.argtypes = [P, W]
    xrr.XRRFreeScreenResources.argtypes = [P]
    xrr.XRRGetCrtcTransform.argtypes = [P, W, c.POINTER(c.POINTER(XRRCrtcTransformAttributes))]
except (OSError, AttributeError):
    xrr = None                          # (no libXrandr: window and screen size only)

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit("boot log: cannot open X display")
root = x11.XDefaultRootWindow(dpy)
depth = x11.XDefaultDepth(dpy, x11.XDefaultScreen(dpy))
sa = XSetWindowAttributes(background_pixel=0, override_redirect=1)
win = x11.XCreateWindow(dpy, root, x0, y0, w, h, 0, 0, 1, None,
                        (1 << 1) | (1 << 9), c.byref(sa))   # CWBackPixel|CWOverrideRedirect
gc = x11.XCreateGC(dpy, win, 0, None)
font = x11.XLoadQueryFont(dpy, b"fixed")
if not font:
    sys.exit("boot log: no 'fixed' font")
fs = font.contents
x11.XSetFont(dpy, gc, fs.fid)
x11.XSetBackground(dpy, gc, 0x000000)
fw, fh, asc = fs.max_bounds.width, fs.ascent + fs.descent, fs.ascent   # 6, 13, 11

# The script's GPU zoom enlarges this area to fit the TV; s = how much the
# font must be enlarged on top, so it ends up 'scale' times its size on the
# TV. Never shrunk (a smaller font would lose pixels).
zoom = min(nw / w, nh / h)
s = max(1.0, scale / zoom)
sw, sh = fw * s, fh * s                 # character spacing (fractional)
cw, ch = -(-int(sw * 1000) // 1000), -(-int(sh * 1000) // 1000)   # glyph size, rounded up
cols, rows = int(w / sw) - 1, int(h / sh) - 2
GREY, GREEN, TRACK = 0xB0B0B0, 0x55DD55, 0x303030

glyphs = {}
def glyph(code, colour):
    # Character 'code' enlarged by s, in 'colour' on black - drawn once from
    # the font's own pixels (nearest neighbour), then kept
    key = (code, colour)
    if key in glyphs:
        return glyphs[key]
    src = x11.XCreatePixmap(dpy, win, fw, fh, depth)
    x11.XSetForeground(dpy, gc, 0)
    x11.XFillRectangle(dpy, src, gc, 0, 0, fw, fh)
    x11.XSetForeground(dpy, gc, 0xFFFFFF)
    x11.XDrawString(dpy, src, gc, 0, asc, bytes([code]), 1)
    img = x11.XGetImage(dpy, src, 0, 0, fw, fh, 0xFFFFFFFF, 2)    # ZPixmap
    im = img.contents
    bpp, bpl = im.bits_per_pixel // 8, im.bytes_per_line
    data = c.string_at(im.data, bpl * fh)
    x11.XDestroyImage(img)
    pm = x11.XCreatePixmap(dpy, win, cw, ch, depth)
    x11.XSetForeground(dpy, gc, 0)
    x11.XFillRectangle(dpy, pm, gc, 0, 0, cw, ch)
    x11.XSetForeground(dpy, gc, colour)
    for py in range(fh):
        y1, y2 = int(py * s), int((py + 1) * s)
        for px in range(fw):
            if any(data[py * bpl + px * bpp: py * bpl + px * bpp + 3]):
                x1, x2 = int(px * s), int((px + 1) * s)
                x11.XFillRectangle(dpy, pm, gc, x1, y1, max(1, x2 - x1), max(1, y2 - y1))
    glyphs[key] = pm
    return pm

def text(t, row, colour):
    # One line, padded to the full width (drawn with its background: no flicker)
    t = t[:cols].ljust(cols)
    y = int(row * sh)
    if s == 1.0:                            # no enlarging needed: the font itself
        x11.XSetForeground(dpy, gc, colour)
        x11.XDrawImageString(dpy, win, gc, 4, y + asc, t, len(t))
        return
    end = len(t.rstrip())
    for i in range(end):
        code = t[i] if 32 <= t[i] < 127 else 63            # '?' for anything odd
        x11.XCopyArea(dpy, glyph(code, colour), win, gc, 0, 0, cw, ch, 4 + int(i * sw), y)
    x11.XSetForeground(dpy, gc, 0)
    x = 4 + int(end * sw)
    x11.XFillRectangle(dpy, win, gc, x, y, 4 + int(cols * sw) - x + 1, ch)

# Clicks pass straight through to the windows underneath (a script's helper
# may click the game's window while it's covered)
try:
    xfx = c.CDLL(c.util.find_library("Xfixes") or "libXfixes.so.3")
    xfx.XFixesCreateRegion.restype = W
    xfx.XFixesCreateRegion.argtypes = [P, P, c.c_int]
    xfx.XFixesSetWindowShapeRegion.argtypes = [P, W, c.c_int, c.c_int, c.c_int, W]
    xfx.XFixesSetWindowShapeRegion(dpy, win, 2, 0, 0,             # ShapeInput: empty
                                   xfx.XFixesCreateRegion(dpy, None, 0))
except (OSError, AttributeError):
    pass
x11.XMapRaised(dpy, win)

def children(p):
    r, pa, kids, n = W(), W(), c.POINTER(W)(), c.c_uint()
    if not x11.XQueryTree(dpy, p, c.byref(r), c.byref(pa), c.byref(kids), c.byref(n)):
        return []
    out = [kids[i] for i in range(n.value)]
    if kids:
        x11.XFree(kids)
    return out

def game_windows(p=root, d=0):
    # Visible windows (100x40 or bigger - or BOOT_LOG_MIN_WINDOW) belonging to
    # one of the game's exes:
    # (width, height, x, y) on the screen
    found = []
    for k in children(p):
        if k == win:
            continue
        a = XWindowAttributes()
        if not x11.XGetWindowAttributes(dpy, k, c.byref(a)) or a.map_state != 2:
            continue
        if a.width >= MIN_W and a.height >= MIN_H:
            hint = XClassHint()
            if x11.XGetClassHint(dpy, k, c.byref(hint)):
                name = c.string_at(hint.res_name).lower() if hint.res_name else b""
                for q in (hint.res_name, hint.res_class):
                    if q:
                        x11.XFree(q)
                if name in exes:
                    rx, ry, ch_ = c.c_int(), c.c_int(), W()
                    x11.XTranslateCoordinates(dpy, k, root, 0, 0, c.byref(rx),
                                              c.byref(ry), c.byref(ch_))
                    found.append((a.width, a.height, rx.value, ry.value))
        if d < 3:
            found += game_windows(k, d + 1)
    return found

def screen_state(g):
    # What the TV shows: the game's largest window (300x200 or bigger), the X
    # screen's size and the TV's scaling. None = the game has no window yet
    g = [v for v in g if v[0] >= 300 and v[1] >= 200]
    if not g:
        return None
    a = XWindowAttributes()
    x11.XGetWindowAttributes(dpy, root, c.byref(a))
    return (max(g, key=lambda v: v[0] * v[1]), a.width, a.height, scaling())

def scaling():
    # The current xrandr transform of each output, as numbers
    if not xrr:
        return ()
    out = []
    rp = xrr.XRRGetScreenResourcesCurrent(dpy, root)
    if not rp:
        return ()
    r = rp.contents
    for i in range(r.ncrtc):
        ta = c.POINTER(XRRCrtcTransformAttributes)()
        if xrr.XRRGetCrtcTransform(dpy, r.crtcs[i], c.byref(ta)) and ta:
            out += list(ta.contents.current)
            x11.XFree(ta)
    xrr.XRRFreeScreenResources(rp)
    return tuple(out)

def view():
    # The X screen's size and the TV's scaling
    a = XWindowAttributes()
    x11.XGetWindowAttributes(dpy, root, c.byref(a))
    return (a.width, a.height, scaling())

def flat(st):
    (gw, gh, gx, gy), sw_, sh_, tf = st
    return " ".join(str(v) for v in (gw, gh, gx, gy, sw_, sh_) + tf)

def record(t, st):
    # For next time: when the game's picture was ready, how many lines and
    # seconds the messages were up (for the progress bar), and the picture
    extra = "L%d C%.2f " % (end_lines, end_time) if end_time is not None else ""
    try:
        with open(tfile, "w") as out:
            out.write("%.2f %s%s\n" % (t, extra, flat(st)))
    except OSError:
        pass

# Hands the TV back to the script's zoom (if it's being held at 1:1)
HOLD, ZCMD = os.environ.get("BOOT_HOLD_FILE"), os.environ.get("ZOOM_CMD_FILE")
def release():
    if not HOLD or not os.path.exists(HOLD):
        return
    try:
        os.remove(HOLD)
    except OSError:
        return
    try:
        cmd = open(ZCMD).read().strip() if ZCMD else ""
    except OSError:
        cmd = ""
    sys.stdout.flush()
    if cmd:
        subprocess.call(["/bin/bash", "-c", cmd])
    subprocess.call(["xrandr", "--delmonitor", "bootlog-tv"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
atexit.register(release)

lines, buf, f, dirty = deque(maxlen=rows), b"", None, True
last_time, final = None, None            # learned from the last launch
last_lines = last_end = None
try:
    v = open(tfile).read().split()
    last_time = float(v[0])
    layout = []
    for tok in v[1:]:
        if tok[0] == "L":
            last_lines = int(tok[1:])
        elif tok[0] == "C":
            last_end = float(tok[1:])
        else:
            layout.append(tok)
    final = " ".join(layout) if len(layout) >= 6 else None
except (OSError, ValueError, IndexError):
    pass                                # first launch: nothing learned yet
end_lines, end_time = 0, None           # this launch: when the messages went

# The log: newest lines for the screen, and a count of the lines written
# since X started (what was there before - set-up before X - isn't counted)
nl, based = 0, False
def read_log():
    global f, buf, nl, based, dirty
    if f is None:
        try:
            f = open(log, "rb")
        except OSError:
            return
    data = f.read()
    if data:
        if based:
            nl += data.count(b"\n")
        *done, buf = (buf + data).split(b"\n")
        for l in done:
            lines.append(l.replace(b"\r", b"").expandtabs(4))
        dirty = True
    based = True                            # (from now on, lines are counted)

# Progress bar along the bottom, one text line high: lines so far against
# the last launch's count (or seconds, if there's no count). Slows down near
# the end, so a slower launch creeps rather than sitting full. None = no bar
# (first launch: nothing to compare with).
def progress(now):
    if last_lines:
        p = nl / last_lines
    elif last_end:
        p = (now - t0) / last_end
    else:
        return None
    return p if p <= 0.9 else 0.9 + 0.09 * (1 - 0.5 ** ((p - 0.9) / 0.1))

bar_w = -1
bar_y = int((rows + 1) * sh + (h - (rows + 1) * sh - ch) / 2)
def bar(p):
    global bar_w
    full = w - 8
    fw_ = max(0, min(full, int(full * p)))
    if fw_ == bar_w:
        return
    bar_w = fw_
    x11.XSetForeground(dpy, gc, GREEN)
    if fw_:
        x11.XFillRectangle(dpy, win, gc, 4, bar_y, fw_, ch)
    x11.XSetForeground(dpy, gc, TRACK)
    if full - fw_:
        x11.XFillRectangle(dpy, win, gc, 4 + fw_, bar_y, full - fw_, ch)
close_at = max(1.0, last_time - GAP) if last_time else None
t0 = time.time()
mode = "log"            # log -> cover (black) -> watch (cover gone, learning) -> end
state, since, cover_t, seen_t = None, 0.0, 0.0, None
start_view, next_draw = view(), 0.0
dialog_t, paused, learned = None, False, False
while True:
    now = time.time()
    read_log()
    g = game_windows() if exes else []
    st = screen_state(g)
    # A dialog of the game's (a window smaller than 500x300) that's still
    # there after 2.5 s is waiting for you (e.g. "enter your name"): step
    # aside until it closes. (Ones a script answers itself close sooner.)
    if any(v[0] < 500 or v[1] < 300 for v in g):
        dialog_t = dialog_t or now
    else:
        dialog_t = None
    pause = mode in ("log", "cover") and dialog_t is not None and now - dialog_t >= 2.5
    if pause != paused:
        paused = pause
        if pause:
            release()                       # (the dialog at the game's zoom)
            x11.XUnmapWindow(dpy, win)
        else:
            x11.XMapRaised(dpy, win)
            dirty, bar_w = True, -1         # (redraw the text and bar)
        x11.XFlush(dpy)
    if paused:
        time.sleep(0.1)
        continue
    if st != state:
        state, since = st, now              # something changed - start counting again
    if st is not None and seen_t is None:
        seen_t = now                        # the game's first window
    if mode == "log" and (st is not None or view() != start_view or
                          (close_at is not None and now - t0 >= close_at)):
        # (the game's window appeared, the script rescaled the TV, or it's time)
        # Text off; black cover over the whole screen (it may be rescaled)
        mode, cover_t = "cover", now
        end_lines, end_time = nl, now - t0      # (for next launch's progress bar)
        x11.XMoveResizeWindow(dpy, win, 0, 0, 8192, 8192)
        x11.XClearWindow(dpy, win)
        x11.XRaiseWindow(dpy, win)
        x11.XSync(dpy, 0)                   # (black before the zoom changes)
        release()                           # the game's zoom, under the cover
        state = None                        # (the screen changed - look again)
    if (mode in ("cover", "watch") and not learned and st is not None
            and now - since >= STEADY):
        # The first picture to stay unchanged STEADY s is the game's real
        # start (resizing/rescaling is over by then) - remember it
        record(since - t0, st)
        learned = True
    if mode == "cover":
        lift = st is not None and (
            flat(st) == final                   # exactly as it started last time
            or now - since >= STEADY            # (new layout: once it's steady)
            or now - seen_t >= 10)              # (never steady: give up)
        if lift or (st is None and now - cover_t > GAP + 15):
            x11.XUnmapWindow(dpy, win)      # the game - or, if it's very late, the desktop
            mode = "watch"
        else:
            x11.XRaiseWindow(dpy, win)      # Wine raises its windows - stay on top
        x11.XFlush(dpy)
        time.sleep(0.05)
        continue
    if mode == "watch":
        # Out of sight: keep watching (up to the game's first 15 s) until
        # it's learned the game's real start, then finish
        if learned:
            break
        if seen_t is None:
            if now - t0 > (last_time or 0) + 120:
                break                       # it never appeared - give up
        elif now - seen_t >= 15:
            if state is not None:
                record(since - t0, state)   # (never steady: the last picture)
            break
        time.sleep(0.25)
        continue
    time.sleep(0.05)                        # check the screen 20 times a second,
    if now < next_draw:                     # redraw the text 4 times a second
        continue
    next_draw = now + 0.25
    x11.XRaiseWindow(dpy, win)              # Wine raises its windows - stay on top
    text(b"%s - starting... %5.1fs" % (title, now - t0), 0, GREEN)
    if dirty:
        for i in range(rows):
            text(lines[i] if i < len(lines) else b"", i + 1, GREY)
        dirty = False
    p = progress(now)
    if p is not None:
        bar(p)
    x11.XFlush(dpy)
