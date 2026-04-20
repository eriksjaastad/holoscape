import XCTest
import AppKit
@testable import Holoscape

/// Chrome v4 Task 5.3 — Component 1 invariants.
///
/// Pins the load-bearing ChromeHostView contracts:
/// - baseLayer.contents is the CGImage passed at init (Req 2.1).
/// - hitTest returns nil regardless of input (Req 2.5 — event
///   routing goes through ShapedContentView's sampler, never here).
/// - animatedLayersContainer is installed above baseLayer so every
///   animated sublayer composites on top (Req 10.4, Property 1).
///
/// Animation-layer install/diff/density paths are stubbed in PR #3
/// and covered by later PR tests (#10 / #13 / #18).
@MainActor
final class ChromeHostViewTests: XCTestCase {

    // MARK: - Fixture

    /// 16×16 solid-magenta RGBA CGImage. Enough for Equatable comparison
    /// without any file I/O — tests only need a unique reference to
    /// confirm the image assigned at init is the one we find on
    /// baseLayer.contents afterward.
    private func makeFixtureImage() -> CGImage {
        let width = 16
        let height = 16
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xFF      // R
            pixels[i + 1] = 0x44  // G
            pixels[i + 2] = 0xCC  // B
            pixels[i + 3] = 0xFF  // A
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func makeChrome(width: Int = 1000, height: Int = 700) -> ChromeDescriptor {
        ChromeDescriptor(
            mode: .baked,
            image: "test-chrome.png",
            width: width,
            height: height,
            interiorRect: SkinRect(x: 40, y: 60, width: Double(width - 80), height: Double(height - 120))
        )
    }

    // MARK: - Base layer

    func testBaseLayerContentsEqualsPassedImage() {
        let image = makeFixtureImage()
        let host = ChromeHostView(chrome: makeChrome(), baseImage: image, clock: nil)

        let contents = host._testBaseLayerContents
        XCTAssertNotNil(contents, "baseLayer.contents must be set at init")

        // Contents round-trip as CFTypeRef (Any); compare via identity.
        let storedImage = contents as! CGImage
        XCTAssertEqual(storedImage.width, image.width)
        XCTAssertEqual(storedImage.height, image.height)
    }

    // MARK: - Hit test

    func testHitTestReturnsNilForAllInputs() {
        let host = ChromeHostView(chrome: makeChrome(), baseImage: makeFixtureImage(), clock: nil)

        // Inside bounds, outside bounds, negative, non-integral — all nil.
        XCTAssertNil(host.hitTest(NSPoint(x: 0, y: 0)))
        XCTAssertNil(host.hitTest(NSPoint(x: 500, y: 350)))
        XCTAssertNil(host.hitTest(NSPoint(x: 999, y: 699)))
        XCTAssertNil(host.hitTest(NSPoint(x: -50, y: -50)))
        XCTAssertNil(host.hitTest(NSPoint(x: 10_000, y: 10_000)))
        XCTAssertNil(host.hitTest(NSPoint(x: 123.456, y: 456.789)))
    }

    // MARK: - Sublayer z-order

    func testAnimatedContainerIsSiblingAboveBase() {
        let host = ChromeHostView(chrome: makeChrome(), baseImage: makeFixtureImage(), clock: nil)

        let sublayers = host._testSublayerOrder ?? []
        XCTAssertGreaterThanOrEqual(sublayers.count, 2,
            "host.layer must have baseLayer + animatedLayersContainer")

        let baseIndex = sublayers.firstIndex(of: host._testBaseLayer)
        let animatedIndex = sublayers.firstIndex(of: host._testAnimatedLayersContainer)

        XCTAssertNotNil(baseIndex, "baseLayer must be a sublayer of host.layer")
        XCTAssertNotNil(animatedIndex, "animatedLayersContainer must be a sublayer of host.layer")

        // CALayer.sublayers is z-ordered from bottom to top, so a
        // higher index means composited above.
        XCTAssertLessThan(baseIndex!, animatedIndex!,
            "animatedLayersContainer must composite above baseLayer (Req 10.4)")
    }

    func testAnimatedContainerStartsEmpty() {
        let host = ChromeHostView(chrome: makeChrome(), baseImage: makeFixtureImage(), clock: nil)
        let container = host._testAnimatedLayersContainer
        XCTAssertTrue(container.sublayers?.isEmpty ?? true,
            "animatedLayersContainer must be empty in PR #3 — first renderer installs in PR #10")
    }

    func testRenderersStartsEmpty() {
        let host = ChromeHostView(chrome: makeChrome(), baseImage: makeFixtureImage(), clock: nil)
        XCTAssertTrue(host.renderers.isEmpty,
            "renderers starts empty until PR #10 installs the first conforming type")
    }

    // MARK: - NSView overrides

    func testIsFlippedTrue() {
        let host = ChromeHostView(chrome: makeChrome(), baseImage: makeFixtureImage(), clock: nil)
        XCTAssertTrue(host.isFlipped,
            "Top-left origin matches chrome-image coords so SkinRect values apply without per-layer y-flip")
    }

    func testDoesNotAcceptFirstResponder() {
        let host = ChromeHostView(chrome: makeChrome(), baseImage: makeFixtureImage(), clock: nil)
        XCTAssertFalse(host.acceptsFirstResponder,
            "ChromeHostView is decorative — focus belongs to interior subviews")
    }

    // MARK: - updateBaseImage

    func testUpdateBaseImageReplacesContents() {
        let first = makeFixtureImage()
        let host = ChromeHostView(chrome: makeChrome(), baseImage: first, clock: nil)

        // Build a second image with a different byte pattern so we can
        // confirm the swap. 8×8 instead of 16×16 — different dimensions
        // make the "has it actually changed" check trivial.
        let second: CGImage = {
            let w = 8, h = 8
            let bytesPerRow = w * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = 0x11; pixels[i + 1] = 0x22; pixels[i + 2] = 0x33; pixels[i + 3] = 0xFF
            }
            let data = Data(pixels)
            return CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: data as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )!
        }()

        host.updateBaseImage(second)
        let contentsAfter = host._testBaseLayerContents as! CGImage
        XCTAssertEqual(contentsAfter.width, 8, "updateBaseImage must swap the image on baseLayer")
        XCTAssertEqual(contentsAfter.height, 8)
    }

    // MARK: - Layout

    func testLayoutKeepsSublayerFramesInSync() {
        let host = ChromeHostView(chrome: makeChrome(width: 1000, height: 700), baseImage: makeFixtureImage(), clock: nil)
        // Resize the host — sublayer frames must follow.
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layout()
        XCTAssertEqual(host._testBaseLayer.frame, NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(host._testAnimatedLayersContainer.frame, NSRect(x: 0, y: 0, width: 800, height: 600))
    }
}
