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

$UserHomeDir = Get-UserHome
$HostConfig = Join-Path $UserHomeDir '.claude'
if (-not (Test-Path $HostConfig)) {
    New-Item -ItemType Directory -Path $HostConfig | Out-Null
}
# Initialize with '{}' (valid empty-object JSON) rather than a zero-byte
# file: Claude Code parses ~/.claude.json on startup and refuses to run
# if it isn't valid JSON, so a 0-byte placeholder triggers a
# "Configuration Error / Unexpected EOF" prompt before the auth flow
# can begin.
$HostSession = Join-Path $UserHomeDir '.claude.json'
if (-not (Test-Path $HostSession) -or (Get-Item $HostSession).Length -eq 0) {
    # WriteAllText (no BOM) avoids UTF-8 BOM issues some Claude Code
    # versions hit when parsing JSON.
    [System.IO.File]::WriteAllText($HostSession, '{}')
}

# Convert Windows paths to a Podman/Docker-friendly form: forward slashes
# with the drive letter intact (e.g. C:/Users/foo/.claude.json). The
# previous '/c/Users/...' form (Git-Bash/MSYS style) is interpreted as a
# Unix path under /c by Podman Desktop's WSL2 backend and silently mounts
# an empty source — the most likely cause of "auth doesn't persist".
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
Write-Host ''

$RunArgs = @(
    'run', '--rm', '--interactive', '--tty',
    '--volume', "${HostConfigUnix}:/home/claude/.claude:z",
    '--volume', "${HostSessionUnix}:/home/claude/.claude.json:z",
    '--security-opt', 'no-new-privileges',
    '--cap-drop', 'ALL'
)

if ($env:SLAWDCODE_EXTRA_ARGS) {
    $RunArgs += ($env:SLAWDCODE_EXTRA_ARGS -split '\s+' | Where-Object { $_ -ne '' })
}

$RunArgs += $Image, 'auth', 'login'

# Optional debug: print the resolved host paths and the full runtime
# command. Useful when the next 'claude' run keeps prompting /login —
# verify the paths printed here match the files Get-ChildItem $HOME\.claude*
# shows after the auth flow completes.
if ($env:SLAWDCODE_DEBUG -match '^(?i:1|true|yes)$') {
    Write-Host '--- SlawdCode debug ---' -ForegroundColor Cyan
    Write-Host ("Runtime:      {0}" -f $Runtime)
    Write-Host ("Image:        {0}" -f $Image)
    Write-Host ("HostConfig:   {0}  ->  {1}" -f $HostConfig, $HostConfigUnix)
    Write-Host ("HostSession:  {0}  ->  {1}" -f $HostSession, $HostSessionUnix)
    Write-Host "Command:"
    Write-Host ("  {0} {1}" -f $Runtime, ($RunArgs -join ' '))
    Write-Host '-----------------------' -ForegroundColor Cyan
}

& $Runtime @RunArgs
exit $LASTEXITCODE
