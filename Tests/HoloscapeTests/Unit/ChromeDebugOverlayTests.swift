import XCTest
import AppKit
@testable import Holoscape

/// Chrome v4 Task 37.1 — ChromeDebugOverlay invariants.
///
/// Pins the env-flag gate + non-interactive contract. Visual
/// output is unit-untestable here (would need a snapshot testing
/// framework + Mac Mini rendering), so we cover:
/// - `isEnabled` respects `HOLOSCAPE_PNG_CHROME_DEBUG`
/// - Flipped isTrue (chrome-image coord convention)
/// - `hitTest` returns nil (non-interactive)
/// - `refresh(phaseSeconds:)` invalidates display
@MainActor
final class ChromeDebugOverlayTests: XCTestCase {

    private func makeChrome() -> ChromeDescriptor {
        ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 1000, height: 700,
            interiorRect: SkinRect(x: 40, y: 60, width: 920, height: 600)
        )
    }

    private func makeFixtureImage() -> CGImage {
        let w = 32, h = 32
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xFF; pixels[i + 1] = 0x44; pixels[i + 2] = 0xCC; pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    // MARK: - Env flag

    func testIsEnabledOnlyWhenEnvFlagIsOne() {
        let previous = ProcessInfo.processInfo.environment["HOLOSCAPE_PNG_CHROME_DEBUG"]
        defer {
            if let previous {
                setenv("HOLOSCAPE_PNG_CHROME_DEBUG", previous, 1)
            } else {
                unsetenv("HOLOSCAPE_PNG_CHROME_DEBUG")
            }
        }

        unsetenv("HOLOSCAPE_PNG_CHROME_DEBUG")
        XCTAssertFalse(ChromeDebugOverlay.isEnabled)

        setenv("HOLOSCAPE_PNG_CHROME_DEBUG", "0", 1)
        XCTAssertFalse(ChromeDebugOverlay.isEnabled,
            "Only the exact string \"1\" enables the overlay (Req 14.7)")

        setenv("HOLOSCAPE_PNG_CHROME_DEBUG", "1", 1)
        XCTAssertTrue(ChromeDebugOverlay.isEnabled)
    }

    // MARK: - View contract

    func testIsFlipped() {
        let overlay = ChromeDebugOverlay(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 700),
            chrome: makeChrome(),
            baseImage: makeFixtureImage(),
            windowShape: nil,
            renderers: []
        )
        XCTAssertTrue(overlay.isFlipped,
            "Overlay uses chrome-image top-left coord convention")
    }

    func testHitTestReturnsNil() {
        let overlay = ChromeDebugOverlay(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 700),
            chrome: makeChrome(),
            baseImage: makeFixtureImage(),
            windowShape: nil,
            renderers: []
        )
        XCTAssertNil(overlay.hitTest(NSPoint(x: 500, y: 350)),
            "Debug overlay must not intercept events")
    }

    // MARK: - Phase refresh

    func testRefreshUpdatesPhaseText() {
        let overlay = ChromeDebugOverlay(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 700),
            chrome: makeChrome(),
            baseImage: makeFixtureImage(),
            windowShape: nil,
            renderers: []
        )
        XCTAssertEqual(overlay._testPhaseText, "0.000")
        overlay.refresh(phaseSeconds: 1.234)
        XCTAssertEqual(overlay._testPhaseText, "1.234",
            "refresh must update the phase-text readout")
        overlay.refresh(phaseSeconds: 42.5)
        XCTAssertEqual(overlay._testPhaseText, "42.500")
    }
}
