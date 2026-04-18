import XCTest
import CoreText
@testable import Holoscape

/// Task 8.4 — `SkinEngine.registerFonts(from:)` and `unregisterFonts(_:)`:
///   - Missing `assets/fonts/` returns empty (not an error)
///   - Valid `.otf` / `.ttf` files register at process scope and appear
///     in the returned bundle keyed by PostScript name
///   - Corrupt files are skipped, siblings still load
///   - Unregister drains every URL and the font is no longer resolvable
///
/// Uses the macOS built-in font `Menlo-Regular.ttc` as source material —
/// copied to a temp skin so CoreText sees an unregistered URL each run.
@MainActor
final class SkinEngineFontRegistrationTests: XCTestCase {

    private var skinDir: URL!
    private var fontsDir: URL!
    private let engine = SkinEngine()

    override func setUpWithError() throws {
        try super.setUpWithError()
        skinDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-font-test-\(UUID().uuidString)")
        fontsDir = skinDir.appendingPathComponent("assets/fonts")
        try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: skinDir)
        try super.tearDownWithError()
    }

    // MARK: - Absent directory

    func testReturnsEmptyWhenNoFontsDirectory() {
        // Fresh dir with no assets/fonts/ subdirectory
        let freshSkin = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-font-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: freshSkin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: freshSkin) }

        let bundle = engine.registerFonts(from: freshSkin)
        defer { engine.unregisterFonts(bundle) }

        XCTAssertEqual(bundle.fonts.count, 0)
        XCTAssertEqual(bundle.registeredURLs.count, 0)
    }

    // MARK: - Happy path

    func testRegistersValidTTF() throws {
        let source = try XCTUnwrap(copyMenloToFontsDir())
        let bundle = engine.registerFonts(from: skinDir)
        defer { engine.unregisterFonts(bundle) }

        // macOS symlinks `/var` → `/private/var` — compare standardized paths.
        let registered = bundle.registeredURLs.map { $0.standardizedFileURL.path }
        XCTAssertEqual(registered, [source.standardizedFileURL.path],
                       "Registered URL list must match what we wrote to disk")
        XCTAssertFalse(bundle.fonts.isEmpty,
                       "At least one PostScript-named entry expected from Menlo")
    }

    // MARK: - Corrupt file

    func testSkipsCorruptFileButContinues() throws {
        // Write a bogus ttf next to a valid one. The bogus one must be
        // skipped; the valid one must still register.
        let bogus = fontsDir.appendingPathComponent("corrupt.ttf")
        try Data("not a real font".utf8).write(to: bogus)
        let realFont = try XCTUnwrap(copyMenloToFontsDir())

        let bundle = engine.registerFonts(from: skinDir)
        defer { engine.unregisterFonts(bundle) }

        let registered = Set(bundle.registeredURLs.map { $0.standardizedFileURL.path })
        XCTAssertFalse(registered.contains(bogus.standardizedFileURL.path),
                       "Corrupt file must not appear in the registered list")
        XCTAssertTrue(registered.contains(realFont.standardizedFileURL.path),
                      "Sibling valid font must still register")
    }

    // MARK: - Extension filtering

    func testIgnoresNonFontFiles() throws {
        try Data("readme".utf8).write(to: fontsDir.appendingPathComponent("README.txt"))
        try Data("png".utf8).write(to: fontsDir.appendingPathComponent("not-a-font.png"))

        let bundle = engine.registerFonts(from: skinDir)
        XCTAssertEqual(bundle.registeredURLs.count, 0,
                       "Non .otf/.ttf files must be ignored by the scan")
    }

    // MARK: - Duplicate PostScript names

    func testDuplicatePostScriptNameLastWins() throws {
        // Two copies of the same font under different filenames both decode
        // to the same PostScript name. Both must land in `registeredURLs`
        // (both were really registered at process scope, so both must be
        // drained on unload), but the `fonts` map holds one entry only.
        let first = try XCTUnwrap(copyMenloToFontsDir())
        let second = try XCTUnwrap(copyMenloToFontsDir())

        let bundle = engine.registerFonts(from: skinDir)
        defer { engine.unregisterFonts(bundle) }

        let paths = Set(bundle.registeredURLs.map { $0.standardizedFileURL.path })
        XCTAssertTrue(paths.contains(first.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(second.standardizedFileURL.path))
        XCTAssertEqual(bundle.fonts.count, 1,
                       "Duplicate PostScript names collapse to one fonts-map entry (last wins)")
    }

    // MARK: - Unregister

    func testUnregisterDrainsAllURLs() throws {
        _ = try XCTUnwrap(copyMenloToFontsDir())
        let bundle = engine.registerFonts(from: skinDir)
        XCTAssertFalse(bundle.registeredURLs.isEmpty)

        engine.unregisterFonts(bundle)

        // Re-registering the same URL after unregister must succeed.
        // If the first unregister didn't drain, the second register
        // would fail with "already registered".
        let reregistered = engine.registerFonts(from: skinDir)
        defer { engine.unregisterFonts(reregistered) }
        XCTAssertFalse(reregistered.registeredURLs.isEmpty,
                       "Re-register after unregister must succeed — proves the first unregister drained process scope")
    }

    // MARK: - Helpers

    /// Copy the system Menlo-Regular.ttc into the skin's fonts directory
    /// with a unique name per test run so CoreText sees an unregistered
    /// URL. Menlo ships as `.ttc` (collection); we rename to `.ttf` so
    /// the extension filter picks it up. CoreText accepts collections
    /// through the `.ttf` extension.
    private func copyMenloToFontsDir() -> URL? {
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc")
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        let dest = fontsDir.appendingPathComponent("test-menlo-\(UUID().uuidString).ttf")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
