<#
.SYNOPSIS
    Millennium - Windows one-click installer / uninstaller.

.DESCRIPTION
    Mirrors scripts/install.sh (Linux) and scripts/macos/install_macos.sh for
    Windows. Downloads a signed Millennium release from GitHub, verifies the
    SHA-256 digest, and drops the binary payload into the user's Steam
    installation directory:

        <Steam>\wsock32.dll                                  (bootstrap)
        <Steam>\millennium\lib\millennium.dll                (core)
        <Steam>\millennium\lib\millennium.hhx64.dll
        <Steam>\millennium\bin\millennium.luavm64.exe
        <Steam>\millennium\bin\millennium.crashhandler64.exe

    The Steam install path is auto-detected from the registry
    (HKCU\Software\Valve\Steam\SteamPath), the same way scripts/cmake/find_steam_path.cmake
    does it during the build.

    Can be run locally (.\install.ps1) or piped from the web:

        iwr -useb https://raw.githubusercontent.com/SmallRob/millennium-steam-patcher/main/scripts/install.ps1 | iex

.PARAMETER Beta
    Install the latest pre-release instead of the latest stable release.

.PARAMETER RunId
    Install a specific GitHub Actions nightly artifact by workflow run id.
    The artifact is fetched from nightly.link, so no auth is required.
    Mutually exclusive with -Beta.

.PARAMETER SteamPath
    Override the auto-detected Steam install path.

.PARAMETER Yes
    Skip the interactive confirmation prompt.

.PARAMETER Force
    Reinstall even if the same version is already installed.

.PARAMETER Uninstall
    Remove Millennium from the Steam install directory instead of installing.

.EXAMPLE
    PS> .\install.ps1
    Downloads and installs the latest stable Millennium.

.EXAMPLE
    PS> .\install.ps1 -Beta
    Installs the latest pre-release.

.EXAMPLE
    PS> .\install.ps1 -Uninstall
    Removes Millennium from the Steam install directory.

.EXAMPLE
    PS> iwr -useb https://raw.githubusercontent.com/SmallRob/millennium-steam-patcher/main/scripts/install.ps1 | iex
    One-line install from the web (PowerShell 5.1+).

.NOTES
    Requires: PowerShell 5.1+ (ships with Windows 10 / 11), Internet access,
    and a Steam installation registered in HKCU\Software\Valve\Steam.

    Does NOT require administrator privileges: Millennium installs into the
    current user's Steam directory, which is owned by the same user.

    Copyright (c) 2026 Project Millennium - MIT License.
#>

[CmdletBinding()]
param(
    [switch]$Beta,
    [string]$RunId,
    [string]$SteamPath,
    [switch]$Yes,
    [switch]$Force,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'Continue'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Script source (this repo) - for one-line install command
$ScriptRepo     = 'SmallRob/millennium-steam-patcher'

# Release source (original repo) - for downloading releases
$ReleaseAccount = 'SteamClientHomebrew'
$ReleaseRepo    = "$ReleaseAccount/Millennium"
$ReleasesApiUri = "https://api.github.com/repos/$ReleaseRepo/releases"
$DownloadBase   = "https://github.com/$ReleaseRepo/releases/download"
$NightlyBase    = "https://nightly.link/$ReleaseRepo/actions/runs"
$UserAgent      = 'millennium-windows-installer/1.0 (+powershell)'
$TempRoot       = Join-Path $env:TEMP 'millennium-install'

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
$Script:UseAnsi = $Host.UI.SupportsVirtualTerminal -or $env:WT_SESSION -or $env:TERM_PROGRAM

function Write-Banner {
    Write-Host ''
    if ($Script:UseAnsi) {
        Write-Host '  ' -NoNewline
        Write-Host 'Millennium' -ForegroundColor Cyan
    } else {
        Write-Host '  Millennium'
    }
    Write-Host '  Windows installer for the Steam modding framework'
    Write-Host '  https://steambrew.app/'
    Write-Host ''
}

function Write-Info  ($msg) { Write-Host "  :: $msg" }
function Write-Step  ($n, $total, $msg) { Write-Host "  ($n/$total) $msg" }
function Write-Ok    ($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn  ($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err   ($msg) { Write-Host "  [ERROR] $msg" -ForegroundColor Red }
function Write-Ask   ($msg) { Write-Host "  :: $msg" -ForegroundColor Cyan }

function Format-Bytes ([long]$bytes) {
    if ($bytes -lt 1) { return '0 B' }
    $units = 'B','KB','MB','GB','TB'
    $i = [math]::Floor([math]::Log($bytes, 1024))
    $i = [math]::Min($i, $units.Count - 1)
    $value = $bytes / [math]::Pow(1024, $i)
    return ('{0:N2} {1}' -f $value, $units[$i])
}

# ---------------------------------------------------------------------------
# Steam helpers
# ---------------------------------------------------------------------------
function Resolve-SteamPath {
    [CmdletBinding()]
    param([string]$Override)

    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override -PathType Container)) {
            throw "SteamPath override '$Override' is not an existing directory."
        }
        return (Resolve-Path -LiteralPath $Override).ProviderPath
    }

    $candidates = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'
    )

    foreach ($key in $candidates) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $value = (Get-ItemProperty -LiteralPath $key -Name 'SteamPath' -ErrorAction SilentlyContinue).SteamPath
        if (-not $value) { continue }

        # Steam writes paths with forward slashes and may contain %ProgramFiles%.
        $expanded = [Environment]::ExpandEnvironmentVariables($value)
        $expanded = $expanded -replace '/', '\'
        $expanded = [System.IO.Path]::GetFullPath($expanded)

        if (Test-Path -LiteralPath $expanded -PathType Container) {
            return $expanded
        }
    }

    throw "Could not detect your Steam installation from the registry. `n" +
          "Install Steam first, or pass -SteamPath to point at it manually."
}

