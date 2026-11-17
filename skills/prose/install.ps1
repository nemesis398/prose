<#
.SYNOPSIS
Installs the prose-check release binary for Windows into bin\ beside SKILL.md.

.DESCRIPTION
Reads the version from ..\..\.claude-plugin\plugin.json (set PROSE_VERSION when
the folder was copied out of the plugin), downloads prose-check-windows-x86_64.exe
and SHA256SUMS from that version's release, checks one against the other, and
only then puts the binary at bin\prose-check.exe. A binary there that already
reports this version is kept unless -Force is given. A bin\prose-check.exe that
does not run, or whose --version names another version, is replaced.

PROSE_RELEASE_BASE replaces https://github.com/nemesis398/prose/releases/download
(the tests point it at a file: folder, which this script copies, because
Invoke-WebRequest in PowerShell 7 has no file support). PROSE_TEST_PLATFORM
replaces the detected platform, as "Windows X64" or any other text, so the
tests can run the script on Linux and macOS. Every refusal is one line on
stderr and exit 1, and leaves nothing behind in bin\.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# A refusal: one line, caught at the bottom so that the cleanup runs.
class InstallRefusal : System.Exception {
    InstallRefusal([string]$Message) : base($Message) {}
}
function Stop-Install([string]$Message) {
    throw [InstallRefusal]::new(($Message -replace '\s+', ' '))
}

# Runs PATH --version without a shell, so a file that is not executable fails
# instead of being opened by the system's default handler (as `& $Path` does
# on Linux and macOS). Returns the first line, or $null when it does not run.
function Get-InstalledVersion([string]$Path) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Path
        $psi.Arguments = '--version'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch { $null = $_ }
            return $null
        }
        if ($proc.ExitCode -ne 0) { return $null }
        return $stdout.Result.Trim()
    } catch {
        return $null
    }
}

function Receive-File([string]$Url, [string]$Out, [string]$Version) {
    try {
        $uri = [System.Uri]$Url
        if ($uri.IsFile) {
            Copy-Item -LiteralPath $uri.LocalPath -Destination $Out -ErrorAction Stop
        } elseif ($uri.Scheme -eq 'https') {
            # Windows PowerShell 5.1 starts with TLS 1.0 and 1.1 only.
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
            # A timeout, so that a stalled connection cannot hang the install. In
            # PowerShell 7 it bounds the whole transfer, in 5.1 each read.
            Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        } else {
            throw 'only https and file URLs are allowed'
        }
    } catch {
        Stop-Install "cannot download $Url ($($_.Exception.Message); is there a release v${Version}?)"
    }
}

function Install-Prose {
    if ($Rest) {
        [Console]::Error.WriteLine("install.ps1: unknown argument: $($Rest[0]) (usage: install.ps1 [-Force])")
        return 2
    }

    $scriptDir = $PSScriptRoot
    $binDir = Join-Path $scriptDir 'bin'
    $target = Join-Path $binDir 'prose-check.exe'
    $asset = 'prose-check-windows-x86_64.exe'

    # The version: PROSE_VERSION, else the plugin manifest two folders up.
    $manifest = [System.IO.Path]::Combine($scriptDir, '..', '..', '.claude-plugin', 'plugin.json')
    $version = $env:PROSE_VERSION
    if (-not $version) {
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            Stop-Install "no version: $manifest is missing, set PROSE_VERSION"
        }
        try {
            $version = (Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } catch {
            Stop-Install "cannot read the version from ${manifest}: $($_.Exception.Message)"
        }
        if (-not $version) { Stop-Install "no version in $manifest, set PROSE_VERSION" }
    }
    if ($version -cnotmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') { Stop-Install "not a version: $version" }

    # The platform. Only Windows on x86-64 has a binary.
    $platform = $env:PROSE_TEST_PLATFORM
    if (-not $platform) {
        $isWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
        $osName = if ($isWin) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' }
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        $platform = "$osName $arch"
    }
    if ($platform -ne 'Windows X64') { Stop-Install "unsupported platform: $platform" }

    # A binary that already reports this version stays.
    if (-not $Force -and (Test-Path -LiteralPath $target -PathType Leaf)) {
        if ((Get-InstalledVersion $target) -eq "prose-check $version") {
            [Console]::Out.WriteLine("prose-check $version is already installed at $target")
            return 0
        }
    }
    if (Test-Path -LiteralPath $target -PathType Container) {
        Stop-Install "$target is a directory, not a file"
    }

    $base = $env:PROSE_RELEASE_BASE
    if (-not $base) { $base = 'https://github.com/nemesis398/prose/releases/download' }
    $releaseUrl = "$($base.TrimEnd('/'))/v$version"

    $null = New-Item -ItemType Directory -Path $binDir -Force
    $tmpDir = Join-Path $binDir (".prose-install." + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tmpDir
    try {
        $sumsFile = Join-Path $tmpDir 'SHA256SUMS'
        $binFile = Join-Path $tmpDir $asset
        Receive-File "$releaseUrl/SHA256SUMS" $sumsFile $version
        Receive-File "$releaseUrl/$asset" $binFile $version

        # The line for this asset: "<sha256>  <name>" or "<sha256> *<name>".
        $expected = $null
        foreach ($line in [System.IO.File]::ReadAllLines($sumsFile)) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -ceq $asset) {
                $expected = $parts[0].ToLowerInvariant()
                break
            }
        }
        if (-not $expected) { Stop-Install "no checksum for $asset in $releaseUrl/SHA256SUMS" }
        if ($expected -cnotmatch '^[0-9a-f]{64}$') {
            Stop-Install "the checksum for $asset in $releaseUrl/SHA256SUMS is not a SHA-256"
        }
        $actual = (Get-FileHash -LiteralPath $binFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Stop-Install "checksum mismatch for $releaseUrl/${asset}: expected $expected, got $actual"
        }

        try {
            Move-Item -LiteralPath $binFile -Destination $target -Force -ErrorAction Stop
        } catch {
            # Another install of the same version may have won the race and
            # hold the file open; that is fine, a good binary is in place.
            if ((Get-InstalledVersion $target) -ne "prose-check $version") {
                Stop-Install "cannot put the binary at ${target}: $($_.Exception.Message)"
            }
        }
        [Console]::Out.WriteLine("installed prose-check $version ($asset) at $target")
        return 0
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$code = 1
try {
    $code = Install-Prose
} catch [InstallRefusal] {
    [Console]::Error.WriteLine("install.ps1: $($_.Exception.Message)")
} catch {
    [Console]::Error.WriteLine("install.ps1: " + ($_.Exception.Message -replace '\s+', ' '))
}
exit $code
