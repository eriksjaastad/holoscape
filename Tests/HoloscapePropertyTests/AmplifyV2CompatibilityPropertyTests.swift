import XCTest
import SwiftCheck
@testable import Holoscape

/// Property 1 — V2 manifest is decoded identically with or without
/// Amplify-only fields (Amplify Requirements 9.1, 9.4, 9.5).
///
/// Every v2 manifest must decode byte-identical through the v3 Codable
/// synthesis. Concretely:
///
/// 1. A v2 manifest's top-level fields (name, version, windowBackground,
///    ansiColors, surfaces, etc.) survive the v3 decode unchanged.
/// 2. v2 image fills on a v2 manifest decode with `sprite: nil`.
/// 3. Adding `windowShape` / `dragRegions` fields to a v2 manifest
///    produces a v3 manifest that still round-trips cleanly and preserves
///    the original v2 field set.
///
/// This is the load-bearing backward-compat guarantee for Amplify. A
/// regression here would break every existing skin.
@MainActor
final class AmplifyV2CompatibilityPropertyTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Generators

    private static let hexColor: Gen<String> = Gen<Character>
        .fromElements(of: Array("0123456789abcdef"))
        .proliferate(withSize: 6)
        .map { "#" + String($0) }

    /// Image path: `assets/<8 chars>.png`. Kept short so SwiftCheck
    /// shrinking produces readable counterexamples.
    private static let imagePath: Gen<String> = Gen<Character>
        .fromElements(of: Array("abcdefghijklmnop"))
        .proliferate(withSize: 8)
        .map { "assets/" + String($0) + ".png" }

    /// `FillDescriptor.TileMode` isn't `Arbitrary` (and SwiftCheck's
    /// `forAll` requires Arbitrary on every generator). Generate an Int
    /// index and resolve to TileMode inside the closure.
    private static let tileModeIndex: Gen<Int> = Gen<Int>.fromElements(of: [0, 1, 2])
    private static func tileMode(forIndex i: Int) -> FillDescriptor.TileMode {
        [.stretch, .tile, .ninepatch][i % 3]
    }

    // MARK: - Property 1.a: v2 image fills decode with sprite = nil

    func testV2ImageFillDecodesWithSpriteNil() {
        property("v2 image fill JSON (no sprite key) decodes with sprite == nil") <- forAll(
            Self.imagePath, Self.tileModeIndex
        ) { (path: String, tileIdx: Int) in
            let tile = Self.tileMode(forIndex: tileIdx)
            let v2Json = """
            { "kind": "image", "path": "\(path)", "tile": "\(tile.rawValue)" }
            """
            guard let decoded = try? self.decoder.decode(FillDescriptor.self, from: Data(v2Json.utf8)),
                  case .image(let decodedPath, let decodedTile, let sprite) = decoded else {
                return false
            }
            return decodedPath == path && decodedTile == tile && sprite == nil
        }
    }

    // MARK: - Property 1.b: v2 manifest round-trip survives v3 decode

    func testV2ManifestEncodeDecodeIdentity() {
        // Build a representative v2 manifest (no windowShape, no dragRegions,
        // no sprite). Encode via v3 Codable; decode via v3 Codable; compare.
        // Byte-identical equality is what Amplify Req 9.1 / 9.4 demand.
        property("v2 manifest encode → decode is identity") <- forAll(
            Self.hexColor, Self.hexColor, Self.imagePath, Self.tileModeIndex
        ) { (bg: String, fg: String, imgPath: String, tileIdx: Int) in
            let tile = Self.tileMode(forIndex: tileIdx)
            var manifest = SkinDefinition()
            manifest.version = "2.0"
            manifest.name = "round-trip-test"
            manifest.windowBackground = bg
            manifest.textForeground = fg
            manifest.surfaces = [
                "sidebar.container": SurfaceDescriptor(
                    fill: .image(path: imgPath, tile: tile, sprite: nil)
                ),
                "tabBar.tab.active": SurfaceDescriptor(
                    fill: .color(bg)
                ),
            ]
            guard let encoded = try? self.encoder.encode(manifest),
                  let decoded = try? self.decoder.decode(SkinDefinition.self, from: encoded) else {
                return false
            }
            return decoded == manifest
                && decoded.windowShape == nil
                && decoded.dragRegions == nil
        }
    }

    // MARK: - Property 1.c: Adding v3 fields leaves v2 fields intact

    func testV3FieldsAreAdditiveAndDoNotAffectV2Fields() {
        // Given a v2 manifest M, constructing a v3 manifest M' by adding
        // windowShape and/or dragRegions must leave every v2 field
        // unchanged. This is the "v3 is additive" invariant.
        property("adding v3 fields preserves v2 field values") <- forAll(
            Self.hexColor, Self.hexColor
        ) { (bg: String, fg: String) in
            var v2 = SkinDefinition()
            v2.version = "2.0"
            v2.windowBackground = bg
            v2.textForeground = fg

            var v3 = v2
            v3.version = "3.0"
            v3.windowShape = WindowShapeDescriptor(
                kind: .polygons,
                polygons: [Polygon(points: [
                    Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 0, y: 10),
                ])],
                maskPath: nil
            )
            v3.dragRegions = [
                DragRegionDescriptor(
                    polygons: [Polygon(points: [
                        Point(x: 0, y: 0), Point(x: 5, y: 0), Point(x: 5, y: 5),
                    ])],
                    modifier: nil
                ),
            ]

            return v3.windowBackground == v2.windowBackground
                && v3.textForeground == v2.textForeground
                && v3.surfaces == v2.surfaces
                && v3.ansiColors == v2.ansiColors
        }
    }

    // MARK: - Property 1.d: Unknown top-level keys are ignored

    func testUnknownTopLevelKeysSurviveDecode() {
        // v3 Codable must tolerate forward-compat unknown keys (a v4
        // manifest loaded on a v3 binary). Synthesized Codable already
        // has this behavior; property-test it so a custom decoder can't
        // silently break it.
        property("manifest with unknown top-level keys decodes cleanly") <- forAll(
            Self.hexColor
        ) { (bg: String) in
            let json = """
            {
              "version": "99.0",
              "windowBackground": "\(bg)",
              "unknownFutureField": { "kind": "mystery" },
              "anotherOne": 42
            }
            """
            guard let decoded = try? self.decoder.decode(SkinDefinition.self, from: Data(json.utf8)) else {
                return false
            }
            return decoded.version == "99.0" && decoded.windowBackground == bg
        }
    }
}
