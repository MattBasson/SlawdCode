#Requires -Version 5.1
# SlawdCode — one-time OAuth authentication setup
# Windows PowerShell (requires Podman Desktop or Docker Desktop)
#
# OAuth tokens are saved to %USERPROFILE%\.claude\ and ~\.claude.json on
# the HOST machine, never inside the container image.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Image = if ($env:SLAWDCODE_IMAGE) { $env:SLAWDCODE_IMAGE } else { 'slawdcode:latest' }

$Runtime = $env:SLAWDCODE_RUNTIME
if (-not $Runtime) {
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        $Runtime = 'podman'
    } elseif (Get-Command docker -ErrorAction SilentlyContinue) {
        $Runtime = 'docker'
    } else {
        Write-Error @"
Neither podman nor docker found.
  Install Podman Desktop: https://podman-desktop.io/
  Install Docker Desktop:  https://docs.docker.com/desktop/
"@
        exit 1
    }
}

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

$UserHomeDir = Get-UserHome
$HostConfig = Join-Path $UserHomeDir '.claude'
if (-not (Test-Path $HostConfig)) {
    New-Item -ItemType Directory -Path $HostConfig | Out-Null
}
# Pre-create ~/.claude.json with '{}' (Claude Code parses it on startup
# and rejects 0-byte / non-JSON content).
$HostSession = Join-Path $UserHomeDir '.claude.json'
if (-not (Test-Path $HostSession) -or (Get-Item $HostSession).Length -eq 0) {
    [System.IO.File]::WriteAllText($HostSession, '{}')
}
# Pre-create ~/.claude/.credentials.json so the regular 'claude' wrapper's
# bind mount has a file source. We intentionally do NOT bind-mount this
# file from THIS script — see the comment below.
$HostCreds = Join-Path $HostConfig '.credentials.json'
if (-not (Test-Path $HostCreds) -or (Get-Item $HostCreds).Length -eq 0) {
    [System.IO.File]::WriteAllText($HostCreds, '{}')
}

function ConvertTo-UnixPath([string]$WinPath) {
    $WinPath -replace '\\', '/'
}
$HostConfigUnix  = ConvertTo-UnixPath $HostConfig
$HostSessionUnix = ConvertTo-UnixPath $HostSession

Write-Host 'SlawdCode — Claude Code Authentication'
Write-Host '======================================='
Write-Host 'A browser window will open. Sign in with your Anthropic account.'
Write-Host 'Your credentials will be saved to:'
Write-Host "  $HostConfig"
Write-Host "  $HostSession"
Write-Host "  $HostCreds"
Write-Host ''

# --- Why this script does not bind-mount .credentials.json + --rm ---
#
# Claude Code writes its OAuth access/refresh tokens to
# /home/claude/.claude/.credentials.json (mode 0600). On Podman-Desktop /
# Docker-Desktop on Windows, that write does not reach the host through
# either a directory bind mount (file dropped when created at the root of
# the mount) or a single-file bind mount (the atomic-rename pattern Claude
# Code uses fails across WSL2 → 9p → NTFS, so the rename never lands).
#
# We work around this by running 'claude auth login' in a NAMED (not --rm)
# container, then extracting the credentials file with the runtime's own
# 'cp' subcommand, which uses a different file-extraction path than bind
# mounts. The container is then removed.

$AuthContainer = "slawdcode-auth-{0}-{1}" -f $PID, [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$RunArgs = @(
    'run',
    '--interactive', '--tty',
    '--name', $AuthContainer,
    '--volume', "${HostConfigUnix}:/home/claude/.claude:z",
    '--volume', "${HostSessionUnix}:/home/claude/.claude.json:z",
    '--security-opt', 'no-new-privileges',
    '--cap-drop', 'ALL'
)

if ($env:SLAWDCODE_EXTRA_ARGS) {
    $tokens = [System.Management.Automation.PSParser]::Tokenize(
        $env:SLAWDCODE_EXTRA_ARGS, [ref]$null
    ) | Where-Object {
        $_.Type -in @(
            [System.Management.Automation.PSTokenType]::CommandArgument,
            [System.Management.Automation.PSTokenType]::String,
            [System.Management.Automation.PSTokenType]::Command,
            [System.Management.Automation.PSTokenType]::Number
        )
    } | ForEach-Object { $_.Content }
    $RunArgs += $tokens
}

$RunArgs += $Image, 'auth', 'login'

if ($env:SLAWDCODE_DEBUG -match '^(?i:1|true|yes)$') {
    Write-Host '--- SlawdCode debug ---' -ForegroundColor Cyan
    Write-Host ("Runtime:        {0}" -f $Runtime)
    Write-Host ("Image:          {0}" -f $Image)
    Write-Host ("AuthContainer:  {0}" -f $AuthContainer)
    Write-Host ("HostConfig:     {0}  ->  {1}" -f $HostConfig, $HostConfigUnix)
    Write-Host ("HostSession:    {0}  ->  {1}" -f $HostSession, $HostSessionUnix)
    Write-Host ("HostCreds:      {0}" -f $HostCreds)
    Write-Host "Strategy:       run named container, then '$Runtime cp' the creds file out after auth"
    Write-Host "Command:"
    Write-Host ("  {0} {1}" -f $Runtime, ($RunArgs -join ' '))
    Write-Host '-----------------------' -ForegroundColor Cyan
}

$authExit = 0
try {
    & $Runtime @RunArgs
    $authExit = $LASTEXITCODE
} finally {
    # Best-effort extract regardless of exit status: even on Ctrl-C the
    # device-code flow may have already written tokens.
    try {
        & $Runtime cp "${AuthContainer}:/home/claude/.claude/.credentials.json" $HostCreds 2>$null
        $extractStatus = $LASTEXITCODE
    } catch {
        $extractStatus = 1
    }

    if ($extractStatus -ne 0) {
        Write-Host ''
        Write-Host 'Warning: could not copy .credentials.json out of the auth container.' -ForegroundColor Yellow
        Write-Host '         The OAuth login probably did not complete. Re-run slawdcode-auth.' -ForegroundColor Yellow
    }

    # Belt-and-suspenders: if the bind mount didn't capture ~/.claude.json
    # either, fall back to extracting it via cp too.
    if ((Get-Item $HostSession -ErrorAction SilentlyContinue) -and (Get-Item $HostSession).Length -le 3) {
        try {
            & $Runtime cp "${AuthContainer}:/home/claude/.claude.json" $HostSession 2>$null
        } catch { }
    }

    # Always remove the named container.
    try { & $Runtime rm -f $AuthContainer 2>$null | Out-Null } catch { }
}

exit $authExit
