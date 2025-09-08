export DOCKER_BUILDKIT=1

# --------------------------
# Variables
# --------------------------

ifneq (,$(wildcard .env))
	include .env
	export
endif

DOCKER_REGISTRY_HOST ?= docker.io
DOCKER_REGISTRY_USER ?= kauech
IMAGE_NAME ?= tor
VERSION ?= latest
PLATFORMS ?= linux/amd64,linux/arm64,linux/arm/v7

# --------------------------
# Colors
# --------------------------

RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

.PHONY: help build push clean setup-buildx release dev-build docker-login info

# --------------------------
# Help
# --------------------------

help: ## Show this help message
	@echo 'Docker Build & Release System'
	@echo ''
	@echo 'Usage: make [target]'
	@echo ''
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --------------------------
# Setup Buildx
# --------------------------

setup-buildx: ## Setup Docker Buildx for multi-architecture builds
	@echo "$(BLUE)[INFO]$(NC) Setting up Docker Buildx..."
	docker buildx create --name multiarch --use || true
	docker buildx inspect --bootstrap
	@echo "$(GREEN)[SUCCESS]$(NC) Docker Buildx setup complete"

# --------------------------
# Build (local, current arch)
# --------------------------

build: ## Build local image for current architecture
	@echo "$(BLUE)[INFO]$(NC) Building local image..."
	docker build -t $(DOCKER_REGISTRY_HOST)/$(DOCKER_REGISTRY_USER)/$(IMAGE_NAME):$(VERSION) .
	@echo "$(GREEN)[SUCCESS]$(NC) Local build completed"

# --------------------------
# Push (current arch)
# --------------------------

push: build ## Push image (current architecture)
	@echo "$(BLUE)[INFO]$(NC) Pushing image..."
	docker push $(DOCKER_REGISTRY_HOST)/$(DOCKER_REGISTRY_USER)/$(IMAGE_NAME):$(VERSION)
	@echo "$(GREEN)[SUCCESS]$(NC) Push completed"

# --------------------------
# Clean
# --------------------------

clean: ## Remove local image
	@echo "$(BLUE)[INFO]$(NC) Cleaning local image..."
	docker rmi $(DOCKER_REGISTRY_HOST)/$(DOCKER_REGISTRY_USER)/$(IMAGE_NAME):$(VERSION) || true
	@echo "$(GREEN)[SUCCESS]$(NC) Clean completed"

# --------------------------
# Release (multi-arch build + push)
# --------------------------
release: setup-buildx ## Full release build and push (multi-arch)
	@echo "$(BLUE)[INFO]$(NC) Building multi-arch image..."
	docker buildx build --platform $(PLATFORMS) \
		-t $(DOCKER_REGISTRY_HOST)/$(DOCKER_REGISTRY_USER)/$(IMAGE_NAME):$(VERSION) \
		--push .
	@echo "$(GREEN)[SUCCESS]$(NC) Release completed"

# --------------------------
# Info
# --------------------------
info: ## Show build information
	@echo "$(BLUE)[INFO]$(NC) Build Information:"
	@echo "  Registry: $(DOCKER_REGISTRY_HOST)/$(DOCKER_REGISTRY_USER)"
	@echo "  Image: $(IMAGE_NAME)"
	@echo "  Version: $(VERSION)"
	@echo "  Platforms: $(PLATFORMS)"
