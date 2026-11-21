#!/usr/bin/env python3
# =============================================================================
#  Jazz Jackrabbit 2 (v1.23) - patches for running under Box64 / Wine
#
#  Makes Jazz2-pi.exe: a patched copy of Jazz2.exe. Jazz2.exe itself is
#  never modified. Run once (and again after updating this file, or if
#  Jazz2.exe changes). Every patch only changes or rearranges existing
#  instructions - nothing is added or moved.
#
#  1. FPU memory copy: on a Pentium or later, JJ2 copies memory 8 bytes at
#     a time through the x87 FPU (FILD/FISTP QWORD - a 1990s speed trick).
#     Box64 does x87 maths in 64-bit doubles, which hold only 53 bits, so
#     the low byte of every 8 gets damaged: thin vertical lines in the
#     picture and a crash on exit (a pointer copied wrongly).
#     At 0x4926AE "je" (74 0E), which skips installing the FPU copy when
#     there's no FPU, becomes "jmp" (EB 0E): always skipped, so the game
#     keeps its plain memory copy. CPU detection, MMX etc. are unaffected.
#
#  2-4. Sound shutdown race: the sound system (Galaxy Music System) mixes on
#     a winmm timer. Its two timer callbacks checked "sound running?"
#     BEFORE taking the sound lock, and the shutdown took the lock, then
#     stopped the timer and released the buffers, and marked sound off
#     last. Slowed down by emulation, the threads collide: a late timer
#     tick used a freed sound buffer (Access Violation on exit), or the
#     exit hung waiting for the lock.
#     2. DirectSound timer callback (0x4A2A40) and
#     3. wave-out timer callback (0x4A2C30): take the lock first, then
#        check "sound running?" - if not, release the lock and return.
#     4. Shutdown (0x4A3B80): mark sound off first, stop the timer, THEN
#        take the lock and release the buffers (as before) - no lock held
#        while stopping the timer.
#
#  The bytes at each patch are checked first, so any other exe version is
#  refused and nothing is written.
#
#  Usage (on the Pi, over SSH):
#      python3 ~/RetroPie/roms/windows/Jazz2/jj2-patch.py
#  or on Windows: double-click it, or  py jj2-patch.py
#  Options: [source.exe [patched.exe]] - default: Jazz2.exe -> Jazz2-pi.exe,
#  in the folder this .py is in.
# =============================================================================
import os
import sys

# (name, file offset, original bytes from that offset, replacement bytes)
PATCHES = [
    ("FPU memory copy off", 0x91AAE,
     bytes.fromhex("740e3c05720ac705fc3d4d008cc74900"), bytes.fromhex("eb0e")),
    # sub esp,10 / push edi,esi,ebx / EnterCriticalSection / check flag,
    # if off: je 0x4A2C16 (LeaveCriticalSection, return)
    ("Sound: DirectSound timer checks under lock", 0xA1E40,
     bytes.fromhex("a0d486600083ec1084c00f84d401000057565368c0836000ff15f0514c00"),
     bytes.fromhex("83ec1057565368c0836000ff15f0514c00a0d486600084c00f84b8010000")),
    # sub esp,0c / push ebx / EnterCriticalSection / check flag,
    # if off: je 0x4A2D0F (LeaveCriticalSection, return)
    ("Sound: wave-out timer checks under lock", 0xA2030,
     bytes.fromhex("a0d486600083ec0c84c00f84db0000005368c0836000ff15f0514c00"),
     bytes.fromhex("83ec0c5368c0836000ff15f0514c00a0d486600084c00f84c3000000")),
    # flag = 0 / timeKillEvent / EnterCriticalSection / timeEndPeriod(1) /
    # mov eax,[0x6083DC] - same instructions, new order
    ("Sound: shutdown stops timer before locking", 0xA2F80,
     bytes.fromhex("68c0836000ff15f0514c00a1ac83600050ff153c534c006a01ff1540534c00a1dc836000881dd4866000"),
     bytes.fromhex("881dd4866000a1ac83600050ff153c534c0068c0836000ff15f0514c006a01ff1540534c00a1dc836000")),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "Jazz2.exe")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(src), "Jazz2-pi.exe")

    try:
        with open(src, "rb") as f:
            data = bytearray(f.read())
    except OSError as e:
        return f"ERROR: can't read {src}: {e}"

    # Check every patch site before changing anything
    for name, off, orig, new in PATCHES:
        found = bytes(data[off:off + len(orig)])
        if found[:len(new)] == new and found[len(new):] == orig[len(new):]:
            return f"ERROR: {src} is already patched ({name}) - give the original Jazz2.exe"
        if found != orig:
            return (f"ERROR: {src} isn't the JJ2 v1.23 exe these patches are for "
                    f"(bytes at 0x{off:X}: {found.hex()}) - nothing changed")

    for name, off, orig, new in PATCHES:
        data[off:off + len(new)] = new

    if os.path.exists(dst):
        with open(dst, "rb") as f:
            if f.read() == bytes(data):
                print(f"{dst} is already up to date - nothing to do")
                return 0

    tmp = dst + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, dst)
    except OSError as e:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return f"ERROR: can't write {dst}: {e}"

    print(f"Made {dst} from {src}:")
    for name, off, orig, new in PATCHES:
        print(f"  0x{off:X}: {orig[:len(new)].hex(' ').upper()} -> {new.hex(' ').upper()}  ({name})")
    return 0


if __name__ == "__main__":
    rc = main()
    if isinstance(rc, str):
        print(rc, file=sys.stderr)
        rc = 1
    if os.name == "nt" and not sys.stdin.closed and len(sys.argv) == 1:
        input("Press Enter to close")       # (double-clicked on Windows)
    sys.exit(rc)
