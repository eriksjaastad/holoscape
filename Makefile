.PHONY: help auth-check build test test-unit test-property test-ui test-ui-fast test-ui-shard test-ui-range test-ui-failing test-ui-resume test-ui-notifications validate-tools xcode bundle clean run setup check-submodules

UI_TEST_TIMEOUT_SECONDS ?= 3600
UI_TEST_RUNNER = ./scripts/run-with-timeout.py $(UI_TEST_TIMEOUT_SECONDS)
UI_TEST_OUTPUT_VALIDATOR = ./scripts/validate-xcode-test-output.sh

help:
	@echo "Holoscape — common ops"
	@echo "  make auth-check       verify Doppler project/config visibility (DOPPLER_PROJECT_NAME/DOPPLER_CONFIG_NAME override)"
	@echo "  make build            Debug SwiftPM build"
	@echo "  make test             Unit + property tests"
	@echo "  make test-unit        Unit tests only"
	@echo "  make test-property    Property tests only"
	@echo "  make test-ui          Full sharded UI suite (Accessibility/Automation permission required)"
	@echo "  make test-ui-fast     Core UI smoke tests"
	@echo "  make test-ui-shard SHARD=3    Run one UI shard"
	@echo "  make test-ui-range RANGE=3-5  Run a UI shard range"
	@echo "  make test-ui-resume   Resume at the last failed shard"
	@echo "  make xcode            Open the checked-in Xcode project"
	@echo "  make validate-tools   Check shell syntax and bundled skin archives"
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
	./scripts/test-ui-shards.sh $(SHARD)

# Run a range of shards (usage: make test-ui-range RANGE=3-5)
test-ui-range: bundle
	./scripts/test-ui-shards.sh $(RANGE)

# Resume from last failed shard
test-ui-resume: bundle
	./scripts/test-ui-shards.sh resume

# Run only currently-failing test classes (~35 min)
test-ui-failing: bundle
	./scripts/test-ui-shards.sh failing

# Quick smoke test — core functionality (~5 min)
test-ui-fast: bundle
	@output=$$(mktemp "$${TMPDIR:-/tmp}/holoscape-ui-fast.XXXXXX"); \
	trap 'rm -f "$$output"' EXIT; \
	set -o pipefail; status=0; $(UI_TEST_RUNNER) xcodebuild test \
		-scheme Holoscape \
		-destination 'platform=macOS' \
		-skipPackagePluginValidation \
		-only-testing:HoloscapeUITests/HoloscapeUITests \
		-only-testing:HoloscapeUITests/SettingsUITests \
		-only-testing:HoloscapeUITests/TerminalDisplayUITests \
		-only-testing:HoloscapeUITests/SidebarUITests \
		-only-testing:HoloscapeUITests/KeyboardShortcutsUITests \
		2>&1 | tee "$$output" | grep -E "Test Case|Executed|TEST|error: command timed out" || status=$$?; \
	$(UI_TEST_OUTPUT_VALIDATOR) "$$output" || status=$$?; \
	exit $$status

# Run notification UI tests
test-ui-notifications: bundle
	@output=$$(mktemp "$${TMPDIR:-/tmp}/holoscape-ui-notifications.XXXXXX"); \
	trap 'rm -f "$$output"' EXIT; \
	set -o pipefail; status=0; $(UI_TEST_RUNNER) xcodebuild test \
		-scheme Holoscape \
		-destination 'platform=macOS' \
		-skipPackagePluginValidation \
		-only-testing:HoloscapeUITests/NotificationSystemUITests \
		2>&1 | tee "$$output" | grep -E "Test Case|Executed|TEST|error: command timed out" || status=$$?; \
	$(UI_TEST_OUTPUT_VALIDATOR) "$$output" || status=$$?; \
	exit $$status

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
