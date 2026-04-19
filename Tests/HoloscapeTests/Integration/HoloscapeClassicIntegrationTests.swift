import XCTest
@testable import Holoscape

/// Amplify Task 19.4 — integration checkpoint for the shipped
/// HoloscapeClassic skin. Proves the bundled skin actually uses
/// the v3 runtime extensions the engine ships; without it, the
/// skin could regress to a v2-equivalent manifest and nobody
/// would notice.
///
/// Features verified here:
///   - `windowShape` is resolved (polygon-validation path)
///   - At least one surface carries a sprite descriptor AND the
///     descriptor passes `isValid(imageSize:)` against the loaded
///     PNG (sprite path, Task 11)
///   - Border / corner / shadow are applied on at least one surface
///     (chrome decoration path, Task 15)
///   - Both sprite-backing PNGs resolve into the image cache
///     (asset pipeline path)
///
/// Two features the parent spec listed are NOT exercised here
/// because HoloscapeClassic doesn't declare them:
///   - Drag regions — HoloscapeClassic relies on the Req 4.6
///     whole-window drag fallback (WindowDragOverlay from PR #136).
///     Explicit drag-region authoring is covered by the Task 9
///     unit + integration tests on synthetic skins.
///   - Font consumption — HoloscapeClassic uses the system mono
///     font. FontDescriptor parsing + CTFontManager registration
///     are covered by HoloscapeSynthwave's test suite + Task 13
///     property tests.
@MainActor
final class HoloscapeClassicIntegrationTests: XCTestCase {

    func testClassicSkinExercisesAmplifyFeatures() throws {
        // Feature flag ON — shape validation only runs when the env
        // flag is set per Req 2.8. Without this, `windowShape` would
        // come back as nil even if the manifest declares polygons.
        setenv("HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS", "1", 1)
        defer { unsetenv("HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS") }

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic")

        // 1. Shape applied — polygon validation ran and produced a
        //    non-nil ResolvedWindowShape.
        XCTAssertNotNil(loaded.windowShape,
                        "HoloscapeClassic declares windowShape.polygons; ResolvedWindowShape must be non-nil")
        if let shape = loaded.windowShape {
            guard case .polygons(let polys) = shape.kind else {
                XCTFail("Expected .polygons kind; got \(shape.kind)")
                return
            }
            XCTAssertGreaterThanOrEqual(polys.count, 1,
                                        "Shape must contain at least one polygon")
            XCTAssertGreaterThan(shape.nominalSize.width, 0,
                                 "nominalSize.width > 0 lets the scale helper work")
            XCTAssertGreaterThan(shape.nominalSize.height, 0)
        }

        // 2. At least one sprite surface resolved. The sprite
        //    descriptor survives through the Codable round-trip on
        //    `FillDescriptor.image(…, sprite: …)`; LoadedSkin exposes
        //    the resolved ResolvedSurface map we can walk.
        let surfaces = try XCTUnwrap(loaded.surfaces, "HoloscapeClassic must publish resolved surfaces")
        var sawSprite = false
        for surface in surfaces.values {
            if case .image(let image, _, _, let spriteOpt) = surface.fill,
               let sprite = spriteOpt {
                sawSprite = true
                // Task 11.2 — the sprite engine validates cell bounds
                // at load time. If a cell runs past the image, the
                // descriptor is dropped and the fill falls back to
                // stretch. Asserting isValid here catches a regression
                // where the PNG is regenerated at a wrong size but
                // the descriptor silently falls back to stretch mode.
                XCTAssertTrue(sprite.isValid(imageSize: image.size),
                              "SpriteDescriptor must pass isValid(imageSize:) against the loaded PNG — otherwise the engine silently drops the sprite and falls back to stretch")
            }
        }
        XCTAssertTrue(sawSprite,
                      "At least one surface must carry a sprite descriptor (Task 11 — sprite-sheet fills)")

        // 3. Border / shadow applied on at least one surface, OR a
        //    non-default corner radius on at least one. `corner` is
        //    non-optional (`.uniform(0)` = no rounding), so we check
        //    whether ANY surface went beyond the default.
        let decorated = surfaces.values.filter { surface in
            if surface.border != nil || surface.shadow != nil { return true }
            if case .uniform(let r) = surface.corner, r > 0 { return true }
            if case .asymmetric = surface.corner { return true }
            return false
        }
        XCTAssertFalse(decorated.isEmpty,
                       "At least one surface must declare border/corner/shadow (Task 15)")

        // 4. Asset pipeline — both expected PNGs must resolve.
        //    Count-equality rather than non-empty catches a regression
        //    where a misspelled `assets/…` path in skin.json fails to
        //    resolve one PNG while the other still loads; under an
        //    isEmpty check that degradation is invisible.
        XCTAssertEqual(loaded.images.count, 2,
                       "HoloscapeClassic ships two sprite PNGs (button + tab); both must resolve via the asset pipeline")
    }
}
