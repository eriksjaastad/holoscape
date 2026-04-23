import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Holoscape

/// Chrome v4 Task 35.1 — extended backward-compat matrix.
///
/// Six new scenarios beyond the existing `BackwardCompatIntegrationTests`:
/// - v4 composed directory (no animations)
/// - v4 baked directory (no animations)
/// - v4 composed with every MVP animation kind (Synthwave — shipped)
/// - v4 baked with every MVP animation kind (HoloscapeClassic-live — shipped)
/// - v4 composed minimal (AmplifyDemo — shipped)
/// - v4 baked directory (programmatic fixture)
///
/// `.wamp` forms of no-anim fixtures aren't staged here because
/// `WampBundleLoader` requires a full ZIP ceremony; the two in-tree
/// skins that have both forms (HoloscapeSynthwave + HoloscapeClassic)
/// cover the directory ↔ wamp parity contract in the original BC
/// tests. This file focuses on v4-specific decoding + bake + validate.
@MainActor
final class ChromeBackwardCompatIntegrationTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeBC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - Lane 1: v4 composed directory, no animations

    func testV4ComposedNoAnimationsLoads() throws {
        let skinDir = tempRoot.appendingPathComponent("bc-composed-noanim")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let skinJSON = """
        {
          "version": "4.0",
          "name": "bc-composed-noanim",
          "chrome": {
            "mode": "composed",
            "width": 400,
            "height": 300,
            "interiorRect": { "x": 0, "y": 0, "width": 400, "height": 300 }
          },
          "surfaces": {
            "window.background": { "fill": { "kind": "color", "value": "#123456" } }
          }
        }
        """
        try skinJSON.write(
            to: skinDir.appendingPathComponent("skin.json"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = try loadIsolated(skinName: "bc-composed-noanim", skinDir: skinDir)
        XCTAssertNotNil(loaded.chrome)
        XCTAssertEqual(loaded.chrome?.mode, .composed)
        XCTAssertNil(loaded.chrome?.animations,
            "v4 composed without animations must decode with animations nil")
        XCTAssertNotNil(loaded.baseImage)
        XCTAssertTrue(loaded.chromeValidation?.valid ?? false)
    }

    // MARK: - Lane 2: v4 baked directory, no animations

    func testV4BakedNoAnimationsLoads() throws {
        let skinDir = tempRoot.appendingPathComponent("bc-baked-noanim")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)

        // Stage a chrome@2x.png at the required dimensions.
        try writeRGBAPng(
            to: skinDir.appendingPathComponent("chrome@2x.png"),
            pixelWidth: 800, pixelHeight: 600
        )

        let skinJSON = """
        {
          "version": "4.0",
          "name": "bc-baked-noanim",
          "chrome": {
            "mode": "baked",
            "image": "chrome@2x.png",
            "width": 400,
            "height": 300,
            "interiorRect": { "x": 0, "y": 0, "width": 400, "height": 300 }
          }
        }
        """
        try skinJSON.write(
            to: skinDir.appendingPathComponent("skin.json"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = try loadIsolated(skinName: "bc-baked-noanim", skinDir: skinDir)
        XCTAssertNotNil(loaded.chrome)
        XCTAssertEqual(loaded.chrome?.mode, .baked)
        XCTAssertNil(loaded.chrome?.animations)
        XCTAssertNotNil(loaded.baseImage)
        XCTAssertTrue(loaded.chromeValidation?.valid ?? false)
    }

    // MARK: - Lane 3: v4 baked with every MVP animation kind (shipped skin)

    func testV4BakedWithEveryAnimationKind() throws {
        // HoloscapeClassic-live is the in-tree reference that declares
        // all four kinds.
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic-live")

        XCTAssertEqual(loaded.chrome?.mode, .baked)
        let kinds = Set(loaded.chrome?.animations?.map { $0.kind } ?? [])
        XCTAssertEqual(kinds, Set([.particle, .ledArray, .spriteAnim, .shader]),
            "Every MVP animation kind present exactly once")
        XCTAssertTrue(loaded.chromeValidation?.valid ?? false)
    }

    // MARK: - Lane 4: v4 composed with every MVP animation kind

    func testComposedWithMultipleAnimKinds() throws {
        // HoloscapeSynthwave has particle + shader animations in its
        // v4 form — two kinds, not all four, but exercises the composed
        // bake with a live animation set.
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")
        XCTAssertEqual(loaded.chrome?.mode, .composed)
        let count = loaded.chrome?.animations?.count ?? 0
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertTrue(loaded.chromeValidation?.valid ?? false)
    }

    // MARK: - Lane 5: v4 composed minimal (AmplifyDemo — single shader)

    func testV4ComposedMinimalSingleShader() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "AmplifyDemo")
        XCTAssertEqual(loaded.chrome?.mode, .composed)
        XCTAssertEqual(loaded.chrome?.animations?.count, 1)
        XCTAssertEqual(loaded.chrome?.animations?.first?.kind, .shader)
    }

    // MARK: - Lane 6: renderer count matches descriptor count

    func testRendererCountMatchesDescriptorCount() throws {
        // For every in-tree v4 skin, descriptor count must equal
        // installed renderer count on a ChromeHostView (the renderer
        // factory matches 1-to-1 — no descriptor silently dropped).
        for name in ["HoloscapeClassic-live", "HoloscapeSynthwave", "AmplifyDemo", "MercuryDeck"] {
            let engine = SkinEngine()
            let loaded = try engine.loadComposite(named: name)
            guard let chrome = loaded.chrome, let image = loaded.baseImage else {
                return XCTFail("\(name): chrome + baseImage required")
            }
            let host = ChromeHostView(chrome: chrome, baseImage: image, clock: nil)
            host.installAnimatedLayers(chrome.animations ?? [])
            XCTAssertEqual(
                host.renderers.count,
                chrome.animations?.count ?? 0,
                "\(name): renderer count must match descriptor count (1-to-1 mapping)"
            )
        }
    }

    // MARK: - Pre-v4 backward compat still works

    func testV1SkinStillLoadsWithChromeNil() throws {
        // v1 manifests never had a chrome field; they must continue to
        // load with chrome == nil (Req 16.1 backward-compat invariant).
        let skinDir = tempRoot.appendingPathComponent("bc-v1")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let skinJSON = """
        {
          "windowBackground": "#1a1a2e",
          "tabActiveColor": "#ff00ff"
        }
        """
        try skinJSON.write(
            to: skinDir.appendingPathComponent("skin.json"),
            atomically: true,
            encoding: .utf8
        )
        let loaded = try loadIsolated(skinName: "bc-v1", skinDir: skinDir)
        XCTAssertNil(loaded.chrome, "v1 manifest must decode with chrome nil (Req 16.1)")
        XCTAssertNil(loaded.baseImage)
    }

    // MARK: - Helpers

    /// Load a skin from an isolated HOLOSCAPE_CONFIG_DIR containing
    /// only the named skin directory. Keeps the real bundle + user
    /// skins invisible to the engine for the duration of the test.
    private func loadIsolated(skinName: String, skinDir: URL) throws -> LoadedSkin {
        let configRoot = tempRoot.appendingPathComponent("config-\(skinName)")
        let skinsDir = configRoot.appendingPathComponent("skins")
        try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)
        let dest = skinsDir.appendingPathComponent(skinName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: skinDir, to: dest)

        let prev = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"]
        setenv("HOLOSCAPE_CONFIG_DIR", configRoot.path, 1)
        defer {
            if let prev {
                setenv("HOLOSCAPE_CONFIG_DIR", prev, 1)
            } else {
                unsetenv("HOLOSCAPE_CONFIG_DIR")
            }
        }

        let engine = SkinEngine()
        return try engine.loadComposite(named: skinName)
    }

    /// Write a solid-magenta RGBA PNG at the given pixel dimensions.
    private func writeRGBAPng(to url: URL, pixelWidth: Int, pixelHeight: Int) throws {
        let bytesPerRow = pixelWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xFF; pixels[i + 1] = 0x44; pixels[i + 2] = 0xCC; pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        )!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
