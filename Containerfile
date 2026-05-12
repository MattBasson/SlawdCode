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
# Optionally pin a version and verify its SHA-256 checksum at build time:
#   make build AWSCLI_VERSION=2.17.0 \
#              AWSCLI_SHA256_X86_64=<hex> \
#              AWSCLI_SHA256_AARCH64=<hex>
# https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
ARG AWSCLI_VERSION=
ARG AWSCLI_SHA256_X86_64=
ARG AWSCLI_SHA256_AARCH64=
RUN set -eux; \
    arch="$(uname -m)"; \
    if [ -n "${AWSCLI_VERSION}" ]; then \
        url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWSCLI_VERSION}.zip"; \
    else \
        url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"; \
    fi; \
    curl -fsSL "$url" -o /tmp/awscliv2.zip; \
    if [ "$arch" = "x86_64" ] && [ -n "${AWSCLI_SHA256_X86_64}" ]; then \
        echo "${AWSCLI_SHA256_X86_64}  /tmp/awscliv2.zip" | sha256sum -c -; \
    elif [ "$arch" = "aarch64" ] && [ -n "${AWSCLI_SHA256_AARCH64}" ]; then \
        echo "${AWSCLI_SHA256_AARCH64}  /tmp/awscliv2.zip" | sha256sum -c -; \
    fi; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# Security: create a non-root user to run Claude Code (login shell = bash)
RUN groupadd --system claude \
    && useradd --system --gid claude --create-home --home-dir /home/claude --shell /bin/bash claude

# Install Claude Code globally (always latest published version)
RUN npm install -g @anthropic-ai/claude-code

# Create the workspace directory that the user's project will be mounted into
RUN mkdir -p /workspace && chown claude:claude /workspace

# Drop to non-root user for all runtime operations
USER claude
WORKDIR /workspace

# Make bash the default subshell for Claude Code's Bash tool
ENV SHELL=/bin/bash

ENTRYPOINT ["claude"]
