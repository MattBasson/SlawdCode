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

# L11: soft warning for images that don't look like locally built slawdcode images.
if ($Image -notmatch '^slawdcode[:/]') {
    Write-Warning "SLAWDCODE_IMAGE='$Image' does not start with 'slawdcode/' — using a custom image."
}

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
# Bind-mounting a single file requires the source to exist. Initialize with
# '{}' rather than a zero-byte file: Claude Code parses ~/.claude.json on
# startup and refuses to run if the file isn't valid JSON, so a 0-byte
# placeholder triggers a "Configuration Error / Unexpected EOF" prompt
# before the auth flow can begin.
$HostSession = Join-Path $UserHomeDir '.claude.json'
if (-not (Test-Path $HostSession) -or (Get-Item $HostSession).Length -eq 0) {
    # WriteAllText is BOM-free; Claude Code's JSON parser dislikes BOMs.
    [System.IO.File]::WriteAllText($HostSession, '{}')
}

# Separately bind-mount ~/.claude/.credentials.json (the OAuth tokens
# Claude Code writes after a successful 'auth login'). On Podman-Desktop /
# Docker-Desktop on Windows, brand-new files at the root of a directory
# bind mount through the WSL2→9p→NTFS path don't reliably reach the host,
# so a freshly-created .credentials.json never appears on disk. Pre-
# creating the file and binding it directly forces the single-file mount
# code path, the same one that already works for ~/.claude.json.
$HostCreds = Join-Path $HostConfig '.credentials.json'
if (-not (Test-Path $HostCreds) -or (Get-Item $HostCreds).Length -eq 0) {
    [System.IO.File]::WriteAllText($HostCreds, '{}')
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
$HostCredsUnix   = ConvertTo-UnixPath $HostCreds

# --- Build run arguments ---
$RunArgs = @(
    'run', '--rm', '--interactive', '--tty',
    '--volume', "${HostCwdUnix}:/workspace:z",
    '--volume', "${HostConfigUnix}:/home/claude/.claude:z",
    '--volume', "${HostSessionUnix}:/home/claude/.claude.json:z",
    '--volume', "${HostCredsUnix}:/home/claude/.claude/.credentials.json:z",
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
    Write-Host ("HostCreds:    {0}  ->  {1}" -f $HostCreds, $HostCredsUnix)
    if (Test-Path $HostCreds) {
        $info = Get-Item $HostCreds
        Write-Host ("HostCreds size:   {0} bytes, last write: {1}" -f $info.Length, $info.LastWriteTime)
    }
    Write-Host "Command:"
    Write-Host ("  {0} {1}" -f $Runtime, ($RunArgs -join ' '))
    Write-Host '-----------------------' -ForegroundColor Cyan
}

# L4: resource limits — override with SLAWDCODE_PIDS_LIMIT / SLAWDCODE_MEMORY; set to 'none' to disable.
$PidsLimit = if ($env:SLAWDCODE_PIDS_LIMIT) { $env:SLAWDCODE_PIDS_LIMIT } else { '512' }
$Memory    = if ($env:SLAWDCODE_MEMORY)     { $env:SLAWDCODE_MEMORY }     else { '4g' }
if ($PidsLimit -ne 'none') { $RunArgs += @('--pids-limit', $PidsLimit) }
if ($Memory    -ne 'none') { $RunArgs += @('--memory',     $Memory)    }

# L5: read-only rootfs (opt-in) — set SLAWDCODE_READONLY_ROOTFS=1.
if ($env:SLAWDCODE_READONLY_ROOTFS -match '^(?i:1|true|yes)$') {
    $RunArgs += @('--read-only', '--tmpfs', '/tmp:mode=1777', '--tmpfs', '/home/claude/.cache:mode=0700')
}

& $Runtime @RunArgs
exit $LASTEXITCODE
