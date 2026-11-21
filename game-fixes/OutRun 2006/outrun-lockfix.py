#!/usr/bin/env python3
# =============================================================================
#  outrun-lockfix.py - OutRun 2006: Coast 2 Coast (PC) thread-safety fixes
#  Version 2
#
#  Makes OR2006C2C_PATCHED.EXE from OR2006C2C.EXE (the original is not
#  changed). Run it once, in the game folder, on the Pi or on a PC:
#      python3 outrun-lockfix.py
#  (or:  python3 outrun-lockfix.py /path/to/OR2006C2C.EXE)
#  A version 1 OR2006C2C_PATCHED.EXE can also be given as the input: only
#  the fixes it is missing are added.
#
#  All three bugs are in the game's background file loader, and are races
#  between it and the main thread. On a real PC each gap is a few
#  instructions wide, so they almost never happen; under Box64 the gaps are
#  much wider.
#
#  1. The loading queue (version 1)  - loader thread, 0x423670
#     Requests are passed to the loader in a "pending" list and moved to an
#     "active" list. Each list is guarded by a semaphore whose handle is kept
#     next to it. The loader takes both semaphores, then sets both handle
#     variables to 0 while it moves the request - so that the list functions
#     it calls skip locking. But any OTHER thread that adds a request at that
#     moment also reads 0, skips locking too, and changes the same list at
#     the same time, breaking it:
#       - the loader takes an empty entry -> crash at 0x4245B4 / 0x4245C8
#       - or a request is lost -> the game waits for it for ever
#     Fix: the loader no longer sets the handles to 0; it moves the request
#     with two small copies of the list functions that don't lock (it
#     already holds both locks), in unused space at the end of the code
#     section (0x595890).
#
#  2. The "parts still loading" count (version 2)  - 0x423D71 / 0x4234FE
#     Each file request counts its parts still being loaded. The main thread
#     adds one (read, add 1, write back - three steps) while the loader
#     takes one away when a part is done. If both happen at once, one change
#     is lost: the count never gets back to 0, and the main thread waits for
#     the file for ever (black screen, 0% CPU, threads in pipe_read).
#     Fix: both changes are made single, locked (atomic) operations.
#
#  3. Waiting for a file (version 2)  - main thread, 0x423BF5
#     If parts are still loading, the main thread creates a semaphore and
#     waits on it; the loader releases it when the count reaches 0 - but
#     only if the semaphore already exists. If the loader finishes between
#     the main thread's check and its creating the semaphore, nobody ever
#     releases it: a wait for ever (black screen, 0% CPU).
#     Fix: the main thread instead checks the count every millisecond
#     (Sleep(1)) until it reaches 0 - no wake-up that can be missed.
#
#  Nothing else in the game is changed.
# =============================================================================
import hashlib, os, struct, sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "OR2006C2C.EXE"
DST = os.path.join(os.path.dirname(os.path.abspath(SRC)), "OR2006C2C_PATCHED.EXE")

TEXT_VA, TEXT_RAW = 0x401000, 0x400          # .text: address <-> file offset
def off(va):
    return va - TEXT_VA + TEXT_RAW

CAVE_VA = 0x595890
POP_NOLOCK, PUSH_NOLOCK = 0x595890, 0x5958D0
CAVE = bytes.fromhex(
    # pop_nolock: eax = list {head, tail, sem} -> eax = first entry (or 0)
    "57 8b38 85ff 742d 3b7804 750f c70000000000 c7400400000000 eb12"
    "51 8b4f04 8908 85c9 7407 c7410800000000 59 c7470400000000"
    "89f8 5f c3 cccccccccccccccc"
    # push_nolock: eax = list, esi = entry -> added at the end
    "57 8b7804 85ff 7412 897704 897e08 c7460400000000 897004 5f c3"
    "8930 897004 c7460400000000 c7460800000000 5f c3")

def call(at, target):
    return b"\xe8" + struct.pack("<i", target - (at + 5))

