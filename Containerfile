# syntax=docker/dockerfile:1
# SlawdCode — secure container for Claude Code (https://github.com/MattBasson/SlawdCode)
# Compatible with Podman (rootless) and Docker.

ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-alpine

# Security: create a non-root user to run Claude Code
RUN addgroup -S claude && adduser -S -G claude -h /home/claude claude

# Install Claude Code globally (always latest published version)
RUN npm install -g @anthropic-ai/claude-code

# Create the workspace directory that the user's project will be mounted into
RUN mkdir -p /workspace && chown claude:claude /workspace

# Drop to non-root user for all runtime operations
USER claude
WORKDIR /workspace

ENTRYPOINT ["claude"]
