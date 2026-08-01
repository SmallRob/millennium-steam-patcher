<#
.SYNOPSIS
    Millennium - Windows uninstaller with cache cleanup.

.DESCRIPTION
    Completely removes Millennium from the Steam installation and cleans up
    all user cache data, restoring Steam to a clean state.

    Removes:
        - Millennium binaries (millennium\lib\, millennium\bin\)
        - Bootstrap DLL (wsock32.dll)
        - User cache and configuration data
        - Temporary files

    Can be run locally (.\uninstall.ps1) or piped from the web:

        iwr -useb https://raw.githubusercontent.com/SmallRob/millennium-steam-patcher/main/scripts/uninstall.ps1 | iex

.PARAMETER SteamPath
    Override the auto-detected Steam install path.

.PARAMETER Yes
    Skip the interactive confirmation prompt.

.PARAMETER KeepCache
    Keep user cache and configuration data.

.EXAMPLE
    PS> .\uninstall.ps1
    Removes Millennium and cleans all cache data.

.EXAMPLE
    PS> .\uninstall.ps1 -KeepCache
    Removes Millennium but keeps user cache.

.EXAMPLE
    PS> .\uninstall.ps1 -Yes
    Removes Millennium without confirmation prompt.

.NOTES
    Requires: PowerShell 5.1+ (ships with Windows 10 / 11).

    Does NOT require administrator privileges: Millennium installs into the
    current user's Steam directory, which is owned by the same user.

    Copyright (c) 2026 Project Millennium - MIT License.
#>

[CmdletBinding()]
param(
    [string]$SteamPath,
    [switch]$Yes,
    [switch]$KeepCache
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
$Script:UseAnsi = $Host.UI.SupportsVirtualTerminal -or $env:WT_SESSION -or $env:TERM_PROGRAM

function Write-Banner {
    Write-Host ''
    if ($Script:UseAnsi) {
        Write-Host '  ' -NoNewline
        Write-Host 'Millennium Uninstaller' -ForegroundColor Cyan
    } else {
        Write-Host '  Millennium Uninstaller'
    }
    Write-Host '  Complete removal with cache cleanup'
    Write-Host '  https://steambrew.app/'
    Write-Host ''
}

function Write-Info  ($msg) { Write-Host "  :: $msg" }
function Write-Step  ($n, $total, $msg) { Write-Host "  ($n/$total) $msg" }
function Write-Ok    ($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn  ($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err   ($msg) { Write-Host "  [ERROR] $msg" -ForegroundColor Red }

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

        $expanded = [Environment]::ExpandEnvironmentVariables($value)
        $expanded = $expanded -replace '/', '\'
        $expanded = [System.IO.Path]::GetFullPath($expanded)

        if (Test-Path -LiteralPath $expanded -PathType Container) {
            return $expanded
        }
    }

    throw "Could not detect your Steam installation from the registry.`n" +
          "Install Steam first, or pass -SteamPath to point at it manually."
}

function Test-SteamRunning {
    [CmdletBinding()] param()
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
        throw 'Steam is still running. Please close it manually and re-run the uninstaller.'
    }
}

# ---------------------------------------------------------------------------
# Cleanup functions
# ---------------------------------------------------------------------------
function Remove-MillenniumFiles {
    [CmdletBinding()]
    param([string]$SteamDir)

    $wsock = Join-Path $SteamDir 'wsock32.dll'
    $mDir  = Join-Path $SteamDir 'millennium'

    if (Test-Path -LiteralPath $mDir) {
        Remove-Item -LiteralPath $mDir -Recurse -Force
        Write-Ok "Removed $mDir"
    } else {
        Write-Info "$mDir does not exist (already uninstalled)."
    }

    if (Test-Path -LiteralPath $wsock) {
        Remove-Item -LiteralPath $wsock -Force
        Write-Ok "Removed $wsock"
    } else {
        Write-Info "$wsock does not exist."
    }
}

