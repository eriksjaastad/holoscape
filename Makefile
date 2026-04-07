.PHONY: build test test-unit test-property test-ui xcode bundle clean run setup

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

# Run UI tests (requires Xcode and built .app bundle)
test-ui: bundle
	xcodebuild test \
		-scheme Holoscape \
		-destination 'platform=macOS' \
		-only-testing:HoloscapeUITests \
		2>&1 | tail -40

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
