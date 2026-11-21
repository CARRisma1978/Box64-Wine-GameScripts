# =============================================================================
#  Serious Sam: The First Encounter v1.05 - Engine.dll fix for Box64 + Wine
#  PowerShell version of serioussam-enginefix.py (same fix, same checks).
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
#  Run it once, on the Windows laptop:
#      Copy this .ps1 into the Serious Sam folder on the Pi's Samba share,
#      then right-click it > Run with PowerShell.
#  Or from a PowerShell window (give the folder or the dll's path if the
#  .ps1 isn't in the game folder):
#      .\serioussam-enginefix.ps1 [path]
#  Undo (puts the original back from Engine.dll.orig):
#      .\serioussam-enginefix.ps1 -Undo [path]
#
#  The original is kept as Bin\Engine.dll.orig (never overwritten once
#  there). Only the known v1.05 Engine.dll is changed - anything else is
#  left alone.
# =============================================================================
param(
    [string]$Path,
    [switch]$Undo
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
function ToHex([byte[]]$b) {
    (@($b) | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}
function Sha1Hex([byte[]]$d) {
    ToHex ([Security.Cryptography.SHA1]::Create().ComputeHash($d))
}

$OFFSET = 0x1D577
$CONTEXT = [byte[]](0x85, 0xC9, 0x75, 0x20)   # test ecx,ecx / jne +0x20
$CTX_AT = $OFFSET - 2                         # where CONTEXT starts
$ORIG_BYTE = 0x75; $NEW_BYTE = 0xEB
$SHA1_ORIG = 'db7620f9eafe1e6286f33a5f4a133cf9207e0a07'
$SHA1_FIXED = '481cb5520f4db08157afc808fe19d8e60992ea8a'

function Find-Dll([string]$arg) {
    # The game folder, its Bin folder, or the dll itself - any upper/lower case
    $start = FullPath $(if ($arg) { $arg } else { $PSScriptRoot })
    if (Test-Path -LiteralPath $start -PathType Leaf) { return $start }
    if (-not (Test-Path -LiteralPath $start -PathType Container)) { return $null }
    $dirs = @($start) + @(Get-ChildItem -LiteralPath $start -Directory |
                          Where-Object { $_.Name -ieq 'bin' } | ForEach-Object { $_.FullName })
    foreach ($dir in $dirs) {
        $f = Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -ieq 'engine.dll' } |
             Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

$dll = Find-Dll $Path
if (-not $dll) {
    Fail "Engine.dll not found - put this .ps1 in the Serious Sam folder, or give the folder's path"
}
$orig = "$dll.orig"
Write-Host "Engine.dll: $dll"

try {
    if ($Undo) {
        if (-not (Test-Path -LiteralPath $orig -PathType Leaf)) {
            Fail 'No Engine.dll.orig to put back - nothing done'
        }
        if ((Sha1Hex ([IO.File]::ReadAllBytes($orig))) -ne $SHA1_ORIG) {
            Write-Host "WARNING: Engine.dll.orig isn't the known v1.05 original - putting it back anyway" -ForegroundColor Yellow
        }
        Copy-Item -LiteralPath $orig -Destination $dll -Force
        Write-Host 'Original Engine.dll put back (Engine.dll.orig kept)'
        Done 0
    }

    $data = [IO.File]::ReadAllBytes($dll)
    $h = Sha1Hex $data
    $ctxOk2 = ($data.Length -ge $CTX_AT + 4 -and
               $data[$CTX_AT] -eq $CONTEXT[0] -and $data[$CTX_AT + 1] -eq $CONTEXT[1])
    if ($h -eq $SHA1_FIXED -or ($data.Length -gt $OFFSET -and $data[$OFFSET] -eq $NEW_BYTE -and $ctxOk2)) {
        Write-Host 'Already fixed - nothing to do'
        Done 0
    }
    if ($h -ne $SHA1_ORIG) {
        # Not the exact known file: only go ahead if the bytes round the
        # change are exactly as expected
        $ctxOk = $ctxOk2 -and $data[$CTX_AT + 2] -eq $CONTEXT[2] -and $data[$CTX_AT + 3] -eq $CONTEXT[3]
        if (-not $ctxOk) {
            Fail "This isn't the Serious Sam TFE v1.05 Engine.dll this fix is for (SHA-1 $h) - nothing changed"
        }
        Write-Host 'WARNING: not the exact known v1.05 file, but the bytes to change match - fixing' -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $orig) {
        Write-Host 'Engine.dll.orig already there - kept as it is'
    } else {
        Copy-Item -LiteralPath $dll -Destination $orig
        Write-Host "Original saved as $(Split-Path $orig -Leaf)"
    }

    $data[$OFFSET] = $NEW_BYTE
    $tmp = "$dll.tmp"
    [IO.File]::WriteAllBytes($tmp, $data)
    Move-Item -LiteralPath $tmp -Destination $dll -Force     # (all or nothing)

    $check = [IO.File]::ReadAllBytes($dll)
    if ($check[$OFFSET] -ne $NEW_BYTE) {
        Fail "ERROR: the change didn't stick - put Engine.dll.orig back"
    }
    if ($h -eq $SHA1_ORIG -and (Sha1Hex $check) -ne $SHA1_FIXED) {
        Write-Host "WARNING: result isn't the expected file (SHA-1 $(Sha1Hex $check))" -ForegroundColor Yellow
    }
    Write-Host ('Fixed: offset 0x{0:X}  {1:X2} -> {2:X2}' -f $OFFSET, $ORIG_BYTE, $NEW_BYTE)
} catch {
    Fail "ERROR: $($_.Exception.Message)"
}
Done 0
