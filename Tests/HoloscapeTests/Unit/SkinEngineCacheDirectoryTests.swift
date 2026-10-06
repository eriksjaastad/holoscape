import XCTest
@testable import Holoscape

@MainActor
final class SkinEngineCacheDirectoryTests: XCTestCase {
    private var tempConfigDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempConfigDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-cache-directory-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempConfigDirectory.appendingPathComponent("skins"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempConfigDirectory)
        try await super.tearDown()
    }

    func testConstructionWithoutUserCacheDirectoryKeepsDefaultTerminalUsable() throws {
        let engine = SkinEngine(
            skinsDirectoryOverride: tempConfigDirectory.appendingPathComponent("skins"),
            cacheDirectoryProvider: { nil }
        )

        let loaded = try engine.loadComposite(named: "Default")

        XCTAssertNil(loaded.surfaces)
        XCTAssertNil(loaded.skinDir)
        XCTAssertNil(engine.bakePipeline.cacheRoot)
    }

    func testWampLoadWithoutUserCacheDirectoryReportsTypedFailure() throws {
        let bundleURL = tempConfigDirectory
            .appendingPathComponent("skins")
            .appendingPathComponent("UnavailableCache.wamp")
        try Data("not read before cache validation".utf8).write(to: bundleURL)
        let engine = SkinEngine(
            skinsDirectoryOverride: tempConfigDirectory.appendingPathComponent("skins"),
            cacheDirectoryProvider: { nil }
        )

        XCTAssertThrowsError(try engine.loadComposite(named: "UnavailableCache")) { error in
            XCTAssertEqual(error as? SkinLoadError, .cacheDirectoryUnavailable)
        }
    }

    func testMalformedWampWithAvailableCachePreservesNotFoundContract() throws {
        let bundleURL = tempConfigDirectory
            .appendingPathComponent("skins")
            .appendingPathComponent("Malformed.wamp")
        try Data("not a zip".utf8).write(to: bundleURL)
        let cacheDirectory = tempConfigDirectory.appendingPathComponent("cache")
        let engine = SkinEngine(
            skinsDirectoryOverride: tempConfigDirectory.appendingPathComponent("skins"),
            cacheDirectoryProvider: { cacheDirectory }
        )

        XCTAssertThrowsError(try engine.loadComposite(named: "Malformed")) { error in
            XCTAssertEqual(error as? SkinLoadError, .notFound("Malformed"))
        }
    }

    func testMalformedUserWampFallsThroughToBundledDirectorySkin() throws {
        let skinName = "BundledFallback"
        let userBundleURL = tempConfigDirectory
            .appendingPathComponent("skins")
            .appendingPathComponent("\(skinName).wamp")
        try Data("not a zip".utf8).write(to: userBundleURL)

        let bundledRoot = tempConfigDirectory.appendingPathComponent("bundled")
        let bundledSkin = bundledRoot.appendingPathComponent(skinName)
        try FileManager.default.createDirectory(at: bundledSkin, withIntermediateDirectories: true)
        try Data(#"{"version":"3.0","name":"BundledFallback"}"#.utf8)
            .write(to: bundledSkin.appendingPathComponent("skin.json"))

        let engine = SkinEngine(
            skinsDirectoryOverride: tempConfigDirectory.appendingPathComponent("skins"),
            bundledSkinsDirectoryOverride: bundledRoot,
            cacheDirectoryProvider: { tempConfigDirectory.appendingPathComponent("cache") }
        )

        let loaded = try engine.loadComposite(named: skinName)

        XCTAssertEqual(loaded.skinDir?.path, bundledSkin.path)
    }
}
