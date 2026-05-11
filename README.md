# SlawdCode

Run [Claude Code](https://docs.anthropic.com/en/claude-code) safely and securely in a rootless container — no native Node.js install, no root access required on your machine.

Works with **Podman** (rootless by default) and **Docker**, on Linux, macOS, Windows WSL2, and Windows native (PowerShell).

---

## Prerequisites

| Platform | Requirement |
|---|---|
| Linux / WSL2 | [Podman](https://podman.io/getting-started/installation) (recommended) or Docker |
| macOS | [Podman Desktop](https://podman-desktop.io/) or [Docker Desktop](https://docs.docker.com/desktop/) |
| Windows (native) | [Podman Desktop](https://podman-desktop.io/) or [Docker Desktop](https://docs.docker.com/desktop/) |

---

## Quick Start

### Linux / macOS / WSL2

```bash
# 1. Clone and build the image
git clone https://github.com/MattBasson/SlawdCode
cd SlawdCode
make build

# 2. Install the 'claude' command to ~/.local/bin
make install
export PATH="$PATH:$HOME/.local/bin"   # add to ~/.bashrc or ~/.zshrc to make permanent

# 3. Authenticate once (browser login — no API key stored on disk)
slawdcode-auth

# 4. Verify and run Claude Code
claude --version
claude "explain this codebase"
```

### Windows (PowerShell)

```powershell
# 1. Clone and build the image
git clone https://github.com/MattBasson/SlawdCode
cd SlawdCode
.\scripts\make.ps1 build

# 2. Install the 'claude' command
.\scripts\make.ps1 install
# Then add the install dir to your PATH if prompted

# 3. Authenticate once (browser login — no API key stored on disk)
slawdcode-auth

# 4. Verify and run Claude Code
claude --version
claude "explain this codebase"
```

---

## Authentication

### Preferred: OAuth browser login (recommended)

Run once per machine. A browser window opens for you to sign in with your Anthropic account. Tokens are written to your **host machine** (`~/.claude/` and `~/.claude.json`) and re-used by every subsequent `claude` invocation — they are never baked into the container image.

```bash
# Linux / macOS / WSL2
slawdcode-auth
```

```powershell
# Windows (PowerShell) — any of these work; pick one
slawdcode-auth                    # if you ran 'make install' / .\scripts\make.ps1 install
.\scripts\make.ps1 auth           # from a fresh clone, no install required
.\scripts\slawdcode-auth.ps1      # the underlying script
```

### Fallback: API key (CI / automation)

For headless environments where browser login isn't possible:

```bash
export ANTHROPIC_API_KEY=sk-ant-your-key-here
claude --help
```

The API key is passed to the container at runtime only — it is **never** baked into the image or written to disk.

---

## How It Works

```
Your shell
  └─ claude (wrapper script)
       └─ podman run  [rootless, --cap-drop ALL, --no-new-privileges]
            └─ container  [node:bookworm-slim, non-root user 'claude']
                 └─ @anthropic-ai/claude-code
                      └─ api.anthropic.com
```

**By default, four host paths are mounted into the container:**

| Host path | Container path | Purpose |
|---|---|---|
| `$PWD` (current dir) | `/workspace` | Your project files |
| `~/.claude` | `/home/claude/.claude` | Project history, MCP server config |
| `~/.claude.json` | `/home/claude/.claude.json` | Claude Code session metadata |
| `~/.claude/.credentials.json` | `/home/claude/.claude/.credentials.json` | OAuth access / refresh tokens (mounted as a single file on top of the directory mount so it persists reliably on Windows-backed bind mounts) |

When `SLAWDCODE_PERSIST_CLOUD_CREDS=1`, three additional **opt-in** mounts are added so the bundled cloud CLIs keep their auth state across runs:

| Host path | Container path | Purpose |
|---|---|---|
| `~/.config/gh` | `/home/claude/.config/gh` | GitHub CLI auth (`gh auth login`) |
| `~/.aws` | `/home/claude/.aws` | AWS CLI credentials and config |
| `~/.azure` | `/home/claude/.azure` | Azure CLI auth (`az login`) |

Everything else on your machine is invisible to the container.

---

## Bundled Tools

The container ships with a small, opinionated set of CLIs so Claude Code's in-session Bash tool can interact with the most common developer ecosystems:

| Tool | Source | Purpose |
|---|---|---|
| `bash`, `git`, `curl`, `jq`, `less`, `tar`, `unzip`, `gnupg`, `ripgrep`, `openssh-client` | Debian apt | Standard userland Claude Code's Bash tool relies on |
| `gh` | [cli.github.com](https://github.com/cli/cli) apt repo | GitHub CLI |
| `az` | [packages.microsoft.com](https://learn.microsoft.com/cli/azure/install-azure-cli-linux) apt repo | Azure CLI |
| `aws` | [awscli.amazonaws.com](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) zip distribution | AWS CLI v2 |

**By default, credentials are NOT persisted across runs.** Because the container is started with `--rm`, anything `gh auth login` / `az login` / `aws configure` writes to `/home/claude/.config/gh`, `/home/claude/.azure`, or `/home/claude/.aws` inside the container is discarded when the session ends.

**To persist them, set `SLAWDCODE_PERSIST_CLOUD_CREDS=1`** before invoking `claude`. The wrapper will mount the matching host directories (`~/.config/gh`, `~/.aws`, `~/.azure`) into the container — creating them on the host if they don't already exist — so `gh auth login` / `az login` / `aws configure` survive across runs.

```bash
# Linux / macOS / WSL2 (bash, zsh)
export SLAWDCODE_PERSIST_CLOUD_CREDS=1     # for the current shell
claude

# To make it permanent across new shells, add the export line to one of:
#   ~/.bashrc          (bash, interactive non-login)
#   ~/.bash_profile    (bash, login)
#   ~/.zshrc           (zsh, interactive)
#   ~/.zprofile        (zsh, login — common on macOS)
```

```powershell
# Windows (PowerShell)
$env:SLAWDCODE_PERSIST_CLOUD_CREDS = '1'   # for the current session
claude

# To make it permanent for all future PowerShell sessions for your user:
[Environment]::SetEnvironmentVariable('SLAWDCODE_PERSIST_CLOUD_CREDS', '1', 'User')
```

Alternatively, for short-lived or CI sessions, pass tokens via environment variables (e.g. `GH_TOKEN`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, `AZURE_*`) using `SLAWDCODE_EXTRA_ARGS`.

---

## Updating

There are two things you might want to update: **SlawdCode itself** (this repo — wrappers, `Containerfile`, bundled tooling) and the underlying **Claude Code** package (refreshed automatically at every image build via `npm install -g @anthropic-ai/claude-code`).

### Updating SlawdCode

Pull the latest source, rebuild the image, and reinstall the wrappers:

```bash
# Linux / macOS / WSL2
cd /path/to/SlawdCode
git pull
make clean && make build      # rebuild image (also pulls the latest Claude Code from npm)
make install                  # refresh the 'claude' and 'slawdcode-auth' wrappers in ~/.local/bin
```

```powershell
# Windows (PowerShell)
cd C:\path\to\SlawdCode
git pull
.\scripts\make.ps1 clean
.\scripts\make.ps1 build
.\scripts\make.ps1 install
```

> If the rebuilt image asks you to `/login` again, Claude Code's on-disk auth layout has changed between releases. Re-run `slawdcode-auth` once to refresh the host-side `~/.claude.json` token, then `claude` will pick it up on the next run.

### Updating only Claude Code

If you don't need newer SlawdCode wrappers or `Containerfile` changes, skip the `git pull` and rebuild in place — every `make build` re-runs `npm install -g @anthropic-ai/claude-code`, which fetches the latest published version:

```bash
# Linux / macOS / WSL2
make clean && make build
```

```powershell
# Windows (PowerShell)
.\scripts\make.ps1 clean
.\scripts\make.ps1 build
```

---

## Configuration

All configuration is done via environment variables:

| Variable | Default | Description |
|---|---|---|
| `SLAWDCODE_IMAGE` | `slawdcode:latest` | Container image to use |
| `SLAWDCODE_RUNTIME` | auto-detect | `podman` or `docker` |
| `SLAWDCODE_EXTRA_ARGS` | _(empty)_ | Extra flags passed to `podman run` / `docker run` |
| `SLAWDCODE_PERSIST_CLOUD_CREDS` | _(empty)_ | Set to `1` / `true` / `yes` to mount `~/.config/gh`, `~/.aws`, and `~/.azure` so `gh`, `aws`, and `az` auth persists across runs (host dirs are auto-created) |
| `ANTHROPIC_API_KEY` | _(empty)_ | API key fallback (CI/automation only) |

### Enterprise / Proxy

Pass extra runtime flags via `SLAWDCODE_EXTRA_ARGS`:

```bash
# Corporate HTTP proxy
export SLAWDCODE_EXTRA_ARGS="--env HTTPS_PROXY=http://proxy.corp.example.com:8080"
claude --help

# Custom CA certificate
export SLAWDCODE_EXTRA_ARGS="--env NODE_EXTRA_CA_CERTS=/certs/ca.pem --volume /etc/ssl/corp-ca.pem:/certs/ca.pem:ro"
claude --help
```

**Windows (PowerShell):**

```powershell
$env:SLAWDCODE_EXTRA_ARGS = "--env HTTPS_PROXY=http://proxy.corp.example.com:8080"
claude --help
```

---

## Security Model

| Concern | Mitigation |
|---|---|
| Root access on host | Podman runs rootless by default — no root required at all |
| Root inside container | Non-root user `claude` created with `useradd --system` (system UID, no shell history, locked password) |
| Privilege escalation | `--security-opt no-new-privileges` + `--cap-drop ALL` |
| Host filesystem exposure | Only explicitly mounted volumes (`$PWD` + `~/.claude` + `~/.claude.json` by default; opt-in `~/.config/gh`, `~/.aws`, `~/.azure` when `SLAWDCODE_PERSIST_CLOUD_CREDS=1`) |
| API key on disk | OAuth preferred — tokens in `~/.claude/` and `~/.claude.json` on host, never in image |
| API key in environment | Optional fallback only; OAuth avoids env vars entirely |
| Image supply chain | Node.js Debian Bookworm-slim base + standard tooling (`bash`, `git`, `curl`, `gnupg`, `jq`, `less`, `tar`, `unzip`, `openssh-client`, `ripgrep`, `ca-certificates`) + cloud CLIs (`gh`, `az`, AWS CLI v2) installed from their official upstream repositories + npm install from official registry at build time |
| Network | Container has outbound access to api.anthropic.com (required by Claude Code) |

---

## Make Targets

### Linux / macOS / WSL2

```
make build    Build the container image
make auth     Authenticate with Claude (one-time OAuth login)
make install  Install 'claude' and 'slawdcode-auth' commands to ~/.local/bin
make run      Open an interactive Claude Code session in the current directory
make clean    Remove the local container image
make help     Show all available targets
```

### Windows (PowerShell)

PowerShell has no built-in `make`, so use the bundled wrapper which exposes the same targets:

```powershell
.\scripts\make.ps1 build     # Build the container image
.\scripts\make.ps1 auth      # Authenticate with Claude (one-time OAuth login)
.\scripts\make.ps1 install   # Install 'claude' and 'slawdcode-auth' commands
.\scripts\make.ps1 run       # Open an interactive Claude Code session in the current directory
.\scripts\make.ps1 clean     # Remove the local container image
.\scripts\make.ps1 help      # Show all available targets
```

The same `SLAWDCODE_IMAGE` and `SLAWDCODE_RUNTIME` environment variables apply.

---

## Compose (Optional)

For users who prefer compose-style invocation:

```bash
# Linux / macOS / WSL2
touch ~/.claude.json                 # one-time: ensures the bind mount has a file source
podman-compose -f compose/podman-compose.yml run --rm claude --help

# Or with Docker Compose
docker compose -f compose/podman-compose.yml run --rm claude --help
```

```powershell
# Windows (PowerShell)
if (-not (Test-Path "$HOME\.claude.json")) { New-Item -ItemType File -Path "$HOME\.claude.json" | Out-Null }
podman-compose -f compose\podman-compose.yml run --rm claude --help

# Or with Docker Compose
docker compose -f compose\podman-compose.yml run --rm claude --help
```

The `slawdcode-auth` and `claude` wrapper scripts auto-create `~/.claude.json` if it's missing, but compose does not — without the touch step the runtime will create it as a *directory* the first time and break the OAuth login flow.

---

## Troubleshooting

### Claude shows `Configuration Error / JSON Parse error: Unexpected EOF`

Claude Code parses `~/.claude.json` on startup and refuses to run if it isn't valid JSON. Older versions of the SlawdCode wrappers pre-created the file as a zero-byte placeholder for the bind mount; current Claude Code rejects that. Fix:

1. Update the wrappers (`git pull` + `make install` / `.\scripts\make.ps1 install`) — the wrappers now initialize the file with `{}`.
2. For an already-broken file, either choose **"2. Reset with default configuration"** in the in-container prompt, or run on the host: `Remove-Item $HOME\.claude.json` (PowerShell) / `rm ~/.claude.json` (bash) and re-run `slawdcode-auth`.

### Claude keeps prompting `/login` after a fresh build

Claude Code stores its OAuth access/refresh tokens in `~/.claude/.credentials.json` and broader session metadata in `~/.claude.json`. If `slawdcode-auth` writes the token but the next `claude` invocation still asks you to `/login` (especially with a "Welcome back" banner alongside the "Not logged in" status), one of these is usually wrong:

1. The image is stale and predates the wrapper's bind mounts — `make clean && make build` (or `.\scripts\make.ps1 clean ; .\scripts\make.ps1 build`) and re-run `slawdcode-auth`.
2. Either `~/.claude.json` or `~/.claude/.credentials.json` exists on the host as an empty *directory* (the runtime created it on a previous run when the file was missing) — delete both (`rm -rf ~/.claude.json ~/.claude/.credentials.json`) and re-run `slawdcode-auth`; the wrappers recreate each as a 600-perm file initialized with `{}`.

> **Windows / Podman Desktop / Docker Desktop note:** Claude Code's `auth login` writes `.credentials.json` using an atomic-rename pattern that doesn't survive a bind mount across the WSL2 → 9p → NTFS path. `slawdcode-auth` works around this by running the auth flow in a *named* container and then using `podman cp` / `docker cp` to extract the credentials file directly — which uses a different file-extraction path than bind mounts.
>
> If even the `cp` workaround fails (the wrapper prints `Warning: '<runtime> cp' did not deliver .credentials.json to the host.`), the named container is left in place so you can extract the file manually, and the OAuth flow may genuinely not be persistable on your runtime/host combo. **The most reliable workaround in that case is to skip OAuth entirely:**
>
> ```powershell
> # Windows (PowerShell) — get an API key from your Anthropic console
> $env:ANTHROPIC_API_KEY = 'sk-ant-...'
> claude
> ```
>
> ```bash
> # Linux / macOS / WSL2
> export ANTHROPIC_API_KEY='sk-ant-...'
> claude
> ```
>
> The API key is passed straight through `--env` and never written to disk by the container. For enterprise plans with "API Usage Billing" (the same plan that supports OAuth via SlawdCode), an API key from your org console is the most reliable auth path on Windows hosts.
3. **(Windows / Podman Desktop)** Your host path didn't translate correctly into the container's bind mount. Run with `SLAWDCODE_DEBUG=1` to see the resolved paths and the exact `podman run` command:

   ```powershell
   $env:SLAWDCODE_DEBUG = '1'
   slawdcode-auth     # then re-run claude with the same env var set
   ```

   The printed `HostSession` line should be `C:/Users/<you>/.claude.json` (forward slashes, drive letter preserved). The older `/c/Users/...` form was changed in this commit because Podman Desktop's WSL2 backend treats it as a Unix path under `/c` and silently mounts an empty source — make sure the version of the wrappers you installed (`~/.local/bin\claude.ps1` or wherever `make install` put them) has been refreshed since this fix landed.
4. You're invoking `podman` / `docker` directly without the SlawdCode wrappers — make sure your `run` command includes both `--volume ~/.claude:/home/claude/.claude` *and* `--volume ~/.claude.json:/home/claude/.claude.json`.

### `make.ps1 install` errors with `Cannot bind argument to parameter 'Path' because it is an empty string`

`$env:USERPROFILE` is unset or empty in your PowerShell session (some service accounts and sandboxed shells hit this). The `.ps1` scripts now fall back through `$HOME` and `[Environment]::GetFolderPath('UserProfile')`, so updating to the latest version of the repo fixes it. If you still see the error, set `$env:USERPROFILE` (or `$HOME`) explicitly before invoking the script.

### `Error: neither podman nor docker found`

The wrappers auto-detect the runtime on `PATH`. Install Podman (Linux/macOS/WSL2) or Podman Desktop / Docker Desktop (macOS/Windows) and confirm with `podman --version` or `docker --version`. If both are installed and you want to force one, set `SLAWDCODE_RUNTIME=podman` or `SLAWDCODE_RUNTIME=docker`.

### Permission denied on a mounted file

On SELinux-enforcing hosts (RHEL/Fedora/CentOS), bind mounts need the `:z` label, which the wrappers already pass. If you're running `podman` directly without the wrappers, append `:z` to your `--volume` arguments. If `~/.claude.json` on your host is owned by a different user than the one running `podman`, fix the ownership (`chown $(id -u):$(id -g) ~/.claude.json`).

### First `make build` is slow / image is large

Expected. The image bundles bash + standard userland, GitHub CLI, Azure CLI, and AWS CLI v2 from upstream-official sources, plus the latest Claude Code from npm — final image is roughly 1 GB. Rebuilds are layer-cached and much faster.

### `gh` / `aws` / `az` keep asking me to log in every session

The cloud CLIs' credentials aren't persisted by default. Set `SLAWDCODE_PERSIST_CLOUD_CREDS=1` to mount `~/.config/gh`, `~/.aws`, and `~/.azure` from the host — see [Bundled Tools](#bundled-tools) for the full setup.

---

## Windows Notes

- `scripts/make.ps1` is the PowerShell equivalent of the `Makefile` and exposes the same `build`, `auth`, `install`, `run`, `clean`, and `help` targets — Windows users do not need to install GNU make.
- The PowerShell wrapper (`scripts/claude.ps1`) automatically converts Windows paths (e.g. `C:\Users\foo\project`) to Unix-style paths (`/c/Users/foo/project`) for volume mounts.
- `.cmd` shims are installed alongside the `.ps1` scripts so `claude` and `slawdcode-auth` work from both **cmd.exe** and **PowerShell** without typing the extension.
- WSL2 users can use the bash scripts (`scripts/claude`, `scripts/slawdcode-auth`) and the `Makefile` targets directly — there is no need for the PowerShell wrappers inside WSL2.
- Ensure Podman Desktop (or Docker Desktop) is running before using the commands.
