import XCTest
@testable import Holoscape

/// Chrome v4 Task 3.3 — Codable round-trips for ChromeDescriptor, every
/// animation kind, and every LedArrayParams.Pattern case, plus the
/// backward-compat invariant that v2/v3 manifests decode with
/// `chrome == nil` and the Req 1.2 enforcement that `mode == .baked`
/// requires a non-empty image path. Pairs with the Codable tests in
/// `AmplifyDescriptorTests.swift` so the v4 field set has parity
/// coverage with the v3 field set.
final class ChromeDescriptorCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - SkinRect

    func testSkinRectRoundTrip() throws {
        let r = SkinRect(x: 40, y: 60, width: 920, height: 600)
        let decoded = try decoder.decode(SkinRect.self, from: try encoder.encode(r))
        XCTAssertEqual(decoded, r)
    }

    // MARK: - ChromeDescriptor modes

    func testChromeDescriptorBakedRoundTrip() throws {
        let desc = ChromeDescriptor(
            mode: .baked,
            image: "chrome@2x.png",
            imageOpaque: "chrome-opaque@2x.png",
            width: 1000,
            height: 700,
            interiorRect: SkinRect(x: 40, y: 60, width: 920, height: 600),
            interiorPath: nil,
            animations: nil
        )
        let decoded = try decoder.decode(ChromeDescriptor.self, from: try encoder.encode(desc))
        XCTAssertEqual(decoded, desc)
    }

    func testChromeDescriptorComposedRoundTripWithoutImage() throws {
        // Composed mode does not require `image` — the bake pipeline
        // produces it at load time.
        let desc = ChromeDescriptor(
            mode: .composed,
            image: nil,
            imageOpaque: nil,
            width: 1000,
            height: 700,
            interiorRect: SkinRect(x: 40, y: 60, width: 920, height: 600),
            interiorPath: nil,
            animations: nil
        )
        let decoded = try decoder.decode(ChromeDescriptor.self, from: try encoder.encode(desc))
        XCTAssertEqual(decoded, desc)
    }

    func testChromeDescriptorBakedWithoutImageRejectedAtDecode() {
        // Req 1.2 — decode-time enforcement. Hand-build JSON so we
        // bypass the memberwise initializer's type system and exercise
        // the custom init(from:).
        let json = """
        {
            "mode": "baked",
            "width": 1000,
            "height": 700,
            "interiorRect": { "x": 40, "y": 60, "width": 920, "height": 600 }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ChromeDescriptor.self, from: json)) { error in
            guard case DecodingError.dataCorrupted(let ctx) = error else {
                return XCTFail("expected .dataCorrupted, got \(error)")
            }
            XCTAssertTrue(ctx.debugDescription.contains("baked"))
        }
    }

    func testChromeDescriptorBakedWithEmptyImageRejectedAtDecode() {
        let json = """
        {
            "mode": "baked",
            "image": "",
            "width": 1000,
            "height": 700,
            "interiorRect": { "x": 40, "y": 60, "width": 920, "height": 600 }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ChromeDescriptor.self, from: json))
    }

    func testChromeDescriptorBakedWithWhitespaceImageRejectedAtDecode() {
        // Req 1.2 — "non-empty image path" must mean non-empty after
        // trimming. A whitespace-only path is functionally empty; the
        // bake pipeline cannot resolve it any better than an empty string.
        let json = """
        {
            "mode": "baked",
            "image": "   \\t\\n  ",
            "width": 1000,
            "height": 700,
            "interiorRect": { "x": 40, "y": 60, "width": 920, "height": 600 }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ChromeDescriptor.self, from: json))
    }

    func testChromeDescriptorWithInteriorPathRoundTrip() throws {
        let desc = ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 1000,
            height: 700,
            interiorRect: SkinRect(x: 40, y: 60, width: 920, height: 600),
            interiorPath: [
                Polygon(points: [
                    Point(x: 40, y: 60),
                    Point(x: 960, y: 60),
                    Point(x: 960, y: 660),
                    Point(x: 40, y: 660),
                ]),
            ]
        )
        let decoded = try decoder.decode(ChromeDescriptor.self, from: try encoder.encode(desc))
        XCTAssertEqual(decoded, desc)
    }

    // MARK: - Animation kinds

    func testParticleLayerRoundTrip() throws {
        let layer = ChromeAnimationLayer(
            id: "porthole-particles",
            kind: .particle,
            rect: SkinRect(x: 50, y: 70, width: 200, height: 200),
            z: 1,
            phaseOffset: 0,
            speedMultiplier: 1.0,
            dataSource: .none,
            params: ChromeAnimationLayer.Params(
                particle: ParticleParams(
                    birthRate: 5.0,
                    lifetime: 3.0,
                    lifetimeRange: 0.5,
                    velocity: 20.0,
                    velocityRange: 5.0,
                    emissionAngle: 1.57,
                    emissionRange: 6.28,
                    color: "#ffaa3388",
                    colorRange: nil,
                    scale: 0.5,
                    scaleRange: 0.2,
                    image: nil,
                    blendMode: .additive
                ),
                ledArray: nil,
                spriteAnim: nil,
                shader: nil
            )
        )
        let decoded = try decoder.decode(ChromeAnimationLayer.self, from: try encoder.encode(layer))
        XCTAssertEqual(decoded, layer)
    }

    func testSpriteAnimLayerRoundTrip() throws {
        let layer = ChromeAnimationLayer(
            id: "lcd-marquee",
            kind: .spriteAnim,
            rect: SkinRect(x: 300, y: 10, width: 400, height: 24),
            z: 1,
            phaseOffset: nil,
            speedMultiplier: nil,
            dataSource: nil,
            params: ChromeAnimationLayer.Params(
                particle: nil,
                ledArray: nil,
                spriteAnim: SpriteAnimParams(
                    sheet: "assets/lcd-frames.png",
                    gridRows: 4,
                    gridCols: 8,
                    frameCount: 30,
                    fps: 12.0,
                    loop: .loop
                ),
                shader: nil
            )
        )
        let decoded = try decoder.decode(ChromeAnimationLayer.self, from: try encoder.encode(layer))
        XCTAssertEqual(decoded, layer)
    }

    func testShaderLayerRoundTripAllPresets() throws {
        for preset: ShaderParams.Preset in [.glow, .scanlines, .noise] {
            let layer = ChromeAnimationLayer(
                id: "ambient-\(preset.rawValue)",
                kind: .shader,
                rect: SkinRect(x: 0, y: 650, width: 1000, height: 50),
                z: 1,
                phaseOffset: nil,
                speedMultiplier: nil,
                dataSource: nil,
                params: ChromeAnimationLayer.Params(
                    particle: nil,
                    ledArray: nil,
                    spriteAnim: nil,
                    shader: ShaderParams(preset: preset, color: "#4488ff", intensity: 0.3, hz: 0.5)
                )
            )
            let decoded = try decoder.decode(ChromeAnimationLayer.self, from: try encoder.encode(layer))
            XCTAssertEqual(decoded, layer, "preset \(preset.rawValue)")
        }
    }

    func testLedArrayLayerRoundTrip() throws {
        let layer = ChromeAnimationLayer(
            id: "status-leds",
            kind: .ledArray,
            rect: SkinRect(x: 800, y: 10, width: 150, height: 20),
            z: 2,
            phaseOffset: nil,
            speedMultiplier: nil,
            dataSource: .time,
            params: ChromeAnimationLayer.Params(
                particle: nil,
                ledArray: LedArrayParams(
                    cellSize: 6.0,
                    cells: [
                        LedArrayParams.LedCell(x: 0, y: 0, defaultState: 0),
                        LedArrayParams.LedCell(x: 8, y: 0, defaultState: 1),
                        LedArrayParams.LedCell(x: 16, y: 0, defaultState: 0),
                    ],
                    palette: ["#333333", "#00ff00", "#ff0000"],
                    pattern: .phased(hz: 2.0)
                ),
                spriteAnim: nil,
                shader: nil
            )
        )
        let decoded = try decoder.decode(ChromeAnimationLayer.self, from: try encoder.encode(layer))
        XCTAssertEqual(decoded, layer)
    }

    // MARK: - LedArrayParams.Pattern — every case

    private func roundTripPattern(_ p: LedArrayParams.Pattern, file: StaticString = #file, line: UInt = #line) throws {
        let decoded = try decoder.decode(LedArrayParams.Pattern.self, from: try encoder.encode(p))
        XCTAssertEqual(decoded, p, file: file, line: line)
    }

    func testPatternSteadyRoundTrip() throws {
        try roundTripPattern(.steady)
    }

    func testPatternBlinkRoundTrip() throws {
        try roundTripPattern(.blink(hz: 4.0, duty: 0.5))
    }

    func testPatternPhasedRoundTrip() throws {
        try roundTripPattern(.phased(hz: 2.0))
    }

    func testPatternRandomRoundTrip() throws {
        try roundTripPattern(.random(hz: 1.5, density: 0.25))
    }

    func testPatternMarqueeRoundTrip() throws {
        try roundTripPattern(.marquee(cellsPerSecond: 20.0, windowSize: 5))
    }

    func testPatternDecodesWorkedExampleForm() throws {
        // Matches the JSON shape shown in claude-specs/chrome/design.md
        // Worked Manifest Example — `"pattern": { "phased": { "hz": 2.0 } }`.
        let json = #"{ "phased": { "hz": 2.0 } }"#.data(using: .utf8)!
        let decoded = try decoder.decode(LedArrayParams.Pattern.self, from: json)
        XCTAssertEqual(decoded, .phased(hz: 2.0))
    }

    func testPatternDecodesSteadyAsEmptyObject() throws {
        let json = #"{ "steady": {} }"#.data(using: .utf8)!
        let decoded = try decoder.decode(LedArrayParams.Pattern.self, from: json)
        XCTAssertEqual(decoded, .steady)
    }

    func testPatternRejectsEmptyObject() {
        let json = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(LedArrayParams.Pattern.self, from: json))
    }

    func testPatternRejectsMultipleDiscriminators() {
        // Ambiguity — two recognized discriminator keys in one object.
        let json = #"{ "steady": {}, "phased": { "hz": 1.0 } }"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(LedArrayParams.Pattern.self, from: json))
    }

    func testPatternRejectsRecognizedPlusUnknownKey() {
        // Typed keyed containers silently drop unknown keys; the raw-key
        // first pass in `init(from:)` catches these so malformed
        // manifests can't sneak through. Without the raw pass, this JSON
        // would decode cleanly as `.phased`.
        let json = #"{ "phased": { "hz": 1.0 }, "typoKey": {} }"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(LedArrayParams.Pattern.self, from: json))
    }

    func testPatternRejectsUnknownDiscriminator() {
        // A single key that isn't one of the five known patterns must
        // throw, not silently decode as nothing.
        let json = #"{ "wobble": { "hz": 1.0 } }"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(LedArrayParams.Pattern.self, from: json))
    }

    // MARK: - SkinDefinition backward compatibility

    func testV1SkinDecodes_chromeIsNil() throws {
        let json = """
        {
            "windowBackground": "#1a1a2e",
            "tabActiveColor": "#ff00ff"
        }
        """.data(using: .utf8)!
        let skin = try decoder.decode(SkinDefinition.self, from: json)
        XCTAssertNil(skin.chrome)
        XCTAssertEqual(skin.windowBackground, "#1a1a2e")
    }

    func testV2SkinDecodes_chromeIsNil() throws {
        let json = """
        {
            "version": "2.0",
            "name": "Test",
            "surfaces": {}
        }
        """.data(using: .utf8)!
        let skin = try decoder.decode(SkinDefinition.self, from: json)
        XCTAssertNil(skin.chrome)
        XCTAssertEqual(skin.version, "2.0")
    }

    func testV3SkinDecodes_chromeIsNil() throws {
        let json = """
        {
            "version": "3.0",
            "name": "Test",
            "windowShape": {
                "kind": "polygons",
                "polygons": [
                    { "points": [{"x": 0, "y": 0}, {"x": 100, "y": 0}, {"x": 50, "y": 100}] }
                ]
            }
        }
        """.data(using: .utf8)!
        let skin = try decoder.decode(SkinDefinition.self, from: json)
        XCTAssertNil(skin.chrome)
        XCTAssertEqual(skin.windowShape?.kind, .polygons)
    }

    func testV4WorkedExample_skinRoundTrips() throws {
        // Mirrors the worked manifest example in
        // claude-specs/chrome/design.md — exercises chrome with every
        // animation kind so the full-manifest path has at least one
        // assertion.
        let json = """
        {
            "version": "4.0",
            "name": "HoloscapeClassic-live",
            "chrome": {
                "mode": "baked",
                "image": "chrome@2x.png",
                "width": 1000,
                "height": 700,
                "interiorRect": { "x": 40, "y": 60, "width": 920, "height": 600 },
                "animations": [
                    {
                        "id": "porthole-particles",
                        "kind": "particle",
                        "rect": { "x": 50, "y": 70, "width": 200, "height": 200 },
                        "z": 1,
                        "dataSource": "none",
                        "params": {
                            "particle": {
                                "birthRate": 5.0,
                                "lifetime": 3.0,
                                "velocity": 20.0,
                                "emissionAngle": 1.57,
                                "emissionRange": 6.28,
                                "color": "#ffaa3388",
                                "scale": 0.5,
                                "blendMode": "additive"
                            }
                        }
                    }
                ]
            }
        }
        """.data(using: .utf8)!
        let skin = try decoder.decode(SkinDefinition.self, from: json)
        XCTAssertNotNil(skin.chrome)
        XCTAssertEqual(skin.chrome?.mode, .baked)
        XCTAssertEqual(skin.chrome?.animations?.count, 1)
        XCTAssertEqual(skin.chrome?.animations?.first?.kind, .particle)

        // Re-encoding the decoded model should itself round-trip cleanly.
        let reencoded = try encoder.encode(skin)
        let redecoded = try decoder.decode(SkinDefinition.self, from: reencoded)
        XCTAssertEqual(redecoded, skin)
    }
}
