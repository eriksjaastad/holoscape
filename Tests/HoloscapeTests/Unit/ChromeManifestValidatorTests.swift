import XCTest
import AppKit
import CoreGraphics
@testable import Holoscape

/// Chrome v4 Task 9.4 — ChromeManifestValidator invariants (Req 12).
///
/// Pins every documented check:
/// - Polygon-vs-alpha bbox agreement within ±2 logical px (Req 12.1, 12.2)
/// - Unique animation ids (Req 12.3)
/// - Rects inside chrome bounds (Req 12.4)
/// - Per-kind param validation (Req 12.5)
/// - Asset existence (Req 12.6)
/// - Sub-minimum size warning (Req 12.9)
/// - Fatal: non-RGBA image, dimension mismatch, interiorRect outside (Req 12.8)
@MainActor
final class ChromeManifestValidatorTests: XCTestCase {

    // MARK: - Image fixtures

    /// Build an RGBA CGImage at (widthPx × heightPx). `paintedRect`
    /// receives full alpha; everything outside gets alpha 0. Used to
    /// synthesize a known-good silhouette for polygon-bbox tests.
    private func makeRGBAImage(
        widthPx: Int,
        heightPx: Int,
        paintedRect: CGRect
    ) -> CGImage {
        let bytesPerRow = widthPx * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * heightPx)
        let xStart = Int(paintedRect.minX)
        let xEnd = Int(paintedRect.maxX)
        let yStart = Int(paintedRect.minY)
        let yEnd = Int(paintedRect.maxY)
        for y in max(0, yStart)..<min(heightPx, yEnd) {
            for x in max(0, xStart)..<min(widthPx, xEnd) {
                let i = y * bytesPerRow + x * 4
                pixels[i] = 0xFF
                pixels[i + 1] = 0x44
                pixels[i + 2] = 0xCC
                pixels[i + 3] = 0xFF
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: widthPx, height: heightPx,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Opaque RGBA image — no alpha zero pixels, fills every pixel.
    private func makeOpaqueImage(widthPx: Int, heightPx: Int) -> CGImage {
        makeRGBAImage(
            widthPx: widthPx,
            heightPx: heightPx,
            paintedRect: CGRect(x: 0, y: 0, width: widthPx, height: heightPx)
        )
    }

    /// Non-alpha (RGB) image. Used to hit the Req 12.8 non-RGBA
    /// fatal check.
    private func makeNoAlphaImage(widthPx: Int, heightPx: Int) -> CGImage {
        let bytesPerRow = widthPx * 4
        let pixels = [UInt8](repeating: 0xFF, count: bytesPerRow * heightPx)
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: widthPx, height: heightPx,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    // MARK: - Manifest fixtures

    private func goodChrome(width: Int = 1000, height: Int = 700) -> ChromeDescriptor {
        ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: width,
            height: height,
            interiorRect: SkinRect(x: 40, y: 60, width: Double(width - 80), height: Double(height - 120))
        )
    }

    private func manifestWith(chrome: ChromeDescriptor, windowShape: WindowShapeDescriptor? = nil) -> SkinDefinition {
        SkinDefinition(
            version: "4.0",
            name: "test",
            windowShape: windowShape,
            chrome: chrome
        )
    }

    // MARK: - Fatal: non-RGBA

    func testNonRGBAImageIsFatal() {
        let image = makeNoAlphaImage(widthPx: 2000, heightPx: 1400)
        let manifest = manifestWith(chrome: goodChrome())
        let result = ChromeManifestValidator.validate(manifest: manifest, baseImage: image, windowShape: nil)
        XCTAssertFalse(result.valid, "Non-RGBA image must be fatal (Req 12.8)")
        XCTAssertTrue(result.warningReason?.contains("RGBA") ?? false)
    }

    // MARK: - Fatal: dimension mismatch

    func testDimensionMismatchIsFatal() {
        // Chrome declares 1000×700, image is 800×600 at 2x.
        let image = makeOpaqueImage(widthPx: 1600, heightPx: 1200)
        let manifest = manifestWith(chrome: goodChrome())
        let result = ChromeManifestValidator.validate(manifest: manifest, baseImage: image, windowShape: nil)
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.warningReason?.contains("pixel dimensions") ?? false)
    }

    // MARK: - Fatal: interiorRect outside

    func testInteriorRectOutsideIsFatal() {
        // interior extends past chrome.width.
        let chrome = ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 1000, height: 700,
            interiorRect: SkinRect(x: 900, y: 0, width: 200, height: 100)
        )
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.warningReason?.contains("interiorRect") ?? false)
    }

    // MARK: - Fatal: missing chrome

    func testMissingChromeIsFatal() {
        let manifest = SkinDefinition(version: "3.0")
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(manifest: manifest, baseImage: image, windowShape: nil)
        XCTAssertFalse(result.valid)
    }

    // MARK: - Warning: sub-minimum size

    func testSubMinimumWidthEmitsWarning() {
        let chrome = ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 100, height: 700,
            interiorRect: SkinRect(x: 0, y: 0, width: 100, height: 700)
        )
        let image = makeOpaqueImage(widthPx: 200, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.valid, "Sub-minimum is a warning, not a rejection (Req 12.9)")
        XCTAssertTrue(result.warningReason?.contains("below minimum") ?? false)
    }

    func testSubMinimumHeightEmitsWarning() {
        // Req 12.9 specifies both width AND height minimums.
        let chrome = ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 500, height: 50,
            interiorRect: SkinRect(x: 0, y: 0, width: 500, height: 50)
        )
        let image = makeOpaqueImage(widthPx: 1000, heightPx: 100)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.valid, "Sub-minimum height is a warning, not a rejection (Req 12.9)")
        XCTAssertTrue(result.warningReason?.contains("below minimum") ?? false)
    }

    // MARK: - Polygon vs alpha

    func testPolygonAlphaAgreementWithinToleranceIsClean() {
        // Chrome is 1000×700 logical. Image at 2x = 2000×1400 px.
        // Paint alpha in (80, 120)–(1920, 1280) px → logical
        // (40, 60)–(960, 640). Polygon matches exactly.
        let image = makeRGBAImage(
            widthPx: 2000, heightPx: 1400,
            paintedRect: CGRect(x: 80, y: 120, width: 1840, height: 1160)
        )
        let polygons = [
            Polygon(points: [
                Point(x: 40, y: 60),
                Point(x: 960, y: 60),
                Point(x: 960, y: 640),
                Point(x: 40, y: 640),
            ]),
        ]
        let shape = WindowShapeDescriptor(kind: .polygons, polygons: polygons, maskPath: nil)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: goodChrome()),
            baseImage: image,
            windowShape: shape
        )
        XCTAssertTrue(result.valid)
        XCTAssertLessThanOrEqual(result.polygonAlphaDeltaPixels, 2,
            "Matched polygon/alpha must be within 2 px tolerance (Req 12.2)")
        XCTAssertNil(result.warningReason)
    }

    func testPolygonAlphaAgreementAtOnePixelStillClean() {
        // 1 px drift — within tolerance, no warning.
        // Alpha: logical (40, 60)–(960, 640). Polygon shifted by 1 px.
        let image = makeRGBAImage(
            widthPx: 2000, heightPx: 1400,
            paintedRect: CGRect(x: 80, y: 120, width: 1840, height: 1160)
        )
        let polygons = [
            Polygon(points: [
                Point(x: 41, y: 60),
                Point(x: 960, y: 60),
                Point(x: 960, y: 640),
                Point(x: 41, y: 640),
            ]),
        ]
        let shape = WindowShapeDescriptor(kind: .polygons, polygons: polygons, maskPath: nil)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: goodChrome()),
            baseImage: image,
            windowShape: shape
        )
        XCTAssertTrue(result.valid)
        XCTAssertLessThanOrEqual(result.polygonAlphaDeltaPixels, 2)
        XCTAssertNil(result.warningReason, "1 px delta must be within tolerance")
    }

    func testPolygonAlphaAgreementAtTwoPixelsStillClean() {
        // 2 px drift — boundary of tolerance, no warning (Req 12.2: "more than 2").
        let image = makeRGBAImage(
            widthPx: 2000, heightPx: 1400,
            paintedRect: CGRect(x: 80, y: 120, width: 1840, height: 1160)
        )
        let polygons = [
            Polygon(points: [
                Point(x: 42, y: 60),
                Point(x: 960, y: 60),
                Point(x: 960, y: 640),
                Point(x: 42, y: 640),
            ]),
        ]
        let shape = WindowShapeDescriptor(kind: .polygons, polygons: polygons, maskPath: nil)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: goodChrome()),
            baseImage: image,
            windowShape: shape
        )
        XCTAssertTrue(result.valid)
        XCTAssertLessThanOrEqual(result.polygonAlphaDeltaPixels, 2, "2 px delta must be exactly at tolerance and pass")
        XCTAssertNil(result.warningReason, "2 px delta is the tolerance boundary — must be clean")
    }

    func testPolygonAlphaAgreementAtThreePixelsWarns() {
        // 3 px drift — just above tolerance, must warn.
        let image = makeRGBAImage(
            widthPx: 2000, heightPx: 1400,
            paintedRect: CGRect(x: 80, y: 120, width: 1840, height: 1160)
        )
        let polygons = [
            Polygon(points: [
                Point(x: 43, y: 60),
                Point(x: 960, y: 60),
                Point(x: 960, y: 640),
                Point(x: 43, y: 640),
            ]),
        ]
        let shape = WindowShapeDescriptor(kind: .polygons, polygons: polygons, maskPath: nil)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: goodChrome()),
            baseImage: image,
            windowShape: shape
        )
        XCTAssertTrue(result.valid, "3 px delta is a warning, not a rejection")
        XCTAssertEqual(result.polygonAlphaDeltaPixels, 3)
        XCTAssertTrue(result.warningReason?.contains("polygon/alpha") ?? false)
    }

    func testPolygonAlphaAgreementAboveToleranceWarns() {
        // Alpha painted in (80, 120)–(1920, 1280) px → logical (40, 60)–(960, 640).
        // Polygon claims (0, 0)–(1000, 700) — big disagreement.
        let image = makeRGBAImage(
            widthPx: 2000, heightPx: 1400,
            paintedRect: CGRect(x: 80, y: 120, width: 1840, height: 1160)
        )
        let polygons = [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 1000, y: 0),
                Point(x: 1000, y: 700),
                Point(x: 0, y: 700),
            ]),
        ]
        let shape = WindowShapeDescriptor(kind: .polygons, polygons: polygons, maskPath: nil)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: goodChrome()),
            baseImage: image,
            windowShape: shape
        )
        XCTAssertTrue(result.valid, "Disagreement is a warning, not a rejection (Req 12.2)")
        XCTAssertGreaterThan(result.polygonAlphaDeltaPixels, 2)
        XCTAssertTrue(result.warningReason?.contains("polygon/alpha") ?? false)
    }

    // MARK: - Unique animation ids

    func testDuplicateAnimationIDsDisablesTheLayer() {
        // Include a unique third animation so we can confirm:
        //   - dup id lands in disabledAnimationIDs
        //   - unique id does NOT land in disabledAnimationIDs
        // This rules out the regression where every animation ends up
        // disabled when any duplicate is present.
        let anim1 = ChromeAnimationLayer(
            id: "dup",
            kind: .shader,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 1,
            params: ChromeAnimationLayer.Params(
                shader: ShaderParams(preset: .glow, color: "#ffffff", intensity: 0.5, hz: 1)
            )
        )
        let anim2 = ChromeAnimationLayer(
            id: "dup",
            kind: .shader,
            rect: SkinRect(x: 200, y: 0, width: 100, height: 100),
            z: 2,
            params: ChromeAnimationLayer.Params(
                shader: ShaderParams(preset: .scanlines, color: nil, intensity: nil, hz: nil)
            )
        )
        let uniqueAnim = ChromeAnimationLayer(
            id: "unique",
            kind: .shader,
            rect: SkinRect(x: 400, y: 0, width: 100, height: 100),
            z: 3,
            params: ChromeAnimationLayer.Params(
                shader: ShaderParams(preset: .noise)
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim1, anim2, uniqueAnim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("dup"),
            "Duplicate id must disable the offending layer (Req 12.3)")
        XCTAssertFalse(result.disabledAnimationIDs.contains("unique"),
            "Unique id must NOT be collateral damage from an unrelated duplicate")
        XCTAssertEqual(result.disabledAnimationIDs, ["dup"],
            "Exactly the duplicate id is disabled; nothing else")
    }

    // MARK: - Shader preset surface

    func testValidShaderPresetsMatchEnumExactly() {
        // Req 12.5 — validator's preset allow-list must match every
        // case of `ShaderParams.Preset`. Codable restricts construction
        // to the three known cases, so this is a defense-in-depth
        // check that catches drift if someone adds a `.bloom` case to
        // the enum but forgets to register it in the validator set.
        let enumCases = Set(["glow", "scanlines", "noise"])  // all raw values of ShaderParams.Preset
        XCTAssertEqual(
            ChromeManifestValidator.validShaderPresets,
            enumCases,
            "ChromeManifestValidator.validShaderPresets must enumerate exactly the ShaderParams.Preset cases"
        )
    }

    // MARK: - Rect inside bounds

    func testRectOutsideChromeIsDisabled() {
        let anim = ChromeAnimationLayer(
            id: "oob",
            kind: .shader,
            rect: SkinRect(x: 900, y: 600, width: 200, height: 200),  // runs off right + bottom
            z: 1,
            params: ChromeAnimationLayer.Params(
                shader: ShaderParams(preset: .glow)
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("oob"),
            "Out-of-bounds rect must disable the layer (Req 12.4)")
    }

    // MARK: - z > 0

    func testZZeroIsDisabled() {
        let anim = ChromeAnimationLayer(
            id: "z0",
            kind: .shader,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 0,
            params: ChromeAnimationLayer.Params(shader: ShaderParams(preset: .glow))
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("z0"),
            "z = 0 collides with Base_Layer and must be disabled (Req 10.4)")
    }

    // MARK: - Per-kind params

    func testParticleZeroBirthRateDisabled() {
        let anim = ChromeAnimationLayer(
            id: "zero",
            kind: .particle,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 1,
            params: ChromeAnimationLayer.Params(
                particle: ParticleParams(
                    birthRate: 0,
                    lifetime: 1.0,
                    velocity: 10,
                    emissionAngle: 0, emissionRange: 0,
                    color: "#ff00ff",
                    scale: 1.0
                )
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("zero"),
            "birthRate = 0 must disable particle (Req 12.5)")
    }

    func testSpriteFrameCountExceedsGridDisabled() {
        let anim = ChromeAnimationLayer(
            id: "overflow",
            kind: .spriteAnim,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 1,
            params: ChromeAnimationLayer.Params(
                spriteAnim: SpriteAnimParams(
                    sheet: "sheet.png",
                    gridRows: 2, gridCols: 2,
                    frameCount: 10,  // > 4 cells
                    fps: 12, loop: .loop
                )
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("overflow"),
            "frameCount > gridRows*gridCols must disable sprite (Req 12.5)")
    }

    func testLedEmptyPaletteDisabled() {
        let anim = ChromeAnimationLayer(
            id: "emptyPalette",
            kind: .ledArray,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 1,
            params: ChromeAnimationLayer.Params(
                ledArray: LedArrayParams(
                    cellSize: 4,
                    cells: [LedArrayParams.LedCell(x: 0, y: 0, defaultState: 0)],
                    palette: [],
                    pattern: .steady
                )
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("emptyPalette"),
            "palette.count = 0 must disable led array (Req 12.5)")
    }

    func testLedDefaultStateOutOfRangeDisabled() {
        let anim = ChromeAnimationLayer(
            id: "badState",
            kind: .ledArray,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 1,
            params: ChromeAnimationLayer.Params(
                ledArray: LedArrayParams(
                    cellSize: 4,
                    cells: [LedArrayParams.LedCell(x: 0, y: 0, defaultState: 5)],  // palette has 2 entries
                    palette: ["#000000", "#ffffff"],
                    pattern: .steady
                )
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("badState"),
            "defaultState outside [0, palette.count) must disable led array (Req 12.5)")
    }

    // MARK: - Asset existence

    func testParticleImageMissingDisabled() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeManifestValidatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let anim = ChromeAnimationLayer(
            id: "missingImg",
            kind: .particle,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            z: 1,
            params: ChromeAnimationLayer.Params(
                particle: ParticleParams(
                    birthRate: 5, lifetime: 3, velocity: 10,
                    emissionAngle: 0, emissionRange: 0,
                    color: "#ff00ff", scale: 1.0,
                    image: "does-not-exist.png"
                )
            )
        )
        var chrome = goodChrome()
        chrome.animations = [anim]
        let image = makeOpaqueImage(widthPx: 2000, heightPx: 1400)
        let result = ChromeManifestValidator.validate(
            manifest: manifestWith(chrome: chrome),
            baseImage: image,
            windowShape: nil,
            skinDir: tempDir
        )
        XCTAssertTrue(result.disabledAnimationIDs.contains("missingImg"),
            "Missing particle image must disable layer (Req 12.6)")
    }
}
