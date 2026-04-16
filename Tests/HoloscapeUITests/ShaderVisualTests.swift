import XCTest

/// Visual screenshot tests for the shader pipeline.
/// Takes actual screenshots and samples pixel rows to verify the shader
/// is producing visible effects — not just "trust me bro."
@MainActor
final class ShaderVisualTests: HoloscapeUITestCase {

    override func configureAppForLaunch(_ app: XCUIApplication) {
        // Launch with scanlines shader active
        app.launchArguments += ["--shader", "demos/scanlines.glsl"]
    }

    func testScanlinesVisibleInScreenshot() throws {
        // Wait for terminal to render some content
        let shell = defaultShellSidebarEntry()
        XCTAssertTrue(shell.waitForExistence(timeout: 5), "Default shell should exist")

        // Send a command to fill the terminal with visible text
        try apiSendInput(label: shell.identifier.replacingOccurrences(of: "sidebar-", with: ""), text: "echo 'SHADER_TEST_FILL'; printf '=%.0s' {1..80}; echo\n")
        sleep(2)

        // Take screenshot
        let screenshot = app.windows["Holoscape"].screenshot()
        let image = screenshot.image

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not get CGImage from screenshot")
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 100, height > 100 else {
            XCTFail("Screenshot too small: \(width)x\(height)")
            return
        }

        // Read pixel data
        guard let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let bytes = CFDataGetBytePtr(pixelData) else {
            XCTFail("Could not access pixel data")
            return
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        // Sample a vertical strip in the terminal area (right half of window, avoiding sidebar)
        let sampleX = width * 3 / 4  // 75% from left — solidly in terminal area
        var brightnessValues: [Int] = []

        // Sample the middle 60% of height (avoid title bar and tab bar)
        let startY = height / 5
        let endY = height * 4 / 5

        for y in startY..<endY {
            let offset = y * bytesPerRow + sampleX * bytesPerPixel
            let r = Int(bytes[offset])
            let g = Int(bytes[offset + 1])
            let b = Int(bytes[offset + 2])
            let brightness = (r + g + b) / 3
            brightnessValues.append(brightness)
        }

        // Analyze: with scanlines, we should see alternating bright/dark rows.
        // Count transitions between "bright" and "dark" rows.
        // Without scanlines (identity or no shader), brightness is mostly uniform.
        var transitions = 0
        let threshold = 15  // minimum brightness difference to count as a transition
        for i in 1..<brightnessValues.count {
            let diff = abs(brightnessValues[i] - brightnessValues[i - 1])
            if diff > threshold {
                transitions += 1
            }
        }

        let rowCount = endY - startY
        print("=== Screenshot analysis ===")
        print("Image: \(width)x\(height), sampled \(rowCount) rows at x=\(sampleX)")
        print("Brightness range: \(brightnessValues.min() ?? 0) - \(brightnessValues.max() ?? 0)")
        print("Transitions (threshold=\(threshold)): \(transitions)")

        // Scanlines at every 3rd row on a ~900px terminal should produce hundreds of transitions.
        // A uniform (no-shader) image produces near-zero transitions in the terminal background area.
        XCTAssertGreaterThan(transitions, 50,
            "Scanlines should produce many brightness transitions (\(transitions) found). " +
            "If this is < 50, the shader is not visually affecting the rendered output.")

        // Also verify we're not just seeing noise — there should be a real brightness spread
        let minBrightness = brightnessValues.min() ?? 0
        let maxBrightness = brightnessValues.max() ?? 0
        let spread = maxBrightness - minBrightness
        print("Brightness spread: \(spread)")

        XCTAssertGreaterThan(spread, 20,
            "Scanlines should create visible brightness variation (spread=\(spread))")
    }

    func testIdentityShaderMatchesNoShader() throws {
        // This test takes screenshots with identity shader and compares
        // to the same area — the transition count should be LOW (no scanlines).
        // Serves as a control to validate the scanlines test isn't a false positive.

        // Note: this test launches with scanlines (from configureAppForLaunch).
        // Switch to identity via settings.
        openSettings()
        let shaderPopup = app.windows["Appearance Settings"].popUpButtons["shader-popup"]
        XCTAssertTrue(shaderPopup.waitForExistence(timeout: 3), "Shader popup should exist")

        shaderPopup.click()
        let identityItem = app.menuItems["Identity"]
        XCTAssertTrue(identityItem.waitForExistence(timeout: 2))
        identityItem.click()
        closeSettings()

        sleep(2)

        let screenshot = app.windows["Holoscape"].screenshot()
        let image = screenshot.image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not get CGImage"); return
        }

        let width = cgImage.width
        let height = cgImage.height
        guard let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let bytes = CFDataGetBytePtr(pixelData) else {
            XCTFail("Could not access pixel data"); return
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        let sampleX = width * 3 / 4

        // Sample the terminal background area (bottom half, likely empty dark rows)
        let startY = height / 2
        let endY = height * 4 / 5
        var transitions = 0

        for y in (startY + 1)..<endY {
            let offset1 = (y - 1) * bytesPerRow + sampleX * bytesPerPixel
            let offset2 = y * bytesPerRow + sampleX * bytesPerPixel
            let b1 = (Int(bytes[offset1]) + Int(bytes[offset1 + 1]) + Int(bytes[offset1 + 2])) / 3
            let b2 = (Int(bytes[offset2]) + Int(bytes[offset2 + 1]) + Int(bytes[offset2 + 2])) / 3
            if abs(b1 - b2) > 15 { transitions += 1 }
        }

        print("=== Identity shader transitions: \(transitions) (should be low) ===")

        // Identity shader should have very few transitions in the background area
        // (just noise from text edges, not from scanline patterns)
        XCTAssertLessThan(transitions, 50,
            "Identity shader should NOT produce scanline-like transitions (\(transitions) found)")
    }
}
