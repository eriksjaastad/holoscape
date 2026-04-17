import XCTest
@testable import Holoscape

/// Requirement 1.5: malformed manifests must fail gracefully — JSON parse
/// errors surface as thrown DecodingErrors, unknown fields are ignored, and
/// known fields in a partial manifest still decode.
final class SkinDefinitionErrorTests: XCTestCase {

    func testInvalidJSONThrows() {
        let garbage = "not { valid } json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SkinDefinition.self, from: garbage))
    }

    func testEmptyObjectDecodesToAllNil() throws {
        let empty = "{}".data(using: .utf8)!
        let skin = try JSONDecoder().decode(SkinDefinition.self, from: empty)

        XCTAssertNil(skin.windowBackground)
        XCTAssertNil(skin.version)
        XCTAssertNil(skin.surfaces)
    }

    func testUnknownTopLevelFieldsIgnored() throws {
        // Forward compatibility: a v2.5 field we don't recognize must decode
        // without error — the caller keeps the known fields and moves on.
        let json = """
        {
            "version": "2.5",
            "unknownTopLevel": 42,
            "anotherUnknown": { "nested": true },
            "arrayUnknown": [1, 2, 3]
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        XCTAssertEqual(skin.version, "2.5")
    }

    func testMalformedSurfaceValueThrows() {
        // A surface value that isn't a JSON object should throw — the caller
        // is expected to catch this and fall back to defaults.
        let json = """
        {
            "version": "2.0",
            "surfaces": {
                "tabBar.container": "not an object"
            }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(SkinDefinition.self, from: json))
    }

    func testV1FieldsWithInvalidTypesThrow() {
        // windowBackground must be a string, not a number. Decoding must fail
        // so the caller logs and falls back.
        let json = """
        { "windowBackground": 42 }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(SkinDefinition.self, from: json))
    }

    func testPartialSurfaceDescriptorDecodes() throws {
        // A surface with only fill (no border, corner, etc.) must decode cleanly
        // — every descriptor field is optional.
        let json = """
        {
            "version": "2.0",
            "surfaces": {
                "tabBar.container": {
                    "fill": { "kind": "color", "value": "#000000" }
                }
            }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        let surface = try XCTUnwrap(skin.surfaces?["tabBar.container"])
        XCTAssertEqual(surface.fill, .color("#000000"))
        XCTAssertNil(surface.border)
        XCTAssertNil(surface.corner)
        XCTAssertNil(surface.states)
    }

    func testUnknownSurfaceKeyRetainedInDictionary() throws {
        // Unknown surface keys (e.g., "future.surface") must decode — the
        // dictionary just keeps them. SurfaceKey resolution rejects them
        // at apply time, not at manifest-decode time.
        let json = """
        {
            "version": "2.0",
            "surfaces": {
                "future.surface.we.dont.know": {
                    "fill": { "kind": "color", "value": "#ff0000" }
                }
            }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        XCTAssertEqual(skin.surfaces?.count, 1)
        XCTAssertNotNil(skin.surfaces?["future.surface.we.dont.know"])
    }

    // MARK: - CornerDescriptor edge cases

    func testCornerAsymmetricRejectsExtraElements() {
        // 5-element array must throw, not silently discard the extra value.
        let json = "[12, 12, 0, 0, 99]".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(CornerDescriptor.self, from: json))
    }

    func testCornerAsymmetricRejectsTooFewElements() {
        let json = "[12, 12, 0]".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(CornerDescriptor.self, from: json))
    }

    // MARK: - MatchValue operator dict validation

    func testMatchValueOperatorsRejectsStringValues() {
        // {"$gte": "active"} must throw — operator values must be numeric.
        let json = """
        { "channelUnread": { "$gte": "active" } }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MatchExpression.self, from: json))
    }

    func testMatchValueRejectsMixedDollarAndBareKeys() {
        // {"$gte": 1, "iTimeFoo": 2} is malformed — can't mix operator and timeSince keys.
        let json = """
        { "mixed": { "$gte": 1, "iTimeFoo": 2 } }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MatchExpression.self, from: json))
    }

    func testMatchValueRejectsEmptyDict() {
        let json = """
        { "empty": {} }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MatchExpression.self, from: json))
    }

    // MARK: - NinepatchSidecar validation

    func testNinepatchValidRanges() {
        let sidecar = NinepatchSidecar(stretchX: [16, 48], stretchY: [8, 24])
        XCTAssertTrue(sidecar.isValid)
    }

    func testNinepatchInvalidRangesDetected() {
        let reversed = NinepatchSidecar(stretchX: [48, 16], stretchY: [8, 24])
        XCTAssertFalse(reversed.isValid, "Reversed stretchX should be invalid")

        let wrongLength = NinepatchSidecar(stretchX: [16], stretchY: [8, 24])
        XCTAssertFalse(wrongLength.isValid, "Single-element stretchX should be invalid")
    }

    func testNinepatchZeroWidthBandIsInvalid() {
        // stretchX = [16, 16] produces a zero-area contentsCenter rect
        // which CALayer silently treats as .zero and bypasses ninepatch.
        // Must be rejected by isValid.
        let zeroX = NinepatchSidecar(stretchX: [16, 16], stretchY: [8, 24])
        XCTAssertFalse(zeroX.isValid, "Zero-width stretchX should be invalid")

        let zeroY = NinepatchSidecar(stretchX: [16, 48], stretchY: [8, 8])
        XCTAssertFalse(zeroY.isValid, "Zero-height stretchY should be invalid")
    }

    func testNinepatchNegativeRangeIsInvalid() {
        let negative = NinepatchSidecar(stretchX: [-1, 48], stretchY: [8, 24])
        XCTAssertFalse(negative.isValid, "Negative pixel offset should be invalid")
    }
}
