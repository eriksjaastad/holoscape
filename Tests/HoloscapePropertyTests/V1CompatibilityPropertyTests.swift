import XCTest
import SwiftCheck
@testable import Holoscape

/// Property 1 — V1 skin backward compatibility (Requirements 1.1, 1.2, 1.3, 1.4).
///
/// A v1 manifest carries a flat set of 10 optional color/image fields;
/// anything beyond that (the v2 `surfaces` dictionary, unknown future
/// fields) must be ignored gracefully. `SkinEngine.apply(skin:to:)`
/// currently transfers three of those v1 fields to the AppearanceConfig:
///
///   - `windowBackground` → `config.backgroundColor`
///   - `ansiColors` (when exactly 16 entries) → named ANSI dictionary
///   - `textForeground` → `config.ansiColors["foreground"]` (only when
///     the ANSI palette is also present)
///
/// The other seven v1 fields (titleBarBackground, sidebarBackground,
/// tabActiveColor, tabInactiveColor, and the three image paths) are
/// stored on the SkinDefinition but don't flow to AppearanceConfig —
/// in v2 they're consumed via the `surfaces` dictionary instead.
@MainActor
final class V1CompatibilityPropertyTests: XCTestCase {

    private let engine = SkinEngine()
    private let decoder = JSONDecoder()

    // MARK: - Generators

    /// A six-character lowercase hex color string, guaranteed to parse.
    private static let hexColor: Gen<String> = Gen<Character>
        .fromElements(of: Array("0123456789abcdef"))
        .proliferate(withSize: 6)
        .map { "#" + String($0) }

    /// A relative image path (always safe — absolute and URL shapes are
    /// rejected by the path sandbox, so a legitimate v1 manifest won't
    /// carry them).
    private static let imagePath: Gen<String> = Gen<Character>
        .fromElements(of: Array("abcdefghijklmnop"))
        .proliferate(withSize: 8)
        .map { "assets/" + String($0) + ".png" }

    /// Exactly 16 hex colors — the ANSI palette length that triggers
    /// `apply`'s named-dictionary mapping.
    private static let ansiPalette: Gen<[String]> =
        hexColor.proliferate(withSize: 16)

    // MARK: - Round-trip decode

    func testV1ManifestRoundTripsThroughCodable() {
        // SwiftCheck forAll caps at 8 generators. Five fields cover the
        // representative shapes: hex colors, a 16-entry ANSI palette,
        // an image path, and an optional v2 metadata field. The remaining
        // fields all reuse the same underlying Codable synthesis and
        // don't need individual coverage to catch a custom-decoder bug
        // (SkinDefinition has no custom decoder).
        property("Representative v1+v2 fields survive encode/decode round trip") <- forAll(
            Self.hexColor,
            Self.hexColor,
            Self.ansiPalette,
            Self.imagePath,
            String.arbitrary.suchThat { !$0.isEmpty }
        ) { (windowBG: String, textFG: String, ansi: [String], winImg: String, version: String) in
            let original = SkinDefinition(
                windowBackground: windowBG,
                textForeground: textFG,
                ansiColors: ansi,
                windowBackgroundImage: winImg,
                version: version
            )
            guard let data = try? JSONEncoder().encode(original),
                  let decoded = try? self.decoder.decode(SkinDefinition.self, from: data) else {
                return false
            }
            return decoded == original
        }
    }

    // MARK: - apply() transfers

    func testApplyTransfersWindowBackground() {
        property("apply copies windowBackground into AppearanceConfig.backgroundColor") <- forAll(
            Self.hexColor
        ) { (bg: String) in
            let skin = SkinDefinition(windowBackground: bg)
            let input = AppearanceConfig(
                backgroundColor: "#000000",
                transparency: 1.0,
                fontFamily: "Menlo",
                fontSize: 13,
                ansiColors: nil
            )
            let result = self.engine.apply(skin: skin, to: input)
            return result.backgroundColor == bg
        }
    }

    func testApplyMapsAnsiPaletteWhenExactly16() {
        property("apply maps a 16-entry ansi palette to the named dict") <- forAll(
            Self.ansiPalette,
            Self.hexColor
        ) { (ansi: [String], fg: String) in
            // Field declaration order is textForeground (6) before ansiColors (7).
            let skin = SkinDefinition(textForeground: fg, ansiColors: ansi)
            let input = AppearanceConfig(
                backgroundColor: "#000000",
                transparency: 1.0,
                fontFamily: "Menlo",
                fontSize: 13,
                ansiColors: nil
            )
            let result = self.engine.apply(skin: skin, to: input)
            guard let mapped = result.ansiColors else { return false }
            let expectedNames = [
                "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                "brightBlack", "brightRed", "brightGreen", "brightYellow",
                "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
            ]
            for (i, name) in expectedNames.enumerated() where mapped[name] != ansi[i] {
                return false
            }
            return mapped["foreground"] == fg
        }
    }

    func testApplyIgnoresAnsiPaletteWhenNot16() {
        // A palette with anything other than 16 entries is silently
        // ignored — the spec treats partial palettes as malformed.
        property("apply ignores ansi palettes whose length != 16") <- forAll(
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 15 }
        ) { (count: Int) in
            let palette = Array(repeating: "#123456", count: count)
            let skin = SkinDefinition(ansiColors: palette.isEmpty ? nil : palette)
            let input = AppearanceConfig(
                backgroundColor: "#000000",
                transparency: 1.0,
                fontFamily: "Menlo",
                fontSize: 13,
                ansiColors: nil
            )
            let result = self.engine.apply(skin: skin, to: input)
            return result.ansiColors == nil
        }
    }

    // MARK: - Forward compatibility

    func testV1ManifestWithUnknownFieldsDecodes() {
        // JSONDecoder ignores unknown keys by default. A v1 manifest
        // with a forward-compat `surfaces` dict or future fields must
        // decode to a valid SkinDefinition whose v1 fields are intact.
        property("Unknown top-level fields in JSON don't break v1 decoding") <- forAll(
            Self.hexColor
        ) { (bg: String) in
            let jsonPayload = """
            {
              "windowBackground": "\(bg)",
              "unknownFutureField": { "anything": true, "nested": [1, 2, 3] },
              "newFlag_v99": "opaque"
            }
            """
            guard let data = jsonPayload.data(using: .utf8),
                  let decoded = try? self.decoder.decode(SkinDefinition.self, from: data) else {
                return false
            }
            return decoded.windowBackground == bg
        }
    }
}
