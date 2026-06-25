#!/usr/bin/env bash
# SlawdCode uninstaller — Linux / macOS / WSL2
# Usage: curl -fsSL https://raw.githubusercontent.com/MattBasson/SlawdCode/main/scripts/uninstall.sh | bash
#    or: bash uninstall.sh [--purge-credentials] [--keep-image] [install-dir]
#
# Removes (the inverse of install.sh + make clean):
#   - the 'claude' and 'slawdcode-auth' wrapper scripts from the install dir
#   - the slawdcode container image
#   - stale 'slawdcode-auth-*' containers
#
# By default the shared Claude auth/config (~/.claude, ~/.claude.json) is LEFT
# IN PLACE — those files are also used by a native (non-containerized) Claude
# Code install. Pass --purge-credentials to delete them too.
set -euo pipefail

PURGE_CREDS=0
KEEP_IMAGE=0
INSTALL_DIR=""

usage() {
    cat <<'EOF'
SlawdCode uninstaller

Usage: bash uninstall.sh [options] [install-dir]

Options:
  --purge-credentials, --purge  Also delete ~/.claude, ~/.claude.json and the
                                OAuth credentials. WARNING: these are shared
                                with any native Claude Code install.
  --keep-image                  Do not remove the container image or stale
                                auth containers (only remove the wrappers).
  -h, --help                    Show this help.

install-dir defaults to ~/.local/bin (matching install.sh).
EOF
}

# Parse flags first; the remaining positional argument is the install dir.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge-credentials|--purge) PURGE_CREDS=1 ;;
        --keep-image)                KEEP_IMAGE=1 ;;
        -h|--help)                   usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
        *)
            if [ -z "$INSTALL_DIR" ]; then
                INSTALL_DIR="$1"
            else
                echo "Error: unexpected argument '$1'" >&2; exit 1
            fi
            ;;
    esac
    shift
done
# Any remaining args after '--'
if [ "$#" -gt 0 ] && [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="$1"
fi
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"

IMAGE="${SLAWDCODE_IMAGE:-slawdcode:latest}"

echo "SlawdCode Uninstaller"
echo "====================="

# --- Remove wrapper scripts ---
removed_any=0
for script in claude slawdcode-auth; do
    target="${INSTALL_DIR}/${script}"
    if [ -e "$target" ]; then
        rm -f "$target"
        echo "Removed ${target}"
        removed_any=1
    fi
done
if [ "$removed_any" -eq 0 ]; then
    echo "No wrapper scripts found in ${INSTALL_DIR} (nothing to remove there)."
fi

# --- Remove image + stale auth containers ---
if [ "$KEEP_IMAGE" -eq 0 ]; then
    # Auto-detect container runtime (prefer podman for rootless operation).
    RUNTIME="${SLAWDCODE_RUNTIME:-}"
    if [ -z "$RUNTIME" ]; then
        if command -v podman &>/dev/null; then
            RUNTIME="podman"
        elif command -v docker &>/dev/null; then
            RUNTIME="docker"
        fi
    fi

    if [ -z "$RUNTIME" ]; then
        echo ""
        echo "NOTE: neither podman nor docker found — skipping image/container removal."
        echo "      If you build the image later, remove it with: <runtime> rmi ${IMAGE}"
    else
        # Remove stale auth containers (same filter as the Makefile 'clean' target).
        stale=$("$RUNTIME" ps -aq --filter "name=slawdcode-auth-" 2>/dev/null || true)
        if [ -n "$stale" ]; then
            echo "Removing stale auth containers..."
            # shellcheck disable=SC2086
            "$RUNTIME" rm -f $stale >/dev/null 2>&1 || true
        fi

        # Remove the image (ignore "no such image").
        if "$RUNTIME" rmi "$IMAGE" >/dev/null 2>&1; then
            echo "Removed image ${IMAGE}"
        else
            echo "Image ${IMAGE} not present (nothing to remove)."
        fi
    fi
fi

# --- Shared credentials ---
HOST_CONFIG="${HOME}/.claude"
HOST_SESSION="${HOME}/.claude.json"
if [ "$PURGE_CREDS" -eq 1 ]; then
    echo ""
    echo "WARNING: removing shared Claude auth/config:"
    echo "  ${HOST_CONFIG}"
    echo "  ${HOST_SESSION}"
    echo "These files are also used by a native (non-containerized) Claude Code"
    echo "install. Removing them will log that out too."
    rm -rf "$HOST_CONFIG"
    rm -f  "$HOST_SESSION"
    echo "Removed shared credentials."
else
    echo ""
    echo "Left shared Claude auth/config in place:"
    echo "  ${HOST_CONFIG}"
    echo "  ${HOST_SESSION}"
    echo "(These are shared with any native Claude Code install. To remove them"
    echo " too, re-run with --purge-credentials.)"
fi

# --- PATH note ---
echo ""
echo "Done. If you added ${INSTALL_DIR} to your PATH (e.g. in ~/.bashrc or"
echo "~/.zshrc) during install, you can remove that line manually."
