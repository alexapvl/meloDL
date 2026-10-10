SCHEME := meloDL
PROJECT := $(SCHEME).xcodeproj
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/$(SCHEME).app

.DEFAULT_GOAL := run
.PHONY: help run build clean

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <command>\n\n"} \
		/^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: build ## Build and launch the debug app
	@osascript -e 'tell application id "com.alexapvl.meloDL" to quit' >/dev/null 2>&1 || true
	open "$(APP)"

build: ## Build the debug app
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED)" \
		build

clean: ## Remove the local build directory
	rm -rf build
