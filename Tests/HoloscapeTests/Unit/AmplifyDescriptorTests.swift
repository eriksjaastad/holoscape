import XCTest
@testable import Holoscape

/// Amplify Task 1.7 — Codable round-trips for the new descriptor types.
/// Catches encode/decode drift on every Amplify model. v2 / v3 decode
/// behavior is covered here so the integration path via `SkinDefinition`
/// can focus on manifest-level invariants.
final class AmplifyDescriptorTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - WindowShapeDescriptor

    func testWindowShapePolygonsRoundTrip() throws {
        let desc = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [
                Polygon(points: [
                    Point(x: 0, y: 0),
                    Point(x: 100, y: 0),
                    Point(x: 50, y: 100),
                ]),
            ],
            maskPath: nil
        )
        let encoded = try encoder.encode(desc)
        let decoded = try decoder.decode(WindowShapeDescriptor.self, from: encoded)
        XCTAssertEqual(decoded, desc)
    }

    func testWindowShapeMaskRoundTrip() throws {
        // `.mask` is accepted by Codable so v3 manifests round-trip cleanly;
        // rejection happens at validate time (Requirement 2.9) elsewhere.
        let desc = WindowShapeDescriptor(
            kind: .mask,
            polygons: nil,
            maskPath: "assets/mask.png"
        )
        let encoded = try encoder.encode(desc)
        let decoded = try decoder.decode(WindowShapeDescriptor.self, from: encoded)
        XCTAssertEqual(decoded, desc)
    }

    // MARK: - Polygon

    func testPolygonIsValid() {
        XCTAssertFalse(Polygon(points: []).isValid())
        XCTAssertFalse(Polygon(points: [Point(x: 0, y: 0)]).isValid())
        XCTAssertFalse(Polygon(points: [Point(x: 0, y: 0), Point(x: 1, y: 1)]).isValid())
        XCTAssertTrue(Polygon(points: [
            Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 0, y: 1),
        ]).isValid())
    }

    // MARK: - DragRegionDescriptor

    func testDragRegionDecodesWithoutModifier() throws {
        let json = #"""
        { "polygons": [{ "points": [{"x":0,"y":0},{"x":10,"y":0},{"x":10,"y":10}] }] }
        """#
        let decoded = try decoder.decode(DragRegionDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.polygons.count, 1)
        XCTAssertNil(decoded.modifier,
                     "Absent modifier must decode as nil (default: no modifier gate)")
    }

    func testDragRegionDecodesWithCommandModifier() throws {
        let json = #"""
        { "polygons": [{ "points": [{"x":0,"y":0},{"x":10,"y":0},{"x":10,"y":10}] }],
          "modifier": "command" }
        """#
        let decoded = try decoder.decode(DragRegionDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.modifier, .command)
    }

    func testDragRegionPrunedToValidPolygons() {
        let desc = DragRegionDescriptor(
            polygons: [
                Polygon(points: [Point(x: 0, y: 0), Point(x: 1, y: 0)]),  // invalid
                Polygon(points: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 0, y: 1)]),  // valid
                Polygon(points: []),  // invalid
            ],
            modifier: .none
        )
        let pruned = desc.prunedToValidPolygons()
        XCTAssertEqual(pruned.polygons.count, 1)
        XCTAssertEqual(pruned.modifier, .none)
    }

    // MARK: - SpriteDescriptor

    func testSpriteDescriptorRoundTrip() throws {
        let desc = SpriteDescriptor(
            cellWidth: 23, cellHeight: 18, rows: 2, cols: 6,
            stateMap: [
                "normal":  SpriteCell(row: 0, col: 0),
                "hover":   SpriteCell(row: 0, col: 1),
                "pressed": SpriteCell(row: 1, col: 0),
            ]
        )
        let encoded = try encoder.encode(desc)
        let decoded = try decoder.decode(SpriteDescriptor.self, from: encoded)
        XCTAssertEqual(decoded, desc)
    }

    func testSpriteDescriptorIsValidDimensions() {
        // Fits in a 138×36 sheet: cols*cellWidth = 6*23=138, rows*cellHeight = 2*18=36
        let desc = SpriteDescriptor(
            cellWidth: 23, cellHeight: 18, rows: 2, cols: 6,
            stateMap: ["normal": SpriteCell(row: 0, col: 0)]
        )
        XCTAssertTrue(desc.isValid(imageSize: CGSize(width: 138, height: 36)))
        XCTAssertFalse(desc.isValid(imageSize: CGSize(width: 137, height: 36)),
                       "Image narrower than the sprite grid must reject")
        XCTAssertFalse(desc.isValid(imageSize: CGSize(width: 138, height: 35)),
                       "Image shorter than the sprite grid must reject")
    }

    func testSpriteDescriptorRejectsOutOfBoundsStateCell() {
        let desc = SpriteDescriptor(
            cellWidth: 10, cellHeight: 10, rows: 1, cols: 2,
            stateMap: ["normal": SpriteCell(row: 5, col: 0)]  // row 5 doesn't exist in 1-row grid
        )
        XCTAssertFalse(desc.isValid(imageSize: CGSize(width: 20, height: 10)),
                       "State cell referencing a row/col outside the grid must reject")
    }

    func testSpriteDescriptorRejectsNegativeCellCoordinates() {
        let negRow = SpriteDescriptor(
            cellWidth: 10, cellHeight: 10, rows: 1, cols: 2,
            stateMap: ["normal": SpriteCell(row: -1, col: 0)]
        )
        XCTAssertFalse(negRow.isValid(imageSize: CGSize(width: 20, height: 10)),
                       "Negative row in stateMap cell must reject")
        let negCol = SpriteDescriptor(
            cellWidth: 10, cellHeight: 10, rows: 1, cols: 2,
            stateMap: ["normal": SpriteCell(row: 0, col: -1)]
        )
        XCTAssertFalse(negCol.isValid(imageSize: CGSize(width: 20, height: 10)),
                       "Negative col in stateMap cell must reject")
    }

    func testSpriteDescriptorRejectsZeroDimensions() {
        let desc = SpriteDescriptor(
            cellWidth: 0, cellHeight: 10, rows: 1, cols: 2,
            stateMap: ["normal": SpriteCell(row: 0, col: 0)]
        )
        XCTAssertFalse(desc.isValid(imageSize: CGSize(width: 20, height: 10)))
    }

    // MARK: - SpriteState

    func testSpriteStateRawIntMappings() {
        XCTAssertEqual(SpriteState.normal.rawInt, 0)
        XCTAssertEqual(SpriteState.hover.rawInt, 1)
        XCTAssertEqual(SpriteState.pressed.rawInt, 2)
        XCTAssertEqual(SpriteState.active.rawInt, 3)
        XCTAssertEqual(SpriteState.disabled.rawInt, 4)
        XCTAssertEqual(SpriteState.focused.rawInt, 5)
        XCTAssertEqual(SpriteState.selected.rawInt, 6)
    }

    func testSpriteStateFromInt32Roundtrip() {
        for state in SpriteState.allCases {
            XCTAssertEqual(SpriteState.fromInt32(state.rawInt), state)
        }
    }

    func testSpriteStateFromInt32FallsBackToNormalOnOutOfRange() {
        XCTAssertEqual(SpriteState.fromInt32(-1), .normal)
        XCTAssertEqual(SpriteState.fromInt32(99), .normal)
        XCTAssertEqual(SpriteState.fromInt32(Int32.max), .normal)
    }

    // MARK: - Integration: SkinDefinition with Amplify fields

    func testSkinDefinitionDecodesWithAmplifyFields() throws {
        let json = #"""
        {
          "version": "3.0",
          "name": "test",
          "windowShape": {
            "kind": "polygons",
            "polygons": [
              { "points": [{"x":0,"y":0},{"x":10,"y":0},{"x":0,"y":10}] }
            ]
          },
          "dragRegions": [
            {
              "polygons": [
                { "points": [{"x":0,"y":0},{"x":5,"y":0},{"x":0,"y":5}] }
              ]
            }
          ]
        }
        """#
        let decoded = try decoder.decode(SkinDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "3.0")
        XCTAssertEqual(decoded.windowShape?.kind, .polygons)
        XCTAssertEqual(decoded.dragRegions?.count, 1)
    }

    func testSkinDefinitionV2DecodesWithNilAmplifyFields() throws {
        // v2 manifest — no windowShape, no dragRegions, no sprite on image fills.
        let json = #"""
        {
          "version": "2.0",
          "name": "synthwave",
          "windowBackground": "#1a0933",
          "surfaces": {
            "sidebar.container": {
              "fill": { "kind": "image", "path": "assets/tile.png", "tile": "ninepatch" }
            }
          }
        }
        """#
        let decoded = try decoder.decode(SkinDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "2.0")
        XCTAssertNil(decoded.windowShape,
                     "v2 manifest must decode windowShape as nil")
        XCTAssertNil(decoded.dragRegions,
                     "v2 manifest must decode dragRegions as nil")
        if case .image(_, _, let sprite) = decoded.surfaces?["sidebar.container"]?.fill {
            XCTAssertNil(sprite,
                         "v2 manifest image fills must decode with sprite == nil")
        } else {
            XCTFail("Expected image fill on sidebar.container")
        }
    }

    // MARK: - ReactiveUniformSnapshot.spriteState

    func testReactiveSnapshotSpriteStateInitialValue() {
        let snap = ReactiveUniformSnapshot()
        XCTAssertEqual(snap.spriteState, 0, "Default spriteState is normal (0)")
    }

    func testReactiveSnapshotSpriteStateSetter() {
        let snap = ReactiveUniformSnapshot()
        snap.setSpriteState(SpriteState.hover.rawInt)
        XCTAssertEqual(snap.spriteState, 1)
        snap.setSpriteState(SpriteState.pressed.rawInt)
        XCTAssertEqual(snap.spriteState, 2)
    }

    func testReactiveSnapshotSpriteStateMatchKeyRouting() {
        let snap = ReactiveUniformSnapshot()
        snap.setSpriteState(SpriteState.active.rawInt)
        XCTAssertEqual(snap.intValue(forMatchKey: "spriteState"), 3,
                       "spriteState match key must route to the sprite state field")
    }
}
