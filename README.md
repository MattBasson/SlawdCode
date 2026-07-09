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

Run once per machine. A browser window opens for you to sign in with your Anthropic account. Tokens are written to your **host machine** (`~/.claude.json` for session metadata, `~/.claude/.credentials.json` for the OAuth access / refresh tokens) and re-used by every subsequent `claude` invocation — they are never baked into the container image.

> **Under the hood:** `slawdcode-auth` does *not* use a bind mount for `~/.claude/.credentials.json` (Claude Code's atomic-rename write of that file doesn't survive bind mounts across the WSL2 → 9p → NTFS path on Podman/Docker Desktop). Instead the auth flow runs in a named container, lets Claude Code write the file inside the container's own filesystem, then the wrapper uses `podman cp` / `docker cp` to extract it to the host. The regular `claude` wrapper then bind-mounts that host file at startup so Claude Code can read the token. Full design in [`docs/AUTH-PERSISTENCE.md`](docs/AUTH-PERSISTENCE.md).

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

**By default, four host paths are mounted into the container by the `claude` wrapper:**

| Host path | Container path | Purpose |
|---|---|---|
| `$PWD` (current dir) | `/workspace` | Your project files |
| `~/.claude` | `/home/claude/.claude` | Project history, MCP server config, settings |
| `~/.claude.json` | `/home/claude/.claude.json` | Claude Code session metadata |
| `~/.claude/.credentials.json` | `/home/claude/.claude/.credentials.json` | OAuth access / refresh tokens (so Claude Code can read them at session start) |