function Test-SteamRunning {
    [CmdletBinding()] param()
    # steam.exe and steamwebhelper.exe are the long-running UI/browser processes.
    $procs = Get-Process -Name 'steam','steamwebhelper' -ErrorAction SilentlyContinue
    return [bool]$procs
}

function Stop-Steam {
    Write-Info 'Closing Steam (this can take a few seconds)...'
    Get-Process -Name 'steam','steamwebhelper','steamservice' -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    }

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-SteamRunning)) { return }
        Start-Sleep -Milliseconds 500
    }

    if (Test-SteamRunning) {
        throw 'Steam is still running. Please close it manually and re-run the installer.'
    }
}

# ---------------------------------------------------------------------------
# Release / artifact discovery
# ---------------------------------------------------------------------------
function Get-LatestRelease {
    [CmdletBinding()]
    param([switch]$AllowPrerelease)

    Write-Info "Querying GitHub for the latest $(if ($AllowPrerelease) { 'pre-release' } else { 'stable' }) release..."

    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    $page = 1
    $tag = $null
    $size = 0

    while ($page -le 5) {
        $uri = "$ReleasesApiUri?per_page=100&page=$page"
        $releases = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30

        if (-not $releases -or $releases.Count -eq 0) { break }

        $pick = $releases | Where-Object {
            ($AllowPrerelease -or -not $_.prerelease) -and $_.tag_name
        } | Select-Object -First 1

        if ($pick) {
            $tag = $pick.tag_name.TrimStart('v')
            $asset = $pick.assets | Where-Object { $_.name -eq "millennium-v$($tag)-windows-x86_64.zip" } | Select-Object -First 1
            if ($asset) { $size = [long]$asset.size }
            break
        }

        $page++
    }

    if (-not $tag) { throw 'No suitable Millennium release was found on GitHub.' }
    return [pscustomobject]@{ Tag = $tag; Size = $size }
}

# ---------------------------------------------------------------------------
# Download / verify
# ---------------------------------------------------------------------------
function Invoke-FileDownload {
    [CmdletBinding()]
    param([string]$Uri, [string]$OutFile)

    Write-Info "Downloading $Uri"
    # Use HttpClient to avoid the awful progress bar of Invoke-WebRequest while
    # still streaming the file to disk in chunks.
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = $UserAgent
    $request.Timeout   = 60_000
    $request.AllowAutoRedirect = $true

    $response = $request.GetResponse()
    $total = [long]$response.ContentLength
    $stream = $response.GetResponseStream()

    $fs = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536
    $read = 0
    $done = 0
    $lastLog = Get-Date
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $done += $read
            if ($total -gt 0 -and ((Get-Date) - $lastLog).TotalMilliseconds -gt 250) {
                $pct = [int](($done / $total) * 100)
                Write-Host "`r   -> $pct%   $(Format-Bytes $done)/$(Format-Bytes $total)" -NoNewline
                $lastLog = Get-Date
            }
        }
    } finally {
        $fs.Dispose()
        $stream.Dispose()
        $response.Dispose()
    }
    Write-Host ''

    if ($total -gt 0 -and $done -ne $total) {
        throw "Downloaded $done bytes but the server reported $total."
    }
}

