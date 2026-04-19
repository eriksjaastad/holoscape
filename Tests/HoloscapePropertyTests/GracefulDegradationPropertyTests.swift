import XCTest
@testable import Holoscape

/// Amplify Task 21.8 — Property 13 — Graceful degradation.
///
/// Requirement 13 guarantees that a broken skin degrades rather than
/// bricks Holoscape. Each fault class has a different expected
/// behavior; the invariant across all of them is that `loadComposite`
/// either (a) returns a well-formed `LoadedSkin` with the offending
/// field zeroed/pruned and the rest intact, or (b) throws a typed
/// `SkinLoadError` — never crashes, never returns a half-initialized
/// value.
///
/// This file pins each fault class at the engine load boundary. Fault
/// injection uses filesystem fixtures rather than mocks so the test
/// exercises the real decode/validate pipeline end-to-end.
///
/// Per-class tests rather than a single SwiftCheck property: the
/// shape-space that matters here is the fault *class*, not random
/// variation within it. A SwiftCheck generator over corruption
/// points wouldn't exercise additional code paths.
@MainActor
final class GracefulDegradationPropertyTests: XCTestCase {

    private var tempDir: URL!
    private var skinsDir: URL!
    private var skinDir: URL!
    private var originalEnv: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-degrade-\(UUID().uuidString)")
        skinsDir = tempDir.appendingPathComponent("skins")
        skinDir = skinsDir.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)

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

    // MARK: - Class A — manifest parse failure (Req 13.1)

    /// Malformed JSON in `skin.json` must cause `loadComposite` to
    /// throw `.notFound` (the engine-visible signal that the skin
    /// isn't usable). `loadSkin` returns nil on decode failure; the
    /// composite load's `.notFound` wraps that — callers drop the skin
    /// from the picker and keep the previously-active context.
    func testMalformedManifestThrowsNotFound() throws {
        try writeManifest("{ this is not json")
        let engine = SkinEngine()
        XCTAssertThrowsError(try engine.loadComposite(named: "Broken")) { error in
            guard case .notFound = error as? SkinLoadError else {
                XCTFail("Expected SkinLoadError.notFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Class B — missing asset (Req 13.4)

    /// An `image` fill whose path doesn't exist on disk must be
    /// logged-and-skipped: the composite still loads, but the image
    /// doesn't appear in the image cache. The surface's fill is still
    /// resolvable via `SkinContext.convert`'s fallback path (renders
    /// as the built-in default color).
    ///
    /// This covers the Req 13.4 spirit without requiring a running
    /// chrome view — we assert at the `LoadedSkin.images` level that
    /// the missing asset dropped out, not the rendered-pixel level.
    func testMissingImageAssetLoadsCompositeWithoutIt() throws {
        try writeManifest("""
        {
          "version": "2.0",
          "name": "Broken",
          "surfaces": {
            "sidebar.container": {
              "fill": { "kind": "image", "path": "assets/missing.png", "tile": "stretch" }
            }
          }
        }
        """)
        // No assets/ directory or file — deliberately.

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Broken")
        XCTAssertNil(loaded.images["assets/missing.png"],
                     "Missing asset must not appear in images map")
        // Still surfaces — the SurfaceKey entry exists (SkinContext.convert
        // writes a fallback ResolvedSurface when the image isn't cached).
        XCTAssertNotNil(loaded.surfaces?[.sidebarContainer],
                        "Surface with missing asset must still produce a ResolvedSurface — degradation, not failure")
    }

    // MARK: - Class C — asset-path escape (Req 13.4, strict class)

    /// A manifest that references an absolute asset path must produce
    /// a hard load failure (not silent skip). The string gate on asset
    /// paths is not a "log and continue" rule — it's a sandbox breach
    /// signal, which propagates as `parseFailure` wrapping the
    /// underlying `invalidPath`.
    func testAbsoluteAssetPathFailsParse() throws {
        try writeManifest("""
        {
          "version": "2.0",
          "name": "Broken",
          "surfaces": {
            "window.background": {
              "fill": { "kind": "image", "path": "/etc/shadow", "tile": "stretch" }
            }
          }
        }
        """)

        let engine = SkinEngine()
        XCTAssertThrowsError(try engine.loadComposite(named: "Broken")) { error in
            guard case .parseFailure = error as? SkinLoadError else {
                XCTFail("Expected SkinLoadError.parseFailure wrapping invalidPath, got \(error)")
                return
            }
        }
    }

    // MARK: - Class D — malformed dragRegions descriptor (Req 13.5)

    /// A `dragRegions` descriptor whose polygon has fewer than 3
    /// vertices must be pruned. If pruning leaves a descriptor with
    /// zero valid polygons, the whole descriptor is dropped — but
    /// other well-formed descriptors in the array survive.
    ///
    /// Invariant: valid descriptors always survive any
    /// companion-descriptor malformation.
    func testMalformedDragRegionIsPrunedOthersSurvive() throws {
        try writeManifest("""
        {
          "version": "3.0",
          "name": "Broken",
          "dragRegions": [
            { "polygons": [ { "points": [ {"x":0,"y":0}, {"x":10,"y":0} ] } ] },
            { "polygons": [ { "points": [
                {"x":0,"y":0}, {"x":100,"y":0}, {"x":100,"y":100}, {"x":0,"y":100}
            ] } ] }
          ]
        }
        """)

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Broken")

        // Descriptor 0 has a 2-vertex polygon — pruned to empty, dropped.
        // Descriptor 1 is a valid 4-vertex polygon — survives.
        XCTAssertEqual(loaded.dragRegions.count, 1,
                       "Malformed drag-region descriptor must be dropped; valid ones survive")
        XCTAssertEqual(loaded.dragRegions.first?.polygons.first?.points.count, 4,
                       "Surviving descriptor must be the 4-vertex polygon, not the pruned one")
    }

    // MARK: - Class E — invalid windowShape (Req 13.2)

    /// A `windowShape` with kind `.mask` is MVP-rejected at validate
    /// time; Holoscape falls back to a rectangular window with a
    /// banner message. `validationBannerReason` is the engine's
    /// surface for that — non-nil when the shape failed.
    ///
    /// Also verifies the companion invariant: other fields (fills,
    /// surfaces) still apply when the shape is rejected. The shape
    /// failure is partial, not total.
    func testMaskShapeIsRejectedWithBannerAndOtherSurfacesApply() throws {
        // Set the feature flag on so the validate-time check runs
        // (otherwise `resolveWindowShape` returns (nil, nil) silently).
        setenv("HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS", "1", 1)
        defer { unsetenv("HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS") }

        try writeManifest("""
        {
          "version": "3.0",
          "name": "Broken",
          "windowShape": { "kind": "mask", "maskPath": "assets/shape.png" },
          "surfaces": {
            "tabBar.container": { "fill": { "kind": "color", "value": "#112233" } }
          }
        }
        """)

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Broken")

        XCTAssertNil(loaded.windowShape,
                     "kind: mask is post-MVP and must be rejected")
        XCTAssertNotNil(loaded.validationBannerReason,
                        "Shape rejection must surface via validationBannerReason for the chrome banner")
        XCTAssertNotNil(loaded.surfaces?[.tabBarContainer],
                        "Unrelated surfaces must still apply when the shape is rejected")
    }

    // MARK: - Class F — unknown SurfaceKey (Req 13 spirit)

    /// Future-compat: a manifest with a surface key the current build
    /// doesn't recognize must load cleanly, skipping the unknown entry
    /// with a log line. v3 manifests targeting a future SurfaceKey
    /// must not brick older builds.
    func testUnknownSurfaceKeyIsIgnored() throws {
        try writeManifest("""
        {
          "version": "3.0",
          "name": "Broken",
          "surfaces": {
            "tabBar.container": { "fill": { "kind": "color", "value": "#112233" } },
            "someFuture.surface.notInThisBuild": { "fill": { "kind": "color", "value": "#445566" } }
          }
        }
        """)

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "Broken")

        XCTAssertNotNil(loaded.surfaces?[.tabBarContainer],
                        "Known surface keys must resolve normally")
        XCTAssertEqual(loaded.surfaces?.count, 1,
                       "Unknown surface keys must be dropped from the resolved map")
    }

    // MARK: - Helpers

    private func writeManifest(_ json: String) throws {
        try Data(json.utf8).write(to: skinDir.appendingPathComponent("skin.json"))
    }
}
