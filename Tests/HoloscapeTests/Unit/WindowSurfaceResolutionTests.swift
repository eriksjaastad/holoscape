import XCTest
import AppKit
@testable import Holoscape

/// Task 9.7 — `window.background` resolution. Covers the static seam
/// `MainWindowController.resolveWindowBackground(from:)` so the mapping
/// from SkinContext to NSWindow.backgroundColor is testable without
/// spinning up a real window + channel manager.
@MainActor
final class WindowSurfaceResolutionTests: XCTestCase {

    private func context(bgColor: NSColor?) -> SkinContext {
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        if let bgColor {
            surfaces[.windowBackground] = SkinContext.ResolvedSurface(
                fill: .color(bgColor), border: nil, corner: .uniform(0),
                padding: .init(), shadow: nil, font: nil,
                text: .init(color: bgColor, shadow: nil),
                animation: nil, states: []
            )
        }
        return SkinContext(surfaces: surfaces, reactive: snap)
    }

    func testSkinnedBackgroundPropagates() {
        let navy = NSColor(red: 0, green: 0, blue: 0.2, alpha: 1)
        let resolved = MainWindowController.resolveWindowBackground(from: context(bgColor: navy))
        XCTAssertEqual(resolved, navy,
                       "Skin-defined window.background color must flow through verbatim")
    }

    func testBuiltInDefaultBackground() {
        // builtInDefaults populates windowBackground with the pre-skinning
        // color (0.1, 0.1, 0.18, 1.0) — verify the mapping round-trips
        // on every channel.
        let resolved = MainWindowController.resolveWindowBackground(from: context(bgColor: nil))
        assertColor(resolved, equals: NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
    }

    func testGradientFillUsesFirstStopColor() {
        // NSWindow.backgroundColor is a single NSColor slot — it can't
        // carry a gradient. For gradient skins we pick the FIRST stop
        // as the NSWindow color so the traffic-lights gap at the
        // titlebar's left edge visually ties to the adjacent tab bar.
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        surfaces[.windowBackground] = SkinContext.ResolvedSurface(
            fill: .gradient(.vertical, [
                GradientStop(offset: 0, color: "#112233"),
                GradientStop(offset: 1, color: "#ffffff"),
            ]),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        let ctx = SkinContext(surfaces: surfaces, reactive: snap)
        let resolved = MainWindowController.resolveWindowBackground(from: ctx)
        assertColor(resolved,
                    equals: NSColor(srgbRed: 0x11/255.0, green: 0x22/255.0, blue: 0x33/255.0, alpha: 1))
    }

    // MARK: - applySkin build-and-reset semantics

    func testBuildSkinContextWithSurfacesKeepsThem() throws {
        let snap = ReactiveUniformSnapshot()
        let navy = NSColor(red: 0, green: 0, blue: 0.2, alpha: 1)
        let surfaces = buildSurfaces(windowBackground: navy)
        let ctx = MainWindowController.buildSkinContext(overriding: surfaces, reactive: snap)
        // The resulting context must paint window.background with the
        // overridden color, not the built-in default.
        let resolved = MainWindowController.resolveWindowBackground(from: ctx)
        XCTAssertEqual(resolved, navy)
    }

    func testBuildSkinContextWithNilResetsToDefault() {
        // applySkin(nil) is the "unload skin" path. The built context
        // must return the pre-skinning default for every well-known
        // surface; verify via window.background.
        let snap = ReactiveUniformSnapshot()
        let ctx = MainWindowController.buildSkinContext(overriding: nil, reactive: snap)
        let resolved = MainWindowController.resolveWindowBackground(from: ctx)
        assertColor(resolved, equals: NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
    }

    // MARK: - Helpers

    private func assertColor(_ actual: NSColor, equals expected: NSColor,
                             file: StaticString = #filePath, line: UInt = #line) {
        let a = actual.usingColorSpace(.sRGB) ?? actual
        let e = expected.usingColorSpace(.sRGB) ?? expected
        XCTAssertEqual(a.redComponent, e.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.alphaComponent, e.alphaComponent, accuracy: 0.001, file: file, line: line)
    }

    private func buildSurfaces(windowBackground: NSColor) -> [SurfaceKey: SkinContext.ResolvedSurface] {
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        surfaces[.windowBackground] = SkinContext.ResolvedSurface(
            fill: .color(windowBackground), border: nil, corner: .uniform(0),
            padding: .init(), shadow: nil, font: nil,
            text: .init(color: windowBackground, shadow: nil),
            animation: nil, states: []
        )
        return surfaces
    }
}