function Get-Sha256OfFile ([string]$Path) {
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.ToLower()
}

function Get-ExpectedSha256 ([string]$Tag) {
    $uri = "$DownloadBase/v$Tag/millennium-v$Tag-windows-x86_64.sha256"
    try {
        $body = (Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 30).Content.Trim()
    } catch {
        return $null
    }
    # Format is "<hash>  <filename>" or just "<hash>" - take the first 64-hex token.
    if ($body -match '([a-fA-F0-9]{64})') { return $Matches[1].ToLower() }
    return $null
}

# ---------------------------------------------------------------------------
# Install / uninstall
# ---------------------------------------------------------------------------
function Backup-ExistingFiles ([string]$SteamDir) {
    $backupDir = Join-Path $TempRoot 'backup'
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $wsock = Join-Path $SteamDir 'wsock32.dll'
    if (Test-Path -LiteralPath $wsock) {
        Copy-Item -LiteralPath $wsock -Destination (Join-Path $backupDir 'wsock32.dll') -Force
        Write-Info "Backed up existing $wsock to backup\wsock32.dll"
    }
}

function Copy-MillenniumToSteam {
    [CmdletBinding()]
    param([string]$ExtractedRoot, [string]$SteamDir)

    $libDir = Join-Path $SteamDir 'millennium\lib'
    $binDir = Join-Path $SteamDir 'millennium\bin'
    New-Item -ItemType Directory -Path $libDir, $binDir -Force | Out-Null

    # Bootstrap dll lands directly in the Steam root.
    $wsock = Join-Path $ExtractedRoot 'wsock32.dll'
    if (Test-Path -LiteralPath $wsock) {
        Copy-Item -LiteralPath $wsock -Destination (Join-Path $SteamDir 'wsock32.dll') -Force
    } else {
        throw "Bootstrap wsock32.dll is missing from the release archive."
    }

    $lib = Join-Path $ExtractedRoot 'millennium\lib'
    if (Test-Path -LiteralPath $lib) {
        Get-ChildItem -LiteralPath $lib -File -Recurse | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $libDir -Force
        }
    }

    $bin = Join-Path $ExtractedRoot 'millennium\bin'
    if (Test-Path -LiteralPath $bin) {
        Get-ChildItem -LiteralPath $bin -File -Recurse | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $binDir -Force
        }
    }
}

function Read-InstalledVersion ([string]$SteamDir) {
    $probe = Join-Path $SteamDir 'millennium\lib\millennium.dll'
    if (-not (Test-Path -LiteralPath $probe)) { return $null }
    $ver = (Get-Item -LiteralPath $probe).VersionInfo.FileVersion
    if ($ver) { return $ver }
    return (Get-Item -LiteralPath $probe).VersionInfo.ProductVersion
}

function Uninstall-Millennium {
    [CmdletBinding()]
    param([string]$SteamDir)

    Write-Step 1 3 'Checking for running Steam...'
    if (Test-SteamRunning) { Stop-Steam } else { Write-Ok 'Steam is not running.' }

    Write-Step 2 3 'Removing Millennium files...'
    $wsock = Join-Path $SteamDir 'wsock32.dll'
    $mDir  = Join-Path $SteamDir 'millennium'

    if (Test-Path -LiteralPath $mDir) {
        Remove-Item -LiteralPath $mDir -Recurse -Force
        Write-Ok "Removed $mDir"
    } else {
        Write-Info "$mDir does not exist (already uninstalled)."
    }

    if (Test-Path -LiteralPath $wsock) {
        $backup = Join-Path $TempRoot 'backup\wsock32.dll'
        if (Test-Path -LiteralPath $backup) {
            Move-Item -LiteralPath $backup -Destination $wsock -Force
            Write-Ok "Restored original $wsock from backup."
        } else {
            Remove-Item -LiteralPath $wsock -Force
            Write-Ok "Removed $wsock (no backup was found)."
        }
    } else {
        Write-Info "$wsock does not exist."
    }

    Write-Step 3 3 'Done.'
    Write-Ok 'Millennium has been uninstalled.'
    Write-Host ''
    Write-Host '  You can now start Steam normally.' -ForegroundColor Cyan
    Write-Host ''
}

