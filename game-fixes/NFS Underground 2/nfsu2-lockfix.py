#!/usr/bin/env python3
# =====================================================================
#  NFSU2 v1.2 (SPEED2.EXE md5 6445adbf4e8d64be51e96a69bba168a4)
#  Menu-crash fix: makes the game's home-made lock thread-safe.
#
#  The code at 0x738E20-0x73B9A7 guards shared data with two globals:
#    0x8B7BC0 = "in use" flag, 0x8B7BB0 = pointer to the current slot.
#  Taking the lock was "check flag == 0 ... later set flag = -1" (two steps),
#  so two threads could both get in; when one finished it zeroed the pointer
#  under the other -> read of [0 + 0x38] at 0x73927D.
#
#  Patch 1  0x73B620  lock routine: claim with one atomic LOCK CMPXCHG. If a
#           claim (-1 argument) finds the lock already taken it returns 0, so
#           the caller takes its normal "busy" exit (every caller checks this).
#  Patch 2  0x73B91A  the periodic update routine claims the lock itself -
#           same atomic claim there.
#  Patch 3  24 unlock sites: clear the pointer BEFORE the flag (was flag first),
#           so nobody can take the lock and then have their pointer wiped.
#
#  Writes a NEW file; the original exe is not modified.
#  Usage:  python3 nfsu2-lockfix.py SPEED2.EXE SPEED2_PATCHED.EXE
# =====================================================================
import hashlib, struct, sys

EXPECTED_MD5 = "6445adbf4e8d64be51e96a69bba168a4"
IMAGEBASE, TEXT_VA, TEXT_RAW = 0x400000, 0x1000, 0x1000
C0, B0 = struct.pack("<I", 0x8B7BC0), struct.pack("<I", 0x8B7BB0)

def off(va):
    return va - IMAGEBASE - TEXT_VA + TEXT_RAW

def put(data, va, old, new):
    o = off(va)
    assert len(old) == len(new), "length mismatch at %08X" % va
    cur = bytes(data[o:o + len(old)])
    if cur == new:
        return "already patched"
    if cur != old:
        sys.exit("ABORT: unexpected bytes at %08X\n  found    %s\n  expected %s"
                 % (va, cur.hex(), old.hex()))
    data[o:o + len(old)] = new
    return "patched"

def build(data):
    log = []

    # ---------- Patch 1: lock routine 0x73B620-0x73B67F (96 bytes) ----------
    old1 = bytes.fromhex(
        "a1c07b8b00" "85c0" "7508" "83c8ff" "a3c07b8b00"          # 73B620 check-then-set
        "8b542404"                                                # 73B631 mov edx,[esp+4]
        "85d2" "7c31" "83fa04" "7d2c" "8bca" "69c928090000" "56"  # 73B635 .. (tail)
        "8bb144578b00" "85f6" "5e" "7418" "8b8140578b00"
        "8d8910578b00" "890db07b8b00" "a3c07b8b00" "c3"
        "83faff" "7407" "33c0" "a3c07b8b00" "c3"                  # 73B66A .. 73B676
        "909090909090909090")                                     # 73B677 .. 73B67F
    tail = old1[0x15:0x57]            # 73B635..73B676, only relative jumps inside itself
    new1 = (bytes.fromhex("8b542404")          # mov  edx,[esp+4]
            + bytes.fromhex("33c0")            # xor  eax,eax
            + bytes.fromhex("83c9ff")          # or   ecx,-1
            + bytes.fromhex("f00fb10d") + C0   # lock cmpxchg [8B7BC0],ecx
            + bytes.fromhex("7408")            # je   got_it
            + bytes.fromhex("83faff")          # cmp  edx,-1
            + bytes.fromhex("7505")            # jne  select   (already held, pick slot)
            + bytes.fromhex("33c0c3")          # xor eax,eax ; ret  -> "busy"
            + bytes.fromhex("8bc1")            # got_it: mov eax,ecx (-1, like before)
            + tail)                            # select: original code, shifted +8
    new1 += b"\x90" * (len(old1) - len(new1))
    log.append(("73B620 atomic lock", put(data, 0x73B620, old1, new1)))

    # ---------- Patch 2: update routine claim 0x73B91A-0x73B937 (30 bytes) ----------
    old2 = bytes.fromhex("a1c07b8b00" "85c0" "0f8580000000"        # check flag
                         "8a442404" "55" "56" "57"                   # mov al,[esp+4]; push x3
                         "c705c07b8b00ffffffff")                     # set flag = -1
    new2 = (bytes.fromhex("33c0") + bytes.fromhex("83c9ff")
            + bytes.fromhex("f00fb10d") + C0                         # lock cmpxchg
            + bytes.fromhex("757e")                                  # jne 73B9A7 (busy -> ret)
            + bytes.fromhex("8a442404" "555657"))
    new2 += b"\x90" * (len(old2) - len(new2))
    log.append(("73B91A atomic lock", put(data, 0x73B91A, old2, new2)))

    # ---------- Patch 3: unlock order (pointer first, then flag) ----------
    sites = {  # address of the flag store : encoding of one store
        "a3":   [0x738ED0, 0x739117, 0x7393C2, 0x739528, 0x739BA7,
                 0x73A534, 0x73A635, 0x73A714, 0x73B261],
        "892d": [0x73924E],
        "890d": [0x739AE4, 0x73A9A7, 0x73A9C2, 0x73AA9A, 0x73ACF7],
        "891d": [0x73AE26],
        "c705": [0x738FDB, 0x739C2D, 0x739CBD, 0x73AF48, 0x73B01E,
                 0x73B089, 0x73B10E, 0x73B992],
    }
    for op, addrs in sites.items():
        pre = bytes.fromhex(op)
        imm = b"\0\0\0\0" if op == "c705" else b""
        first, second = pre + C0 + imm, pre + B0 + imm
        for va in addrs:
            log.append(("%08X unlock order" % va, put(data, va, first + second, second + first)))
    return log

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__ or "usage: nfsu2-lockfix.py SPEED2.EXE SPEED2_PATCHED.EXE")
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    md5 = hashlib.md5(data).hexdigest()
    if md5 != EXPECTED_MD5:
        sys.exit("ABORT: %s md5 is %s, expected %s (different exe version)" % (src, md5, EXPECTED_MD5))
    for what, res in build(data):
        print("%-24s %s" % (what, res))
    open(dst, "wb").write(data)
    print("\nWritten %s  (md5 %s)" % (dst, hashlib.md5(data).hexdigest()))

if __name__ == "__main__":
    main()