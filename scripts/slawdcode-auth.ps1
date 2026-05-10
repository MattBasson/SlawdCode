#Requires -Version 5.1
# SlawdCode — one-time OAuth authentication setup
# Windows PowerShell (requires Podman Desktop or Docker Desktop)
#
# Run this once. A browser window will open — sign in with your Anthropic account.
# OAuth tokens are saved to %USERPROFILE%\.claude\ on the HOST machine (never in the container).
# After this, you can run 'claude' without any API key.

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

# Determine the user's home directory portably. $env:USERPROFILE is the
# usual Windows source but is empty in some session contexts (service
# accounts, sandboxed shells, etc.), so fall back through PowerShell's
# automatic $HOME, the .NET UserProfile folder, and $env:HOME.
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

$HostConfig = Join-Path (Get-UserHome) '.claude'
if (-not (Test-Path $HostConfig)) {
    New-Item -ItemType Directory -Path $HostConfig | Out-Null
}

# Convert Windows path to Unix-style for container volume mount
$HostConfigUnix = $HostConfig -replace '\\', '/' -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }

Write-Host 'SlawdCode — Claude Code Authentication'
Write-Host '======================================='
Write-Host 'A browser window will open. Sign in with your Anthropic account.'
Write-Host "Your credentials will be saved to: $HostConfig"
Write-Host ''

$RunArgs = @(
    'run', '--rm', '--interactive', '--tty',
    '--volume', "${HostConfigUnix}:/home/claude/.claude:z",
    '--security-opt', 'no-new-privileges',
    '--cap-drop', 'ALL'
)

if ($env:SLAWDCODE_EXTRA_ARGS) {
    $RunArgs += ($env:SLAWDCODE_EXTRA_ARGS -split '\s+' | Where-Object { $_ -ne '' })
}

$RunArgs += $Image, 'auth', 'login'

& $Runtime @RunArgs
exit $LASTEXITCODE
