# SlawdCode — Development & Debugging Context

This file captures the full context of how SlawdCode was developed and debugged through an interactive session with Claude Code. It's a permanent record of:

- What the project is and the threat model it addresses
- The major design decisions, and why each one was made the way it was
- Every problem we hit, what we tried, and what finally worked
- Lessons learned, especially around container bind-mount semantics on Windows

It's intended as both onboarding for new contributors and a reference for "why on earth does the auth flow do *that*?" questions in the future.

---

## 1. What SlawdCode is

A thin wrapper that runs [Claude Code](https://docs.anthropic.com/en/claude-code) (Anthropic's official agentic CLI) inside a rootless container, so that:

- You don't need Node.js or any other runtime installed on the host beyond a container engine (Podman or Docker).
- The agent's code-execution surface is contained — by default it can only read/write the directory you `cd` into.
- Sensitive credentials live on the host (mounted in), never baked into the image.
- The image is reproducible: the same `Containerfile` produces the same tools, optionally pinned by digest.

The project intentionally chose **Podman (rootless) first, Docker as fallback** — this gives a meaningfully smaller blast radius than Docker rootful for the typical solo-developer install.

## 2. Project layout

```
SlawdCode/
├─ Containerfile               # The image — Debian Bookworm-slim + Node.js + Claude Code + dev CLIs
├─ Makefile                    # build / install / auth / run / clean / help (Linux/macOS/WSL2)
├─ compose/podman-compose.yml  # Optional compose-spec entry point
├─ scripts/
│  ├─ claude                   # bash wrapper around `podman run` — for regular sessions
│  ├─ claude.ps1               # PowerShell equivalent for Windows
│  ├─ slawdcode-auth           # bash wrapper around `claude auth login` — for the OAuth flow
│  ├─ slawdcode-auth.ps1       # PowerShell equivalent
│  ├─ install.sh / install.ps1 # Drop the wrappers into ~/.local/bin (or %USERPROFILE%\.local\bin)
│  └─ make.ps1                 # PowerShell equivalent of the Makefile
├─ .github/workflows/
│  └─ security-scan.yml        # Trivy + filesystem scan on PRs / push / weekly cron
├─ docs/
│  └─ AUTH-PERSISTENCE.md      # Deep-dive on how OAuth state is persisted (the saga; see §5 below)
├─ README.md                   # User-facing docs
└─ CONTEXT.md                  # This file
```

The wrappers exist because invoking `podman run` directly with the right flag set (mounts, capabilities, security-opts, environment) is too long and too easy to get wrong. They're thin — they don't do anything magic, they just compose the right `podman run` command and apply a few quality-of-life defaults.

## 3. Threat model and security posture

The setup assumes:

- **A developer running SlawdCode on a personal or corporate workstation.** Not multi-tenant. Not a shared server.
- **The user trusts the Claude Code package they install.** We pin it (optionally) by version and verify npm provenance signatures at build time, but the agent itself is given execution authority inside the container.
- **The user does NOT trust the agent's runtime behavior to stay inside the container's sandbox.** Container-escape exploits exist; we add defense in depth.

The hardening we apply:

| Concern | Mitigation |
|---|---|
| Root on host | Podman is rootless by default; nothing in SlawdCode requires `sudo`. |
| Root inside container | `claude` is a `useradd --system` system user, not root. |
| Privilege escalation | `--security-opt no-new-privileges`, `--cap-drop ALL`. |
| Resource exhaustion | `--pids-limit=512`, `--memory=4g` defaults; override via `SLAWDCODE_*` env vars; `--read-only` rootfs is opt-in via `SLAWDCODE_READONLY_ROOTFS=1`. |
| Filesystem exposure | Only `$PWD`, `~/.claude`, `~/.claude.json`, `~/.claude/.credentials.json` mount by default. `~/.config/gh`, `~/.aws`, `~/.azure` opt-in via `SLAWDCODE_PERSIST_CLOUD_CREDS=1`. |
| `SLAWDCODE_EXTRA_ARGS` re-arming attackers | Deny-list: `--privileged`, `--cap-add`, `--user 0/root`, `--*=host`, `--security-opt seccomp/apparmor/label disable/unconfined`. Override with `SLAWDCODE_ALLOW_UNSAFE_EXTRA_ARGS=1`. |
| TOCTOU / symlink attacks on `~/.claude.json` and `~/.claude/.credentials.json` | The wrappers refuse to operate if either path is a symlink/reparse point. |
| Image supply chain | Optional digest pinning for the base image (`NODE_BASE_IMAGE`), version pinning for Claude Code (`CLAUDE_CODE_VERSION`), and `npm audit signatures` runs at build time to verify Anthropic's provenance attestation. GPG fingerprint pinning is opt-in for the `gh` and Microsoft apt keyrings. |
| Network egress | The container has full outbound by default — this is **explicitly called out** in the README and Security Model. We don't restrict it because Claude Code itself needs network and any allow-list would be brittle. Enterprise users can plug in `SLAWDCODE_EXTRA_ARGS=--network=...` or an egress proxy. |
| CVE drift | A `security-scan.yml` GitHub Actions workflow runs Trivy on every PR / push to main / weekly cron, failing on CRITICAL/HIGH issues with fixes available. |

## 4. Major design decisions

These are the choices that, if you tried to "improve" them without understanding the context, would re-introduce problems we'd already fixed.

### 4.1 Why Debian Bookworm-slim, not Alpine

The repo started on `node:20-alpine` because it's the smallest Node.js base image. We switched in PR #5 when adding the GitHub / Azure / AWS CLIs:

- **AWS CLI v2 has no first-class Alpine/musl support.** AWS only publishes a glibc-linked binary; running it on Alpine requires either `gcompat` shims or the v1 CLI (which is on a maintenance track).
- **Azure CLI on Alpine** requires pip + Rust toolchain compilation through `cryptography`, hundreds of MB of build tooling, and is generally fragile.
- **GitHub CLI** is fine on Alpine but using the official apt repo on Debian gets us signature-verified updates with the same configuration as the other two.

Trade-off: the image grew from ~250 MB to ~1 GB. We considered this an acceptable cost — the bundled CLIs are the whole point of having a "dev environment" container, and the image is built locally so size mostly matters for first build.

### 4.2 Why we pin the Node.js base image (optionally), not by default

`FROM node:20-bookworm-slim` is a *floating tag*. Whatever the registry serves at build time gets baked in. For most users this is fine — they get security updates automatically. For enterprise/regulated environments it isn't, because:

- The build is not reproducible.
- A compromised registry mirror can substitute a different layer with no detection.

The fix (PR #11) introduced a `NODE_BASE_IMAGE` build-arg. Default is the tag; override is a digest:

```
make build NODE_BASE_IMAGE='node:20-bookworm-slim@sha256:<digest>'
```

We didn't make digest-pinning the default because:
- Most users want the latest CVE-patched base.
- Hard-coding a digest in the repo means it goes stale and the build starts failing for everyone until someone bumps it.
- Users who *want* the rigour can take the documented two-step (look up, pin) — and they should, because it commits them to a CVE-monitoring policy.

The same logic applies to `CLAUDE_CODE_VERSION` (PR #12) — default `latest`, optionally pin.

### 4.3 Why `SLAWDCODE_EXTRA_ARGS` is deny-listed, not allow-listed

`SLAWDCODE_EXTRA_ARGS` is forwarded verbatim to `podman run`. A user setting `--privileged` or `--cap-add=SYS_ADMIN` or `--user 0` would silently undo everything else the wrapper does. We considered:

- **Allow-listing safe flags** (e.g. `--env`, `--volume`, `--label`). Too restrictive — users need to pass things we can't anticipate (proxy settings, custom CA bundles, network names, etc.).
- **Just trusting the user.** Loud failure mode if they typo or someone tampers with their shell rc.
- **Deny-listing the bad flags** (PR #13). Catches the worst, lets through everything else, and provides `SLAWDCODE_ALLOW_UNSAFE_EXTRA_ARGS=1` as the explicit escape hatch.

We landed on deny-listing. It's not perfect — a determined attacker can find ways to undo hardening — but it stops accidental damage and forces deliberate intent.

### 4.4 Why we mount `~/.claude.json` as a separate single-file bind, not just `~/.claude/`

Discovered in PR #8: Claude Code stores some session state in `~/.claude.json` (a sibling *file* of the `~/.claude/` directory, not inside it). The first version of SlawdCode only mounted the directory, so the session-state file never reached the host. After a successful auth, the file existed inside the `--rm` container and was lost on exit.

Fixing this required either:
- Mounting `~/` (too much exposure)
- Bind-mounting `~/.claude.json` as a single file (right answer)

Single-file bind mounts have a quirk: the source must exist on the host before `podman run`. The wrappers handle this by `touch`ing the file (and initializing it with `{}` since Claude Code parses it as JSON on startup — see PR #16).

### 4.5 Why the auth flow is split out into `slawdcode-auth` and uses `podman cp` instead of bind mounts

This is the big one. It took **eight PRs** (#15 through #20) to converge on the right design. The short version:

Claude Code writes its OAuth tokens to `~/.claude/.credentials.json` using a **temp-file + atomic-rename** pattern. On rootless Podman/Docker Desktop on Windows, that rename does not survive the WSL2 → 9p → NTFS bind-mount layer. The write *appears* to succeed (no error, `Login successful.` prints), but the host never sees the file. Neither a directory bind mount nor a single-file bind mount fixes it — both are still going through the same translation layer.

The solution is to bypass the bind mount entirely for the auth flow:

1. `slawdcode-auth` runs `claude auth login` in a **named** container (not `--rm`).
2. It bind-mounts `~/.claude.json` only — the `~/.claude/` directory is NOT mounted, so Claude Code's writes inside `~/.claude/` (including `.credentials.json`) go to the container's own overlay filesystem.
3. After auth completes, `podman cp <container>:/home/claude/.claude/.credentials.json ~/.claude/.credentials.json` extracts the file via the runtime's own file-extraction path. This isn't subject to the bind-mount quirk.
4. The named container is removed.

The regular `claude` wrapper is unchanged — it bind-mounts the directory as normal, because for *reading* the credentials file (which is what every subsequent session does) the bind mount works fine. The atomic-rename quirk is specifically about new-file-via-rename *writes*.

See [`docs/AUTH-PERSISTENCE.md`](docs/AUTH-PERSISTENCE.md) for the full technical write-up, including the failure modes we ruled out along the way and the diagnostic that revealed the root cause.

## 5. The auth-persistence saga, condensed

For posterity, the chronological story of how we got to the working auth flow:

| PR | Hypothesis | Result |
|---|---|---|
| #2 | The Alpine image doesn't have `bash` or full GNU userland. | Fixed: added the missing tools. |
| #5 | `node:alpine` doesn't support AWS CLI v2 properly. | Fixed: switched to `node:20-bookworm-slim`. |
| #7 | `.ps1` scripts crash with empty `$env:USERPROFILE`. | Fixed: added `Get-UserHome` fallback chain. |
| #8 | `slawdcode-auth` succeeds but `claude` prompts `/login`. Claude Code stores auth state in `~/.claude.json` (sibling file), not inside `~/.claude/`. | Mounted the file. Looked fixed. |
| #15 | After a rebuild it broke again on Windows. Hypothesis: PowerShell `ConvertTo-UnixPath` produces `/c/Users/...` which Podman Desktop misinterprets. | Fixed the path conversion to `C:/Users/...`. Auth ran further but still didn't stick. |
| #16 | The wrapper pre-creates `.claude.json` as a zero-byte file; current Claude Code parses it as JSON and rejects it with "Unexpected EOF". | Initialized with `{}`. Auth flow ran clean, *still* prompted `/login`. |
| #17 | The OAuth tokens live in `~/.claude/.credentials.json`, which is inside the mounted directory but never reaches the host. Single-file bind mount it. | Bind-mounted the credentials file. Still 2 bytes (`{}`) on host after auth. |
| #18 | The bind mount doesn't carry the write at all on Windows (atomic-rename quirk). Run `claude auth login` in a named container and `podman cp` the file out. | `cp` failed: `no such file or directory`. |
| #19 | Add stderr capture + retry path formats + recovery options to surface what `cp` was actually complaining about. | Revealed the real error: `cp` looks through the directory bind mount back at the empty host source. |
| #20 | **Drop the `~/.claude/` directory mount from `slawdcode-auth`.** Let Claude Code write to the container's own filesystem, then `cp` extracts it. | ✓ Works. `.credentials.json` arrives on host. `claude` no longer prompts `/login`. |

Lessons that were either non-obvious or that we'd want to re-learn quickly:

1. **Container bind mounts on Windows have asymmetric semantics**: reads, updates-in-place, and new files in subdirectories work; new-file-via-atomic-rename at the root of a directory mount does not.
2. **`podman cp` reads through bind mounts** if they cover the source path, which means it can return "not found" even when the file objectively exists in the container's intent. This is the trickiest part because there's no error message that points at it.
3. **`SLAWDCODE_DEBUG=1` should print everything**, including the actual stderr of any sub-tool the wrapper runs. Most of the iteration cost in the saga above was caused by `2>$null` suppressing the actual error.
4. **When a write "succeeds" but the file isn't where you expect**, run the same operation with no mounts and see where the file actually lands. That single diagnostic (`touch /tmp/marker; <op>; find / -newer /tmp/marker`) is the highest-information-density tool for these problems.

## 6. Other notable decisions

### 6.1 Opt-in mounts for cloud-CLI credentials (`SLAWDCODE_PERSIST_CLOUD_CREDS=1`)

The container ships `gh`, `aws`, and `az`. By default these don't have access to your host credentials. Setting `SLAWDCODE_PERSIST_CLOUD_CREDS=1` mounts `~/.config/gh`, `~/.aws`, and `~/.azure` into the container so authentication state persists.

This is a meaningful security trade-off: it gives the agent (and anything it executes) the same authority as you on those cloud accounts. The README explicitly warns about this, recommends short-lived credentials (AWS SSO, GH fine-grained PATs, Azure scoped service principals), and advises disabling persistence for untrusted projects.

### 6.2 Installer prefers local checkout over downloading from `main`

`scripts/install.sh` and `install.ps1` used to always download from `raw.githubusercontent.com/MattBasson/SlawdCode/main`. PR #14 changed both to detect a local checkout (sibling `claude` / `slawdcode-auth` files next to the installer) and copy from there. Fixes the surprising case where `make install` from a feature branch would silently install `main`'s wrappers.

Also added `SLAWDCODE_REF` for users who run the curl-pipe-install form and want to pin a specific tag/commit.

### 6.3 No bundled `~/.claude/.credentials.json` extraction in the regular `claude` wrapper

The regular `claude` wrapper bind-mounts `~/.claude/.credentials.json` (works for *reads*) but does **not** do the `podman cp` extraction after every session. We considered this — Claude Code does refresh tokens during long sessions, and those refreshes hit the same atomic-rename quirk on Windows, so they don't persist back to the host.

We decided not to:

- It would require named (non-`--rm`) containers for every session, complicating cleanup and lifecycle.
- Most `claude` sessions are well within an access token's lifetime.
- If refresh fails and the token expires, the user re-runs `slawdcode-auth`. Not great UX, but rare in practice, and avoids architectural complexity for an edge case.

If this turns out to bite users in practice, the followup is a tidy job: rework the `claude` wrapper to use named containers + post-session `cp` of the credentials file, with the same `try`/`finally` cleanup pattern as `slawdcode-auth`.

## 7. Pointers for future work

- **`docs/AUTH-PERSISTENCE.md`** — the technical reference for the auth flow. If a Claude Code release changes where the credentials live, that's the doc to update first.
- **`scripts/slawdcode-auth` / `scripts/slawdcode-auth.ps1`** — the auth flow's wrapper. The named-container + `cp` pattern lives here. Both scripts are kept in tight parity (bash and PowerShell branches of the same logic).
- **`scripts/claude` / `scripts/claude.ps1`** — the regular session wrapper. Bind mounts only; no `cp`. Reasonably stable; the recent churn has been around mount layouts, not core logic.
- **`Containerfile`** — image build. Mostly stable; biggest open question is whether to default-pin the base image and Claude Code version (currently both float; users opt into pinning).
- **`.github/workflows/security-scan.yml`** — Trivy CVE scan on every PR and weekly cron. If a base-image CVE shows up here, the workflow is to either (a) bump the digest pin if used, or (b) wait for the upstream slim image to be rebuilt and rebuild ours.

If the auth flow regresses again, the diagnostic recipe is:

```bash
# Reproduce inside an unmounted container and see where Claude Code actually writes
podman run --rm -it \
  --security-opt no-new-privileges --cap-drop ALL \
  --entrypoint /bin/bash slawdcode:latest \
  -c 'touch /tmp/marker; claude auth login; find /home/claude /root /tmp /etc -newer /tmp/marker -type f 2>/dev/null'
```

That run uses no mounts and reveals every file Claude Code touches during auth — the foundation for figuring out what mount or extraction strategy to use next.
