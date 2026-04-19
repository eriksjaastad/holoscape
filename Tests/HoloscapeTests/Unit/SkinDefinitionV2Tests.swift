import XCTest
@testable import Holoscape

/// Phase 1 coverage for SkinDefinition v2 schema extensions.
/// Requirements: 1.2 (v1 compat), 1.3 (v2 surfaces), 1.4 (mixed manifests).
final class SkinDefinitionV2Tests: XCTestCase {

    // MARK: - v1 backward compatibility

    func testV1ManifestDecodesWithoutV2Fields() throws {
        let json = """
        {
            "windowBackground": "#1a1a2e",
            "titleBarBackground": "#0e0e1a",
            "sidebarBackground": "#0a0a18",
            "tabActiveColor": "#bd93f9",
            "tabInactiveColor": "#6272a4",
            "textForeground": "#ffffff"
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)

        XCTAssertEqual(skin.windowBackground, "#1a1a2e")
        XCTAssertEqual(skin.tabActiveColor, "#bd93f9")
        XCTAssertNil(skin.version)
        XCTAssertNil(skin.name)
        XCTAssertNil(skin.surfaces)
    }

    func testV1AnsiColorsPreserved() throws {
        let json = """
        {
            "ansiColors": ["#000000", "#ff0000", "#00ff00", "#0000ff",
                           "#ffff00", "#ff00ff", "#00ffff", "#ffffff",
                           "#808080", "#ff8080", "#80ff80", "#8080ff",
                           "#ffff80", "#ff80ff", "#80ffff", "#ffffff"]
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        XCTAssertEqual(skin.ansiColors?.count, 16)
        XCTAssertEqual(skin.ansiColors?[1], "#ff0000")
    }

    // MARK: - v2 surfaces decoding

    func testV2ManifestWithSurfacesOnly() throws {
        let json = """
        {
            "version": "2.0",
            "name": "Test Skin",
            "author": "Erik",
            "surfaces": {
                "tabBar.container": {
                    "fill": { "kind": "color", "value": "#1a1a2e" },
                    "corner": 8
                }
            }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        XCTAssertEqual(skin.version, "2.0")
        XCTAssertEqual(skin.name, "Test Skin")
        XCTAssertEqual(skin.author, "Erik")
        XCTAssertEqual(skin.surfaces?.count, 1)

        let surface = try XCTUnwrap(skin.surfaces?["tabBar.container"])
        XCTAssertEqual(surface.fill, .color("#1a1a2e"))
        XCTAssertEqual(surface.corner, .uniform(8))
    }

    func testMixedV1AndV2Manifest() throws {
        let json = """
        {
            "windowBackground": "#1a1a2e",
            "tabActiveColor": "#bd93f9",
            "version": "2.0",
            "surfaces": {
                "sidebar.container": {
                    "fill": {
                        "kind": "image",
                        "path": "assets/sidebar.png",
                        "tile": "ninepatch"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        XCTAssertEqual(skin.windowBackground, "#1a1a2e")
        XCTAssertEqual(skin.tabActiveColor, "#bd93f9")
        XCTAssertEqual(skin.version, "2.0")

        let sidebar = try XCTUnwrap(skin.surfaces?["sidebar.container"])
        if case .image(let path, let tile, let sprite) = sidebar.fill {
            XCTAssertEqual(path, "assets/sidebar.png")
            XCTAssertEqual(tile, .ninepatch)
            XCTAssertNil(sprite, "v2 manifest must decode image fills with sprite == nil")
        } else {
            XCTFail("Expected image fill")
        }
    }

    func testUnknownFieldsIgnored() throws {
        // Forward compatibility: a v2.1 field we don't recognize must not break decoding.
        let json = """
        {
            "version": "2.1",
            "name": "Future Skin",
            "unknownFutureField": { "nested": true }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        XCTAssertEqual(skin.version, "2.1")
        XCTAssertEqual(skin.name, "Future Skin")
    }

    // MARK: - Round-trip

    func testV2SkinRoundTrip() throws {
        let original = SkinDefinition(
            windowBackground: "#1a1a2e",
            tabActiveColor: "#bd93f9",
            version: "2.0",
            name: "Round Trip",
            author: "Erik",
            description: "Codable round-trip check",
            surfaces: [
                "tabBar.container": SurfaceDescriptor(
                    fill: .color("#1a1a2e"),
                    border: BorderDescriptor(color: "#000000", width: 1.0),
                    corner: .uniform(8)
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SkinDefinition.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Descriptor encoding specifics

    func testFillColorEncoding() throws {
        let fill = FillDescriptor.color("#ff0000")
        let data = try JSONEncoder().encode(fill)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "color")
        XCTAssertEqual(json["value"] as? String, "#ff0000")
    }

    func testFillGradientEncoding() throws {
        let fill = FillDescriptor.gradient(
            direction: .vertical,
            stops: [
                GradientStop(offset: 0.0, color: "#000000"),
                GradientStop(offset: 1.0, color: "#ffffff"),
            ]
        )
        let data = try JSONEncoder().encode(fill)
        let decoded = try JSONDecoder().decode(FillDescriptor.self, from: data)
        XCTAssertEqual(fill, decoded)
    }

    func testCornerUniformAndAsymmetricRoundTrip() throws {
        let uniform = CornerDescriptor.uniform(8)
        let asym = CornerDescriptor.asymmetric(topLeft: 12, topRight: 12, bottomRight: 0, bottomLeft: 0)

        let uniformData = try JSONEncoder().encode(uniform)
        let asymData = try JSONEncoder().encode(asym)

        XCTAssertEqual(try JSONDecoder().decode(CornerDescriptor.self, from: uniformData), uniform)
        XCTAssertEqual(try JSONDecoder().decode(CornerDescriptor.self, from: asymData), asym)
    }

    func testCornerAsymmetricJSONShape() throws {
        // Must encode as a 4-element JSON array, not an object.
        let corner = CornerDescriptor.asymmetric(topLeft: 12, topRight: 12, bottomRight: 0, bottomLeft: 0)
        let data = try JSONEncoder().encode(corner)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Double])
        XCTAssertEqual(array, [12, 12, 0, 0])
    }

    func testMatchValueScalarShorthand() throws {
        // `"agentState": 3` should decode as .scalar(3), the $eq shorthand.
        let json = """
        { "agentState": 3 }
        """.data(using: .utf8)!

        let expr = try JSONDecoder().decode(MatchExpression.self, from: json)
        if case .scalar(let value) = expr.conditions["agentState"] {
            XCTAssertEqual(value, 3)
        } else {
            XCTFail("Expected scalar shorthand")
        }
    }

    func testMatchValueOperatorDict() throws {
        let json = """
        { "channelUnread": { "$gte": 1 } }
        """.data(using: .utf8)!

        let expr = try JSONDecoder().decode(MatchExpression.self, from: json)
        if case .operators(let ops) = expr.conditions["channelUnread"] {
            XCTAssertEqual(ops["$gte"], 1)
        } else {
            XCTFail("Expected operator dict")
        }
    }
}
