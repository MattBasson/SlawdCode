#Requires -Version 5.1
# SlawdCode — PowerShell equivalent of the Makefile.
# Usage:
#   .\scripts\make.ps1 <target>
# Targets:
#   build    Build the container image
#   auth     Authenticate with Claude (one-time OAuth browser login)
#   install  Install 'claude' and 'slawdcode-auth' commands to %USERPROFILE%\.local\bin
#   run      Open an interactive Claude Code session in the current directory
#   clean    Remove the local container image
#   help     Show this help

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Image      = if ($env:SLAWDCODE_IMAGE) { $env:SLAWDCODE_IMAGE } else { 'slawdcode:latest' }
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir

function Resolve-Runtime {
    if ($env:SLAWDCODE_RUNTIME) { return $env:SLAWDCODE_RUNTIME }
    if (Get-Command podman -ErrorAction SilentlyContinue) { return 'podman' }
    if (Get-Command docker -ErrorAction SilentlyContinue) { return 'docker' }
    Write-Error @"
Neither podman nor docker found.
  Install Podman Desktop: https://podman-desktop.io/
  Install Docker Desktop: https://docs.docker.com/desktop/
"@
}

function Show-Help {
    Write-Host 'SlawdCode — PowerShell make targets'
    Write-Host ''
    Write-Host '  build    Build the container image'
    Write-Host '  auth     Authenticate with Claude (one-time OAuth browser login)'
    Write-Host '  install  Install ''claude'' and ''slawdcode-auth'' commands to %USERPROFILE%\.local\bin'
    Write-Host '  run      Open an interactive Claude Code session in the current directory'
    Write-Host '  clean    Remove the local container image'
    Write-Host '  help     Show this help'
    Write-Host ''
    Write-Host 'Environment variables:'
    Write-Host "  SLAWDCODE_IMAGE    Container image to build/run/clean (default: slawdcode:latest)"
    Write-Host "  SLAWDCODE_RUNTIME  Force 'podman' or 'docker' (default: auto-detect)"
}

switch ($Target.ToLowerInvariant()) {
    'help' {
        Show-Help
    }
    'build' {
        $Runtime = Resolve-Runtime
        & $Runtime build -t $Image $RepoRoot
        exit $LASTEXITCODE
    }
    'clean' {
        $Runtime = Resolve-Runtime
        & $Runtime rmi $Image 2>$null
        exit 0
    }
    'auth' {
        & (Join-Path $ScriptDir 'slawdcode-auth.ps1') @Rest
        exit $LASTEXITCODE
    }
    'install' {
        & (Join-Path $ScriptDir 'install.ps1') @Rest
        exit $LASTEXITCODE
    }
    'run' {
        & (Join-Path $ScriptDir 'claude.ps1') @Rest
        exit $LASTEXITCODE
    }
    default {
        Write-Error "Unknown target '$Target'. Run '.\scripts\make.ps1 help' for the list of targets."
    }
}
