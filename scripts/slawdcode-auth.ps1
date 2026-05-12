#Requires -Version 5.1
# SlawdCode — one-time OAuth authentication setup
# Windows PowerShell (requires Podman Desktop or Docker Desktop)
#
# Run this once (or any time you need to re-authenticate). A browser window
# will open — sign in with your Anthropic account. OAuth tokens are saved to
# %USERPROFILE%\.claude\ and %USERPROFILE%\.claude.json on the HOST machine,
# never inside the container image.

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
$HostSession = Join-Path $UserHomeDir '.claude.json'
$HostCreds   = Join-Path $HostConfig '.credentials.json'

function ConvertTo-UnixPath([string]$WinPath) {
    $WinPath -replace '\\', '/'
}

# --- Pre-auth: remove stale auth containers from previous failed runs ---
#
# When credential extraction fails, slawdcode-auth intentionally leaves the
# named container behind so the user can run 'podman cp' manually. On
# Windows / Podman Desktop these stopped containers can hold Podman's WSL2
# bridge in a degraded state that causes subsequent auth runs to also fail.
# Removing them here resets that state before every new attempt, eliminating
# the need to run 'make clean' just to get a working re-auth.
try {
    $staleIds = @(& $Runtime ps -aq --filter 'name=slawdcode-auth-' 2>$null |
                    Where-Object { $_ -ne '' })
    if ($staleIds.Count -gt 0) {
        Write-Host 'Removing stale auth containers...'
        & $Runtime rm -f @staleIds 2>$null | Out-Null
    }
} catch { }

# Reset both credential files to clean '{}' placeholders before every auth run.
#
# This serves two purposes:
#
#  1. It clears any stale / expired session state so that the regular 'claude'
#     wrapper always has valid JSON files to bind-mount, even when auth fails.
#     The files are overwritten by 'podman cp' once auth succeeds.
#
#  2. It prevents stale data from influencing behaviour: previously the host
#     ~/.claude.json (containing an existing session reference) was
#     bind-mounted into the auth container. Claude Code would detect the
#     "existing session" and sometimes skip the OAuth browser redirect
#     entirely, leaving credentials empty. By resetting the file here and
#     NOT mounting it (see below), every auth run is a guaranteed clean-slate
#     OAuth flow.
[System.IO.File]::WriteAllText($HostSession, '{}')
[System.IO.File]::WriteAllText($HostCreds, '{}')

Write-Host 'SlawdCode — Claude Code Authentication'
Write-Host '======================================='
Write-Host 'A browser window will open. Sign in with your Anthropic account.'
Write-Host 'Your credentials will be saved to:'
Write-Host "  $HostConfig"
Write-Host "  $HostSession"
Write-Host "  $HostCreds"
Write-Host ''

# --- Why this script runs the auth container with NO volume mounts ---
#
# The auth container is intentionally started with no bind mounts so that:
#
#  a) Claude Code writes its OAuth tokens and session metadata entirely to
#     the container's own overlay filesystem (ext4 inside the WSL2 VM on
#     Windows). There is no WSL2 → 9p → NTFS boundary for the
#     atomic-rename write to fail across.
#
#  b) 'podman cp' reads from that same overlay, not through a bind mount.
#     When ~/.claude.json was bind-mounted, 'podman cp' would read through
#     the mount back to the host file, returning the stale placeholder
#     instead of the freshly-written session file.
#
#  c) Every re-auth is a guaranteed clean-slate OAuth flow. A stale or
#     expired ~/.claude.json on the host can cause Claude Code to detect
#     an "existing session" and skip the browser redirect, leaving the
#     credentials file empty. With no mounts, that can't happen.

