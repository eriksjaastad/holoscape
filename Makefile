.PHONY: build test xcode bundle clean run

# Default: build debug
build:
	swift build

# Run all unit and property tests
test:
	swift test

# Generate Xcode project with all targets and open it
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

# Clean build artifacts
clean:
	swift package clean
	rm -rf build/
	rm -rf Holoscape.xcodeproj
