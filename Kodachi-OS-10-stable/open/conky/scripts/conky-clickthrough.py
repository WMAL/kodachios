#!/usr/bin/env python3
"""Make Kodachi's conky panels click-through: keep the X input region of every conky window EMPTY,
so a click on a panel reaches the desktop, and the desktop icons, underneath it.

WHY (reported by a user, 2026-10-06). The panels use `own_window_type normal` with the hints
`undecorated,below,sticky,...`: they stay below other windows and survive "show desktop". A normal
window takes mouse input over its whole area, so a desktop icon under a panel could not be clicked.
Measured on test VMs (conky 1.22.1, xfwm4): all five panels had a full input region; with an empty
one on the conky window alone (its xfwm4 frame untouched) the X server puts the pointer on xfdesktop
at the same spot. No Kodachi panel uses Lua mouse hooks, so the panels lose nothing.

WHY IT STAYS RUNNING. conky resets the region whenever it re-initialises its window: a config reload
re-maps the window and gives it a full region again (measured on VM .220; a plain resize keeps it
empty). So this watches instead of shaping once. It sleeps on the X connection, which wakes it for
every window event on the root (the X server sends them all, moves and resizes included), and it
does real work only for the few that concern a panel: a map or reparent of a window that is or
holds a Conky window (a full scan), the unmap or destroy of a watched panel or its frame (a full
scan), and an input-shape change on a watched panel (that one window is checked and emptied again).
An unrelated unmap, destroy or configure costs no X round trip; an unrelated map or reparent costs
two plus one per child window of the new window. Measured on VM .239 on 2026-10-06 with a burst of
short-lived windows (not part of the VM test): 1.23 ms of CPU per managed window, 0.50 ms per popup,
0 ticks in 60 s idle. Every window of class Conky is treated as a panel: the launcher stops every
conky of this user (pkill -x conky) before it starts the panels. A window cannot be tied to its panel
more tightly: conky sets no _NET_WM_PID, its title is the hostname, and X-Resource names the pid
that OPENED the connection, which every panel's `background yes` fork has already left (measured:
5 of 5 pids gone from /proc).

LIFETIME. One instance per user and display: a lock in $XDG_RUNTIME_DIR, or in ~/.cache/kodachi when
that is unset (never /tmp). A second instance waits up to --linger + 5 seconds for the lock, so a
launcher restart never ends with no watcher. It exits 0 when the X server goes away (logout) and when
no Conky window has existed for --linger seconds (panels stopped). It never edits a conky config and
is never fatal: any failure is printed and it exits 0, and the panels keep running exactly as before.
Pure ctypes against libX11 and libXext, no new dependency.

Usage: conky-clickthrough.py [--linger SECONDS] [--class NAME]
"""
import ctypes
import ctypes.util
import fcntl
import os
import re
import select
import sys
import time


def say(message):
    try:
        print(f'conky-clickthrough: {message}', file=sys.stderr, flush=True)
    except OSError:  # whoever started us may be gone along with its stderr
        pass


LINGER = 30.0
WM_CLASS = b'Conky'
try:
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a in ('--linger', '--wait') and args:
            LINGER = max(1.0, float(args.pop(0)))
        elif a == '--class' and args:
            WM_CLASS = args.pop(0).encode()
        else:
            raise ValueError(f'unknown argument {a!r}')
except ValueError as exc:
    say(f'{exc}; usage: conky-clickthrough.py [--linger SECONDS] [--class NAME]')
    sys.exit(0)

display_name = os.environ.get('DISPLAY', '')
if not display_name:
    say('no DISPLAY; panels stay clickable')
    sys.exit(0)

# One watcher per user and display. A second instance waits for the lock instead of giving up at
# once, so a watcher that is about to exit (its panels were just stopped) cannot strand the new ones.
# Without XDG_RUNTIME_DIR (started outside a login session) the lock lives in the user's own cache, not in
# /tmp, where another local user could create the path first and keep this watcher from ever starting.
runtime_dir = os.environ.get('XDG_RUNTIME_DIR') or os.path.join(os.path.expanduser('~'), '.cache', 'kodachi')
try:
    os.makedirs(runtime_dir, mode=0o700, exist_ok=True)
except OSError:
    pass
lock_path = os.path.join(runtime_dir, 'kodachi-conky-clickthrough-%d-%s.lock'
                         % (os.getuid(), re.sub(r'[^A-Za-z0-9_.-]', '_', display_name)))
try:
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
except OSError as exc:
    say(f'cannot open the lock {lock_path}: {exc}; panels stay clickable')
    sys.exit(0)
