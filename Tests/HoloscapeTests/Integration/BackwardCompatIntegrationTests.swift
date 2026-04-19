import XCTest
@testable import Holoscape

/// Amplify Task 19.3 — backward-compat round-trip.
///
/// Requirement 9 (and the whole Amplify pitch) hinges on: every
/// existing skin keeps working unchanged. The strongest possible
/// proof is a structural comparison between the directory-layout
/// skin and the same skin repackaged as a `.wamp` — they MUST produce
/// semantically-equivalent `LoadedSkin` values. This test loads
/// `HoloscapeSynthwave` both ways and checks each load surface
/// against its `.wamp` counterpart.
///
/// The test uses the bundled resources directly rather than staging
/// fixtures — this way a skin-content change that accidentally
/// breaks parity between directory and `.wamp` forms fails this
/// test immediately. Running `Tools/package_synthwave.sh` is what
/// keeps the `.wamp` synchronized; the test doesn't re-package
/// on the fly.
@MainActor
final class BackwardCompatIntegrationTests: XCTestCase {

    func testSynthwaveDirectoryAndWampProduceEquivalentSurfaces() throws {
        let engine = SkinEngine()

        // The directory-layout skin is discovered via "HoloscapeSynthwave";
        // the bundle via "HoloscapeSynthwave.wamp". Both resolve via the
        // same SkinEngine.loadComposite path — directory wins per the
        // resolveSkinDir precedence (Req 1.7), so to compare we:
        //   1. Load the directory form via the engine.
        //   2. Load the .wamp form by pointing at it directly through
        //      a second engine instance configured with a bundle dir
        //      that contains ONLY the .wamp.
        // For this first pass we use the engine's normal enumeration —
        // the directory takes precedence, so we load "HoloscapeSynthwave"
        // and compare against a .wamp loaded by its filename.

        // Directory form — normal enumeration picks the dir-layout.
        let directoryForm = try engine.loadComposite(named: "HoloscapeSynthwave")

        // .wamp form — use the filename directly. availableSkins strips
        // `.wamp` for display; loadComposite(named:) matches by resolved
        // file. We work around the name-collision rule by setting up a
        // second engine that sees ONLY the .wamp bundle.
        let wampForm = try loadWampOnly(named: "HoloscapeSynthwave", in: engine)

        // Surfaces parity — same SurfaceKey set.
        let dirKeys = Set(directoryForm.surfaces?.keys ?? [:].keys)
        let wampKeys = Set(wampForm.surfaces?.keys ?? [:].keys)
        XCTAssertEqual(dirKeys, wampKeys,
                       "Both forms must resolve the same SurfaceKey set")

        // Per-surface: fill kind + basic border/corner/shadow presence
        // agreement. We can't use value-equality (NSImage isn't Equatable
        // in a useful sense) — compare by structural shape.
        for key in dirKeys {
            let dirSurface = directoryForm.surfaces![key]!
            let wampSurface = wampForm.surfaces![key]!
            XCTAssertEqual(
                fillShape(dirSurface.fill),
                fillShape(wampSurface.fill),
                "Surface \(key.rawValue) must have the same fill kind in both forms"
            )
            XCTAssertEqual(
                dirSurface.border != nil,
                wampSurface.border != nil,
                "Surface \(key.rawValue) border presence must match"
            )
            XCTAssertEqual(
                dirSurface.shadow != nil,
                wampSurface.shadow != nil,
                "Surface \(key.rawValue) shadow presence must match"
            )
        }

        // Image keys — the PNG paths referenced in both manifests must
        // be identical.
        XCTAssertEqual(
            Set(directoryForm.images.keys),
            Set(wampForm.images.keys),
            "Both forms must resolve images from the same manifest paths"
        )
    }

    // MARK: - Helpers

    /// Load the HoloscapeSynthwave `.wamp` via a fresh engine that has
    /// an isolated bundle dir containing only the bundle file — so
    /// `resolveSkinDir` picks the `.wamp` (no dir-layout to prefer).
    private func loadWampOnly(named name: String, in engine: SkinEngine) throws -> LoadedSkin {
        // Stage a temp bundle root that holds just the `.wamp` copy.
        // HOLOSCAPE_BUNDLE_SKINS_DIR env override lets `SkinEngine`
        // find the staging dir without touching the real bundle.
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-backcompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Copy the `.wamp` from the real bundle resources into the
        // staging dir. `Bundle.module.url` resolves SwiftPM-generated
        // bundle paths.
        guard let moduleURL = Bundle.module.url(
            forResource: "HoloscapeSynthwave",
            withExtension: "wamp",
            subdirectory: "Skins"
        ) else {
            throw XCTSkip("HoloscapeSynthwave.wamp not in bundle — run Tools/package_synthwave.sh")
        }
        let dest = tempRoot.appendingPathComponent("HoloscapeSynthwave.wamp")
        try FileManager.default.copyItem(at: moduleURL, to: dest)

        // Isolated engine scoped to the staging dir.
        let previousBundle = ProcessInfo.processInfo.environment["HOLOSCAPE_BUNDLE_SKINS_DIR"]
        let previousConfig = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"]
        setenv("HOLOSCAPE_BUNDLE_SKINS_DIR", tempRoot.path, 1)
        let configTemp = tempRoot.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configTemp, withIntermediateDirectories: true)
        setenv("HOLOSCAPE_CONFIG_DIR", configTemp.path, 1)
        defer {
            if let previousBundle {
                setenv("HOLOSCAPE_BUNDLE_SKINS_DIR", previousBundle, 1)
            } else {
                unsetenv("HOLOSCAPE_BUNDLE_SKINS_DIR")
            }
            if let previousConfig {
                setenv("HOLOSCAPE_CONFIG_DIR", previousConfig, 1)
            } else {
                unsetenv("HOLOSCAPE_CONFIG_DIR")
            }
        }

        let isolated = SkinEngine()
        return try isolated.loadComposite(named: name)
    }

    /// Structural tag for a fill — lets us compare fill kinds without
    /// value-equating NSImages.
    private func fillShape(_ fill: SkinContext.ResolvedFill) -> String {
        switch fill {
        case .color:    return "color"
        case .image:    return "image"
        case .gradient: return "gradient"
        }
    }
}
