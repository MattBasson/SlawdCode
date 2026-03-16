#Requires -Version 5.1
# SlawdCode installer — Windows PowerShell
# Usage (from PowerShell):
#   Invoke-WebRequest https://raw.githubusercontent.com/MattBasson/SlawdCode/main/scripts/install.ps1 | Invoke-Expression
#   or:
#   .\install.ps1 [InstallDir]

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.local\bin')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRaw = 'https://raw.githubusercontent.com/MattBasson/SlawdCode/main'

Write-Host 'SlawdCode Installer'
Write-Host '==================='

# Ensure install directory exists
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}

Write-Host "Downloading scripts to $InstallDir ..."

# Download PowerShell scripts
Invoke-WebRequest "$RepoRaw/scripts/claude.ps1"          -OutFile (Join-Path $InstallDir 'claude.ps1')
Invoke-WebRequest "$RepoRaw/scripts/slawdcode-auth.ps1"  -OutFile (Join-Path $InstallDir 'slawdcode-auth.ps1')

# Create .cmd shims so the commands work from cmd.exe and PowerShell
# without having to type the .ps1 extension
$ClaudeCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude.ps1" %*
'@
$ClaudeCmd | Set-Content (Join-Path $InstallDir 'claude.cmd') -Encoding ASCII

$AuthCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0slawdcode-auth.ps1" %*
'@
$AuthCmd | Set-Content (Join-Path $InstallDir 'slawdcode-auth.cmd') -Encoding ASCII

Write-Host ''
Write-Host 'Installed:'
Write-Host "  $InstallDir\claude.ps1           — run Claude Code in a secure container"
Write-Host "  $InstallDir\slawdcode-auth.ps1   — one-time OAuth login setup"
Write-Host "  $InstallDir\claude.cmd            — cmd.exe shim"
Write-Host "  $InstallDir\slawdcode-auth.cmd    — cmd.exe shim"

# Check if install dir is on PATH
$UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($UserPath -notlike "*$InstallDir*") {
    Write-Host ''
    Write-Host "NOTE: $InstallDir is not in your PATH."
    Write-Host 'Add it permanently by running:'
    Write-Host ''
    Write-Host "  [Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$InstallDir', 'User')"
    Write-Host ''
}

Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Build the container image:'
Write-Host '       git clone https://github.com/MattBasson/SlawdCode; cd SlawdCode'
Write-Host '       podman build -t slawdcode:latest .'
Write-Host ''
Write-Host '  2. Authenticate once (browser login — no API key stored):'
Write-Host '       slawdcode-auth'
Write-Host ''
Write-Host '  3. Start using Claude Code:'
Write-Host '       claude --help'
