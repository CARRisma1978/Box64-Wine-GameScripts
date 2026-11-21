# =============================================================================
#  Jazz Jackrabbit 2 (v1.23) - patches for running under Box64 / Wine
#  PowerShell version of jj2-patch.py (same patches, same checks).
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
#  Usage (on the Windows laptop):
#      Copy this .ps1 into the Jazz2 folder on the Pi's Samba share, then
#      right-click it > Run with PowerShell.
#  Or from a PowerShell window:
#      .\jj2-patch.ps1 [source.exe [patched.exe]]
#  Default: Jazz2.exe -> Jazz2-pi.exe, in the folder this .ps1 is in.
# =============================================================================
param(
    [string]$Source,
    [string]$Patched
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
    # .NET file calls don't follow PowerShell's current folder - resolve first
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}
function Hex([string]$h) {
    $h = $h -replace '\s', ''
    $b = New-Object byte[] ($h.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
    return ,$b
}
function ToHex([byte[]]$b, [string]$sep = '') {
    (@($b) | ForEach-Object { '{0:x2}' -f $_ }) -join $sep
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

# (name, file offset, original bytes from that offset, replacement bytes)
$PATCHES = @(
    [pscustomobject]@{ Name = 'FPU memory copy off'; Off = 0x91AAE
        Orig = Hex '740e3c05720ac705fc3d4d008cc74900'; New = Hex 'eb0e' },
    # sub esp,10 / push edi,esi,ebx / EnterCriticalSection / check flag,
    # if off: je 0x4A2C16 (LeaveCriticalSection, return)
    [pscustomobject]@{ Name = 'Sound: DirectSound timer checks under lock'; Off = 0xA1E40
        Orig = Hex 'a0d486600083ec1084c00f84d401000057565368c0836000ff15f0514c00'
        New  = Hex '83ec1057565368c0836000ff15f0514c00a0d486600084c00f84b8010000' },
    # sub esp,0c / push ebx / EnterCriticalSection / check flag,
    # if off: je 0x4A2D0F (LeaveCriticalSection, return)
    [pscustomobject]@{ Name = 'Sound: wave-out timer checks under lock'; Off = 0xA2030
        Orig = Hex 'a0d486600083ec0c84c00f84db0000005368c0836000ff15f0514c00'
        New  = Hex '83ec0c5368c0836000ff15f0514c00a0d486600084c00f84c3000000' },
    # flag = 0 / timeKillEvent / EnterCriticalSection / timeEndPeriod(1) /
    # mov eax,[0x6083DC] - same instructions, new order
    [pscustomobject]@{ Name = 'Sound: shutdown stops timer before locking'; Off = 0xA2F80
        Orig = Hex '68c0836000ff15f0514c00a1ac83600050ff153c534c006a01ff1540534c00a1dc836000881dd4866000'
        New  = Hex '881dd4866000a1ac83600050ff153c534c0068c0836000ff15f0514c006a01ff1540534c00a1dc836000' }
)

if (-not $Source) { $Source = Join-Path $PSScriptRoot 'Jazz2.exe' }
$Source = FullPath $Source
if (-not $Patched) { $Patched = Join-Path (Split-Path $Source -Parent) 'Jazz2-pi.exe' }
$Patched = FullPath $Patched

try {
    $data = [IO.File]::ReadAllBytes($Source)
} catch {
    Fail "ERROR: can't read ${Source}: $($_.Exception.Message)"
}

# Check every patch site before changing anything
foreach ($p in $PATCHES) {
    $found = ToHex (Slice $data $p.Off $p.Orig.Length)
    $orig = ToHex $p.Orig
    $new = ToHex $p.New
    if ($found.Length -eq $orig.Length -and
        $found.Substring(0, $new.Length) -eq $new -and
        $found.Substring($new.Length) -eq $orig.Substring($new.Length)) {
        Fail "ERROR: $Source is already patched ($($p.Name)) - give the original Jazz2.exe"
    }
    if ($found -ne $orig) {
        Fail ("ERROR: $Source isn't the JJ2 v1.23 exe these patches are for " +
              "(bytes at 0x{0:X}: {1}) - nothing changed" -f $p.Off, $found)
    }
}

foreach ($p in $PATCHES) {
    [Array]::Copy($p.New, 0, $data, $p.Off, $p.New.Length)
}

if (Test-Path -LiteralPath $Patched -PathType Leaf) {
    if ((Sha1Hex ([IO.File]::ReadAllBytes($Patched))) -eq (Sha1Hex $data)) {
        Write-Host "$Patched is already up to date - nothing to do"
        Done 0
    }
}

$tmp = "$Patched.tmp"
try {
    [IO.File]::WriteAllBytes($tmp, $data)
    Move-Item -LiteralPath $tmp -Destination $Patched -Force
} catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Fail "ERROR: can't write ${Patched}: $($_.Exception.Message)"
}

Write-Host "Made $Patched from ${Source}:"
foreach ($p in $PATCHES) {
    $was = (ToHex (Slice $p.Orig 0 $p.New.Length) ' ').ToUpper()
    $now = (ToHex $p.New ' ').ToUpper()
    Write-Host ("  0x{0:X}: {1} -> {2}  ({3})" -f $p.Off, $was, $now, $p.Name)
}
Done 0