lock_deadline = time.monotonic() + LINGER + 5.0
while True:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError:
        if time.monotonic() >= lock_deadline:
            say('another watcher is running for this display; leaving it to that one')
            sys.exit(0)
        time.sleep(1.0)


def load(name, soname):
    try:
        return ctypes.CDLL(soname)
    except OSError:
        path = ctypes.util.find_library(name)
        return ctypes.CDLL(path) if path else None


x11 = load('X11', 'libX11.so.6')
xext = load('Xext', 'libXext.so.6')
if x11 is None or xext is None:
    say('libX11 or libXext not found; panels stay clickable')
    sys.exit(0)


class XClassHint(ctypes.Structure):
    # Raw pointers, not c_char_p: reading a c_char_p field returns a Python COPY, and handing that copy to
    # XFree aborts the process ("munmap_chunk(): invalid pointer", measured on the first VM run).
    _fields_ = [('res_name', ctypes.c_void_p), ('res_class', ctypes.c_void_p)]


class XEvent(ctypes.Union):
    _fields_ = [('type', ctypes.c_int), ('pad', ctypes.c_long * 24)]


Display = ctypes.c_void_p
Window = ctypes.c_ulong
x11.XOpenDisplay.restype = Display
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XDefaultRootWindow.restype = Window
x11.XDefaultRootWindow.argtypes = [Display]
x11.XQueryTree.argtypes = [Display, Window, ctypes.POINTER(Window), ctypes.POINTER(Window),
                           ctypes.POINTER(ctypes.POINTER(Window)), ctypes.POINTER(ctypes.c_uint)]
x11.XGetClassHint.argtypes = [Display, Window, ctypes.POINTER(XClassHint)]
x11.XFree.argtypes = [ctypes.c_void_p]
x11.XSync.argtypes = [Display, ctypes.c_int]
x11.XFlush.argtypes = [Display]
x11.XPending.argtypes = [Display]
x11.XNextEvent.argtypes = [Display, ctypes.POINTER(XEvent)]
x11.XSelectInput.argtypes = [Display, Window, ctypes.c_long]
x11.XConnectionNumber.argtypes = [Display]
xext.XShapeQueryExtension.argtypes = [Display, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
xext.XShapeCombineRectangles.argtypes = [Display, Window, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                         ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
xext.XShapeGetRectangles.restype = ctypes.c_void_p
xext.XShapeGetRectangles.argtypes = [Display, Window, ctypes.c_int, ctypes.POINTER(ctypes.c_int),
                                     ctypes.POINTER(ctypes.c_int)]
xext.XShapeSelectInput.argtypes = [Display, Window, ctypes.c_ulong]
SHAPE_INPUT, SHAPE_SET, UNSORTED, SHAPE_NOTIFY_MASK = 2, 0, 0, 1
SUBSTRUCTURE_NOTIFY_MASK = 1 << 19
DESTROY_NOTIFY, UNMAP_NOTIFY, MAP_NOTIFY, REPARENT_NOTIFY = 17, 18, 19, 21


class XAnyWindowEvent(ctypes.Structure):
    # The common head of XMapEvent, XUnmapEvent, XDestroyWindowEvent and XReparentEvent: `window` is the
    # window the event is about. XShapeEvent has its window where these have `event`.
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong), ('send_event', ctypes.c_int),
                ('display', ctypes.c_void_p), ('event', ctypes.c_ulong), ('window', ctypes.c_ulong)]

# Xlib's default error handler EXITS the process. A window can be destroyed between listing it and
# shaping it (a panel restarting), and that must cost nothing, so X errors are counted, not fatal.
ERRORS = [0]
ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, Display, ctypes.c_void_p)
IO_ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, Display)
SHAPED = [0]


def _ignore(_display, _event):
    ERRORS[0] += 1
    return 0


def _display_gone(_display):
    # Xlib exits the process with status 1 once this returns, so leave first, with status 0: the X
    # server went away (a logout), which is the normal end of this watcher.
    say(f'the X server went away; exiting after making {SHAPED[0]} window(s) click-through')
    os._exit(0)


_handler = ERROR_HANDLER(_ignore)
_io_handler = IO_ERROR_HANDLER(_display_gone)
x11.XSetErrorHandler.argtypes = [ERROR_HANDLER]
x11.XSetErrorHandler(_handler)
x11.XSetIOErrorHandler.argtypes = [IO_ERROR_HANDLER]
x11.XSetIOErrorHandler(_io_handler)

dpy = x11.XOpenDisplay(None)
if not dpy:
    say('cannot open the X display; panels stay clickable')
    sys.exit(0)
