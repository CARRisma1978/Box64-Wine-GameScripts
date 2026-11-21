# Black panels beside the game's area - started by panels_start (display.inc)
#
# Reads lines from zoom_to on stdin:
#   "left top right bottom x y w h" - the TV shows left..right x top..bottom
#       of the X screen; the game's area is w x h at x,y. Panels cover the
#       rest, and are kept on top (Wine raises its own windows).
#   "hide" - no panels.
# Arguments: tag (just a name in the command line) fb-width fb-height fence
#   fence = 1: pointer barriers round the game's area as well, so the mouse
#   stays on the picture (needs libXfixes). Checked every 0.5 s too: a
#   pointer that got outside anyway is put back just inside.
# While the start-up messages hold the TV at 1:1 (BOOT_HOLD_FILE exists),
# nothing is shown or fenced; the latest request is carried out once it's
# released.
# X11 via ctypes - nothing to install.
import ctypes as c, ctypes.util, os, select, sys

args = sys.argv[1:] + ["", "0", "0", "0"]
fw, fh, fence = int(args[1] or 0), int(args[2] or 0), args[3] == "1"   # args[0] = tag


def lib(name, so):
    try:
        return c.CDLL(c.util.find_library(name) or so)
    except OSError:
        return None


x11 = lib("X11", "libX11.so.6")
if not x11:
    sys.exit("panels: libX11 not found")
xf = lib("Xfixes", "libXfixes.so.3") if fence else None
if fence and not xf:
    print("panels: libXfixes not found - mouse not fenced", file=sys.stderr)


class XSetWindowAttributes(c.Structure):
    _fields_ = [("background_pixmap", c.c_ulong), ("background_pixel", c.c_ulong),
                ("border_pixmap", c.c_ulong), ("border_pixel", c.c_ulong),
                ("bit_gravity", c.c_int), ("win_gravity", c.c_int),
                ("backing_store", c.c_int), ("backing_planes", c.c_ulong),
                ("backing_pixel", c.c_ulong), ("save_under", c.c_int),
                ("event_mask", c.c_long), ("do_not_propagate_mask", c.c_long),
                ("override_redirect", c.c_int), ("colormap", c.c_ulong),
                ("cursor", c.c_ulong)]


W = c.c_ulong
I = c.POINTER(c.c_int)
x11.XOpenDisplay.restype = c.c_void_p
x11.XOpenDisplay.argtypes = [c.c_char_p]
x11.XDefaultRootWindow.restype = W
x11.XDefaultRootWindow.argtypes = [c.c_void_p]
x11.XCreateWindow.restype = W
x11.XCreateWindow.argtypes = [c.c_void_p, W, c.c_int, c.c_int, c.c_uint, c.c_uint,
                              c.c_uint, c.c_int, c.c_uint, c.c_void_p, c.c_ulong,
                              c.POINTER(XSetWindowAttributes)]
for f in ("XMapRaised", "XUnmapWindow", "XRaiseWindow"):
    getattr(x11, f).argtypes = [c.c_void_p, W]
x11.XMoveResizeWindow.argtypes = [c.c_void_p, W, c.c_int, c.c_int, c.c_uint, c.c_uint]
x11.XQueryPointer.argtypes = [c.c_void_p, W, c.POINTER(W), c.POINTER(W), I, I, I, I,
                              c.POINTER(c.c_uint)]
x11.XWarpPointer.argtypes = [c.c_void_p, W, W, c.c_int, c.c_int, c.c_uint, c.c_uint,
                             c.c_int, c.c_int]
x11.XFlush.argtypes = [c.c_void_p]
if xf:
    xf.XFixesCreatePointerBarrier.restype = W
    xf.XFixesCreatePointerBarrier.argtypes = [c.c_void_p, W, c.c_int, c.c_int, c.c_int,
                                              c.c_int, c.c_int, c.c_int, c.c_void_p]
    xf.XFixesDestroyPointerBarrier.argtypes = [c.c_void_p, W]
