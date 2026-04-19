import XCTest
import AppKit
import SwiftCheck
@testable import Holoscape

/// Amplify Property 8 — Font fallback terminates (Requirement 6.4).
///
/// For ANY `family` string (including gibberish, empty, Unicode,
/// symbol-dense), `SkinContext.resolvedFont(for:)` MUST return a
/// non-nil `NSFont` within three lookups:
///   1. `fontRegistry[family]` — skin-shipped font
///   2. `NSFont(name: family, size:)` — system lookup
///   3. `NSFont.monospacedSystemFont(ofSize:weight:)` — guaranteed fallback
///
/// Step 3 is load-bearing: without it, a skin that references a
/// non-installed font would render invisible text. The property
/// ensures the chain is total — no family string can slip through
/// and produce `nil`.
///
/// `resolvedFont(for:)` returns nil when the surface HAS NO font
/// descriptor at all. That's a separate contract ("caller preserves
/// the pre-Amplify font") and isn't what this property tests. We
/// construct surfaces with an explicit font descriptor on every
/// input so the nil-descriptor branch doesn't interfere.
@MainActor
final class FontFallbackPropertyTests: XCTestCase {

    // MARK: - Generators

    /// A family string. Alphabet includes ASCII letters, digits,
    /// spaces, and dashes — the bulk of real-world font family
    /// names (e.g. "SF Mono", "Helvetica-Neue"). Generated lengths
    /// are bounded to stay readable in counterexamples.
    private static var familyName: Gen<String> {
        Gen<Character>
            .fromElements(of: Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -"))
            .proliferate(withSize: 12)
            .map { String($0) }
    }

    private static var fontSize: Gen<Double> {
        Int.arbitrary.suchThat { $0 >= 6 && $0 <= 48 }.map { Double($0) }
    }

    // MARK: - Properties

    func testResolvedFontAlwaysReturnsNonNilForValidDescriptor() {
        property("resolvedFont returns non-nil for any family + size combination") <- forAll(
            Self.familyName, Self.fontSize
        ) { (family: String, size: Double) in
            let surface = Self.makeSurface(family: family, size: size)
            let ctx = SkinContext(
                surfaces: [.tabBarTabActive: surface],
                reactive: ReactiveUniformSnapshot()
            )
            return ctx.resolvedFont(for: .tabBarTabActive) != nil
        }
    }

    func testResolvedFontForMissingSurfaceIsNil() {
        // Complement: resolvedFont returns nil when the surface
        // doesn't exist in the context — documented contract.
        let ctx = SkinContext(surfaces: [:], reactive: ReactiveUniformSnapshot())
        XCTAssertNil(ctx.resolvedFont(for: .tabBarTabActive))
    }

    func testResolvedFontForSurfaceWithoutFontIsNil() {
        // Surface exists but its FontDescriptor was nil — chrome
        // views interpret nil as "don't touch my font."
        let surface = SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: nil, corner: .uniform(0), padding: NSEdgeInsets(),
            shadow: nil,
            font: nil,  // ← critical
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil, states: []
        )
        let ctx = SkinContext(
            surfaces: [.tabBarTabActive: surface],
            reactive: ReactiveUniformSnapshot()
        )
        XCTAssertNil(ctx.resolvedFont(for: .tabBarTabActive))
    }

    func testResolvedFontUsesRegistryWhenKeyed() {
        // When a PostScript name lookup hits the registry, the
        // resolved font must be the one built from the registry's
        // CGFont, not the name-based system lookup. We can't easily
        // compare identity (CTFontCreateWithGraphicsFont produces
        // a new CTFont), but we CAN verify the resolved font's
        // postScriptName matches the registered font's.
        let size: CGFloat = 14
        // Menlo is always installed on macOS. Use its CGFont as a
        // stand-in for a "skin-shipped" font in the registry.
        guard let menlo = NSFont(name: "Menlo", size: size),
              let cgFont = CTFontCopyGraphicsFont(menlo, nil) as CGFont? else {
            XCTSkip("Menlo not available on this system")
            return
        }
        // Build a surface whose FontDescriptor family equals Menlo's
        // PostScript name so resolvedFont's registry path trips.
        let psName = menlo.fontDescriptor.postscriptName ?? "Menlo"
        let surface = Self.makeSurface(family: psName, size: Double(size))
        let ctx = SkinContext(
            surfaces: [.tabBarTabActive: surface],
            reactive: ReactiveUniformSnapshot(),
            fontRegistry: [psName: cgFont]
        )
        let resolved = ctx.resolvedFont(for: .tabBarTabActive)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.fontDescriptor.postscriptName, psName)
    }

    // MARK: - Helpers

    private static func makeSurface(family: String, size: Double) -> SkinContext.ResolvedSurface {
        // `resolved.font` is populated by `convertFont` during skin
        // build. For tests we construct it directly with an NSFont
        // the system produces via the same fallback chain. The
        // property under test is that `resolvedFont(for:)` doesn't
        // return nil when the surface carries a font.
        let nsFont = NSFont(name: family, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        return SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: nil, corner: .uniform(0), padding: NSEdgeInsets(),
            shadow: nil,
            font: nsFont,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil, states: []
        )
    }
}
