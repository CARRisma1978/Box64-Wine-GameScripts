# =============================================================================
#  outrun-lockfix.ps1 - OutRun 2006: Coast 2 Coast (PC) thread-safety fixes
#  Version 2 - PowerShell version of outrun-lockfix.py (same fixes, same checks)
#
#  Makes OR2006C2C_PATCHED.EXE from OR2006C2C.EXE (the original is not
#  changed). Run it once, on the Windows laptop:
#      Copy this .ps1 into the game folder on the Pi's Samba share, then
#      right-click it > Run with PowerShell.
#  Or from a PowerShell window:
#      .\outrun-lockfix.ps1 [path\to\OR2006C2C.EXE]
#  (default: OR2006C2C.EXE in the folder this .ps1 is in)
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
param(
    [string]$Source
)
$ErrorActionPreference = 'Stop'
$PauseAtEnd = ($PSBoundParameters.Count -eq 0)    # (started with Run with PowerShell)

function Done([int]$code) {
    if ($PauseAtEnd) { [void](Read-Host 'Press Enter to close') }
    exit $code
}
function Fail([string]$msg) {
    Write-Host $msg -ForegroundColor Red
    Done 1
}
function FullPath([string]$p) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}
function Hex([string]$h) {
    $h = $h -replace '\s', ''
    $b = New-Object byte[] ($h.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
    return ,$b
}
function ToHex([byte[]]$b) {
    (@($b) | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}
function Slice([byte[]]$d, [int]$o, [int]$n) {
    $n = [Math]::Max(0, [Math]::Min($n, $d.Length - $o))
    $r = New-Object byte[] $n
    if ($n -gt 0) { [Array]::Copy($d, $o, $r, 0, $n) }
    return ,$r
}
function Sha1Hex([byte[]]$d) {
    ToHex ([Security.Cryptography.SHA1]::Create().ComputeHash($d))
}

if (-not $Source) { $Source = Join-Path $PSScriptRoot 'OR2006C2C.EXE' }
$Source = FullPath $Source
$Dest = Join-Path (Split-Path $Source -Parent) 'OR2006C2C_PATCHED.EXE'

$TEXT_VA = 0x401000; $TEXT_RAW = 0x400          # .text: address <-> file offset
function Off([int]$va) { $va - $TEXT_VA + $TEXT_RAW }

$CAVE_VA = 0x595890
$POP_NOLOCK = 0x595890; $PUSH_NOLOCK = 0x5958D0
$CAVE = Hex (
    # pop_nolock: eax = list {head, tail, sem} -> eax = first entry (or 0)
    '57 8b38 85ff 742d 3b7804 750f c70000000000 c7400400000000 eb12' +
    '51 8b4f04 8908 85c9 7407 c7410800000000 59 c7470400000000' +
    '89f8 5f c3 cccccccccccccccc' +
    # push_nolock: eax = list, esi = entry -> added at the end
    '57 8b7804 85ff 7412 897704 897e08 c7460400000000 897004 5f c3' +
    '8930 897004 c7460400000000 c7460800000000 5f c3')

function CallTo([int]$at, [int]$target) {
    # e8 + 32-bit relative offset (little-endian)
    return ,[byte[]](@(0xE8) + [BitConverter]::GetBytes([int32]($target - ($at + 5))))
}

# (address, original bytes, new bytes)
$PATCHES = @(
    # --- 1. loading queue ---
    # mov [0x955aac],esi / mov [0x955a90],esi  (handles set to 0) -> nops
    ,@(0x4236A2, (Hex '8935ac5a9500'), (Hex '909090909090'))
    ,@(0x4236A8, (Hex '8935905a9500'), (Hex '909090909090'))
    # call list_pop -> call pop_nolock
    ,@(0x4236AE, (CallTo 0x4236AE 0x4244F0), (CallTo 0x4236AE $POP_NOLOCK))
    # call list_push -> call push_nolock
    ,@(0x4236EC, (CallTo 0x4236EC 0x424580), (CallTo 0x4236EC $PUSH_NOLOCK))

    # --- 2. parts-still-loading count: atomic add / subtract ---
    # main thread:  mov edx,[edi+1c] ... inc edx ... mov [edi+1c],edx
    #   -> lock inc dword [edi+1c] (other instructions kept, test last)
    ,@(0x423D71, (Hex '8b571c 8b4728 03e9 42 85c0 896f04 89571c'),
                 (Hex 'f0ff471c 8b4728 03e9 896f04 909090 85c0'))
    # loader thread:  dec dword [eax+1c]  -> lock dec dword [eax+1c]
    ,@(0x4234FB, (Hex '8b4714 ff481c 8b4714 8b481c'),
                 (Hex '8b4714 f0ff481c 8b481c 9090'))

    # --- 3. waiting for a file: poll the count instead of a semaphore ---
    #   mov edi,[WaitForSingleObject]        (still used after this)
    #   loop: cmp dword [esi+1c],0 / je 0x423C29 / push 1 / call [Sleep] / jmp loop
    ,@(0x423BF5, (Hex ('8b461c 85c0 8b3d14615900 7427 6a00 6a01 6a00 6a00 ff1518615900' +
                       '6aff 50 894620 ffd7 8b4620 50 ff15ec605900 c7462000000000')),
                 (Hex ('8b3d14615900 837e1c00 0f8424000000 6a01 ff1500615900 ebec' + ('90' * 26))))
)

try {
    $d = [IO.File]::ReadAllBytes($Source)
} catch {
    Fail "ERROR: can't read ${Source}: $($_.Exception.Message)"
}
Write-Host "${Source}: sha1 $(Sha1Hex $d)"

# Check the code section is where this version of the game has it
try {
    $pe = [BitConverter]::ToUInt32($d, 0x3C)
    $sec = $pe + 24 + [BitConverter]::ToUInt16($d, $pe + 20)
    $name = [Text.Encoding]::ASCII.GetString($d, $sec, 8).TrimEnd([char]0)
    $va = [BitConverter]::ToUInt32($d, $sec + 12)
    $rsize = [BitConverter]::ToUInt32($d, $sec + 16)
    $raw = [BitConverter]::ToUInt32($d, $sec + 20)
} catch {
    $name = ''                                    # (not a Windows exe at all)
}
if ($name -ne '.text' -or $va -ne ($TEXT_VA - 0x400000) -or $raw -ne $TEXT_RAW) {
    Fail 'ERROR: not the expected OR2006C2C.EXE (code section differs)'
}

$todo = New-Object System.Collections.Generic.List[object]
foreach ($p in $PATCHES) {
    $at = $p[0]; $old = ToHex $p[1]; $new = ToHex $p[2]
    if ($old.Length -ne $new.Length) { throw ('length mismatch at 0x{0:X}' -f $at) }
    $cur = ToHex (Slice $d (Off $at) $p[1].Length)
    if ($cur -eq $new) { continue }                       # (already there)
    if ($cur -ne $old) {
        Fail ("ERROR: unexpected bytes at 0x{0:X} ({1}) - a different version of the game?" -f $at, $cur)
    }
    $todo.Add($p)
}

$c = Off $CAVE_VA
$caveNow = ToHex (Slice $d $c $CAVE.Length)
$caveHex = ToHex $CAVE
if ($caveNow -ne $caveHex -and $caveNow -match '[^0]') {
    Fail 'ERROR: the unused space at 0x595890 isn''t empty'
}
if ($todo.Count -eq 0 -and $caveNow -eq $caveHex) {
    Write-Host "Nothing to do: $Source already has every fix"
    Done 0
}

foreach ($p in $todo) {
    [Array]::Copy($p[2], 0, $d, (Off $p[0]), $p[2].Length)
}
[Array]::Copy($CAVE, 0, $d, $c, $CAVE.Length)
# Let the loader read the cave from the file: the code section's file
# size ended just before it (0x194881); rounded up to cover it, still
# before the next section (0x195000 in the file)
$newRsize = ($c + $CAVE.Length - $TEXT_RAW + 0x1FF) -band (-bnot 0x1FF)
$nxtRaw = [BitConverter]::ToUInt32($d, $sec + 40 + 20)
if ($TEXT_RAW + $newRsize -gt $nxtRaw) {
    Fail 'ERROR: no room for the new code'
}
$sizeBytes = [BitConverter]::GetBytes([uint32][Math]::Max([int64]$rsize, [int64]$newRsize))
[Array]::Copy($sizeBytes, 0, $d, $sec + 16, 4)

try {
    if ($Source -ieq $Dest) {
        Move-Item -LiteralPath $Dest -Destination "$Dest.v1" -Force      # keep the old one
        Write-Host "Old version kept as $(Split-Path $Dest -Leaf).v1"
    }
    [IO.File]::WriteAllBytes($Dest, $d)
} catch {
    Fail "ERROR: can't write ${Dest}: $($_.Exception.Message)"
}
Write-Host "Fixes added: $($todo.Count)"
Write-Host "Written: $Dest"
Write-Host "         sha1 $(Sha1Hex $d)"
Done 0
