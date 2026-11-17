# Tests for skills/prose/install.ps1. Run: pwsh -NoProfile -File tests/install_test.ps1
#
# The same cases as tests/install_test.sh, minus the ones that need a Unix
# shell (signals, a missing sha256sum). Each case copies the real script into a
# fake plugin folder, serves fake release assets over file:// (install.ps1
# copies a file: URL instead of asking Invoke-WebRequest, which has no file
# support in PowerShell 7), and runs the script in a child PowerShell.
#
# On Linux and macOS the script is told it runs on Windows with
# PROSE_TEST_PLATFORM, so the download, checksum and rename logic is tested
# there too. Windows needs real executables for the fake binary: the test
# compiles a tiny one with the .NET Framework's csc.exe. The suite runs twice,
# once in a plain folder and once in `a dir/ünï/` (a space and non-ASCII
# characters in the path).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$here = $PSScriptRoot
$installSrc = [IO.Path]::Combine($here, '..', 'skills', 'prose', 'install.ps1')
$childShell = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("prose-install-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

$script:pass = 0
$script:fail = 0
$script:suite = ''

function Check([string]$Description, [bool]$Condition) {
    if ($Condition) { $script:pass++ } else {
        $script:fail++
        [Console]::Error.WriteLine("FAIL [$($script:suite)]: $Description")
    }
}

function Join([string]$A, [string]$B) { [IO.Path]::Combine($A, $B) }

# ---- fake binaries ----------------------------------------------------------

# A fake prose-check prints "prose-check $PROSE_FAKE_VERSION" (default 0.1.0)
# and exits with $PROSE_FAKE_EXIT (default 0).
function New-FakeBinary([string]$Path, [string]$Marker) {
    if ($onWindows) {
        $cache = Join-Path $work 'fake.exe'
        if (-not (Test-Path -LiteralPath $cache)) {
            $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
            if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc; the test cannot build a fake binary" }
            $cs = Join-Path $work 'fake.cs'
            [IO.File]::WriteAllText($cs, @'
using System;
class P {
    static int Main(string[] a) {
        string v = Environment.GetEnvironmentVariable("PROSE_FAKE_VERSION");
        if (string.IsNullOrEmpty(v)) v = "0.1.0";
        string e = Environment.GetEnvironmentVariable("PROSE_FAKE_EXIT");
        Console.WriteLine("prose-check " + v);
        return string.IsNullOrEmpty(e) ? 0 : int.Parse(e);
    }
}
'@)
            & $csc /nologo "/out:$cache" $cs | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'csc.exe failed to build the fake binary' }
        }
        Copy-Item -LiteralPath $cache -Destination $Path
    } else {
        $body = "#!/bin/sh`n# asset $Marker`necho `"prose-check `${PROSE_FAKE_VERSION:-0.1.0}`"`nexit `${PROSE_FAKE_EXIT:-0}`n"
        [IO.File]::WriteAllText($Path, $body)
        & chmod 755 $Path
    }
}

function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function New-Release([string]$Dir, [scriptblock]$Tweak) {
    $v = Join (Join $work $Dir) 'v0.1.0'
    New-Item -ItemType Directory -Path $v -Force | Out-Null
    $asset = Join $v 'prose-check-windows-x86_64.exe'
    New-FakeBinary $asset 'windows-x86_64.exe'
    $sums = Join $v 'SHA256SUMS'
    [IO.File]::WriteAllText($sums, ("{0}  prose-check-windows-x86_64.exe`n" -f (Get-Sha $asset)))
    if ($Tweak) { & $Tweak $v $asset $sums }
    return (Join $work $Dir)
}

# [Uri] of a bare Unix path is a relative URI, so the file: URL is built by hand.
function To-Url([string]$Path) {
    $p = $Path -replace '\\', '/'
    if (-not $p.StartsWith('/')) { $p = '/' + $p }
    ([Uri]('file://' + $p)).AbsoluteUri
}

$release = New-Release 'release' $null
$badRelease = New-Release 'bad-release' { param($v, $asset, $sums)
    [IO.File]::WriteAllText($sums, ("{0}  prose-check-windows-x86_64.exe`n" -f ('0' * 64))) }
$noEntry = New-Release 'noentry' { param($v, $asset, $sums)
    [IO.File]::WriteAllText($sums, ("{0}  prose-check-linux-x86_64`n" -f ('a' * 64))) }
$malformed = New-Release 'malformed' { param($v, $asset, $sums)
    [IO.File]::WriteAllText($sums, "nothex  prose-check-windows-x86_64.exe`n") }
$crlf = New-Release 'crlf' { param($v, $asset, $sums)
    [IO.File]::WriteAllText($sums, ("{0} *prose-check-windows-x86_64.exe`r`n" -f (Get-Sha $asset))) }
$emptyAsset = New-Release 'empty' { param($v, $asset, $sums)
    [IO.File]::WriteAllText($asset, '') }
$half = New-Release 'half' { param($v, $asset, $sums) Remove-Item -LiteralPath $asset }

# ---- one run of the script --------------------------------------------------

function New-Root([string]$Root) {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    New-Item -ItemType Directory -Path (Join $Root '.claude-plugin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join (Join $Root 'skills') 'prose') -Force | Out-Null
    [IO.File]::WriteAllText((Join (Join $Root '.claude-plugin') 'plugin.json'), "{`n  `"name`": `"prose`",`n  `"version`": `"0.1.0`"`n}`n")
    Copy-Item -LiteralPath $installSrc -Destination (Join (Join (Join $Root 'skills') 'prose') 'install.ps1')
}

# Runs the script in a child PowerShell. Returns @{ Out = merged output; Rc = exit code }.
function Invoke-Install([string]$Root, [string[]]$ScriptArgs = @()) {
    $script = Join (Join (Join $Root 'skills') 'prose') 'install.ps1'
    $lines = & $childShell -NoProfile -NonInteractive -File $script @ScriptArgs 2>&1 | ForEach-Object { "$_" }
    return @{ Out = ($lines -join "`n"); Rc = $LASTEXITCODE }
}

function Lines([string]$Text) { if ($Text -eq '') { 0 } else { ($Text -split "`r?`n").Count } }

function Dir-Empty([string]$Dir) {
    -not (Test-Path -LiteralPath $Dir) -or -not (Get-ChildItem -LiteralPath $Dir -Force)
}

# Never `& $Path` on a file that may not be executable: on Linux that opens it
# with the desktop's default handler.
function Fake-Version([string]$Path) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = '--version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $text = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return $text.Trim()
}

function Run-Suite([string]$Name, [string]$Base) {
    $script:suite = $Name
    $root = Join $Base 'plugin'
    $bin = Join (Join (Join $root 'skills') 'prose') 'bin'
    $exe = Join $bin 'prose-check.exe'
    $env:PROSE_RELEASE_BASE = To-Url $release
    $env:PROSE_TEST_PLATFORM = 'Windows X64'
    Remove-Item Env:PROSE_VERSION -ErrorAction SilentlyContinue
    Remove-Item Env:PROSE_FAKE_VERSION -ErrorAction SilentlyContinue
    Remove-Item Env:PROSE_FAKE_EXIT -ErrorAction SilentlyContinue

    # 1. installs, and the binary runs
    New-Root $root
    $r = Invoke-Install $root
    Check "install exits 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    Check 'install puts bin/prose-check.exe in place' (Test-Path -LiteralPath $exe)
    if (Test-Path -LiteralPath $exe) {
        Check 'installed binary runs' ((Fake-Version $exe) -eq 'prose-check 0.1.0')
        Check 'installed binary is the release asset' ((Get-Sha $exe) -eq (Get-Sha (Join (Join $release 'v0.1.0') 'prose-check-windows-x86_64.exe')))
    }
    $left = @(Get-ChildItem -LiteralPath $bin -Force | ForEach-Object Name)
    Check "install leaves only prose-check.exe in bin/ (got: $($left -join ', '))" (($left.Count -eq 1) -and ($left[0] -eq 'prose-check.exe'))

    # 2. unsupported platforms are refused in one line
    foreach ($p in 'SunOS sparc', 'Linux Arm64', 'Windows Arm64', 'Windows X86') {
        New-Root $root
        $env:PROSE_TEST_PLATFORM = $p
        $r = Invoke-Install $root
        Check "$p is refused (rc $($r.Rc))" ($r.Rc -ne 0)
        Check "$p message says 'unsupported platform: $p' (got: $($r.Out))" ($r.Out.Contains("unsupported platform: $p"))
        Check "$p message is one line" ((Lines $r.Out) -eq 1)
        Check "$p leaves bin/ empty" (Dir-Empty $bin)
    }
    $env:PROSE_TEST_PLATFORM = 'Windows X64'

    # 3. a wrong checksum
    New-Root $root
    $env:PROSE_RELEASE_BASE = To-Url $badRelease
    $r = Invoke-Install $root
    Check 'wrong checksum exits non-zero' ($r.Rc -ne 0)
    Check "wrong checksum names the mismatch (got: $($r.Out))" ($r.Out.Contains('checksum mismatch'))
    Check 'wrong checksum message is one line' ((Lines $r.Out) -eq 1)
    Check 'wrong checksum leaves bin/ empty' (Dir-Empty $bin)
    $env:PROSE_RELEASE_BASE = To-Url $release

    # 4. a matching binary is kept, and the release is not asked
    New-Root $root
    $null = Invoke-Install $root
    $old = [datetime]::new(2000, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    (Get-Item -LiteralPath $exe).LastWriteTimeUtc = $old
    $env:PROSE_RELEASE_BASE = To-Url (Join $work 'nowhere')
    $r = Invoke-Install $root
    Check "matching binary: exit 0 with no release reachable (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    Check 'matching binary: mtime unchanged' ((Get-Item -LiteralPath $exe).LastWriteTimeUtc -eq $old)
    Check "matching binary: says it is kept (got: $($r.Out))" ($r.Out.Contains('already installed'))
    $env:PROSE_RELEASE_BASE = To-Url $release

    # 5. -Force installs again
    $r = Invoke-Install $root @('-Force')
    Check "-Force exits 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    Check '-Force replaces the binary' ((Get-Item -LiteralPath $exe).LastWriteTimeUtc -ne $old)

    # 6. odd states are replaced
    New-Root $root
    $null = Invoke-Install $root
    $env:PROSE_FAKE_VERSION = '0.0.9'
    $r = Invoke-Install $root
    Remove-Item Env:PROSE_FAKE_VERSION
    Check "other version: exit 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    Check 'other version: replaced' ((Fake-Version $exe) -eq 'prose-check 0.1.0')

    New-Root $root
    $null = Invoke-Install $root
    $env:PROSE_FAKE_EXIT = '3'
    $r = Invoke-Install $root
    Remove-Item Env:PROSE_FAKE_EXIT
    Check "--version fails: exit 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    Check '--version fails: replaced' ((Fake-Version $exe) -eq 'prose-check 0.1.0')

    if (-not $onWindows) {
        New-Root $root
        $null = Invoke-Install $root
        & chmod 644 $exe
        $r = Invoke-Install $root
        Check "not executable: exit 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
        Check 'not executable: replaced by one that runs' ((Fake-Version $exe) -eq 'prose-check 0.1.0')
    }

    New-Root $root
    New-Item -ItemType Directory -Path $exe -Force | Out-Null
    $r = Invoke-Install $root
    Check "bin/prose-check.exe is a directory: refused (rc $($r.Rc))" ($r.Rc -ne 0)
    Check "bin/prose-check.exe is a directory: one line (got: $($r.Out))" ((Lines $r.Out) -eq 1)
    Check 'bin/prose-check.exe is a directory: nothing moved into it' (Dir-Empty $exe)

    # 7. missing release, missing asset, bad SHA256SUMS
    New-Root $root
    $nowhere = To-Url (Join $work 'nowhere')
    $env:PROSE_RELEASE_BASE = $nowhere
    $r = Invoke-Install $root
    Check 'missing release exits non-zero' ($r.Rc -ne 0)
    Check "missing release names the URL (got: $($r.Out))" ($r.Out.Contains("$nowhere/v0.1.0/SHA256SUMS"))
    Check 'missing release message is one line' ((Lines $r.Out) -eq 1)
    Check 'missing release leaves bin/ empty' (Dir-Empty $bin)

    foreach ($case in @(
            @('missing asset', $half, 'prose-check-windows-x86_64.exe'),
            @('no checksum line', $noEntry, 'SHA256SUMS'),
            @('malformed checksum', $malformed, 'SHA256SUMS'),
            @('empty asset', $emptyAsset, 'checksum mismatch'))) {
        New-Root $root
        $env:PROSE_RELEASE_BASE = To-Url $case[1]
        $r = Invoke-Install $root
        Check "$($case[0]): exit non-zero" ($r.Rc -ne 0)
        Check "$($case[0]): message names '$($case[2])' (got: $($r.Out))" ($r.Out.Contains($case[2]))
        Check "$($case[0]): one line" ((Lines $r.Out) -eq 1)
        Check "$($case[0]): bin/ empty" (Dir-Empty $bin)
    }

    New-Root $root
    $env:PROSE_RELEASE_BASE = To-Url $crlf
    $r = Invoke-Install $root
    Check "CRLF and binary-mark SHA256SUMS: exit 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    $env:PROSE_RELEASE_BASE = To-Url $release

    # 8. the version
    New-Root $root
    Remove-Item -LiteralPath (Join (Join $root '.claude-plugin') 'plugin.json')
    $r = Invoke-Install $root
    Check 'no manifest and no PROSE_VERSION: exit non-zero' ($r.Rc -ne 0)
    Check "no manifest: names PROSE_VERSION (got: $($r.Out))" ($r.Out.Contains('PROSE_VERSION'))
    Check 'no manifest: one line' ((Lines $r.Out) -eq 1)
    Check 'no manifest: bin/ empty' (Dir-Empty $bin)
    $env:PROSE_VERSION = '0.1.0'
    $r = Invoke-Install $root
    Check "no manifest, PROSE_VERSION set: exit 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)

    New-Root $root
    $env:PROSE_VERSION = '9.9.9'
    $r = Invoke-Install $root
    Check "PROSE_VERSION beats the manifest: asks for v9.9.9 (got: $($r.Out))" ($r.Out.Contains('/v9.9.9/'))
    Check 'PROSE_VERSION beats the manifest: bin/ empty' (Dir-Empty $bin)
    $env:PROSE_VERSION = '../../etc'
    $r = Invoke-Install $root
    Check 'a version that is not a version is refused' ($r.Rc -ne 0)
    Check 'a bad version leaves bin/ empty' (Dir-Empty $bin)
    Remove-Item Env:PROSE_VERSION

    # 9. an unknown option is a usage error
    New-Root $root
    $r = Invoke-Install $root @('--bogus')
    Check "unknown option: exit 2 (got $($r.Rc))" ($r.Rc -eq 2)
    Check "unknown option: names it (got: $($r.Out))" ($r.Out.Contains('--bogus'))

    # 10. without the override the real platform is used: on Windows x64 it
    # installs, anywhere else it is refused by name
    New-Root $root
    Remove-Item Env:PROSE_TEST_PLATFORM
    $r = Invoke-Install $root
    $realWindowsX64 = $onWindows -and ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'X64')
    if ($realWindowsX64) {
        Check "real Windows x64: exit 0 (got $($r.Rc): $($r.Out))" ($r.Rc -eq 0)
    } else {
        Check "real other platform: refused (got $($r.Rc): $($r.Out))" (($r.Rc -ne 0) -and $r.Out.Contains('unsupported platform: '))
        Check 'real other platform: bin/ empty' (Dir-Empty $bin)
    }
    $env:PROSE_TEST_PLATFORM = 'Windows X64'

    # 11. parallel installs
    New-Root $root
    $script = Join (Join (Join $root 'skills') 'prose') 'install.ps1'
    $procs = 1..3 | ForEach-Object {
        Start-Process -FilePath $childShell -PassThru -NoNewWindow -RedirectStandardOutput (Join $work "par$_.out") `
            -RedirectStandardError (Join $work "par$_.err") `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', ('"' + $script + '"'))
    }
    $procs | Wait-Process
    $allOk = $true
    foreach ($p in $procs) { if ($p.ExitCode -ne 0) { $allOk = $false } }
    Check 'three parallel installs all exit 0' $allOk
    $left = @(Get-ChildItem -LiteralPath $bin -Force | ForEach-Object Name)
    Check "three parallel installs leave only prose-check.exe (got: $($left -join ', '))" (($left.Count -eq 1) -and ($left[0] -eq 'prose-check.exe'))
}

try {
    Run-Suite 'plain' (Join $work 'plain')
    Run-Suite 'unicode-and-space' (Join (Join $work 'a dir') 'ünï')
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("install_test.ps1: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -ne 0) { exit 1 }