function Install-Millennium {
    [CmdletBinding()]
    param(
        [string]$SteamDir,
        [switch]$AllowPrerelease,
        [string]$RunIdOverride,
        [switch]$ForceInstall,
        [switch]$AutoYes
    )

    # ------------------------------------------------------------------
    # Discover release
    # ------------------------------------------------------------------
    if ($RunIdOverride) {
        $tag = "run-$RunIdOverride"
        $zipName = 'millennium-windows.zip'
        $zipUri  = "$NightlyBase/$RunIdOverride/$zipName"
        $expectedSha = $null
        $expectedSize = 0
    } else {
        $rel = Get-LatestRelease -AllowPrerelease:$AllowPrerelease
        $tag = $rel.Tag
        $zipName = "millennium-v$tag-windows-x86_64.zip"
        $zipUri  = "$DownloadBase/v$tag/$zipName"
        $expectedSha = Get-ExpectedSha256 -Tag $tag
        $expectedSize = $rel.Size
    }

    $sizeStr = if ($expectedSize -gt 0) { Format-Bytes $expectedSize } else { 'unknown' }

    Write-Host ''
    Write-Host "  Package : Millennium v$tag (windows-x86_64)" -ForegroundColor Cyan
    Write-Host "  Download: $sizeStr"
    Write-Host "  Target  : $SteamDir"
    Write-Host ''

    if (-not $AutoYes) {
        Write-Ask 'Proceed with installation? [Y/n]'
        $answer = Read-Host
        if ($answer -match '^[Nn]') {
            Write-Info 'Aborted by user.'
            return
        }
    }

    # ------------------------------------------------------------------
    # Pre-flight
    # ------------------------------------------------------------------
    Write-Step 1 4 'Checking for running Steam...'
    if (Test-SteamRunning) { Stop-Steam } else { Write-Ok 'Steam is not running.' }

    $existing = Read-InstalledVersion -SteamDir $SteamDir
    if ($existing -and -not $ForceInstall) {
        Write-Warn "Millennium $existing is already installed in $SteamDir."
        Write-Info 'Re-run with -Force to reinstall, or -Uninstall to remove.'
        return
    }

    # ------------------------------------------------------------------
    # Download + verify
    # ------------------------------------------------------------------
    if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    $zipPath = Join-Path $TempRoot $zipName
    Write-Step 2 4 "Downloading Millennium v$tag..."
    Invoke-FileDownload -Uri $zipUri -OutFile $zipPath

    Write-Step 3 4 'Verifying SHA-256 checksum...'
    $actualSha = Get-Sha256OfFile -Path $zipPath
    if ($expectedSha) {
        if ($actualSha -ne $expectedSha) {
            throw "SHA-256 mismatch.`n  expected: $expectedSha`n  actual:   $actualSha`nThe download is corrupt - aborting."
        }
        Write-Ok 'Checksum verified.'
    } else {
        Write-Warn "No published SHA-256 for this build (nightly run or rate-limited). Skipping verification."
    }

    # ------------------------------------------------------------------
    # Extract + install
    # ------------------------------------------------------------------
    Write-Step 4 4 'Extracting and installing...'
    $extractDir = Join-Path $TempRoot 'files'
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    # Use [System.IO.Compression.ZipFile] so we don't depend on tar/external tools.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

    Backup-ExistingFiles -SteamDir $SteamDir
    Copy-MillenniumToSteam -ExtractedRoot $extractDir -SteamDir $SteamDir

    # Best-effort cleanup of the temp dir (don't fail the install on error).
    try { Remove-Item -LiteralPath $TempRoot -Recurse -Force } catch { }

    Write-Host ''
    Write-Ok "Millennium v$tag installed."
    Write-Host ''
    Write-Host '  You can now start Steam.' -ForegroundColor Cyan
    Write-Host '  Docs: https://docs.steambrew.app/users/getting-started/installation' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
try {
    if ($Beta -and $RunId) { throw '-Beta and -RunId are mutually exclusive.' }

    Write-Banner

    $steamDir = Resolve-SteamPath -Override $SteamPath

    if ($Uninstall) {
        Uninstall-Millennium -SteamDir $steamDir
    } else {
        # `:[bool]` (here written as the :Switch form) is the only reliable
        # way to forward a script-level [switch] into a child function that
        # also declares it as [switch] / [bool]. Plain `[bool]$Beta` looks
        # valid but the binder sees a string and refuses.
        Install-Millennium `
            -SteamDir          $steamDir `
            -AllowPrerelease:$Beta `
            -RunIdOverride     $RunId `
            -ForceInstall:$Force `
            -AutoYes:$Yes
    }
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Host ''
    exit 1
}
