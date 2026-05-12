# syntax=docker/dockerfile:1
# SlawdCode — secure container for Claude Code (https://github.com/MattBasson/SlawdCode)
# Compatible with Podman (rootless) and Docker.

ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-bookworm-slim

# Shell + tooling that Claude Code's in-session Bash tool relies on, plus
# everything required to install the cloud CLIs from upstream repositories.
# node:bookworm-slim is a stripped Debian base, so we re-add the standard
# CLI surface explicitly.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        less \
        openssh-client \
        ripgrep \
        tar \
        unzip; \
    install -m 0755 -d /etc/apt/keyrings; \
    rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) — installed from the official cli.github.com apt repository
# so the version stays current at build time. https://github.com/cli/cli
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# Azure CLI (az) — installed from packages.microsoft.com, the
# Microsoft-maintained apt repository for Azure CLI on Debian/Ubuntu.
# https://learn.microsoft.com/cli/azure/install-azure-cli-linux
RUN set -eux; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    chmod go+r /etc/apt/keyrings/microsoft.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" \
        > /etc/apt/sources.list.d/azure-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends azure-cli; \
    rm -rf /var/lib/apt/lists/*

# AWS CLI v2 — installed from the official self-contained zip distribution.
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# Security: create a non-root user to run Claude Code (login shell = bash)
RUN groupadd --system claude \
    && useradd --system --gid claude --create-home --home-dir /home/claude --shell /bin/bash claude

# Install Claude Code globally.
# Pin CLAUDE_CODE_VERSION at build time for reproducibility, e.g.:
#   make build CLAUDE_CODE_VERSION=1.2.3
# The default 'latest' fetches whatever is current on the registry.
# npm audit signatures verifies the package's npm provenance attestation,
# failing-closed if the tarball is unsigned, tampered, or unattested.
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm audit signatures

# Create the workspace directory that the user's project will be mounted into
RUN mkdir -p /workspace && chown claude:claude /workspace

# Drop to non-root user for all runtime operations
USER claude
WORKDIR /workspace

# Make bash the default subshell for Claude Code's Bash tool
ENV SHELL=/bin/bash

ENTRYPOINT ["claude"]
