import XCTest
import AppKit
@testable import Holoscape

/// Task 8.1 + 8.3 — SkinEngine asset pipeline:
///   - `validateAssetPath` rejects traversal, absolute, and HTTP URLs
///   - `loadImages` walks surface fills + state-variant fills, validates,
///     and returns the NSImage map keyed by manifest-relative path
@MainActor
final class SkinEngineAssetLoadingTests: XCTestCase {

    private var tempSkinDir: URL!
    private let engine = SkinEngine()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempSkinDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-skin-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempSkinDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempSkinDir)
        try super.tearDownWithError()
    }

    // MARK: - validateAssetPath

    func testValidateAcceptsRelativePath() throws {
        XCTAssertNoThrow(try engine.validateAssetPath("assets/tab-bg.png"))
        XCTAssertNoThrow(try engine.validateAssetPath("nested/deep/path/img.png"))
        XCTAssertNoThrow(try engine.validateAssetPath("single.png"))
    }

    /// Documents the intended behavior: single-dot segments are a no-op
    /// that collapse during path resolution and are permitted.
    func testValidateAcceptsSingleDotSegment() throws {
        XCTAssertNoThrow(try engine.validateAssetPath("./assets/tab-bg.png"))
        XCTAssertNoThrow(try engine.validateAssetPath("assets/./tab-bg.png"))
    }

    func testValidateRejectsAbsolutePath() {
        XCTAssertThrowsError(try engine.validateAssetPath("/etc/passwd")) { err in
            XCTAssertEqual(err as? SkinAssetError, .invalidPath("/etc/passwd"))
        }
    }

    func testValidateRejectsTraversal() {
        for bad in ["../../../etc/passwd", "assets/../../../etc/passwd", ".."] {
            XCTAssertThrowsError(try engine.validateAssetPath(bad)) { err in
                XCTAssertEqual(err as? SkinAssetError, .invalidPath(bad),
                               "Traversal input '\(bad)' must throw .invalidPath")
            }
        }
    }

    func testValidateRejectsHTTPAndHTTPSURLs() {
        for bad in [
            "http://evil.example/img.png",
            "https://evil.example/img.png",
            "HTTPS://evil.example/img.png",  // case-insensitive
        ] {
            XCTAssertThrowsError(try engine.validateAssetPath(bad)) { err in
                XCTAssertEqual(err as? SkinAssetError, .invalidPath(bad))
            }
        }
    }

    func testValidateRejectsFileURLScheme() {
        for bad in ["file:///etc/passwd", "FILE:///etc/passwd"] {
            XCTAssertThrowsError(try engine.validateAssetPath(bad)) { err in
                XCTAssertEqual(err as? SkinAssetError, .invalidPath(bad),
                               "file:// URLs must be rejected by the string-level gate")
            }
        }
    }

    // MARK: - loadImages

    func testLoadImagesReturnsEmptyWhenNoSurfaces() throws {
        let skin = SkinDefinition()
        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertEqual(images.count, 0)
    }

    func testLoadImagesSkipsColorAndGradientFills() throws {
        var skin = SkinDefinition()
        skin.surfaces = [
            "topBar": SurfaceDescriptor(fill: .color("#123456")),
            "bottomBar": SurfaceDescriptor(fill: .gradient(
                direction: .vertical,
                stops: [GradientStop(offset: 0, color: "#000"), GradientStop(offset: 1, color: "#fff")]
            )),
        ]
        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertEqual(images.count, 0,
                       "Non-image fills must not produce entries in the image cache")
    }

    func testLoadImagesLoadsReferencedPNG() throws {
        let pngPath = "tab-bg.png"
        try writePNG(relPath: pngPath)

        var skin = SkinDefinition()
        skin.surfaces = [
            "tabBar": SurfaceDescriptor(fill: .image(path: pngPath, tile: .stretch))
        ]

        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(images[pngPath], "Image should be keyed by manifest path")
    }

    func testLoadImagesWalksStateVariantFills() throws {
        let basePath = "base.png"
        let hoverPath = "hover.png"
        try writePNG(relPath: basePath)
        try writePNG(relPath: hoverPath)

        var surface = SurfaceDescriptor(fill: .image(path: basePath, tile: .stretch))
        surface.states = [
            StateVariant(
                name: "hover",
                match: MatchExpression(conditions: ["hover": .scalar(1)]),
                fill: .image(path: hoverPath, tile: .stretch)
            )
        ]
        var skin = SkinDefinition()
        skin.surfaces = ["tabActive": surface]

        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertEqual(images.count, 2)
        XCTAssertNotNil(images[basePath])
        XCTAssertNotNil(images[hoverPath],
                        "State-variant image fills must also be loaded")
    }

    func testLoadImagesDeduplicatesRepeatedPaths() throws {
        let shared = "shared.png"
        try writePNG(relPath: shared)

        var skin = SkinDefinition()
        skin.surfaces = [
            "a": SurfaceDescriptor(fill: .image(path: shared, tile: .stretch)),
            "b": SurfaceDescriptor(fill: .image(path: shared, tile: .tile)),
        ]

        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertEqual(images.count, 1,
                       "Same path referenced by two surfaces must be loaded once")
    }

    func testLoadImagesPropagatesInvalidPath() {
        var skin = SkinDefinition()
        skin.surfaces = [
            "bad": SurfaceDescriptor(fill: .image(path: "/etc/passwd", tile: .stretch))
        ]
        XCTAssertThrowsError(try engine.loadImages(from: tempSkinDir, manifest: skin)) { err in
            XCTAssertEqual(err as? SkinAssetError, .invalidPath("/etc/passwd"))
        }
    }

    func testLoadImagesRejectsSymlinkEscapingSkinDir() throws {
        // Write a real PNG outside the skin directory, then create a
        // symlink inside the skin dir pointing at it. String-level
        // validation passes; the filesystem-level gate must catch it.
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let realTarget = outsideDir.appendingPathComponent("secret.png")
        try writePNG(absolutePath: realTarget)

        let linkPath = "assets/bg.png"
        let link = tempSkinDir.appendingPathComponent(linkPath)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realTarget)

        var skin = SkinDefinition()
        skin.surfaces = [
            "tab": SurfaceDescriptor(fill: .image(path: linkPath, tile: .stretch))
        ]

        XCTAssertThrowsError(try engine.loadImages(from: tempSkinDir, manifest: skin)) { err in
            XCTAssertEqual(err as? SkinAssetError, .invalidPath(linkPath),
                           "Symlink escaping skin dir must be rejected at the fs gate")
        }
    }

    func testLoadImagesIgnoresStateVariantColorFills() throws {
        // Regression guard: a state variant with a non-image fill must
        // not inflate the image cache.
        let basePath = "base.png"
        try writePNG(relPath: basePath)

        var surface = SurfaceDescriptor(fill: .image(path: basePath, tile: .stretch))
        surface.states = [
            StateVariant(
                name: "pressed",
                match: MatchExpression(conditions: ["pressed": .scalar(1)]),
                fill: .color("#333333")
            )
        ]
        var skin = SkinDefinition()
        skin.surfaces = ["button": surface]

        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertEqual(images.count, 1,
                       "Only the base image should load — the color state variant adds nothing")
        XCTAssertNotNil(images[basePath])
    }

    func testLoadImagesSkipsUndecodableFileButContinues() throws {
        // Write a non-image file where a PNG is expected. NSImage(contentsOfFile:)
        // returns nil; the loader logs and skips rather than aborting the skin.
        let corruptPath = "corrupt.png"
        let goodPath = "good.png"
        try Data("not a png".utf8).write(to: tempSkinDir.appendingPathComponent(corruptPath))
        try writePNG(relPath: goodPath)

        var skin = SkinDefinition()
        skin.surfaces = [
            "a": SurfaceDescriptor(fill: .image(path: corruptPath, tile: .stretch)),
            "b": SurfaceDescriptor(fill: .image(path: goodPath, tile: .stretch)),
        ]

        let images = try engine.loadImages(from: tempSkinDir, manifest: skin)
        XCTAssertNil(images[corruptPath],
                     "Undecodable image must not appear in the result map")
        XCTAssertNotNil(images[goodPath],
                        "Sibling images must still load when one is corrupt")
    }

    // MARK: - Helpers

    /// Write a trivial 1x1 PNG to `tempSkinDir/relPath`. Creates any
    /// intermediate directories the path implies.
    private func writePNG(relPath: String) throws {
        try writePNG(absolutePath: tempSkinDir.appendingPathComponent(relPath))
    }

    private func writePNG(absolutePath: URL) throws {
        try FileManager.default.createDirectory(
            at: absolutePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SkinEngineAssetLoadingTests", code: 1)
        }
        try png.write(to: absolutePath)
    }
}
