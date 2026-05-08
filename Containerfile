# syntax=docker/dockerfile:1
# SlawdCode — secure container for Claude Code (https://github.com/MattBasson/SlawdCode)
# Compatible with Podman (rootless) and Docker.

ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-alpine

# Shell + tooling that Claude Code's in-session Bash tool relies on.
# node:alpine ships only BusyBox ash and lacks bash, git, and a full GNU
# userland — without these the Bash tool fails to run most commands.
RUN apk add --no-cache \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        grep \
        jq \
        less \
        openssh-client \
        ripgrep \
        sed \
        tar

# Security: create a non-root user to run Claude Code (login shell = bash)
RUN addgroup -S claude && adduser -S -G claude -h /home/claude -s /bin/bash claude

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
