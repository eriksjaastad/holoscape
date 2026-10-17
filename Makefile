.PHONY: help auth-check build test test-unit test-property test-ui test-ui-fast test-ui-shard test-ui-range test-ui-failing test-ui-resume test-ui-notifications validate-tools xcode bundle clean run setup check-submodules

help:
	@echo "Holoscape — common ops"
	@echo "  make auth-check       verify Doppler project/config visibility (DOPPLER_PROJECT_NAME/DOPPLER_CONFIG_NAME override)"
	@echo "  make build            Debug SwiftPM build"
	@echo "  make test             Unit + property tests"
	@echo "  make test-unit        Unit tests only"
	@echo "  make test-property    Property tests only"
	@echo "  make test-ui          Full sharded UI suite (Accessibility/Automation permission required)"
	@echo "  make test-ui-fast     Core UI smoke tests"
	@echo "  make test-ui-notifications  Notification UI tests"
	@echo "  make test-ui-shard SHARD=3    Run one UI shard"
	@echo "  make test-ui-range RANGE=3-5  Run a UI shard range"
	@echo "  make test-ui-failing FAILING_RESULTS=path  Run classes failed in an xcodebuild log"
	@echo "  make test-ui-resume   Resume at the last failed shard"
	@echo "  make test-class CLASS=Name    Run one Swift test class"
	@echo "  make xcode            Open the checked-in Xcode project"
	@echo "  make validate-tools   Check scripts, skin archives, and Xcode tooling"
	@echo "  make bundle           Build debug .app bundle"
	@echo "  make run              Build and open debug .app bundle"
	@echo "  make setup            Install Claude Code MCP/hooks integration"

auth-check:
	@./scripts/doppler-auth-check.sh

check-submodules:
	@./scripts/check-submodules.sh

# Default: build debug
build: check-submodules
	swift build

# Run all unit and property tests
test: check-submodules
	swift test

# Run only unit tests
test-unit: check-submodules
	swift test --filter HoloscapeTests

# Run only property-based tests
test-property: check-submodules
	swift test --filter HoloscapePropertyTests

# Validate scripts and generated skin archives without modifying them
validate-tools:
	@./scripts/validate-tools.sh
	@./scripts/test-package-tools.sh
	@./scripts/test-xcode-tools.sh

# Run all UI tests via shards with per-shard reporting (~5 hrs)
test-ui: bundle
	./scripts/test-ui-shards.sh all

# Run a single shard (usage: make test-ui-shard SHARD=3)
test-ui-shard: bundle
	./scripts/test-ui-shards.sh "$(SHARD)"

# Run a range of shards (usage: make test-ui-range RANGE=3-5)
test-ui-range: bundle
	./scripts/test-ui-shards.sh "$(RANGE)"

# Resume from last failed shard
test-ui-resume: bundle
	./scripts/test-ui-shards.sh resume

# Run classes failed in a prior xcodebuild log (~35 min)
test-ui-failing: bundle
	HOLOSCAPE_UI_FAILING_RESULTS_FILE="$(FAILING_RESULTS)" ./scripts/test-ui-shards.sh failing

# Quick smoke test — core functionality (~5 min)
test-ui-fast: bundle
	./scripts/test-ui-shards.sh fast

# Run notification UI tests
test-ui-notifications: bundle
	./scripts/test-ui-shards.sh notifications

# Run a specific test class (usage: make test-class CLASS=CommandHistoryTests)
test-class:
	swift test --filter $(CLASS)

# Open the authoritative checked-in Xcode project
xcode: check-submodules
	open Holoscape.xcodeproj

# Build and assemble .app bundle
bundle: check-submodules
	./bundle.sh

bundle-release:
	./bundle.sh release

# Open the built .app
run: bundle
	open build/Holoscape.app

# Set up Claude Code integration (MCP server, hooks, notifications)
setup:
	bash scripts/setup.sh

# Clean build artifacts
clean:
	swift package clean
	rm -rf build/