H = bytes.fromhex
# (address, original bytes, new bytes)
PATCHES = [
    # --- 1. loading queue ---
    # mov [0x955aac],esi / mov [0x955a90],esi  (handles set to 0) -> nops
    (0x4236A2, H("8935ac5a9500"), b"\x90" * 6),
    (0x4236A8, H("8935905a9500"), b"\x90" * 6),
    # call list_pop -> call pop_nolock
    (0x4236AE, call(0x4236AE, 0x4244F0), call(0x4236AE, POP_NOLOCK)),
    # call list_push -> call push_nolock
    (0x4236EC, call(0x4236EC, 0x424580), call(0x4236EC, PUSH_NOLOCK)),

    # --- 2. parts-still-loading count: atomic add / subtract ---
    # main thread:  mov edx,[edi+1c] ... inc edx ... mov [edi+1c],edx
    #   -> lock inc dword [edi+1c] (other instructions kept, test last)
    (0x423D71, H("8b571c 8b4728 03e9 42 85c0 896f04 89571c"),
               H("f0ff471c 8b4728 03e9 896f04 909090 85c0")),
    # loader thread:  dec dword [eax+1c]  -> lock dec dword [eax+1c]
    (0x4234FB, H("8b4714 ff481c 8b4714 8b481c"),
               H("8b4714 f0ff481c 8b481c 9090")),

    # --- 3. waiting for a file: poll the count instead of a semaphore ---
    #   mov edi,[WaitForSingleObject]        (still used after this)
    #   loop: cmp dword [esi+1c],0 / je 0x423C29 / push 1 / call [Sleep] / jmp loop
    (0x423BF5, H("8b461c 85c0 8b3d14615900 7427 6a00 6a01 6a00 6a00 ff1518615900"
                 "6aff 50 894620 ffd7 8b4620 50 ff15ec605900 c7462000000000"),
               H("8b3d14615900 837e1c00 0f8424000000 6a01 ff1500615900 ebec")
               + b"\x90" * 26),
]

def main():
    try:
        d = bytearray(open(SRC, "rb").read())
    except OSError as e:
        sys.exit(f"ERROR: can't read {SRC}: {e}")
    print(f"{SRC}: sha1 {hashlib.sha1(d).hexdigest()}")

    pe = struct.unpack_from("<I", d, 0x3C)[0]
    sec = pe + 24 + struct.unpack_from("<H", d, pe + 20)[0]
    name, vsize, va, rsize, raw = struct.unpack_from("<8sIIII", d, sec)
    if name.rstrip(b"\0") != b".text" or va != TEXT_VA - 0x400000 or raw != TEXT_RAW:
        sys.exit("ERROR: not the expected OR2006C2C.EXE (code section differs)")

    todo = []
    for at, old, new in PATCHES:
        assert len(old) == len(new), hex(at)
        cur = bytes(d[off(at):off(at) + len(old)])
        if cur == new:
            continue                                  # (already there)
        if cur != old:
            sys.exit(f"ERROR: unexpected bytes at 0x{at:X} ({cur.hex()}) - "
                     "a different version of the game?")
        todo.append((at, new))

    c = off(CAVE_VA)
    cave_now = bytes(d[c:c + len(CAVE)])
    if cave_now != CAVE and any(cave_now):
        sys.exit("ERROR: the unused space at 0x595890 isn't empty")
    if not todo and cave_now == CAVE:
        sys.exit(f"Nothing to do: {SRC} already has every fix")

    for at, new in todo:
        d[off(at):off(at) + len(new)] = new
    d[c:c + len(CAVE)] = CAVE
    # Let the loader read the cave from the file: the code section's file
    # size ended just before it (0x194881); rounded up to cover it, still
    # before the next section (0x195000 in the file)
    new_rsize = (c + len(CAVE) - TEXT_RAW + 0x1FF) & ~0x1FF
    nxt_raw = struct.unpack_from("<I", d, sec + 40 + 20)[0]
    if TEXT_RAW + new_rsize > nxt_raw:
        sys.exit("ERROR: no room for the new code")
    struct.pack_into("<I", d, sec + 16, max(rsize, new_rsize))

    if os.path.abspath(SRC) == os.path.abspath(DST):
        os.replace(DST, DST + ".v1")                  # keep the old one
        print(f"Old version kept as {os.path.basename(DST)}.v1")
    open(DST, "wb").write(d)
    print(f"Fixes added: {len(todo)}")
    print(f"Written: {DST}")
    print(f"         sha1 {hashlib.sha1(d).hexdigest()}")

if __name__ == "__main__":
    main()