HANDLER = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)
ignore = HANDLER(lambda d, e: 0)
x11.XSetErrorHandler(ignore)

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit("panels: cannot open X display")
root = x11.XDefaultRootWindow(dpy)
sa = XSetWindowAttributes(background_pixel=0, override_redirect=1)
panels = [x11.XCreateWindow(dpy, root, 0, 0, 1, 1, 0, 0, 1, None,
                            (1 << 1) | (1 << 9), c.byref(sa)) for _ in range(4)]
barriers, fenced = [], None


def pointer():
    r, ch, rx, ry, wx, wy, m = W(), W(), c.c_int(), c.c_int(), c.c_int(), c.c_int(), c.c_uint()
    x11.XQueryPointer(dpy, root, c.byref(r), c.byref(ch), c.byref(rx), c.byref(ry),
                      c.byref(wx), c.byref(wy), c.byref(m))
    return rx.value, ry.value


def fence_to(area):
    global barriers, fenced
    if not xf:
        return
    for b in barriers:
        xf.XFixesDestroyPointerBarrier(dpy, b)
    barriers, fenced = [], None
    if not area:
        return
    x, y, w, h = area
    # A barrier doesn't move a pointer that's already outside - and would
    # then trap it there - so put it in the middle of the game first
    px, py = pointer()
    if not (x <= px < x + w and y <= py < y + h):
        x11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0, x + w // 2, y + h // 2)
    for x1, y1, x2, y2, need in ((x, 0, x, fh, x > 0),                  # left
                                 (x + w, 0, x + w, fh, x + w < fw),     # right
                                 (0, y, fw, y, y > 0),                  # top
                                 (0, y + h, fw, y + h, y + h < fh)):    # bottom
        if need:
            barriers.append(xf.XFixesCreatePointerBarrier(dpy, root, x1, y1, x2, y2,
                                                          0, 0, None))
    fenced = area


def keep_inside():
    # The pointer can still end up outside the fence: moved fast just as the
    # game's area changed (before the fence moved), or moved there by the
    # game or Wine (a barrier stops the mouse, not a program moving the
    # pointer) - and the fence then keeps it OUT. Checked every time round:
    # if it's outside, it's put just inside the nearest edge.
    if not fenced:
        return
    x, y, w, h = fenced
    px, py = pointer()
    if x <= px < x + w and y <= py < y + h:
        return
    x11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0,
                     min(max(px, x), x + w - 1), min(max(py, y), y + h - 1))
    x11.XFlush(dpy)


HOLD = os.environ.get("BOOT_HOLD_FILE")
def held():
    return bool(HOLD) and os.path.exists(HOLD)

def show(rects, area):
    global shown
    shown = []
    for i, p in enumerate(panels):
        px, py, pw, ph = rects[i] if i < len(rects) else (0, 0, 0, 0)
        if pw > 0 and ph > 0:
            x11.XMoveResizeWindow(dpy, p, px, py, pw, ph)
            x11.XMapRaised(dpy, p)
            shown.append(p)
        else:
            x11.XUnmapWindow(dpy, p)
    fence_to(area)
    x11.XFlush(dpy)

shown, buf, pending, latest = [], b"", None, None
while True:
    if select.select([0], [], [], 0.5)[0]:
        data = os.read(0, 4096)
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            v = line.split()
            rects, area = [], None
            if len(v) == 8:
                l, t, r, b, x, y, w, h = map(int, v)
                area = (x, y, w, h)
                rects = [(l, t, x - l, b - t),              # left
                         (x + w, t, r - (x + w), b - t),    # right
                         (x, t, w, y - t),                  # top
                         (x, y + h, w, b - (y + h))]        # bottom
            pending = latest = (rects, area)
    if held():
        if shown:                           # out of the way until it's released
            for p in shown:
                x11.XUnmapWindow(dpy, p)
            fence_to(None)
            x11.XFlush(dpy)
            shown, pending = [], latest
    elif pending:
        show(*pending)
        pending = None
    elif shown:
        for p in shown:                     # Wine raises its windows - stay on top
            x11.XRaiseWindow(dpy, p)
        x11.XFlush(dpy)
    if not held():
        keep_inside()
