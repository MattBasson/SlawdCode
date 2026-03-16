IMAGE   ?= slawdcode:latest
RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

.PHONY: build auth install run clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the container image
	$(RUNTIME) build -t $(IMAGE) .

auth: ## Authenticate with Claude (one-time OAuth browser login)
	./scripts/slawdcode-auth

install: ## Install the 'claude' and 'slawdcode-auth' commands to ~/.local/bin
	./scripts/install.sh

run: ## Open an interactive Claude Code session in the current directory
	./scripts/claude

clean: ## Remove the local container image
	$(RUNTIME) rmi $(IMAGE) 2>/dev/null || true