shape_event_base, shape_error_base = ctypes.c_int(), ctypes.c_int()
if not xext.XShapeQueryExtension(dpy, ctypes.byref(shape_event_base), ctypes.byref(shape_error_base)):
    say('the X server has no SHAPE extension; panels stay clickable')
    sys.exit(0)
root = x11.XDefaultRootWindow(dpy)


def children(win):
    r, p = Window(), Window()
    kids = ctypes.POINTER(Window)()
    n = ctypes.c_uint()
    if not x11.XQueryTree(dpy, win, ctypes.byref(r), ctypes.byref(p), ctypes.byref(kids), ctypes.byref(n)):
        return []
    out = [kids[i] for i in range(n.value)]
    if kids:
        x11.XFree(kids)
    return out


def wm_class(win):
    hint = XClassHint()
    if not x11.XGetClassHint(dpy, win, ctypes.byref(hint)):
        return None
    value = ctypes.string_at(hint.res_class) if hint.res_class else None
    if hint.res_name:
        x11.XFree(hint.res_name)
    if hint.res_class:
        x11.XFree(hint.res_class)
    return value


def input_rectangles(win):
    count, ordering = ctypes.c_int(), ctypes.c_int()
    rects = xext.XShapeGetRectangles(dpy, win, SHAPE_INPUT, ctypes.byref(count), ctypes.byref(ordering))
    if rects:
        x11.XFree(rects)
    return count.value


watched = {}  # Conky client window -> its window-manager frame (or None when it has no frame)


def empty_if_needed(win):
    if input_rectangles(win) != 0:
        xext.XShapeCombineRectangles(dpy, win, SHAPE_INPUT, 0, 0, None, 0, SHAPE_SET, UNSORTED)
        SHAPED[0] += 1


def full_scan():
    """Rebuild the watched set from the window tree and empty every Conky window that needs it."""
    found = {}
    for top in children(root):
        if wm_class(top) == WM_CLASS:
            found[top] = None
            continue
        for kid in children(top):
            if wm_class(kid) == WM_CLASS:
                found[kid] = top
    for win in found:
        if win not in watched:
            xext.XShapeSelectInput(dpy, win, SHAPE_NOTIFY_MASK)
        empty_if_needed(win)
    watched.clear()
    watched.update(found)
    x11.XSync(dpy, 0)


def holds_conky(win):
    """True when `win` is a Conky window or a frame with one inside: one or a few round trips."""
    if wm_class(win) == WM_CLASS:
        return True
    return any(wm_class(kid) == WM_CLASS for kid in children(win))


def handle(event):
    if event.type == shape_event_base.value:
        win = ctypes.cast(ctypes.byref(event), ctypes.POINTER(XAnyWindowEvent)).contents.event
        if win in watched:
            empty_if_needed(win)
        return
    if event.type not in (DESTROY_NOTIFY, UNMAP_NOTIFY, MAP_NOTIFY, REPARENT_NOTIFY):
        return
    win = ctypes.cast(ctypes.byref(event), ctypes.POINTER(XAnyWindowEvent)).contents.window
    if event.type in (DESTROY_NOTIFY, UNMAP_NOTIFY):
        if win in watched or win in watched.values():
            full_scan()
    elif win in watched or win in watched.values() or holds_conky(win):
        full_scan()


try:
    x11.XSelectInput(dpy, root, SUBSTRUCTURE_NOTIFY_MASK)
    full_scan()
    fd = x11.XConnectionNumber(dpy)
    event = XEvent()
    last_seen = time.monotonic()
    while True:
        if watched:
            last_seen = time.monotonic()
        elif time.monotonic() - last_seen >= LINGER:
            break
        # XPending flushes the request buffer and counts the events Xlib already holds. Sleep on the
        # socket only when it is 0: replies awaited during a scan pull events off the socket into
        # Xlib's queue, and select() cannot see those. With panels present, sleep until X has
        # something to say; without, wake once a second to notice that the linger time is up.
        if not x11.XPending(dpy):
            select.select([fd], [], [], None if watched else 1.0)
        while x11.XPending(dpy):
            x11.XNextEvent(dpy, ctypes.byref(event))
            handle(event)
        x11.XFlush(dpy)
    message = f'no conky panel for {LINGER:.0f} s; exiting after making {SHAPED[0]} window(s) click-through'
except Exception as exc:  # never fatal: the panels keep running as they are
    message = f'stopped early after making {SHAPED[0]} window(s) click-through: {exc}'
say(f'{message} ({ERRORS[0]} X error(s) ignored)')
sys.exit(0)
