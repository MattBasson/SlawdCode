#!/usr/bin/env bash
# SlawdCode installer — Linux / macOS / WSL2
# Usage: curl -fsSL https://raw.githubusercontent.com/MattBasson/SlawdCode/main/scripts/install.sh | bash
#    or: bash install.sh [install-dir]
set -euo pipefail

INSTALL_DIR="${1:-${HOME}/.local/bin}"
REPO_RAW="https://raw.githubusercontent.com/MattBasson/SlawdCode/main"

echo "SlawdCode Installer"
echo "==================="

# Ensure install directory exists
mkdir -p "$INSTALL_DIR"

# Download wrapper scripts
echo "Downloading scripts to $INSTALL_DIR ..."
curl -fsSL "${REPO_RAW}/scripts/claude"         -o "${INSTALL_DIR}/claude"
curl -fsSL "${REPO_RAW}/scripts/slawdcode-auth" -o "${INSTALL_DIR}/slawdcode-auth"
chmod +x "${INSTALL_DIR}/claude" "${INSTALL_DIR}/slawdcode-auth"

echo ""
echo "Installed:"
echo "  ${INSTALL_DIR}/claude           — run Claude Code in a secure container"
echo "  ${INSTALL_DIR}/slawdcode-auth   — one-time OAuth login setup"

# Check if install dir is on PATH
if ! echo "$PATH" | grep -q "${INSTALL_DIR}"; then
    echo ""
    echo "NOTE: ${INSTALL_DIR} is not in your PATH."
    echo "Add it by appending the following to your ~/.bashrc or ~/.zshrc:"
    echo ""
    echo "  export PATH=\"\$PATH:${INSTALL_DIR}\""
    echo ""
fi

echo ""
echo "Next steps:"
echo "  1. Build the container image:"
echo "       git clone https://github.com/MattBasson/SlawdCode && cd SlawdCode && make build"
echo ""
echo "  2. Authenticate once (browser login — no API key stored):"
echo "       slawdcode-auth"
echo ""
echo "  3. Start using Claude Code:"
echo "       claude --help"