$AuthContainer = "slawdcode-auth-{0}-{1}" -f $PID, [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$RunArgs = @(
    'run',
    '--interactive', '--tty',
    '--name', $AuthContainer,
    '--security-opt', 'no-new-privileges',
    '--cap-drop', 'ALL'
)

if ($env:SLAWDCODE_EXTRA_ARGS) {
    # M3: reject flags that would undo container hardening.
    $deniedPattern = '--privileged|--cap-add|--user[\s=]+0|--user[\s=]+root|--network[\s=]+host|--pid[\s=]+host|--ipc[\s=]+host|--userns[\s=]+host|--security-opt[\s=]+seccomp=unconfined|--security-opt[\s=]+apparmor=unconfined|--security-opt[\s=]+label=disable'
    if ($env:SLAWDCODE_EXTRA_ARGS -imatch $deniedPattern) {
        if ($env:SLAWDCODE_ALLOW_UNSAFE_EXTRA_ARGS -eq '1') {
            Write-Warning 'SLAWDCODE_ALLOW_UNSAFE_EXTRA_ARGS=1 — security-hardening bypass active.'
        } else {
            Write-Error 'SLAWDCODE_EXTRA_ARGS contains a flag that undoes container hardening. Set SLAWDCODE_ALLOW_UNSAFE_EXTRA_ARGS=1 to override.'
            exit 1
        }
    }
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
    Write-Host ("HostConfig:     {0}" -f $HostConfig)
    Write-Host ("HostSession:    {0}" -f $HostSession)
    Write-Host ("HostCreds:      {0}" -f $HostCreds)
    Write-Host "Strategy:       no mounts; named container + '$Runtime cp' both files after auth"
    Write-Host "Command:"
    Write-Host ("  {0} {1}" -f $Runtime, ($RunArgs -join ' '))
    Write-Host '-----------------------' -ForegroundColor Cyan
}

$authExit = 0
try {
    & $Runtime @RunArgs
    $authExit = $LASTEXITCODE
} finally {
    # Extract .credentials.json. Try both Windows-style and forward-slash
    # destination paths because Podman Desktop on Windows can be fussy about
    # which form it accepts.
    $HostCredsUnix = ConvertTo-UnixPath $HostCreds
    $cpAttempts = @(
        @{ Label = 'Windows-style path'; Dest = $HostCreds     },
        @{ Label = 'Forward-slash path'; Dest = $HostCredsUnix }
    )
    $extractStatus = 1
    $lastOutput    = ''
    foreach ($attempt in $cpAttempts) {
        $output = & $Runtime cp `
            "${AuthContainer}:/home/claude/.claude/.credentials.json" `
            $attempt.Dest 2>&1
        $extractStatus = $LASTEXITCODE
        $lastOutput    = ($output | Out-String).Trim()
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
        Write-Host '           1. Re-run slawdcode-auth — stale containers are pre-cleaned automatically.' -ForegroundColor Yellow
        Write-Host '           2. Manually extract:' -ForegroundColor Yellow
        Write-Host ("                $Runtime cp '${AuthContainer}:/home/claude/.claude/.credentials.json' '$HostCreds'") -ForegroundColor Yellow
        Write-Host '              (the named container above is left in place if this happens, so the file is still inside it).' -ForegroundColor Yellow
        Write-Host '           3. Bypass OAuth entirely by setting ANTHROPIC_API_KEY before running ''claude''.' -ForegroundColor Yellow
        Write-Host '              See the README "Authentication / Fallback: API key" section.' -ForegroundColor Yellow

        if (-not (Test-Path $HostCreds) -or (Get-Item $HostCreds).Length -eq 0) {
            [System.IO.File]::WriteAllText($HostCreds, '{}')
        }
    }

    # Extract ~/.claude.json — since we no longer bind-mount it, Claude Code
    # creates a fresh version in the container overlay. We must always cp it
    # out; otherwise the host file stays at the '{}' placeholder and the
    # regular 'claude' wrapper starts each session without user/org identity.
    $HostSessionUnix = ConvertTo-UnixPath $HostSession
    foreach ($dest in @($HostSession, $HostSessionUnix)) {
        try {
            $out = & $Runtime cp "${AuthContainer}:/home/claude/.claude.json" $dest 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path $HostSession) -and (Get-Item $HostSession).Length -gt 3) {
                break
            }
        } catch { }
    }

    # Leave the named container in place only when extraction failed — the
    # user can then recover by running 'podman cp' manually.
    if ($extractStatus -eq 0) {
        try { & $Runtime rm -f $AuthContainer 2>$null | Out-Null } catch { }
    } else {
        Write-Host ("`nThe auth container '$AuthContainer' has been left in place so you can inspect or extract its contents.") -ForegroundColor Cyan
        Write-Host ("Remove it manually when done: $Runtime rm -f $AuthContainer") -ForegroundColor Cyan
    }
}

exit $authExit
