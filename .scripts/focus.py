# Keyboard focus keeper - started by focus_start (display.inc)
#
# Without a window manager (or when one fails to hand it over), X gives the
# keyboard to whatever window is under the pointer - with the pointer hidden,
# often none of the game's. Every second: if no window has the keyboard
# focus, it's given to the largest visible window of the named programs
# (normally Wine's desktop, explorer.exe - Wine passes keys on to the game).
# A window that already has the focus is left alone, so this never fights a
# window manager or the game.
# Arguments: tag program... (e.g. keep-focus explorer.exe)
# X11 via ctypes - nothing to install.
import ctypes as c, ctypes.util, sys, time

names = [n.lower().encode() for n in sys.argv[2:]]      # argv[1] = tag
x11 = c.CDLL(c.util.find_library("X11") or "libX11.so.6")
W, P = c.c_ulong, c.c_void_p


class XWindowAttributes(c.Structure):
    _fields_ = [("x", c.c_int), ("y", c.c_int), ("width", c.c_int), ("height", c.c_int),
                ("border_width", c.c_int), ("depth", c.c_int), ("visual", P),
                ("root", W), ("class_", c.c_int), ("bit_gravity", c.c_int),
                ("win_gravity", c.c_int), ("backing_store", c.c_int),
                ("backing_planes", c.c_ulong), ("backing_pixel", c.c_ulong),
                ("save_under", c.c_int), ("colormap", W), ("map_installed", c.c_int),
                ("map_state", c.c_int), ("all_event_masks", c.c_long),
                ("your_event_mask", c.c_long), ("do_not_propagate_mask", c.c_long),
                ("override_redirect", c.c_int), ("screen", P)]


class XClassHint(c.Structure):
    _fields_ = [("res_name", P), ("res_class", P)]


x11.XOpenDisplay.restype = P
x11.XOpenDisplay.argtypes = [c.c_char_p]
x11.XDefaultRootWindow.restype = W
x11.XDefaultRootWindow.argtypes = [P]
x11.XQueryTree.argtypes = [P, W, c.POINTER(W), c.POINTER(W), c.POINTER(c.POINTER(W)),
                           c.POINTER(c.c_uint)]
x11.XGetWindowAttributes.argtypes = [P, W, c.POINTER(XWindowAttributes)]
x11.XGetClassHint.argtypes = [P, W, c.POINTER(XClassHint)]
x11.XGetInputFocus.argtypes = [P, c.POINTER(W), c.POINTER(c.c_int)]
x11.XSetInputFocus.argtypes = [P, W, c.c_int, c.c_ulong]
x11.XFree.argtypes = [P]
x11.XFlush.argtypes = [P]
x11.XSync.argtypes = [P, c.c_int]
HANDLER = c.CFUNCTYPE(c.c_int, P, P)
ignore = HANDLER(lambda d, e: 0)          # windows can vanish mid-query
x11.XSetErrorHandler(ignore)

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit("keep-focus: cannot open X display")
root = x11.XDefaultRootWindow(dpy)


def children(w):
    r, p, ch, n = W(), W(), c.POINTER(W)(), c.c_uint()
    if not x11.XQueryTree(dpy, w, c.byref(r), c.byref(p), c.byref(ch), c.byref(n)):
        return []
    out = [ch[i] for i in range(n.value)]
    if ch:
        x11.XFree(ch)
    return out


def candidates(w=root, depth=0):
    # (rank, area, window): rank = position of its program in the list
    for k in children(w):
        a = XWindowAttributes()
        if x11.XGetWindowAttributes(dpy, k, c.byref(a)) and a.map_state == 2:
            h = XClassHint()
            if x11.XGetClassHint(dpy, k, c.byref(h)):
                name = c.string_at(h.res_name).lower() if h.res_name else b""
                for q in (h.res_name, h.res_class):
                    if q:
                        x11.XFree(q)
                if name in names:
                    yield (names.index(name), -a.width * a.height, k)
        if depth < 2:
            yield from candidates(k, depth + 1)


last = None
while True:
    time.sleep(1)
    f, rev = W(), c.c_int()
    x11.XGetInputFocus(dpy, c.byref(f), c.byref(rev))
    if f.value not in (0, 1, root):          # None/PointerRoot/root: nobody
        continue
    found = sorted(candidates())
    if not found:
        continue
    w = found[0][2]
    x11.XSetInputFocus(dpy, w, 2, 0)         # RevertToParent, CurrentTime
    x11.XSync(dpy, 0)
    if w != last:
        print("Keyboard focus given to 0x%x (%s)" % (w, names[found[0][0]].decode()),
              flush=True)
        last = w
