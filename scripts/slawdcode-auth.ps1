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
    # Attempt to extract .credentials.json from the named container. On
    # Podman Desktop / Windows we've seen 'podman cp' silently fail with
    # the Windows-style destination path, so try multiple formats and
    # capture stderr for diagnosis.
    $HostCredsUnix = ConvertTo-UnixPath $HostCreds
    $cpAttempts = @(
        @{ Label = 'Windows-style path';    Dest = $HostCreds     },
        @{ Label = 'Forward-slash path';    Dest = $HostCredsUnix }
    )
    $extractStatus = 1
    $lastOutput = ''
    foreach ($attempt in $cpAttempts) {
        $output = & $Runtime cp `
            "${AuthContainer}:/home/claude/.claude/.credentials.json" `
            $attempt.Dest 2>&1
        $extractStatus = $LASTEXITCODE
        $lastOutput = ($output | Out-String).Trim()
        if ($env:SLAWDCODE_DEBUG -match '^(?i:1|true|yes)$') {
            Write-Host ("`n[debug] '$Runtime cp ... {0}' -> exit {1}" -f $attempt.Label, $extractStatus) -ForegroundColor Cyan
            if ($lastOutput) { Write-Host "[debug] output: $lastOutput" -ForegroundColor Cyan }
        }
        if ($extractStatus -eq 0 -and (Test-Path $HostCreds) -and (Get-Item $HostCreds).Length -gt 3) {
            break
        }
    }

    if ($extractStatus -ne 0 -or -not (Test-Path $HostCreds) -or (Get-Item $HostCreds).Length -le 3) {
        Write-Host ''
        Write-Host "Warning: '$Runtime cp' did not deliver .credentials.json to the host." -ForegroundColor Yellow
        if ($lastOutput) {
            Write-Host "         Last error: $lastOutput" -ForegroundColor Yellow
        }
        Write-Host '         Recovery options:' -ForegroundColor Yellow
        Write-Host '           1. Re-run slawdcode-auth (transient errors usually clear).' -ForegroundColor Yellow
        Write-Host '           2. Manually extract:' -ForegroundColor Yellow
        Write-Host ("                $Runtime cp '${AuthContainer}:/home/claude/.claude/.credentials.json' '$HostCreds'") -ForegroundColor Yellow
        Write-Host '              (the named container above is left in place if this happens, so the file is still inside it).' -ForegroundColor Yellow
        Write-Host '           3. Bypass OAuth entirely by setting ANTHROPIC_API_KEY before running ''claude''.' -ForegroundColor Yellow
        Write-Host '              See the README "Authentication / Fallback: API key" section.' -ForegroundColor Yellow

        # Restore a placeholder so the regular 'claude' wrapper's bind
        # mount has a file source even after a failed extraction.
        if (-not (Test-Path $HostCreds) -or (Get-Item $HostCreds).Length -eq 0) {
            [System.IO.File]::WriteAllText($HostCreds, '{}')
        }
    }

    # Belt-and-suspenders: if the bind-mounted ~/.claude.json stayed at
    # the 2-byte placeholder, fall back to extracting it via cp too.
    if ((Get-Item $HostSession -ErrorAction SilentlyContinue) -and (Get-Item $HostSession).Length -le 3) {
        try {
            & $Runtime cp "${AuthContainer}:/home/claude/.claude.json" $HostSession 2>$null
        } catch { }
    }

    # Always remove the named container, EXCEPT when the cp failed —
    # leaving the container behind lets the user run their own
    # 'podman cp' against it to diagnose / recover. They can remove
    # the container manually with: podman rm <name>
    if ($extractStatus -eq 0) {
        try { & $Runtime rm -f $AuthContainer 2>$null | Out-Null } catch { }
    } else {
        Write-Host ("`nThe auth container '$AuthContainer' has been left in place so you can inspect or extract its contents.") -ForegroundColor Cyan
        Write-Host ("Remove it manually when done: $Runtime rm -f $AuthContainer") -ForegroundColor Cyan
    }
}

exit $authExit
