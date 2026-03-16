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

# --- Volume mounts ---
$HostCwd = (Get-Location).Path
$HostConfig = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $HostConfig)) {
    New-Item -ItemType Directory -Path $HostConfig | Out-Null
}

# Convert Windows paths to Unix-style paths for container volume mounts
# e.g. C:\Users\foo\project → /c/Users/foo/project
function ConvertTo-UnixPath([string]$WinPath) {
    $WinPath -replace '\\', '/' -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
}

$HostCwdUnix    = ConvertTo-UnixPath $HostCwd
$HostConfigUnix = ConvertTo-UnixPath $HostConfig

# --- Build run arguments ---
$RunArgs = @(
    'run', '--rm', '--interactive', '--tty',
    '--volume', "${HostCwdUnix}:/workspace:z",
    '--volume', "${HostConfigUnix}:/home/claude/.claude:z",
    '--workdir', '/workspace',
    '--security-opt', 'no-new-privileges',
    '--cap-drop', 'ALL'
)

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

& $Runtime @RunArgs
exit $LASTEXITCODE