> **How the OAuth token gets there:** `slawdcode-auth` uses a *different* mount layout — it runs without the `~/.claude/` directory mount because Claude Code's atomic-rename write of `.credentials.json` doesn't survive that mount on Windows. After the auth flow completes, the wrapper extracts the credentials file from the container with `podman cp` / `docker cp` and writes it to the host. The regular `claude` wrapper then bind-mounts that host file so Claude Code can read the token at startup. See [Authentication](#authentication) below and the [auth-persistence design doc](docs/AUTH-PERSISTENCE.md) for the full story.

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

> If the rebuilt image asks you to `/login` again, Claude Code's on-disk auth layout may have changed between releases. Re-run `slawdcode-auth` once to refresh the host-side credentials; see [Troubleshooting → "Claude keeps prompting /login"](#claude-keeps-prompting-login-after-slawdcode-auth) if a fresh auth still doesn't stick.

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

## Uninstalling

Uninstall is the inverse of install: it removes the `claude` and
`slawdcode-auth` wrapper scripts, the `slawdcode:latest` image, and any stale
`slawdcode-auth-*` containers.

```bash
# Linux / macOS / WSL2 — from a clone:
make uninstall

# …or standalone (no clone needed):
bash scripts/uninstall.sh
curl -fsSL https://raw.githubusercontent.com/MattBasson/SlawdCode/main/scripts/uninstall.sh | bash
```

```powershell
# Windows (PowerShell) — from a clone:
.\scripts\make.ps1 uninstall

# …or standalone:
.\scripts\uninstall.ps1
Invoke-WebRequest https://raw.githubusercontent.com/MattBasson/SlawdCode/main/scripts/uninstall.ps1 | Invoke-Expression
```

If you installed the wrappers to a non-default directory, pass it as the last
argument (e.g. `bash scripts/uninstall.sh /opt/bin` or
`.\scripts\uninstall.ps1 C:\tools\bin`).

### Keeping or removing your credentials

By default uninstall **leaves your Claude auth/config in place** —
`~/.claude/`, `~/.claude.json`, and `~/.claude/.credentials.json`. These files
are shared with a native (non-containerized) Claude Code install, so removing
them would log that out too.

To delete them as well, add the purge flag — only do this if you do **not** use
Claude Code outside of SlawdCode:

```bash
# Linux / macOS / WSL2
bash scripts/uninstall.sh --purge-credentials
```

```powershell
# Windows (PowerShell)
.\scripts\uninstall.ps1 -PurgeCredentials
```

> Uninstall does not modify your `PATH`. If you added the install dir to your
> shell profile (`~/.bashrc` / `~/.zshrc`) or User PATH during install, remove
> that entry manually — the uninstall output prints a ready-to-run command for Windows.

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

### Pinning the image to a digest

Every `make build` / `.\scripts\make.ps1 build` prints the content-addressable image ID and a ready-to-copy export line:

```text
Image ID:  sha256:abc123...
To pin this exact build, export:
  export SLAWDCODE_IMAGE='slawdcode:latest@sha256:abc123...'
```

Export that line (or set `$env:SLAWDCODE_IMAGE` on Windows) before invoking `claude`. The container runtime will refuse to start if the locally cached image no longer matches the digest — protecting against a poisoned local image cache or an unintended out-of-band update.

To look up the digest of an already-built image without rebuilding:

```bash
podman inspect --format '{{.Id}}' slawdcode:latest
```

```powershell
podman inspect --format '{{.Id}}' slawdcode:latest
```

### Pinning the base image to a digest

The `Containerfile` defaults to `node:20-bookworm-slim` — a floating tag that changes on every upstream release. For reproducible, supply-chain-safe builds, override it with a digest-pinned reference:

```bash
# 1. Look up the current digest
podman pull node:20-bookworm-slim
podman inspect --format '{{index .RepoDigests 0}}' node:20-bookworm-slim
# → node:20-bookworm-slim@sha256:abc123...

# 2. Build against that exact digest
make build NODE_BASE_IMAGE='node:20-bookworm-slim@sha256:abc123...'
```

```powershell
# Windows (PowerShell)
podman pull node:20-bookworm-slim
podman inspect --format '{{index .RepoDigests 0}}' node:20-bookworm-slim
.\scripts\make.ps1 build -BaseImage 'node:20-bookworm-slim@sha256:abc123...'
```

Passing a wrong or tampered digest fails the build immediately with a clear "manifest not found" error. Without pinning, `make build` continues to use the floating tag (current behavior).
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
make build      Build the container image
make auth       Authenticate with Claude (one-time OAuth login)
make install    Install 'claude' and 'slawdcode-auth' commands to ~/.local/bin
make uninstall  Remove the installed commands, the image, and stale auth containers
make run        Open an interactive Claude Code session in the current directory
make clean      Remove the local container image
make help       Show all available targets
```

### Windows (PowerShell)

PowerShell has no built-in `make`, so use the bundled wrapper which exposes the same targets:

```powershell
.\scripts\make.ps1 build      # Build the container image
.\scripts\make.ps1 auth       # Authenticate with Claude (one-time OAuth login)
.\scripts\make.ps1 install    # Install 'claude' and 'slawdcode-auth' commands
.\scripts\make.ps1 uninstall  # Remove the installed commands, image, and stale auth containers
.\scripts\make.ps1 run        # Open an interactive Claude Code session in the current directory
.\scripts\make.ps1 clean      # Remove the local container image
.\scripts\make.ps1 help       # Show all available targets
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

The `slawdcode-auth` and `claude` wrapper scripts auto-create `~/.claude.json` (and `~/.claude/.credentials.json`) if missing; compose does not, so the runtime will create them as *directories* on first use and break Claude Code's startup. Touch both files first.

> **Compose doesn't run the OAuth-flow workaround.** Compose just bind-mounts everything, so if you're on Windows + Podman/Docker Desktop you'll hit the same `.credentials.json` persistence problem that `slawdcode-auth` works around with `podman cp`. Either:
> - Authenticate via the bash/PowerShell `slawdcode-auth` wrapper *once* (it'll populate `~/.claude/.credentials.json` on the host), then use compose only for the regular `claude` runs, or
> - Skip OAuth and use `ANTHROPIC_API_KEY` (set it in `.env` next to the compose file, or export it in your shell before `compose run`).

---

## Troubleshooting

### Claude shows `Configuration Error / JSON Parse error: Unexpected EOF`

Claude Code parses `~/.claude.json` on startup and refuses to run if it isn't valid JSON. Older versions of the SlawdCode wrappers pre-created the file as a zero-byte placeholder for the bind mount; current Claude Code rejects that. Fix:

1. Update the wrappers (`git pull` + `make install` / `.\scripts\make.ps1 install`) — the wrappers now initialize the file with `{}`.
2. For an already-broken file, either choose **"2. Reset with default configuration"** in the in-container prompt, or run on the host: `Remove-Item $HOME\.claude.json` (PowerShell) / `rm ~/.claude.json` (bash) and re-run `slawdcode-auth`.

### Claude keeps prompting `/login` after `slawdcode-auth`

The expected flow is:
1. `slawdcode-auth` → device-code OAuth flow → `Login successful.` → host gains `~/.claude.json` (~1–3 KB) and `~/.claude/.credentials.json` (~400–500 B).
2. `claude` reads both files via bind mounts and starts up logged in.

If step 2 still says `Not logged in`, walk through these in order:

1. **Stale wrappers / image.** Pull, rebuild, reinstall:
   ```bash
   cd /path/to/SlawdCode && git pull
   make clean && make build          # or .\scripts\make.ps1 clean ; .\scripts\make.ps1 build
   make install                       # or .\scripts\make.ps1 install
   ```
   Then re-run `slawdcode-auth`.

2. **Corrupt host files.** If either host file exists as an empty *directory* (the runtime created it that way on an older wrapper version), remove and retry:
   ```bash
   rm -rf ~/.claude.json ~/.claude/.credentials.json
   slawdcode-auth
   ```

3. **Run with `SLAWDCODE_DEBUG=1`** to see the resolved paths, the runtime command, and the actual `cp` output:
   ```powershell
   $env:SLAWDCODE_DEBUG = '1' ; slawdcode-auth
   ```
   ```bash
   SLAWDCODE_DEBUG=1 slawdcode-auth
   ```
   On Windows the printed `HostSession` should be `C:/Users/<you>/.claude.json` (forward slashes, drive letter preserved). After the auth flow, both `cp` lines should report `exit 0`. If they don't, the wrapper now prints the actual error message — paste it into an issue.

4. **`cp` legitimately failed and the wrapper left the auth container around.** The warning message gives you the container name; you can extract manually:
   ```bash
   podman cp <auth-container-name>:/home/claude/.claude/.credentials.json ~/.claude/.credentials.json
   podman rm -f <auth-container-name>
   ```

5. **Last-resort: bypass OAuth entirely.** Some host/runtime combinations may not be able to persist the OAuth flow at all. For enterprise plans (the same ones SlawdCode supports for OAuth), an API key from your Anthropic console works through the same wrapper:
   ```powershell
   $env:ANTHROPIC_API_KEY = 'sk-ant-...'   # Windows (PowerShell)
   claude
   ```
   ```bash
   export ANTHROPIC_API_KEY='sk-ant-...'   # Linux / macOS / WSL2
   claude
   ```
   The key is passed via `--env`; it's never written to disk by the container.

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
- The PowerShell wrappers convert Windows paths (`C:\Users\foo\project`) to a forward-slash form with the drive letter intact (`C:/Users/foo/project`) for volume mounts. The older Git-Bash style `/c/Users/...` is **not** used — Podman Desktop's WSL2 backend treats that as a literal Unix path under `/c` and silently mounts an empty source.
- `.cmd` shims are installed alongside the `.ps1` scripts so `claude` and `slawdcode-auth` work from both **cmd.exe** and **PowerShell** without typing the extension.
- WSL2 users can use the bash scripts (`scripts/claude`, `scripts/slawdcode-auth`) and the `Makefile` targets directly — there is no need for the PowerShell wrappers inside WSL2.
- Ensure Podman Desktop (or Docker Desktop) is running before using the commands.
- The auth flow uses `podman cp` to extract `~/.claude/.credentials.json` from the container after `auth login`, working around a known WSL2 → 9p → NTFS bind-mount quirk. See [Authentication](#authentication) for details, or [`docs/AUTH-PERSISTENCE.md`](docs/AUTH-PERSISTENCE.md) for the full design.

---

## Further reading

- [`docs/AUTH-PERSISTENCE.md`](docs/AUTH-PERSISTENCE.md) — Technical deep-dive on how OAuth state is persisted across container runs, including the Windows bind-mount quirk we work around and the failure modes we've ruled out.
- [`CONTEXT.md`](CONTEXT.md) — Project context, design rationale, and the chronological debugging journey that produced the current auth flow. Read this before "fixing" something that looks weird in the wrappers — it probably *is* weird, for a documented reason.
