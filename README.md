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

# 4. Run Claude Code
claude --help
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

# 4. Run Claude Code
claude --help
claude "explain this codebase"
```

---

## Authentication

### Preferred: OAuth browser login (recommended)

Run once — a browser window opens for you to sign in with your Anthropic account. Credentials are stored in `~/.claude/` on your **host machine**, never inside the container image.

```bash
# Linux / macOS / WSL2
slawdcode-auth

# Windows (PowerShell)
slawdcode-auth                    # if installed, or:
.\scripts\make.ps1 auth           # via the make wrapper, or:
.\scripts\slawdcode-auth.ps1      # direct script
```

After this, every `claude` invocation automatically uses your stored credentials.

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

**Only two host directories are ever mounted into the container:**

| Host path | Container path | Purpose |
|---|---|---|
| `$PWD` (current dir) | `/workspace` | Your project files |
| `~/.claude` | `/home/claude/.claude` | Config + OAuth credentials |

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

> **Credentials are NOT persisted across runs.** Because the container is started with `--rm`, anything `gh auth login` / `az login` / `aws configure` writes to `/home/claude/.config/gh`, `/home/claude/.azure`, or `/home/claude/.aws` inside the container is discarded when the session ends. The host directories are not currently mounted; for short-lived sessions, set the matching environment variables instead (e.g. `GH_TOKEN`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, `AZURE_*`) via `SLAWDCODE_EXTRA_ARGS`.

---

## Updating Claude Code

The container always installs the latest published version of `@anthropic-ai/claude-code` at **build time**. To get a newer version, rebuild the image:

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
| Root inside container | Non-root user `claude` created with `adduser -S` |
| Privilege escalation | `--security-opt no-new-privileges` + `--cap-drop ALL` |
| Host filesystem exposure | Only explicitly mounted volumes (`$PWD` + `~/.claude`) |
| API key on disk | OAuth preferred — tokens in `~/.claude/` on host, never in image |
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
podman-compose -f compose/podman-compose.yml run --rm claude --help

# Or with Docker Compose
docker compose -f compose/podman-compose.yml run --rm claude --help
```

```powershell
# Windows (PowerShell)
podman-compose -f compose\podman-compose.yml run --rm claude --help

# Or with Docker Compose
docker compose -f compose\podman-compose.yml run --rm claude --help
```

---

## Windows Notes

- `scripts/make.ps1` is the PowerShell equivalent of the `Makefile` and exposes the same `build`, `auth`, `install`, `run`, `clean`, and `help` targets — Windows users do not need to install GNU make.
- The PowerShell wrapper (`scripts/claude.ps1`) automatically converts Windows paths (e.g. `C:\Users\foo\project`) to Unix-style paths (`/c/Users/foo/project`) for volume mounts.
- `.cmd` shims are installed alongside the `.ps1` scripts so `claude` and `slawdcode-auth` work from both **cmd.exe** and **PowerShell** without typing the extension.
- WSL2 users can use the bash scripts (`scripts/claude`, `scripts/slawdcode-auth`) and the `Makefile` targets directly — there is no need for the PowerShell wrappers inside WSL2.
- Ensure Podman Desktop (or Docker Desktop) is running before using the commands.
