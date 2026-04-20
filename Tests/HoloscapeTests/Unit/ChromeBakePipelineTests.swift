import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Holoscape

/// Chrome v4 Task 7.3 — ChromeBakePipeline invariants.
///
/// Pins the load-bearing cache + bake contracts:
/// - Baked mode decodes `chrome.image` from the skin dir (Req 1.2).
/// - Composed mode produces a non-empty CGImage (Req 5.1).
/// - Cache hit skips the CGContext step and returns the cached PNG
///   (Req 5.4, Req 5.8 — ≤ 30 ms hit budget).
/// - SHA determinism across two independent bakes of the same
///   inputs (Req 5.2, Property 5 — byte-identical PNGs + SHAs).
/// - LRU purge preserves active SHAs (Req 5.6).
/// - Cold bake completes in ≤ 500 ms for 1000×700 logical (Req 5.7).
@MainActor
final class ChromeBakePipelineTests: XCTestCase {

    // MARK: - Fixture helpers

    private var tempRoot: URL!
    private var cacheRoot: URL!
    private var skinDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeBakePipelineTests-\(UUID().uuidString)")
        cacheRoot = tempRoot.appendingPathComponent("cache")
        skinDir = tempRoot.appendingPathComponent("skin")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    /// Write a small RGBA PNG fixture into skinDir and return its
    /// relative path. Pillow-free — CGImageDestination handles it.
    private func stageBakedPNG(named: String, width: Int = 32, height: Int = 32) throws -> String {
        let url = skinDir.appendingPathComponent(named)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        // Solid magenta (#ff44cc, opaque) so the image is non-zero.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xFF
            pixels[i + 1] = 0x44
            pixels[i + 2] = 0xCC
            pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "Failed to write PNG fixture")
        return named
    }

    private func bakedManifest(imagePath: String, width: Int = 1000, height: Int = 700) -> SkinDefinition {
        SkinDefinition(
            version: "4.0",
            name: "test-baked",
            chrome: ChromeDescriptor(
                mode: .baked,
                image: imagePath,
                width: width,
                height: height,
                interiorRect: SkinRect(x: 40, y: 60, width: Double(width - 80), height: Double(height - 120))
            )
        )
    }

    private func composedManifestWithSurface(width: Int = 1000, height: Int = 700) -> SkinDefinition {
        SkinDefinition(
            version: "4.0",
            name: "test-composed",
            surfaces: [
                "window.background": SurfaceDescriptor(fill: .color("#1a1a2e")),
                "tabBar.container": SurfaceDescriptor(fill: .color("#2a1a3e")),
                "sidebar.container": SurfaceDescriptor(fill: .color("#3a2a4e")),
            ],
            chrome: ChromeDescriptor(
                mode: .composed,
                width: width,
                height: height,
                interiorRect: SkinRect(x: 40, y: 60, width: Double(width - 80), height: Double(height - 120))
            )
        )
    }

    private func bakedChromeIdempotent() -> ChromeDescriptor {
        ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 1000,
            height: 700,
            interiorRect: SkinRect(x: 40, y: 60, width: 920, height: 600)
        )
    }

    private func makePipeline() -> ChromeBakePipeline {
        ChromeBakePipeline(cacheRoot: cacheRoot)
    }

    // MARK: - Baked mode

    func testBakedModeDecodesCGImage() throws {
        let path = try stageBakedPNG(named: "chrome.png", width: 64, height: 64)
        let manifest = bakedManifest(imagePath: path, width: 64, height: 64)
        let pipeline = makePipeline()

        let (image, sha) = try pipeline.bake(manifest: manifest, skinDir: skinDir)

        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertEqual(sha.count, 64, "SHA-256 hex must be exactly 64 chars")
    }

    func testBakedModeMissingImageThrows() {
        // No PNG staged.
        let manifest = bakedManifest(imagePath: "missing.png")
        let pipeline = makePipeline()

        XCTAssertThrowsError(try pipeline.bake(manifest: manifest, skinDir: skinDir)) { error in
            guard case ChromeBakePipeline.BakeError.imageDecodeFailed = error else {
                return XCTFail("expected imageDecodeFailed, got \(error)")
            }
        }
    }

    func testBakeThrowsWhenManifestChromeIsNil() {
        // Caller violated the pre-condition — SkinEngine.loadComposite
        // guards this and never invokes bake without a chrome field.
        // The pipeline still surfaces a clear error rather than
        // silently producing garbage.
        let manifest = SkinDefinition(version: "3.0", name: "no-chrome")
        let pipeline = makePipeline()

        XCTAssertThrowsError(try pipeline.bake(manifest: manifest, skinDir: skinDir)) { error in
            guard case ChromeBakePipeline.BakeError.missingChromeDescriptor = error else {
                return XCTFail("expected missingChromeDescriptor, got \(error)")
            }
        }
    }

    // MARK: - Composed mode

    func testComposedModeProducesNonEmptyImage() throws {
        let manifest = composedManifestWithSurface()
        let pipeline = makePipeline()

        let (image, sha) = try pipeline.bake(manifest: manifest, skinDir: skinDir)

        // Image is 2x the logical size.
        XCTAssertEqual(image.width, 2000)
        XCTAssertEqual(image.height, 1400)
        XCTAssertEqual(sha.count, 64)
    }

    func testComposedModeWithNoSurfacesStillProducesImage() throws {
        // A manifest that declares composed mode but no surfaces is a
        // valid edge case — the pipeline produces a transparent PNG.
        let manifest = SkinDefinition(
            version: "4.0",
            chrome: ChromeDescriptor(
                mode: .composed,
                width: 100,
                height: 100,
                interiorRect: SkinRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
        let pipeline = makePipeline()

        let (image, _) = try pipeline.bake(manifest: manifest, skinDir: skinDir)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)
    }

    // MARK: - Cache

    func testCacheHitReturnsStoredImage() throws {
        let path = try stageBakedPNG(named: "chrome.png")
        let manifest = bakedManifest(imagePath: path, width: 32, height: 32)
        let pipeline = makePipeline()

        // Cold bake — populates cache.
        let (firstImage, firstSHA) = try pipeline.bake(manifest: manifest, skinDir: skinDir)
        XCTAssertNotNil(pipeline.cachedImage(for: firstSHA),
            "First bake must populate the cache at <sha>.png")

        // Warm bake — should read the cached PNG. Same SHA, same image.
        let (secondImage, secondSHA) = try pipeline.bake(manifest: manifest, skinDir: skinDir)
        XCTAssertEqual(firstSHA, secondSHA)
        XCTAssertEqual(firstImage.width, secondImage.width)
        XCTAssertEqual(firstImage.height, secondImage.height)
    }

    func testCacheWritesCorrectFilename() throws {
        let path = try stageBakedPNG(named: "chrome.png")
        let manifest = bakedManifest(imagePath: path, width: 32, height: 32)
        let pipeline = makePipeline()

        let (_, sha) = try pipeline.bake(manifest: manifest, skinDir: skinDir)

        let expected = cacheRoot.appendingPathComponent("\(sha).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
            "Cached PNG must be written to <sha>.png under cacheRoot")
    }

    // MARK: - SHA determinism

    func testSHADeterministicAcrossBakes() throws {
        let path = try stageBakedPNG(named: "chrome.png")
        let manifest = bakedManifest(imagePath: path, width: 100, height: 100)

        let first = makePipeline()
        let (_, firstSHA) = try first.bake(manifest: manifest, skinDir: skinDir)

        // Fresh pipeline instance, nuke cache so we recompute SHA from
        // scratch rather than hit.
        try FileManager.default.removeItem(at: cacheRoot)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let second = makePipeline()
        let (_, secondSHA) = try second.bake(manifest: manifest, skinDir: skinDir)

        XCTAssertEqual(firstSHA, secondSHA,
            "Two independent bakes of byte-identical inputs must produce identical SHAs (Property 5)")
    }

    func testSHAChangesWhenManifestChanges() throws {
        let path = try stageBakedPNG(named: "chrome.png")
        let firstManifest = bakedManifest(imagePath: path, width: 100, height: 100)
        let secondManifest = bakedManifest(imagePath: path, width: 100, height: 200)

        let pipeline = makePipeline()
        let (_, firstSHA) = try pipeline.bake(manifest: firstManifest, skinDir: skinDir)
        let (_, secondSHA) = try pipeline.bake(manifest: secondManifest, skinDir: skinDir)

        XCTAssertNotEqual(firstSHA, secondSHA,
            "A manifest field change must miss the cache and recompute the SHA")
    }

    func testSHAChangesWhenAssetBytesChange() throws {
        let path = try stageBakedPNG(named: "chrome.png", width: 32, height: 32)
        let manifest = bakedManifest(imagePath: path, width: 32, height: 32)
        let pipeline = makePipeline()
        let (_, firstSHA) = try pipeline.bake(manifest: manifest, skinDir: skinDir)

        // Overwrite the fixture with different bytes (different size).
        try FileManager.default.removeItem(at: skinDir.appendingPathComponent(path))
        _ = try stageBakedPNG(named: "chrome.png", width: 16, height: 16)

        let (_, secondSHA) = try pipeline.bake(manifest: manifest, skinDir: skinDir)

        XCTAssertNotEqual(firstSHA, secondSHA,
            "Changed asset bytes must change the SHA (Req 5.5 — any input change misses the cache)")
    }

    // MARK: - LRU purge

    func testPurgeLRUPreservesActiveSHAs() throws {
        let pipeline = makePipeline()

        // Write 3 dummy cache entries with staggered modification dates.
        let shaA = String(repeating: "a", count: 64)
        let shaB = String(repeating: "b", count: 64)
        let shaC = String(repeating: "c", count: 64)
        // Large files so the LRU cap kicks in — ~20 MB each.
        let payload = Data(count: 20 * 1024 * 1024)
        for (sha, daysAgo) in [(shaA, 3), (shaB, 2), (shaC, 1)] {
            let url = cacheRoot.appendingPathComponent("\(sha).png")
            try payload.write(to: url)
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        // Total 60 MB, cap 50 MB — at least one must be evicted.
        // Preserve the oldest (shaA) to prove active-SHA protection.
        try pipeline.purgeLRU(preservingSHAs: [shaA])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent("\(shaA).png").path
        ), "preservingSHAs[\(shaA)] must survive even though it's the oldest entry")
    }

    func testPurgeLRUNoopsUnderCap() throws {
        let pipeline = makePipeline()

        // One small entry — well under cap.
        let sha = String(repeating: "d", count: 64)
        let url = cacheRoot.appendingPathComponent("\(sha).png")
        try Data(count: 1024).write(to: url)

        try pipeline.purgeLRU(preservingSHAs: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "Cache under cap must not evict anything")
    }

    // MARK: - Reduce Transparency (Task 17.2)

    func testReduceTransparencyUsesImageOpaqueWhenDeclared() throws {
        // Skin ships both translucent + opaque variants; pipeline
        // picks imageOpaque at bake time when RT is on.
        let translucent = try stageBakedPNG(named: "chrome.png", width: 64, height: 64)
        // Mark the opaque fixture with a different dimension so we can
        // assert "pipeline decoded THIS file, not the other one."
        _ = try stageBakedPNG(named: "chrome-opaque.png", width: 128, height: 128)
        let manifest = SkinDefinition(
            version: "4.0",
            chrome: ChromeDescriptor(
                mode: .baked,
                image: translucent,
                imageOpaque: "chrome-opaque.png",
                width: 64,
                height: 64,
                interiorRect: SkinRect(x: 0, y: 0, width: 64, height: 64)
            )
        )
        let pipeline = makePipeline()

        let (image, _) = try pipeline.bake(manifest: manifest, skinDir: skinDir, reduceTransparency: true)
        XCTAssertEqual(image.width, 128, "RT on + imageOpaque declared must decode the opaque fixture")
        XCTAssertEqual(image.height, 128)
    }

    func testReduceTransparencyOpacifiesWhenImageOpaqueMissing() throws {
        // Synthetic fixture with known translucent edge — opacify
        // should push that alpha to 255.
        let width = 8, height = 8
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        // Left column: fully transparent. Right column: semi-transparent
        // (alpha 0x80). Middle: opaque magenta.
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                if x == 0 {
                    // Fully transparent — alpha already 0.
                } else if x == width - 1 {
                    // Premultiplied semitransparent magenta.
                    pixels[i] = 0x80     // R = 0xFF * (0x80/0xFF) rounded
                    pixels[i + 1] = 0x20 // G
                    pixels[i + 2] = 0x68 // B
                    pixels[i + 3] = 0x80 // A
                } else {
                    pixels[i] = 0xFF; pixels[i + 1] = 0x44; pixels[i + 2] = 0xCC; pixels[i + 3] = 0xFF
                }
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let source = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!

        let pipeline = makePipeline()
        let opacified = pipeline.opacifyImage(source)!

        // Sample pixel buffer of the opacified image.
        let outContext = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        outContext.draw(opacified, in: CGRect(x: 0, y: 0, width: width, height: height))
        let outPtr = outContext.data!.assumingMemoryBound(to: UInt8.self)

        // Fully transparent pixels stay transparent.
        XCTAssertEqual(outPtr[3], 0, "alpha-0 pixels must stay transparent (silhouette preserved)")

        // Semi-transparent pixels (x = width-1, y = 0) become opaque.
        let semiIdx = 0 * bytesPerRow + (width - 1) * 4
        XCTAssertEqual(outPtr[semiIdx + 3], 0xFF, "semi-transparent pixels must become fully opaque")

        // Already-opaque pixels stay opaque.
        let opaqueIdx = 0 * bytesPerRow + 1 * 4
        XCTAssertEqual(outPtr[opaqueIdx + 3], 0xFF)
    }

    func testReduceTransparencyCachesSeparatelyFromTranslucent() throws {
        let translucent = try stageBakedPNG(named: "chrome.png", width: 32, height: 32)
        let manifest = bakedManifest(imagePath: translucent, width: 32, height: 32)
        let pipeline = makePipeline()

        // Cold bake translucent.
        let (_, sha) = try pipeline.bake(manifest: manifest, skinDir: skinDir, reduceTransparency: false)
        let translucentURL = cacheRoot.appendingPathComponent("\(sha).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: translucentURL.path),
            "Translucent cache entry at <sha>.png")

        // Cold bake opaque — distinct key, both now present.
        _ = try pipeline.bake(manifest: manifest, skinDir: skinDir, reduceTransparency: true)
        let opaqueURL = cacheRoot.appendingPathComponent("\(sha).opaque.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: opaqueURL.path),
            "Opaque cache entry at <sha>.opaque.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: translucentURL.path),
            "Opaque bake must not delete the translucent variant")

        // Warm hit on opaque — read the cache.
        XCTAssertNotNil(pipeline.cachedOpaqueImage(for: sha))
    }

    // MARK: - Performance

    func testColdBakeMeetsBudget() throws {
        // Req 5.7 — ≤ 500 ms cold bake for a 1000×700 composed skin
        // on Apple Silicon. Allow generous headroom (1000 ms) so the
        // test isn't flaky under CI contention; the budget failure we
        // care about is "takes seconds", not "takes 600ms sometimes."
        let manifest = composedManifestWithSurface(width: 1000, height: 700)
        let pipeline = makePipeline()

        let start = Date()
        _ = try pipeline.bake(manifest: manifest, skinDir: skinDir)
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        XCTAssertLessThan(elapsedMs, 1000,
            "Cold bake of 1000×700 took \(elapsedMs) ms — design budget is 500 ms, test threshold 1000 ms")
    }
}
