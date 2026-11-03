import AppKit
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
        XCTAssertEqual(manifest.surfaces?[SurfaceKey.inputBoxField.rawValue]?.font?.family, "SF Pro")
        XCTAssertEqual(manifest.surfaces?[SurfaceKey.inputBoxField.rawValue]?.font?.size, 14)
    }

    func testStarterSkinResolvesSFProThroughProductionPipeline() throws {
        _ = try library.create(name: "Aurora")
        let loaded = try engine.loadComposite(named: "Aurora")
        defer { engine.unregisterFonts(loaded.fonts) }
        let context = SkinContext(
            surfaces: try XCTUnwrap(loaded.surfaces),
            reactive: ReactiveUniformSnapshot(),
            fontRegistry: loaded.fonts.fonts
        )

        let regular = try XCTUnwrap(context.resolvedFont(for: .inputBoxField))
        let medium = try XCTUnwrap(context.resolvedFont(for: .sessionLauncherRow))
        let semibold = try XCTUnwrap(context.resolvedFont(for: .tabBarTabActive))
        let manager = NSFontManager.shared

        XCTAssertFalse(manager.traits(of: regular).contains(.fixedPitchFontMask))
        XCTAssertEqual(regular.fontName, NSFont.systemFont(ofSize: 14, weight: .regular).fontName)
        XCTAssertEqual(manager.weight(of: medium), manager.weight(of: NSFont.systemFont(ofSize: 13, weight: .medium)))
        XCTAssertEqual(manager.weight(of: semibold), manager.weight(of: NSFont.systemFont(ofSize: 13, weight: .semibold)))
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

    func testDuplicateRejectsRootSymlinkEscapingApprovedRoots() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        let outsideSkin = outside.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: outsideSkin, withIntermediateDirectories: true)
        try Data(#"{"name":"Source","version":"2.0"}"#.utf8).write(to: outsideSkin.appendingPathComponent("skin.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Source"),
            withDestinationURL: outsideSkin
        )
        defer {
            do { try FileManager.default.removeItem(at: outside) }
            catch { XCTFail("Failed to clean outside fixture: \(error)") }
        }

        XCTAssertThrowsError(try library.create(name: "Copy", from: .existing("Source"))) { error in
            XCTAssertEqual(error as? SkinLibraryError, .unsafePath("Source"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
    }

    func testDuplicateRejectsDescendantSymlinkWithoutCopyingOutsideFile() throws {
        let source = root.appendingPathComponent("Source")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-file-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"Source","version":"2.0"}"#.utf8).write(to: source.appendingPathComponent("skin.json"))
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("secret.txt"),
            withDestinationURL: outside
        )
        defer {
            do { try FileManager.default.removeItem(at: outside) }
            catch { XCTFail("Failed to clean outside fixture: \(error)") }
        }

        XCTAssertThrowsError(try library.create(name: "Copy", from: .existing("Source"))) { error in
            XCTAssertEqual(error as? SkinLibraryError, .invalidSource("Source"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy/secret.txt").path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "secret")
    }

    func testDecodableManifestWithEscapingImagePathFailsCompleteValidationAndCleansStaging() throws {
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = """
        {"name":"Source","version":"2.0","surfaces":{"window.background":{"fill":{"kind":"image","path":"../outside.png","tile":"stretch"}}}}
        """
        try Data(manifest.utf8).write(to: source.appendingPathComponent("skin.json"))

        XCTAssertThrowsError(try library.create(name: "Copy", from: .existing("Source"))) { error in
            guard case .validationFailure = error as? SkinLibraryError else {
                return XCTFail("Expected validationFailure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix(".Copy.staging-") })
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

    func testManagementRefusesUserSkinRootSymlinkEvenWhenItStaysInsideLibrary() throws {
        let target = try library.create(name: "Target")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertFalse(library.isUserManaged(name: "Alias"))
        XCTAssertThrowsError(try library.revealURL(for: "Alias")) { error in
            XCTAssertEqual(error as? SkinLibraryError, .unsafePath("Alias"))
        }
        XCTAssertThrowsError(try library.delete(name: "Alias", activeSkinName: nil)) { error in
            XCTAssertEqual(error as? SkinLibraryError, .unsafePath("Alias"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("skin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }

    func testRevealReturnsResolvedDirectory() throws {
        let created = try library.create(name: "Revealable")
        XCTAssertEqual(try library.revealURL(for: "Revealable"), created)
    }
}
