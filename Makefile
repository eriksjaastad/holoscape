.PHONY: build test test-unit test-property test-ui test-ui-fast test-ui-shard test-ui-failing test-ui-resume xcode bundle clean run setup

# Default: build debug
build:
	swift build

# Run all unit and property tests
test:
	swift test

# Run only unit tests
test-unit:
	swift test --filter HoloscapeTests

# Run only property-based tests
test-property:
	swift test --filter HoloscapePropertyTests

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
	xcodebuild test \
		-scheme Holoscape \
		-destination 'platform=macOS' \
		-only-testing:HoloscapeUITests/HoloscapeUITests \
		-only-testing:HoloscapeUITests/SettingsUITests \
		-only-testing:HoloscapeUITests/SearchBarUITests \
		-only-testing:HoloscapeUITests/SidebarUITests \
		-only-testing:HoloscapeUITests/KeyboardShortcutsUITests \
		2>&1 | grep -E "Test Case|Executed|TEST"

# Run notification UI tests
test-ui-notifications: bundle
	xcodebuild test \
		-scheme Holoscape \
		-destination 'platform=macOS' \
		-only-testing:HoloscapeUITests/NotificationSystemUITests \
		2>&1 | grep -E "Test Case|Executed|TEST"

# Run a specific test class (usage: make test-class CLASS=CommandHistoryTests)
test-class:
	swift test --filter $(CLASS)

# Generate Xcode project and open it
xcode:
	swift package generate-xcodeproj
	@echo ""
	@echo "Xcode project generated. Opening..."
	@echo "NOTE: After opening, manually add the UI test target:"
	@echo "  1. File > New > Target > UI Testing Bundle"
	@echo "  2. Drag Tests/HoloscapeUITests/HoloscapeUITests.swift into it"
	@echo "  3. Set the target application to Holoscape"
	@echo ""
	open Holoscape.xcodeproj

# Build and assemble .app bundle
bundle:
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
	rm -rf Holoscape.xcodeproj
