# Authentication persistence design

This document explains how SlawdCode persists Claude Code's OAuth credentials across runs, why the design is the way it is, and what to do when it breaks.

If you just want the short version, the README's [Authentication](../README.md#authentication) and [Troubleshooting](../README.md#troubleshooting) sections cover the operational view. This doc is the *why* — useful when you need to diagnose a new failure mode or evaluate whether SlawdCode is safe to use in a specific environment.

## What Claude Code writes during `auth login`

When Claude Code's `auth login` succeeds inside the container, it writes three files:

| Path inside container | Size | Contents |
|---|---|---|
| `/home/claude/.claude.json` | ~1 KB | Session metadata: user identity, organization binding, account type. |
| `/home/claude/.claude/.credentials.json` | ~400–500 B, mode `0600` | OAuth `accessToken`, `refreshToken`, `expiresAt`. The sensitive bit. |
| `/home/claude/.claude/backups/.claude.json.backup.<ts>` | ~50 B | Backup of the previous `.claude.json` Claude Code rotates these. |

For Claude Code to start as "logged in", it needs to read **both** `.claude.json` (which identifies you) and `.credentials.json` (which has the live token). If `.claude.json` is there but `.credentials.json` is missing, the welcome banner shows your name and org *and* says "Not logged in" — because Claude Code recognizes the account but has no token to call the API with.

## The Windows bind-mount problem

On rootless Podman / Docker Desktop on Windows, bind mounts go through:

```
Container view (Linux ext4-ish)
    ↕  WSL2 9p file-sharing protocol
Windows host (NTFS, accessed by the podman-machine VM)
```

Three things have to traverse that boundary reliably for the naive "bind-mount `~/.claude/` and let Claude Code write" approach to work:

1. **Writes to existing files in the mounted directory** — these work.
2. **Writes to new files in subdirectories** — these work (`backups/.claude.json.backup.*` shows up on the host).
3. **New mode-0600 files created at the root of the mount, especially via the temp-file + atomic-rename pattern Claude Code uses for `.credentials.json`** — these **don't** work. The write fails silently. No error, no partial file, no nothing — `claude auth login` happily prints `Login successful.` and the host directory simply doesn't gain the file.

We verified this experimentally: with the `~/.claude/` bind mount in place, `.credentials.json` never lands on the host. With no bind mount, the file shows up exactly where expected inside the container's overlay filesystem.

This wasn't a quick discovery — it took eight PRs in the `#15..#20` range to converge on it. See [`CONTEXT.md`](../CONTEXT.md) for the full debugging journey.

## The fix: two scripts with different mount layouts

The auth flow and the regular session flow have different needs, so SlawdCode uses different mount sets for each.

### `slawdcode-auth` — write path

```
podman run \
  --name <ephemeral-name> \                        # named, not --rm
  --volume ~/.claude.json:/home/claude/.claude.json:z \   # single-file mount only
  …                                                # NO ~/.claude/ directory mount
  slawdcode:latest auth login
```

Then, after the auth flow returns:

```
podman cp <ephemeral-name>:/home/claude/.claude/.credentials.json ~/.claude/.credentials.json
podman rm -f <ephemeral-name>
```

Three pieces are doing real work:

- **No `~/.claude/` directory mount.** Claude Code's atomic-rename write of `.credentials.json` now goes to the container's own overlay filesystem, not through the bind-mount layer. It works.
- **Single-file bind mount for `~/.claude.json`.** That one *does* work through the bind mount on Windows (it's an in-place overwrite of an existing file, not a new-file-via-rename). So in-place updates to the session-metadata file persist directly.
- **`podman cp` to extract `.credentials.json`.** `cp` reads from the container's own filesystem (the same place Claude Code wrote the file). It doesn't go through the bind-mount layer, so the Windows quirk doesn't apply. Bytes land on the host.

The script falls back through two destination path formats (`C:\...` and `C:/...`) and prints `cp`'s actual stderr on failure, so genuinely-failed extractions are debuggable. If `cp` truly can't deliver the file, the named container is left in place so the user can extract it manually, and the wrapper points at the `ANTHROPIC_API_KEY` fallback.

### `claude` — read path

```
podman run --rm \
  --volume $PWD:/workspace:z \
  --volume ~/.claude:/home/claude/.claude:z \
  --volume ~/.claude.json:/home/claude/.claude.json:z \
  --volume ~/.claude/.credentials.json:/home/claude/.claude/.credentials.json:z \
  slawdcode:latest
```

The directory mount is back here, because for normal session use we *do* want history, projects, settings, plugins, etc. to persist. Those are all writes that go through the bind mount cleanly (existing files updated in place, new files in subdirectories).

`.credentials.json` is bind-mounted as a single file on top of the directory. The Windows quirk doesn't apply to **reads** through bind mounts — only to new-file atomic-rename writes — so Claude Code can load the token slawdcode-auth extracted.

If Claude Code tries to *refresh* the access token mid-session, that write will fail silently (same root cause). In practice this matters less than it sounds: the access token typically lasts hours, and a refresh-failure during one session still leaves the existing (older) credentials file on disk for the next session. Worst case: re-run `slawdcode-auth`.

## Failure modes we encountered, and what each told us

| Symptom | What it told us | Fixed in |
|---|---|---|
| `Cannot bind argument to parameter 'Path' because it is an empty string` | `$env:USERPROFILE` is empty in some PowerShell session contexts; we needed a home-directory fallback chain. | #7 |
| `claude` prompts `/login`, `slawdcode-auth` writes nothing visible | Claude Code stores OAuth in `~/.claude.json`, not just inside `~/.claude/`. Mount the file. | #8 |
| `Configuration Error / JSON Parse error: Unexpected EOF` | Bind-mounting a zero-byte placeholder for `~/.claude.json` is rejected — Claude Code parses it as JSON on startup. Initialize as `{}`. | #16 |
| `slawdcode-auth` "succeeds", `~/.claude.json` shows 2,685 B of user identity, but `claude` still says "Not logged in" | The OAuth token is in a *different* file — `.credentials.json` — and that wasn't being mounted. | #17 |
| `.credentials.json` stays at 2 bytes on host even with a single-file bind mount | Bind mount can't carry atomic-rename writes; need to extract via `podman cp`. | #18 |
| `podman cp` fails with `no such file or directory` | With the `~/.claude/` directory mount in place, `cp` reads through the bind mount back to the empty host source. Drop the directory mount for auth. | #20 |

## What to do if it breaks again

The wrapper now prints `cp`'s real error message and leaves the named container behind on failure. That's enough information for any future regression: capture the debug output (`SLAWDCODE_DEBUG=1`) and the `podman ps -a` listing showing the leftover container, and the next failure mode is diagnosable from those alone — no guesswork, no PR-cycle thrashing.

If a new Claude Code release changes where it stores the access token, the symptoms will be identical to the early ones in the table above (welcome banner OK, "Not logged in" persists). The diagnostic from `#cp+find` would be:

```bash
podman run --rm \
  --security-opt no-new-privileges --cap-drop ALL \
  --entrypoint /bin/bash slawdcode:latest \
  -c 'touch /tmp/marker; claude auth login; find /home/claude /root /tmp /etc -newer /tmp/marker -type f 2>/dev/null'
```

That run uses no mounts, so it reveals every file Claude Code actually writes during auth.
