import XCTest
import AppKit
@testable import Holoscape

/// Task 9.3, 9.4, 9.6 — migrations on InputBoxView, SessionLauncherView,
/// and SplitPaneView. Task 9.5's target (`TerminalContainerView`) was
/// deleted in the same commit that migrated these views — the class
/// had been replaced by `SplitPaneManager` two weeks earlier and was
/// dead code. The `terminalContainerPadding` SurfaceKey remains in the
/// spec for a future re-introduction of a terminal-wrapping view.
///
/// Each view already has a skin context observer path tested end-to-end
/// in TabBarViewSkinContextTests — these tests focus on the per-view
/// surface-key wiring (that the right `SurfaceKey` drives the right
/// visual property) and the nil-context fallback.
@MainActor
final class SmallViewsSkinContextTests: XCTestCase {

    private func context(key: SurfaceKey, color: NSColor) -> SkinContext {
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        surfaces[key] = SkinContext.ResolvedSurface(
            fill: .color(color), border: nil, corner: .uniform(0),
            padding: .init(), shadow: nil, font: nil,
            text: .init(color: color, shadow: nil),
            animation: nil, states: []
        )
        return SkinContext(surfaces: surfaces, reactive: snap)
    }

    // MARK: - InputBoxView

    func testInputBoxSkinContextRepaintsFieldBg() {
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let cyan = NSColor(red: 0, green: 1, blue: 1, alpha: 1)
        view.skinContext = context(key: .inputBoxField, color: cyan)
        XCTAssertEqual(view.backgroundColor, cyan,
                       "inputBoxField fill must drive backgroundColor")
        XCTAssertEqual(view.textColor, cyan,
                       "inputBoxField text color must drive textColor")
    }

    func testInputBoxNilContextRestoresBuiltInField() {
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.skinContext = context(key: .inputBoxField, color: .red)
        view.skinContext = nil

        let expected = NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0)
        assertColorsClose(view.backgroundColor, expected)
    }

    // MARK: - SessionLauncherView

    func testSessionLauncherSkinContextRepaintsContainer() {
        let view = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let yellow = NSColor(red: 1, green: 1, blue: 0, alpha: 1)
        view.skinContext = context(key: .sessionLauncherContainer, color: yellow)
        XCTAssertEqual(view.layer?.backgroundColor, yellow.cgColor)
    }

    func testSessionLauncherNilContextRestoresBuiltInContainer() {
        let view = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        view.skinContext = context(key: .sessionLauncherContainer, color: .red)
        view.skinContext = nil

        let expected = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor
        assertCGColorComponents(view.layer?.backgroundColor, expected)
    }

    // MARK: - SplitPaneView
    //
    // NOTE: `splitPaneDivider` is reused here for the active-pane border
    // color even though its name reads as "the bar between panes." This
    // is intentional — the surface enum is spec-level and renaming is
    // deferred; until then, skin authors treat `splitPane.divider`'s
    // `border` field as the active-pane highlight ring. Documenting the
    // aliasing here so a future reader doesn't spend time hunting for a
    // dedicated border surface.

    func testSplitPaneSkinContextDrivesActiveBorderColor() {
        let view = SplitPaneView(paneId: UUID())
        // Build a context whose splitPaneDivider surface declares a
        // magenta border. Active border on the pane should pick it up.
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        let magenta = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        surfaces[.splitPaneDivider] = SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: .init(color: magenta, width: 2),
            corner: .uniform(0), padding: .init(), shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        view.skinContext = SkinContext(surfaces: surfaces, reactive: snap)
        view.isActivePane = true
        XCTAssertEqual(view.layer?.borderColor, magenta.cgColor,
                       "Active pane must pull its border color from splitPaneDivider.border")
    }

    func testSplitPaneInactiveStaysClearRegardlessOfSkin() {
        let view = SplitPaneView(paneId: UUID())
        view.skinContext = context(key: .splitPaneDivider, color: .red)
        view.isActivePane = false
        XCTAssertEqual(view.layer?.borderColor, NSColor.clear.cgColor,
                       "Inactive pane must stay clear — skin affects active-state color only")
    }

    // MARK: - Helpers

    /// `CGColor ==` is pointer equality; we compare components so a
    /// fresh NSColor-to-CGColor round-trip doesn't fail the test.
    private func assertColorsClose(_ actual: NSColor?, _ expected: NSColor,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("Expected color \(expected), got nil", file: file, line: line)
            return
        }
        let a = actual.usingColorSpace(.sRGB) ?? actual
        let e = expected.usingColorSpace(.sRGB) ?? expected
        XCTAssertEqual(a.redComponent, e.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.alphaComponent, e.alphaComponent, accuracy: 0.001, file: file, line: line)
    }

    private func assertCGColorComponents(_ actual: CGColor?, _ expected: CGColor,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard let actualComps = actual?.components, let expectedComps = expected.components else {
            XCTFail("Both colors must have components to compare", file: file, line: line)
            return
        }
        XCTAssertEqual(actualComps.count, expectedComps.count, file: file, line: line)
        for (a, e) in zip(actualComps, expectedComps) {
            XCTAssertEqual(a, e, accuracy: 0.001, file: file, line: line)
        }
    }
}
