#Requires -Version 5.1
# SlawdCode — run Claude Code securely in a rootless container
# Windows PowerShell wrapper (requires Podman Desktop or Docker Desktop)
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Configuration ---
$Image = if ($env:SLAWDCODE_IMAGE) { $env:SLAWDCODE_IMAGE } else { 'slawdcode:latest' }

# Auto-detect container runtime (prefer podman for rootless operation)
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

# --- Volume mounts ---
$HostCwd = (Get-Location).Path
$UserHomeDir = Get-UserHome
$HostConfig = Join-Path $UserHomeDir '.claude'
if (-not (Test-Path $HostConfig)) {
    New-Item -ItemType Directory -Path $HostConfig | Out-Null
}
# Bind-mounting a single file requires the source to exist. Recent Claude
# Code releases store the OAuth login state in ~/.claude.json, so without
# this file mount the token is written inside the --rm container and lost
# when the session ends.
$HostSession = Join-Path $UserHomeDir '.claude.json'
if (-not (Test-Path $HostSession)) {
    New-Item -ItemType File -Path $HostSession | Out-Null
}

# Convert Windows paths to a form both Podman Desktop and Docker Desktop
# accept reliably: forward slashes with the drive letter intact, e.g.
#   C:\Users\foo\project   →   C:/Users/foo/project
# Previously we lowercased and rewrote drive letters as '/c/Users/...'
# (the Git-Bash/MSYS form). That works in some Docker Desktop builds but
# not Podman Desktop's WSL2 backend, which interprets it as a Unix path
# under /c and silently mounts an empty location — the most likely cause
# of "slawdcode-auth succeeds but the next claude run prompts /login".
function ConvertTo-UnixPath([string]$WinPath) {
    $WinPath -replace '\\', '/'
}

$HostCwdUnix     = ConvertTo-UnixPath $HostCwd
$HostConfigUnix  = ConvertTo-UnixPath $HostConfig
$HostSessionUnix = ConvertTo-UnixPath $HostSession

# --- Build run arguments ---
$RunArgs = @(
    'run', '--rm', '--interactive', '--tty',
    '--volume', "${HostCwdUnix}:/workspace:z",
    '--volume', "${HostConfigUnix}:/home/claude/.claude:z",
    '--volume', "${HostSessionUnix}:/home/claude/.claude.json:z",
    '--workdir', '/workspace',
    '--security-opt', 'no-new-privileges',
    '--cap-drop', 'ALL'
)

# --- Optional: cloud CLI credential persistence ---
# When SLAWDCODE_PERSIST_CLOUD_CREDS is truthy, also mount the host config
# directories for the bundled cloud CLIs (gh, aws, az) so authentication
# survives across 'claude' invocations. Host directories are created if
# they do not already exist.
$PersistRaw = if ($env:SLAWDCODE_PERSIST_CLOUD_CREDS) { $env:SLAWDCODE_PERSIST_CLOUD_CREDS } else { '' }
if ($PersistRaw -match '^(?i:1|true|yes)$') {
    $UserHome = Get-UserHome
    $CloudMounts = @(
        @{ Host = (Join-Path $UserHome '.config\gh'); Container = '/home/claude/.config/gh' },
        @{ Host = (Join-Path $UserHome '.aws');       Container = '/home/claude/.aws' },
        @{ Host = (Join-Path $UserHome '.azure');     Container = '/home/claude/.azure' }
    )
    foreach ($m in $CloudMounts) {
        if (-not (Test-Path $m.Host)) {
            New-Item -ItemType Directory -Path $m.Host -Force | Out-Null
        }
        $HostUnix = ConvertTo-UnixPath $m.Host
        $RunArgs += @('--volume', "${HostUnix}:$($m.Container):z")
    }
}

# Authentication — OAuth preferred (run slawdcode-auth.ps1 once to set up)
# Fallback: ANTHROPIC_API_KEY for CI / automation only
if ($env:ANTHROPIC_API_KEY) {
    $RunArgs += @('--env', "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY")
}

# Extra runtime flags (e.g. proxy, custom CA)
if ($env:SLAWDCODE_EXTRA_ARGS) {
    $RunArgs += ($env:SLAWDCODE_EXTRA_ARGS -split '\s+' | Where-Object { $_ -ne '' })
}

$RunArgs += $Image
if ($ClaudeArgs) { $RunArgs += $ClaudeArgs }

# --- Optional debug ---
# SLAWDCODE_DEBUG=1 prints the resolved host paths and the full runtime
# command before executing — useful when troubleshooting "auth doesn't
# persist" issues, where the most common cause is a host path that
# doesn't resolve correctly through the container runtime's bind mount.
if ($env:SLAWDCODE_DEBUG -match '^(?i:1|true|yes)$') {
    Write-Host '--- SlawdCode debug ---' -ForegroundColor Cyan
    Write-Host ("Runtime:      {0}" -f $Runtime)
    Write-Host ("Image:        {0}" -f $Image)
    Write-Host ("HostCwd:      {0}  ->  {1}" -f $HostCwd, $HostCwdUnix)
    Write-Host ("HostConfig:   {0}  ->  {1}" -f $HostConfig, $HostConfigUnix)
    Write-Host ("HostSession:  {0}  ->  {1}" -f $HostSession, $HostSessionUnix)
    if (Test-Path $HostSession) {
        $info = Get-Item $HostSession
        Write-Host ("HostSession size: {0} bytes, last write: {1}" -f $info.Length, $info.LastWriteTime)
    }
    Write-Host "Command:"
    Write-Host ("  {0} {1}" -f $Runtime, ($RunArgs -join ' '))
    Write-Host '-----------------------' -ForegroundColor Cyan
}

& $Runtime @RunArgs
exit $LASTEXITCODE
