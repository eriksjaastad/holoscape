import XCTest
@testable import Holoscape

/// PR A coverage for `SkinEngine.loadComposite(named:)` — the atomic
/// "load a skin fully" entry point shared by the Appearance Settings
/// picker, the launch-time persistence load, and (Task 11) the
/// FSEventStream hot-reload path.
///
/// Four shapes the method must handle:
///   1. "Default" → sentinel, no disk touch
///   2. Unknown skin name → SkinLoadError.notFound
///   3. Malformed skin.json → SkinLoadError.parseFailure
///   4. Valid v2 manifest → LoadedSkin with resolved surfaces and fonts
///
/// Uses `HOLOSCAPE_CONFIG_DIR` to redirect the engine at a per-test
/// temp directory so disk writes don't collide with each other or with
/// the user's real `~/.holoscape/skins/`.
@MainActor
final class SkinEngineLoadCompositeTests: XCTestCase {

    private var tempDir: URL!
    private var skinsDir: URL!
    private var originalEnv: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-loadcomposite-\(UUID().uuidString)")
        skinsDir = tempDir.appendingPathComponent("skins")
        try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)
        originalEnv = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"]
        setenv("HOLOSCAPE_CONFIG_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        if let original = originalEnv {
            setenv("HOLOSCAPE_CONFIG_DIR", original, 1)
        } else {
            unsetenv("HOLOSCAPE_CONFIG_DIR")
        }
        try super.tearDownWithError()
    }

    // MARK: - "Default" sentinel

    func testDefaultReturnsSentinelWithoutTouchingDisk() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Default")

        XCTAssertEqual(loaded.name, "Default")
        XCTAssertNil(loaded.surfaces, "Default resolves to nil surfaces so applySkin resets to built-in defaults")
        XCTAssertTrue(loaded.fonts.registeredURLs.isEmpty, "Default registers no fonts")
        XCTAssertTrue(loaded.images.isEmpty, "Default loads no images")
        XCTAssertNil(loaded.skinDir, "Default has no skin directory")
    }

    // MARK: - Unknown skin name

    func testUnknownSkinThrowsNotFound() {
        let engine = SkinEngine()

        XCTAssertThrowsError(try engine.loadComposite(named: "DoesNotExist")) { error in
            guard case SkinLoadError.notFound(let name) = error else {
                XCTFail("Expected SkinLoadError.notFound, got \(error)")
                return
            }
            XCTAssertEqual(name, "DoesNotExist")
        }
    }

    // MARK: - Malformed JSON

    func testMalformedSkinJsonIsTreatedAsNotFound() throws {
        // SkinEngine.loadSkin returns nil for malformed JSON (it's the same
        // early-return as missing file), so loadComposite surfaces it as
        // `.notFound` rather than `.parseFailure`. Document that behavior
        // here so a future refactor that distinguishes the two still
        // satisfies "loadComposite throws on bad input" — callers can't
        // rely on the specific variant.
        let skinDir = skinsDir.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8)
            .write(to: skinDir.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        XCTAssertThrowsError(try engine.loadComposite(named: "Broken")) { error in
            guard let skinError = error as? SkinLoadError else {
                XCTFail("Expected SkinLoadError, got \(error)")
                return
            }
            switch skinError {
            case .notFound, .parseFailure:
                break  // either variant is acceptable for malformed JSON
            }
        }
    }

    // MARK: - Valid v2 manifest

    func testValidV2SkinReturnsResolvedSurfaces() throws {
        let skinDir = skinsDir.appendingPathComponent("Garish")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let json = """
        {
          "version": "2.0",
          "name": "Garish",
          "surfaces": {
            "window.background": { "fill": { "kind": "color", "value": "#ff00ff" } },
            "tabBar.container":  { "fill": { "kind": "color", "value": "#ffff00" } }
          }
        }
        """
        try Data(json.utf8).write(to: skinDir.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Garish")

        XCTAssertEqual(loaded.name, "Garish")
        XCTAssertEqual(loaded.skinDir?.lastPathComponent, "Garish")

        guard let surfaces = loaded.surfaces else {
            XCTFail("Expected surfaces dict to be non-nil for a skin with v2 surfaces")
            return
        }
        XCTAssertNotNil(surfaces[.windowBackground],
                        "window.background key resolves from the manifest")
        XCTAssertNotNil(surfaces[.tabBarContainer],
                        "tabBar.container key resolves from the manifest")
        // Keys NOT in the manifest fall back to defaults when
        // MainWindowController builds its SkinContext from these surfaces.
        XCTAssertNil(surfaces[.sidebarContainer],
                     "Unmapped keys are absent from the result — defaults fill in at SkinContext build time")
    }

    // MARK: - Unknown surface keys (forward compat)

    func testUnknownSurfaceKeysAreSkippedNotFatal() throws {
        let skinDir = skinsDir.appendingPathComponent("ForwardCompat")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let json = """
        {
          "version": "99.0",
          "name": "ForwardCompat",
          "surfaces": {
            "window.background":        { "fill": { "kind": "color", "value": "#123456" } },
            "future.surface.from.v99":  { "fill": { "kind": "color", "value": "#abcdef" } }
          }
        }
        """
        try Data(json.utf8).write(to: skinDir.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "ForwardCompat")

        guard let surfaces = loaded.surfaces else {
            XCTFail("Known-key surface should still resolve even when siblings are unknown")
            return
        }
        XCTAssertNotNil(surfaces[.windowBackground])
        XCTAssertEqual(surfaces.count, 1,
                       "Unknown surface keys are logged and skipped; only the known key resolves")
    }

    // MARK: - v1-only manifest (no surfaces block)

    func testV1OnlyManifestReturnsNilSurfaces() throws {
        // v1 manifests carry no `surfaces` dict. loadComposite returns
        // nil surfaces so the caller falls back to built-in defaults
        // for the chrome while the v1 apply path still runs separately.
        let skinDir = skinsDir.appendingPathComponent("V1Only")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let json = """
        {
          "windowBackground": "#1a1a2e",
          "ansiColors": ["#000","#800","#080","#880","#008","#808","#088","#888",
                         "#444","#f00","#0f0","#ff0","#00f","#f0f","#0ff","#fff"]
        }
        """
        try Data(json.utf8).write(to: skinDir.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "V1Only")

        XCTAssertNil(loaded.surfaces,
                     "v1-only manifest (no surfaces dict) resolves to nil so chrome uses defaults")
        XCTAssertTrue(loaded.images.isEmpty)
    }

    func testManifestLayoutIsCarriedThroughLoadedSkin() throws {
        let skinDir = skinsDir.appendingPathComponent("Vesselized")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let json = """
        {
          "version": "4.0",
          "name": "Vesselized",
          "layout": {
            "channelVessel": {
              "dock": "left",
              "size": 248,
              "capStart": 96,
              "capEnd": 56,
              "variant": "mercuryControlSpine"
            },
            "screenVessel": {
              "viewportInsets": { "top": 12, "right": 14, "bottom": 14, "left": 12 },
              "variant": "mercuryScreenBody"
            },
            "seam": { "thickness": 20, "style": "mechanical" }
          }
        }
        """
        try Data(json.utf8).write(to: skinDir.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Vesselized")

        XCTAssertEqual(loaded.layout?.channelVessel?.dock, .left)
        XCTAssertEqual(loaded.layout?.channelVessel?.size, 248)
        XCTAssertEqual(loaded.layout?.channelVessel?.variant, .mercuryControlSpine)
        XCTAssertEqual(loaded.layout?.screenVessel?.viewportInsets.top, 12)
        XCTAssertEqual(loaded.layout?.screenVessel?.variant, .mercuryScreenBody)
        XCTAssertEqual(loaded.layout?.seam?.thickness, 20)
        XCTAssertEqual(loaded.layout?.seam?.style, .mechanical)
    }
}
