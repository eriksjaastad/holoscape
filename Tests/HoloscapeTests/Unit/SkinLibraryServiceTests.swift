import XCTest
@testable import Holoscape

@MainActor
final class SkinLibraryServiceTests: XCTestCase {
    private var root: URL!
    private var engine: SkinEngine!
    private var library: SkinLibraryService!

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-skin-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = SkinEngine(skinsDirectoryOverride: root, bundledSkinsDirectoryOverride: root.appendingPathComponent("bundle"))
        library = SkinLibraryService(engine: engine)
    }

    override func tearDown() async throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testStarterCreationIsDiscoverableAndLoadable() throws {
        let url = try library.create(name: "Aurora")
        XCTAssertEqual(url.lastPathComponent, "Aurora")
        XCTAssertTrue(engine.availableSkins().contains("Aurora"))
        XCTAssertEqual(engine.loadSkin(named: "Aurora")?.name, "Aurora")
        XCTAssertTrue(library.isUserManaged(name: "Aurora"))
        let manifest = try XCTUnwrap(engine.loadSkin(named: "Aurora"))
        XCTAssertEqual(manifest.surfaces?[SurfaceKey.settingsPanel.rawValue]?.corner, .uniform(14))
        XCTAssertEqual(manifest.surfaces?[SurfaceKey.inputBoxField.rawValue]?.font?.family, "SF Mono")
    }

    func testDuplicateCopiesAndRenamesManifest() throws {
        _ = try library.create(name: "Source")
        let duplicate = try library.create(name: "Copy", from: .existing("Source"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.appendingPathComponent("skin.json").path))
        XCTAssertEqual(engine.loadSkin(named: "Copy")?.name, "Copy")
    }

    func testNameValidationAndCaseInsensitiveCollision() throws {
        for invalid in ["", " ", "Default", "../escape", "a/b", "a\\b", "bad\nname"] {
            XCTAssertThrowsError(try library.create(name: invalid)) { error in
                XCTAssertEqual(error as? SkinLibraryError, .invalidName(invalid))
            }
        }
        _ = try library.create(name: "Aurora")
        XCTAssertThrowsError(try library.create(name: "aUrOrA")) { error in
            XCTAssertEqual(error as? SkinLibraryError, .duplicateName("aUrOrA"))
        }
    }

    func testInvalidSourceLeavesNoDestination() throws {
        XCTAssertThrowsError(try library.create(name: "Copy", from: .existing("Missing"))) { error in
            XCTAssertEqual(error as? SkinLibraryError, .sourceMissing("Missing"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix(".Copy.staging-") })
    }

    func testMalformedSourceIsRejectedWithoutCreatingDestination() throws {
        let source = root.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: source.appendingPathComponent("skin.json"))

        XCTAssertThrowsError(try library.create(name: "Copy", from: .existing("Broken"))) { error in
            XCTAssertEqual(error as? SkinLibraryError, .invalidSource("Broken"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
    }

    func testExistingFilesystemEntryIsNeverOverwritten() throws {
        let occupied = root.appendingPathComponent("Occupied")
        try Data("keep".utf8).write(to: occupied)

        XCTAssertThrowsError(try library.create(name: "Occupied")) { error in
            XCTAssertEqual(error as? SkinLibraryError, .duplicateName("Occupied"))
        }
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "keep")
    }

    func testDeleteRefusesDefaultBundledAndActive() throws {
        _ = try library.create(name: "Owned")
        XCTAssertThrowsError(try library.delete(name: "Owned", activeSkinName: "Owned")) { error in
            XCTAssertEqual(error as? SkinLibraryError, .activeSkin("Owned"))
        }
        XCTAssertTrue(library.isUserManaged(name: "Owned"))
        XCTAssertThrowsError(try library.delete(name: "Default", activeSkinName: nil))
        XCTAssertThrowsError(try library.delete(name: "Bundled", activeSkinName: nil))
        try library.delete(name: "Owned", activeSkinName: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Owned").path))
    }

    func testRevealReturnsResolvedDirectory() throws {
        let created = try library.create(name: "Revealable")
        XCTAssertEqual(try library.revealURL(for: "Revealable"), created)
    }
}