function Remove-MillenniumCache {
    [CmdletBinding()]
    param([string]$SteamDir)

    Write-Info 'Cleaning Millennium cache and configuration...'

    # User data directories
    $userDataDir = Join-Path $SteamDir 'userdata'
    $cacheDirs = @()

    if (Test-Path -LiteralPath $userDataDir) {
        # Find all user directories and clean Millennium cache
        Get-ChildItem -LiteralPath $userDataDir -Directory | ForEach-Object {
            $userId = $_.Name
            $millenniumCache = Join-Path $_.FullName 'millennium'
            $millenniumConfig = Join-Path $_.FullName 'millennium_config'

            if (Test-Path -LiteralPath $millenniumCache) {
                $cacheDirs += $millenniumCache
            }
            if (Test-Path -LiteralPath $millenniumConfig) {
                $cacheDirs += $millenniumConfig
            }

            # Clean app cache with Millennium data
            $appCache = Join-Path $_.FullName '7' 'remote' 'cache'
            if (Test-Path -LiteralPath $appCache) {
                $millenniumFiles = Get-ChildItem -LiteralPath $appCache -Filter '*millennium*' -ErrorAction SilentlyContinue
                if ($millenniumFiles) {
                    $millenniumFiles | ForEach-Object {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Ok "Removed cache: $($_.FullName)"
                    }
                }
            }
        }
    }

    # Remove collected cache directories
    foreach ($dir in $cacheDirs) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Ok "Removed: $dir"
        }
    }

    # Clean temp files
    $tempDir = Join-Path $env:TEMP 'millennium-install'
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed temp: $tempDir"
    }

    # Clean local app data
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $millenniumLocal = Join-Path $localAppData 'Millennium'
    if (Test-Path -LiteralPath $millenniumLocal) {
        Remove-Item -LiteralPath $millenniumLocal -Recurse -Force
        Write-Ok "Removed local data: $millenniumLocal"
    }

    # Clean roaming app data
    $appData = [Environment]::GetFolderPath('ApplicationData')
    $millenniumRoaming = Join-Path $appData 'Millennium'
    if (Test-Path -LiteralPath $millenniumRoaming) {
        Remove-Item -LiteralPath $millenniumRoaming -Recurse -Force
        Write-Ok "Removed roaming data: $millenniumRoaming"
    }
}

function Remove-RegistryEntries {
    [CmdletBinding()]
    param()

    Write-Info 'Cleaning registry entries...'

    $registryPaths = @(
        'HKCU:\Software\Millennium',
        'HKCU:\Software\Classes\millennium'
    )

    foreach ($path in $registryPaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Ok "Removed registry: $path"
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
try {
    Write-Banner

    $steamDir = Resolve-SteamPath -Override $SteamPath
    Write-Info "Steam installation: $steamDir"

    # Confirmation
    if (-not $Yes) {
        Write-Host ''
        Write-Host '  This will completely remove Millennium and clean all cache data.' -ForegroundColor Yellow
        Write-Host '  Steam will be restored to its original state.' -ForegroundColor Yellow
        if ($KeepCache) {
            Write-Host '  Cache data will be preserved.' -ForegroundColor Cyan
        }
        Write-Host ''
        Write-Host '  Continue? [Y/n]' -ForegroundColor Cyan -NoNewline
        $answer = Read-Host
        if ($answer -match '^[Nn]') {
            Write-Info 'Aborted by user.'
            exit 0
        }
    }

    # Count steps
    $totalSteps = 3
    if (-not $KeepCache) { $totalSteps += 2 }

    $currentStep = 0

    # Step 1: Check Steam
    $currentStep++
    Write-Step $currentStep $totalSteps 'Checking for running Steam...'
    if (Test-SteamRunning) { Stop-Steam } else { Write-Ok 'Steam is not running.' }

    # Step 2: Remove Millennium files
    $currentStep++
    Write-Step $currentStep $totalSteps 'Removing Millennium files...'
    Remove-MillenniumFiles -SteamDir $steamDir

    # Step 3: Clean cache (if not keeping)
    if (-not $KeepCache) {
        $currentStep++
        Write-Step $currentStep $totalSteps 'Cleaning cache and configuration...'
        Remove-MillenniumCache -SteamDir $steamDir

        $currentStep++
        Write-Step $currentStep $totalSteps 'Cleaning registry entries...'
        Remove-RegistryEntries
    }

    # Final step
    $currentStep++
    Write-Step $currentStep $totalSteps 'Done.'

    Write-Host ''
    Write-Ok 'Millennium has been completely uninstalled.'
    Write-Host ''
    Write-Host '  Steam has been restored to its original state.' -ForegroundColor Cyan
    Write-Host '  You can now start Steam normally.' -ForegroundColor Cyan
    Write-Host ''

} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Host ''
    exit 1
}
