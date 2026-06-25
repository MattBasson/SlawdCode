#Requires -Version 5.1
# SlawdCode uninstaller — Windows PowerShell
# Usage (from PowerShell):
#   Invoke-WebRequest https://raw.githubusercontent.com/MattBasson/SlawdCode/main/scripts/uninstall.ps1 | Invoke-Expression
#   or:
#   .\uninstall.ps1 [-PurgeCredentials] [-KeepImage] [InstallDir]
#
# Removes (the inverse of install.ps1 + make.ps1 clean):
#   - the claude/slawdcode-auth wrappers (.ps1 + .cmd shims) from the install dir
#   - the slawdcode container image
#   - stale 'slawdcode-auth-*' containers
#
# By default the shared Claude auth/config (~/.claude, ~/.claude.json) is LEFT
# IN PLACE — those files are also used by a native (non-containerized) Claude
# Code install. Pass -PurgeCredentials to delete them too.

param(
    [string]$InstallDir,
    [switch]$PurgeCredentials,
    [switch]$KeepImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Determine the user's home directory portably (same logic as install.ps1).
function Get-UserHome {
    foreach ($candidate in @(
        $env:USERPROFILE,
        $HOME,
        [Environment]::GetFolderPath('UserProfile'),
        $env:HOME
    )) {
        if ($candidate) { return $candidate }
    }
    throw 'Could not determine user home directory. Set $HOME or $env:USERPROFILE.'
}

function Resolve-Runtime {
    if ($env:SLAWDCODE_RUNTIME) { return $env:SLAWDCODE_RUNTIME }
    if (Get-Command podman -ErrorAction SilentlyContinue) { return 'podman' }
    if (Get-Command docker -ErrorAction SilentlyContinue) { return 'docker' }
    return $null
}

if (-not $InstallDir) {
    $InstallDir = Join-Path (Get-UserHome) '.local\bin'
}

$Image = if ($env:SLAWDCODE_IMAGE) { $env:SLAWDCODE_IMAGE } else { 'slawdcode:latest' }

Write-Host 'SlawdCode Uninstaller'
Write-Host '====================='

# --- Remove wrapper scripts + cmd shims ---
$removedAny = $false
foreach ($file in @('claude.ps1', 'slawdcode-auth.ps1', 'claude.cmd', 'slawdcode-auth.cmd')) {
    $target = Join-Path $InstallDir $file
    if (Test-Path $target) {
        Remove-Item -Force $target
        Write-Host "Removed $target"
        $removedAny = $true
    }
}
if (-not $removedAny) {
    Write-Host "No wrapper scripts found in $InstallDir (nothing to remove there)."
}

# --- Remove image + stale auth containers ---
if (-not $KeepImage) {
    $Runtime = Resolve-Runtime
    if (-not $Runtime) {
        Write-Host ''
        Write-Host 'NOTE: neither podman nor docker found — skipping image/container removal.'
        Write-Host "      If you build the image later, remove it with: <runtime> rmi $Image"
    } else {
        # Remove stale auth containers (same logic as make.ps1 'clean').
        try {
            $staleIds = @(& $Runtime ps -aq --filter 'name=slawdcode-auth-' 2>$null |
                            Where-Object { $_ -ne '' })
            if ($staleIds.Count -gt 0) {
                Write-Host 'Removing stale auth containers...'
                & $Runtime rm -f @staleIds 2>$null | Out-Null
            }
        } catch { }

        # Remove the image (ignore "no such image").
        & $Runtime rmi $Image 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Removed image $Image"
        } else {
            Write-Host "Image $Image not present (nothing to remove)."
        }
    }
}

# --- Shared credentials ---
$HostConfig  = Join-Path (Get-UserHome) '.claude'
$HostSession = Join-Path (Get-UserHome) '.claude.json'
if ($PurgeCredentials) {
    Write-Host ''
    Write-Host 'WARNING: removing shared Claude auth/config:'
    Write-Host "  $HostConfig"
    Write-Host "  $HostSession"
    Write-Host 'These files are also used by a native (non-containerized) Claude Code'
    Write-Host 'install. Removing them will log that out too.'
    if (Test-Path $HostConfig)  { Remove-Item -Recurse -Force $HostConfig }
    if (Test-Path $HostSession) { Remove-Item -Force $HostSession }
    Write-Host 'Removed shared credentials.'
} else {
    Write-Host ''
    Write-Host 'Left shared Claude auth/config in place:'
    Write-Host "  $HostConfig"
    Write-Host "  $HostSession"
    Write-Host '(These are shared with any native Claude Code install. To remove them'
    Write-Host ' too, re-run with -PurgeCredentials.)'
}

# --- PATH note ---
Write-Host ''
Write-Host "Done. If you added $InstallDir to your User PATH during install, you"
Write-Host 'can remove it with:'
Write-Host ''
Write-Host "  [Environment]::SetEnvironmentVariable('PATH', (([Environment]::GetEnvironmentVariable('PATH','User') -split ';' | Where-Object { `$_ -ne '$InstallDir' }) -join ';'), 'User')"
