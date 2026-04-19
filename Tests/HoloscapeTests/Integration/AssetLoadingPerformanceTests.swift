import XCTest
@testable import Holoscape

/// Task 15.3 — asset-loading sync + size bounds (Requirement 15.3).
///
/// Two invariants:
///
/// 1. **Synchronous.** `SkinEngine.loadComposite(named:)` finishes its
///    work (manifest parse, image decode, ninepatch sidecar load, font
///    registration, surface conversion) before returning — no
///    background completion, no callback. This matters because
///    `MainWindowController.applySkin(_:)` is called on the main actor
///    and expects a ready-to-paint `LoadedSkin`; an async loader would
///    require flight-of-stairs plumbing for a marginal gain.
///
/// 2. **Bounded size.** Total on-disk asset size for a bundled skin
///    must stay under 10 MB. Skin bundles that ship images + fonts and
///    push past this ceiling create memory pressure the density-mode
///    contract won't save us from — `.minimal` skips images at render
///    time but they're still decoded. Bound the on-disk footprint and
///    the in-memory footprint follows.
///
/// Both checks run against the shipped `HoloscapeSynthwave` reference
/// skin, loaded via the same Bundle.module path production uses.
@MainActor
final class AssetLoadingPerformanceTests: XCTestCase {

    /// Size ceiling from Requirement 15.3. 10 MB is chosen because
    /// the current reference skin is ~1 KB of PNG + 1 KB of JSON —
    /// a 10,000× headroom that flags genuine bloat without gating
    /// legitimate artwork.
    private static let maxAssetBytes: Int = 10 * 1024 * 1024

    /// 100ms budget for the synchronous load. Ref skin loads in ~10ms
    /// on this machine; 100ms is the "feels instant" threshold that
    /// also serves as a proxy for "no background handoff happened."
    private static let syncBudget: TimeInterval = 0.100

    func testReferenceSkinLoadsSynchronouslyWithinBudget() throws {
        let engine = SkinEngine()
        // If the reference skin folder isn't available (dev environment
        // where bundled resources weren't processed), skip rather than
        // fail — this test pins behavior, it doesn't build the skin.
        guard engine.availableSkins().contains("HoloscapeSynthwave") else {
            throw XCTSkip("HoloscapeSynthwave not present in Bundle.module — run `swift build` first")
        }

        let start = CACurrentMediaTime()
        let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")
        let elapsed = CACurrentMediaTime() - start

        // Returning synchronously with a populated payload proves no
        // async handoff: a real background loader would return an empty
        // or partial payload here.
        XCTAssertNotNil(loaded.surfaces, "Reference skin must resolve at least one surface synchronously")
        XCTAssertFalse(loaded.images.isEmpty,
                       "Reference skin ships a ninepatch PNG — images must be decoded before return")

        XCTAssertLessThan(elapsed, Self.syncBudget,
                          "loadComposite took \(elapsed * 1000)ms; budget is \(Self.syncBudget * 1000)ms")
    }

    func testReferenceSkinAssetsStayUnderSizeBound() throws {
        // Bundle.module resolves to the Holoscape_Holoscape.bundle inside
        // .build; `Resources/Skins/HoloscapeSynthwave` is the tree.
        // Bundle.module.resourceURL points at the bundle's resource root;
        // `Skins/HoloscapeSynthwave` lives directly under it because
        // Package.swift uses `.copy` (not `.process`, which would flatten).
        guard let root = Bundle.module.resourceURL?
            .appendingPathComponent("Skins/HoloscapeSynthwave") else {
            throw XCTSkip("Bundle.module.resourceURL unavailable in test harness")
        }
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("HoloscapeSynthwave not staged in module bundle — run `swift build` first")
        }

        let totalBytes = try totalSize(of: root)
        XCTAssertGreaterThan(totalBytes, 0, "Reference skin directory exists but is empty")
        XCTAssertLessThanOrEqual(totalBytes, Self.maxAssetBytes,
                                 "HoloscapeSynthwave asset tree is \(totalBytes) bytes; cap is \(Self.maxAssetBytes) (10 MB)")
    }

    // MARK: - Helpers

    /// Recursive directory size. Skips directories (size is reported as
    /// block-count by FileManager, which misleads on APFS); sums regular
    /// files only.
    private func totalSize(of root: URL) throws -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }

        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            total += size
        }
        return total
    }
}
