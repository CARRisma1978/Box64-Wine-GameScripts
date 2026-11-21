#!/usr/bin/env python3
# =============================================================================
#  Serious Sam: The First Encounter v1.05 - Engine.dll fix for Box64 + Wine
#
#  Without it the game stops at start-up with:
#      Fatal Error: Write attempted on read-only file stream!
#
#  Why: the engine reads its files through memory that is filled in when
#  first touched (an access-violation handler in Engine.dll). Box64 reports
#  a fault during a "rep movs" copy as a WRITE even when the copy is READING
#  that memory, and the engine then stops with the message above. The fix
#  skips that one check - the page is then filled in as for any read. The
#  check only ever chose between that message and carrying on; nothing else
#  uses it.
#
#  The change: one byte, at file offset 0x1D577 (jne -> jmp, 75 -> EB), in
#  CTFileStream's page handler (address 0x600DD577).
#
#  Run it once, in the game folder (or give the folder or the dll's path):
#      cd ~/RetroPie/roms/windows/"Serious Sam"
#      python3 serioussam-enginefix.py
#  Undo (puts the original back from Engine.dll.orig):
#      python3 serioussam-enginefix.py --undo
#
#  The original is kept as Bin\Engine.dll.orig (never overwritten once
#  there). Only the known v1.05 Engine.dll is changed - anything else is
#  left alone.
# =============================================================================
import hashlib, os, shutil, sys

OFFSET = 0x1D577
CONTEXT = bytes.fromhex("85c97520")          # test ecx,ecx / jne +0x20
CTX_AT = OFFSET - 2                          # where CONTEXT starts
ORIG_BYTE, NEW_BYTE = 0x75, 0xEB
SHA1_ORIG = "db7620f9eafe1e6286f33a5f4a133cf9207e0a07"
SHA1_FIXED = "481cb5520f4db08157afc808fe19d8e60992ea8a"


def find_dll(arg):
    # The game folder, its Bin folder, or the dll itself - any upper/lower case
    start = os.path.abspath(arg or ".")
    if os.path.isfile(start):
        return start
    if not os.path.isdir(start):
        return None
    dirs = [start] + [os.path.join(start, s) for s in os.listdir(start)
                      if s.lower() == "bin" and os.path.isdir(os.path.join(start, s))]
    for d in dirs:
        for name in os.listdir(d):
            if name.lower() == "engine.dll" and os.path.isfile(os.path.join(d, name)):
                return os.path.join(d, name)
    return None


def sha1(data):
    return hashlib.sha1(data).hexdigest()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    undo = "--undo" in sys.argv[1:]
    dll = find_dll(args[0] if args else None)
    if not dll:
        sys.exit("Engine.dll not found - run this in the Serious Sam folder, "
                 "or give the folder's path")
    orig = dll + ".orig"
    print("Engine.dll:", dll)

    if undo:
        if not os.path.isfile(orig):
            sys.exit("No Engine.dll.orig to put back - nothing done")
        if sha1(open(orig, "rb").read()) != SHA1_ORIG:
            print("WARNING: Engine.dll.orig isn't the known v1.05 original - putting it back anyway")
        shutil.copy2(orig, dll)
        print("Original Engine.dll put back (Engine.dll.orig kept)")
        return

    data = bytearray(open(dll, "rb").read())
    h = sha1(data)
    if h == SHA1_FIXED or (len(data) > OFFSET and data[OFFSET] == NEW_BYTE
                           and data[CTX_AT:CTX_AT + 2] == CONTEXT[:2]):
        print("Already fixed - nothing to do")
        return
    if h != SHA1_ORIG:
        # Not the exact known file: only go ahead if the bytes round the
        # change are exactly as expected
        if data[CTX_AT:CTX_AT + len(CONTEXT)] != CONTEXT:
            sys.exit("This isn't the Serious Sam TFE v1.05 Engine.dll this fix is for "
                     "(SHA-1 %s) - nothing changed" % h)
        print("WARNING: not the exact known v1.05 file, but the bytes to change match - fixing")

    if os.path.exists(orig):
        print("Engine.dll.orig already there - kept as it is")
    else:
        shutil.copy2(dll, orig)
        print("Original saved as", os.path.basename(orig))

    data[OFFSET] = NEW_BYTE
    tmp = dll + ".tmp"
    with open(tmp, "wb") as out:
        out.write(data)
    shutil.copymode(dll, tmp)
    os.replace(tmp, dll)                     # (all or nothing)

    check = open(dll, "rb").read()
    if check[OFFSET] != NEW_BYTE:
        sys.exit("ERROR: the change didn't stick - put Engine.dll.orig back")
    if h == SHA1_ORIG and sha1(check) != SHA1_FIXED:
        print("WARNING: result isn't the expected file (SHA-1 %s)" % sha1(check))
    print("Fixed: offset 0x%X  %02X -> %02X" % (OFFSET, ORIG_BYTE, NEW_BYTE))


if __name__ == "__main__":
    main()
