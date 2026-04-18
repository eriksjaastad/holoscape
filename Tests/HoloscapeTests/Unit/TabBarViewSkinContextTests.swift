import XCTest
import AppKit
@testable import Holoscape

/// Task 9.1 — TabBarView reads its container and tab-state colors from
/// the injected SkinContext. Without a context the view still renders
/// (using the hardcoded pre-skinning constants) — this is the fallback
/// path used by XCUITest fixtures that don't build a full controller.
@MainActor
final class TabBarViewSkinContextTests: XCTestCase {

    private func makeContext(tabBarContainer: NSColor = .black,
                             tabActive: NSColor = .blue) -> SkinContext {
        // Build a skin whose tabBar container and active-tab surfaces
        // override the built-in defaults, then let builtInDefaults fill
        // the rest of the 23 keys.
        let snap = ReactiveUniformSnapshot()
        let base = SkinContext.builtInDefaults(reactive: snap)
        var surfaces = base.allResolvedSurfacesForTesting
        surfaces[.tabBarContainer] = SkinContext.ResolvedSurface(
            fill: .color(tabBarContainer),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil, text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        surfaces[.tabBarTabActive] = SkinContext.ResolvedSurface(
            fill: .color(tabActive),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil, text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        return SkinContext(surfaces: surfaces, reactive: snap)
    }

    func testAssigningSkinContextRepaintsContainer() {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.layoutSubtreeIfNeeded()

        // Before: uses the built-in constant.
        let preAssign = view.layer?.backgroundColor
        XCTAssertNotNil(preAssign)

        let magenta = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        view.skinContext = makeContext(tabBarContainer: magenta)

        XCTAssertEqual(view.layer?.backgroundColor, magenta.cgColor,
                       "Assigning a SkinContext with a magenta tabBar.container must repaint the container")
    }

    func testSkinDidChangeNotificationRepaintsInIsolation() {
        // Exercises only the `.skinDidChange` observer path, with no
        // `skinContext =` assignment between set-up and post. Breaks if
        // the observer is ever disconnected or calls the wrong method.
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.layoutSubtreeIfNeeded()

        // Hold a reference to a mutable surfaces dictionary so we can
        // swap the container fill without reassigning skinContext.
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        let green = NSColor(red: 0, green: 1, blue: 0, alpha: 1)
        surfaces[.tabBarContainer] = SkinContext.ResolvedSurface(
            fill: .color(green), border: nil, corner: .uniform(0),
            padding: .init(), shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        // Assign once, then mutate-and-notify.
        view.skinContext = SkinContext(surfaces: surfaces, reactive: snap)

        let purple = NSColor(red: 0.5, green: 0, blue: 0.5, alpha: 1)
        surfaces[.tabBarContainer] = SkinContext.ResolvedSurface(
            fill: .color(purple), border: nil, corner: .uniform(0),
            padding: .init(), shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        view.skinContext = SkinContext(surfaces: surfaces, reactive: snap)
        // didSet already repainted. Now forcibly reset and verify the
        // notification path alone drives the repaint.
        view.layer?.backgroundColor = NSColor.black.cgColor
        NotificationCenter.default.post(name: .skinDidChange, object: nil)
        XCTAssertEqual(view.layer?.backgroundColor, purple.cgColor,
                       ".skinDidChange observer must re-resolve from the held context")
    }

    func testFallsBackToBuiltInWhenNoContext() {
        // The built-in tabBar.container default is (0.06, 0.06, 0.12, 1.0).
        // Without a SkinContext, setupScrollView must paint that exact
        // constant so the standalone rendering path (XCUITest fixtures)
        // stays visually identical to the skinned path's built-in mode.
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.layoutSubtreeIfNeeded()

        XCTAssertNil(view.skinContext)

        let expected = NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0).cgColor
        let actual = view.layer?.backgroundColor
        XCTAssertNotNil(actual, "Hardcoded fallback must paint a non-nil background")

        // CGColor `==` is pointer equality; compare components instead.
        guard let actualComps = actual?.components, let expectedComps = expected.components else {
            XCTFail("Both colors must have RGB components to compare")
            return
        }
        XCTAssertEqual(actualComps.count, expectedComps.count)
        for (a, e) in zip(actualComps, expectedComps) {
            XCTAssertEqual(a, e, accuracy: 0.001,
                           "Fallback background must match the hardcoded (0.06, 0.06, 0.12, 1.0)")
        }
    }
}

// MARK: - Testing hook

extension SkinContext {
    /// Test-only accessor exposing the private `surfaces` dictionary so
    /// tests can build variants of the built-in defaults without having
    /// to reconstruct all 23 keys from scratch.
    var allResolvedSurfacesForTesting: [SurfaceKey: ResolvedSurface] {
        SurfaceKey.allCases.reduce(into: [:]) { result, key in
            result[key] = resolve(key)
        }
    }
}
