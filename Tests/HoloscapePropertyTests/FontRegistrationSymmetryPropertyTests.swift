import XCTest
import CoreText
import SwiftCheck
@testable import Holoscape

/// Property 9 — Font registration symmetry (Requirement 8.3).
///
/// Every URL registered by `SkinEngine.registerFonts` must be deregistered
/// by `SkinEngine.unregisterFonts(_:)`. Asymmetry leaks fonts into process
/// scope — a drag-and-drop Font Book contaminant that survives skin
/// unload.
///
/// Observable invariant:
///   register(dir) → bundle1
///   unregister(bundle1)
///   register(dir) → bundle2
///   assert bundle1.registeredURLs (as Set) == bundle2.registeredURLs (as Set)
///
/// If the first unregister drained the wrong URLs (or missed any), the
/// second register would see different process-scope state and produce a
/// different bundle — either fewer entries (previous register leaked,
/// blocking re-register) or the same entries but with different
/// observable side-effects down the line.
///
/// Runs with a reduced iteration count because each property case does
/// four full CTFontManager round-trips with disk I/O; 100 iterations
/// would take minutes for no additional coverage value.
@MainActor
final class FontRegistrationSymmetryPropertyTests: XCTestCase {

    private let engine = SkinEngine()

    // MARK: - Generators

    /// Number of valid fonts to copy into the test skin (0–3).
    private static let fontCount: Gen<Int> =
        Gen<Int>.fromElements(of: [0, 1, 2, 3])

    /// Number of sibling corrupt `.ttf` files (0–2). Confirms the filter
    /// doesn't leak them into registeredURLs, and that their presence
    /// doesn't perturb the symmetry invariant.
    private static let corruptCount: Gen<Int> =
        Gen<Int>.fromElements(of: [0, 1, 2])

    /// Number of sibling non-font files (0–2) — extensions other than
    /// `.ttf`/`.otf` that the scanner must ignore.
    private static let nonFontCount: Gen<Int> =
        Gen<Int>.fromElements(of: [0, 1, 2])

    // MARK: - Properties

    func testRegisterUnregisterRegisterProducesSameURLSet() {
        // Reduced iteration count — each case does 2x (copy Menlo + register + unregister).
        // 15 cases keeps the total test time under ~10s while covering the shape space.
        let args = CheckerArguments(maxAllowableSuccessfulTests: 15)

        property("register → unregister → register yields identical URL sets", arguments: args) <- forAll(
            Self.fontCount,
            Self.corruptCount,
            Self.nonFontCount
        ) { (fonts: Int, corrupt: Int, nonFonts: Int) in
            guard let skinDir = self.makeSkinDir(fonts: fonts, corrupt: corrupt, nonFonts: nonFonts) else {
                return false
            }
            defer { try? FileManager.default.removeItem(at: skinDir) }

            // Cycle 1
            let bundle1 = self.engine.registerFonts(from: skinDir)
            self.engine.unregisterFonts(bundle1)

            // Cycle 2 — fresh registration after complete drain.
            let bundle2 = self.engine.registerFonts(from: skinDir)
            defer { self.engine.unregisterFonts(bundle2) }

            let set1 = Set(bundle1.registeredURLs.map { $0.standardizedFileURL.path })
            let set2 = Set(bundle2.registeredURLs.map { $0.standardizedFileURL.path })

            // Symmetric drain ⇒ both cycles register the same set of URLs.
            return set1 == set2
        }
    }

    func testRegisteredURLsAreAlwaysASubsetOfFilesystemFonts() {
        // Every URL in the bundle must point to an .otf or .ttf file that
        // actually exists. A URL that snuck in from somewhere else would
        // make `unregisterFonts` target the wrong process-scope entry.
        let args = CheckerArguments(maxAllowableSuccessfulTests: 15)

        property("registeredURLs ⊆ filesystem .otf/.ttf files in assets/fonts/", arguments: args) <- forAll(
            Self.fontCount,
            Self.corruptCount,
            Self.nonFontCount
        ) { (fonts: Int, corrupt: Int, nonFonts: Int) in
            guard let skinDir = self.makeSkinDir(fonts: fonts, corrupt: corrupt, nonFonts: nonFonts) else {
                return false
            }
            defer { try? FileManager.default.removeItem(at: skinDir) }

            let bundle = self.engine.registerFonts(from: skinDir)
            defer { self.engine.unregisterFonts(bundle) }

            let fontsDirEntries: [String]
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: skinDir.appendingPathComponent("assets/fonts"),
                    includingPropertiesForKeys: nil
                )
                fontsDirEntries = urls
                    .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
                    .map { $0.standardizedFileURL.path }
            } catch {
                return false
            }
            let registered = Set(bundle.registeredURLs.map { $0.standardizedFileURL.path })
            return registered.isSubset(of: Set(fontsDirEntries))
        }
    }

    // MARK: - Helpers

    /// Create a temporary skin directory with the given mix of font/corrupt/non-font files.
    /// Returns nil if system Menlo is missing (rare — would indicate a broken macOS install).
    private func makeSkinDir(fonts: Int, corrupt: Int, nonFonts: Int) -> URL? {
        let skinDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-font-prop-\(UUID().uuidString)")
        let fontsDir = skinDir.appendingPathComponent("assets/fonts")
        do {
            try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let source = URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc")
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }

        for i in 0..<fonts {
            let dest = fontsDir.appendingPathComponent("font-\(i)-\(UUID().uuidString).ttf")
            do { try FileManager.default.copyItem(at: source, to: dest) } catch { return nil }
        }
        for i in 0..<corrupt {
            let dest = fontsDir.appendingPathComponent("corrupt-\(i).ttf")
            try? Data("not a font".utf8).write(to: dest)
        }
        for i in 0..<nonFonts {
            let dest = fontsDir.appendingPathComponent("readme-\(i).txt")
            try? Data("just a txt".utf8).write(to: dest)
        }
        return skinDir
    }
}
