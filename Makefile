IMAGE          ?= slawdcode:latest
RUNTIME        ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
NODE_BASE_IMAGE ?=

.PHONY: build auth install uninstall run clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the container image
	$(RUNTIME) build \
		$(if $(NODE_BASE_IMAGE),--build-arg NODE_BASE_IMAGE=$(NODE_BASE_IMAGE),) \
		-t $(IMAGE) .
	@echo ""
	@id=$$($(RUNTIME) inspect --format '{{.Id}}' $(IMAGE) 2>/dev/null); \
	 echo "Image ID:  $$id"; \
	 echo "To pin this exact build, export:"; \
	 echo "  export SLAWDCODE_IMAGE='$(IMAGE)@$$id'"

auth: ## Authenticate with Claude (one-time OAuth browser login)
	./scripts/slawdcode-auth

install: ## Install the 'claude' and 'slawdcode-auth' commands to ~/.local/bin
	./scripts/install.sh

uninstall: ## Remove the installed commands, the image, and stale auth containers
	./scripts/uninstall.sh

run: ## Open an interactive Claude Code session in the current directory
	./scripts/claude

clean: ## Remove stale auth containers and the local container image
	-$(RUNTIME) ps -aq --filter "name=slawdcode-auth-" | xargs -r $(RUNTIME) rm -f 2>/dev/null
	$(RUNTIME) rmi $(IMAGE) 2>/dev/null || true
