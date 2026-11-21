# =====================================================================
#  NFSU2 v1.2 (SPEED2.EXE md5 6445adbf4e8d64be51e96a69bba168a4)
#  Menu-crash fix: makes the game's home-made lock thread-safe.
#  PowerShell version of nfsu2-lockfix.py (same patches, same checks).
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
#
#  Usage (on the Windows laptop):
#      Copy this .ps1 into the nfsu2 folder on the Pi's Samba share, then
#      right-click it > Run with PowerShell
#      (SPEED2.EXE -> SPEED2_PATCHED.EXE, in the folder this .ps1 is in).
#  Or from a PowerShell window:
#      .\nfsu2-lockfix.ps1 SPEED2.EXE SPEED2_PATCHED.EXE
# =====================================================================
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
function Md5Hex([byte[]]$d) {
    ToHex ([Security.Cryptography.MD5]::Create().ComputeHash($d))
}

$EXPECTED_MD5 = '6445adbf4e8d64be51e96a69bba168a4'
$IMAGEBASE = 0x400000; $TEXT_VA = 0x1000; $TEXT_RAW = 0x1000
$C0 = 'c07b8b00'          # 0x8B7BC0, little-endian
$B0 = 'b07b8b00'          # 0x8B7BB0, little-endian

function Off([int]$va) { $va - $IMAGEBASE - $TEXT_VA + $TEXT_RAW }

# Hex strings in, so lengths and comparisons are simple
function Put([byte[]]$data, [int]$va, [string]$old, [string]$new) {
    if ($old.Length -ne $new.Length) { throw ('length mismatch at {0:X8}' -f $va) }
    $o = Off $va
    $cur = ToHex (Slice $data $o ($old.Length / 2))
    if ($cur -eq $new) { return 'already patched' }
    if ($cur -ne $old) {
        Fail ("ABORT: unexpected bytes at {0:X8}`n  found    {1}`n  expected {2}" -f $va, $cur, $old)
    }
    $nb = Hex $new
    [Array]::Copy($nb, 0, $data, $o, $nb.Length)
    return 'patched'
}

function Build([byte[]]$data) {
    $log = New-Object System.Collections.Generic.List[object]

    # ---------- Patch 1: lock routine 0x73B620-0x73B67F (96 bytes) ----------
    $old1 = ('a1c07b8b00' + '85c0' + '7508' + '83c8ff' + 'a3c07b8b00' +       # 73B620 check-then-set
             '8b542404' +                                                   # 73B631 mov edx,[esp+4]
             '85d2' + '7c31' + '83fa04' + '7d2c' + '8bca' + '69c928090000' + '56' +  # 73B635 .. (tail)
             '8bb144578b00' + '85f6' + '5e' + '7418' + '8b8140578b00' +
             '8d8910578b00' + '890db07b8b00' + 'a3c07b8b00' + 'c3' +
             '83faff' + '7407' + '33c0' + 'a3c07b8b00' + 'c3' +            # 73B66A .. 73B676
             '909090909090909090')                                          # 73B677 .. 73B67F
    $tail = $old1.Substring(0x15 * 2, (0x57 - 0x15) * 2)   # 73B635..73B676, only relative jumps inside itself
    $new1 = ('8b542404' +              # mov  edx,[esp+4]
             '33c0' +                  # xor  eax,eax
             '83c9ff' +                # or   ecx,-1
             'f00fb10d' + $C0 +        # lock cmpxchg [8B7BC0],ecx
             '7408' +                  # je   got_it
             '83faff' +                # cmp  edx,-1
             '7505' +                  # jne  select   (already held, pick slot)
             '33c0c3' +                # xor eax,eax ; ret  -> "busy"
             '8bc1' +                  # got_it: mov eax,ecx (-1, like before)
             $tail)                    # select: original code, shifted +8
    $new1 += '90' * (($old1.Length - $new1.Length) / 2)
    $log.Add(@('73B620 atomic lock', (Put $data 0x73B620 $old1 $new1)))

    # ---------- Patch 2: update routine claim 0x73B91A-0x73B937 (30 bytes) ----------
    $old2 = ('a1c07b8b00' + '85c0' + '0f8580000000' +          # check flag
             '8a442404' + '55' + '56' + '57' +                 # mov al,[esp+4]; push x3
             'c705c07b8b00ffffffff')                           # set flag = -1
    $new2 = ('33c0' + '83c9ff' +
             'f00fb10d' + $C0 +                                # lock cmpxchg
             '757e' +                                          # jne 73B9A7 (busy -> ret)
             '8a442404' + '555657')
    $new2 += '90' * (($old2.Length - $new2.Length) / 2)
    $log.Add(@('73B91A atomic lock', (Put $data 0x73B91A $old2 $new2)))

    # ---------- Patch 3: unlock order (pointer first, then flag) ----------
    # encoding of one store : addresses of the flag store
    $sites = [ordered]@{
        'a3'   = @(0x738ED0, 0x739117, 0x7393C2, 0x739528, 0x739BA7,
                   0x73A534, 0x73A635, 0x73A714, 0x73B261)
        '892d' = @(0x73924E)
        '890d' = @(0x739AE4, 0x73A9A7, 0x73A9C2, 0x73AA9A, 0x73ACF7)
        '891d' = @(0x73AE26)
        'c705' = @(0x738FDB, 0x739C2D, 0x739CBD, 0x73AF48, 0x73B01E,
                   0x73B089, 0x73B10E, 0x73B992)
    }
    foreach ($op in $sites.Keys) {
        $imm = if ($op -eq 'c705') { '00000000' } else { '' }
        $first = $op + $C0 + $imm
        $second = $op + $B0 + $imm
        foreach ($va in $sites[$op]) {
            $log.Add(@(('{0:X8} unlock order' -f $va), (Put $data $va ($first + $second) ($second + $first))))
        }
    }
    return ,$log
}

if (-not $Source) { $Source = Join-Path $PSScriptRoot 'SPEED2.EXE' }
$Source = FullPath $Source
if (-not $Patched) { $Patched = Join-Path (Split-Path $Source -Parent) 'SPEED2_PATCHED.EXE' }
$Patched = FullPath $Patched

try {
    $data = [IO.File]::ReadAllBytes($Source)
} catch {
    Fail "ERROR: can't read ${Source}: $($_.Exception.Message)"
}
$md5 = Md5Hex $data
if ($md5 -ne $EXPECTED_MD5) {
    Fail "ABORT: $Source md5 is $md5, expected $EXPECTED_MD5 (different exe version)"
}
foreach ($entry in (Build $data)) {
    Write-Host ('{0,-24} {1}' -f $entry[0], $entry[1])
}
try {
    [IO.File]::WriteAllBytes($Patched, $data)
} catch {
    Fail "ERROR: can't write ${Patched}: $($_.Exception.Message)"
}
Write-Host ''
Write-Host "Written $Patched  (md5 $(Md5Hex $data))"
Done 0
