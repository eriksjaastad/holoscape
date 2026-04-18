import XCTest
import AppKit
@testable import Holoscape

/// Task 9.9 — Integration test for chrome view migrations.
///
/// Unit-level tests in the Unit/ subdirectory verify that the right
/// `SurfaceKey` drives the right `layer.backgroundColor` property. This
/// test goes further: it renders each chrome view's layer tree
/// offscreen via `CALayer.render(in:)`, samples the resulting pixel
/// buffer via `NSBitmapImageRep`, and asserts the sampled color matches
/// the skin override. That proves the layer color actually reached the
/// rendered pixels — not just that the model value was written.
///
/// The spec's wording ("render offscreen via `NSView.cacheDisplay(in:to:)`")
/// doesn't work for layer-hosted views without a host window:
/// `cacheDisplay` only calls `draw(_:in:)` on non-layer views, and CA's
/// compositor doesn't run for unattached layers — the bitmap comes
/// back blank. `CALayer.render(in:)` walks the layer tree into a
/// supplied `CGContext`, which is what the spec actually wants.
///
/// The negative assertion (sampled pixel does not equal the built-in
/// default) is what the spec means by "no hardcoded defaults bleed
/// through." A migration bug that forgot to swap the default color for
/// the skinned value would pass the unit test (layer was set to the
/// default, not to the override) and fail this one (the pixel is the
/// default).
///
/// Covered surfaces, one per view:
///   - TabBarView        → `tabBar.container`
///   - SidebarView       → `sidebar.container`
///   - InputBoxView      → `inputBox.container`
///   - SessionLauncherView → `sessionLauncher.container`
///   - SplitPaneView     → `splitPane.divider` (active border)
///
/// TerminalContainerView is not covered — the class was deleted before
/// this test landed (see `claude-specs/chrome-skinning/tasks.md` 9.5).
@MainActor
final class ChromeViewMigrationTests: XCTestCase {

    // MARK: - Distinctive test colors
    //
    // Each surface gets a saturated color that can't be confused with a
    // built-in default. The assertion tolerance is `± 1/255` to absorb
    // any color-space conversion noise between NSColor and CGColor.

    private struct TestColors {
        static let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        static let cyan    = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
        static let yellow  = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        static let orange  = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        static let lime    = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    }

    // MARK: - Per-view pixel assertions

    func testTabBarViewRendersSkinnedContainerColor() {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.wantsLayer = true
        view.skinContext = makeContext(overrides: [.tabBarContainer: TestColors.magenta])
        view.layoutSubtreeIfNeeded()

        let bitmap = renderToBitmap(view)
        let sampled = sampleCenter(of: bitmap)
        assertColorMatches(sampled, TestColors.magenta,
                           message: "tabBar.container override must reach the pixel buffer")
        assertColorDoesNotMatch(sampled, builtInDefaultFill(for: .tabBarContainer),
                                message: "Hardcoded default must not bleed through")
    }

    func testSidebarViewRendersSkinnedContainerColor() {
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        view.wantsLayer = true
        view.skinContext = makeContext(overrides: [.sidebarContainer: TestColors.cyan])
        view.layoutSubtreeIfNeeded()

        let bitmap = renderToBitmap(view)
        let sampled = sampleCenter(of: bitmap)
        assertColorMatches(sampled, TestColors.cyan,
                           message: "sidebar.container override must reach the pixel buffer")
        assertColorDoesNotMatch(sampled, builtInDefaultFill(for: .sidebarContainer),
                                message: "Hardcoded default must not bleed through")
    }

    func testInputBoxViewRendersSkinnedFieldColor() {
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.wantsLayer = true
        // InputBoxView is an NSTextField; skinnable fill drives `backgroundColor`
        // on the text field itself, not its layer's backgroundColor directly.
        // cacheDisplay picks up the field-level color through the render pipeline.
        view.skinContext = makeContext(overrides: [.inputBoxField: TestColors.yellow])
        view.layoutSubtreeIfNeeded()

        let bitmap = renderToBitmap(view)
        let sampled = sampleCenter(of: bitmap)
        assertColorMatches(sampled, TestColors.yellow,
                           message: "inputBox.field override must reach the pixel buffer")
        assertColorDoesNotMatch(sampled, builtInDefaultFill(for: .inputBoxField),
                                message: "Hardcoded default must not bleed through")
    }

    func testSessionLauncherViewRendersSkinnedContainerColor() {
        let view = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        view.wantsLayer = true
        view.skinContext = makeContext(overrides: [.sessionLauncherContainer: TestColors.orange])
        view.layoutSubtreeIfNeeded()

        let bitmap = renderToBitmap(view)
        let sampled = sampleCenter(of: bitmap)
        assertColorMatches(sampled, TestColors.orange,
                           message: "sessionLauncher.container override must reach the pixel buffer")
        assertColorDoesNotMatch(sampled, builtInDefaultFill(for: .sessionLauncherContainer),
                                message: "Hardcoded default must not bleed through")
    }

    func testSplitPaneViewRendersSkinnedActiveBorderColor() {
        // SplitPaneView paints its active-pane border from splitPaneDivider.border.
        // Fill is also skinnable but the unit tests use border as the test surface
        // because the divider is the visually prominent artifact; we match that
        // convention here. Sampling is edge-biased (just inside the border
        // region) to catch the border paint, not the interior fill.
        let view = SplitPaneView(paneId: UUID())
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        view.wantsLayer = true
        view.isActivePane = true

        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        surfaces[.splitPaneDivider] = SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: .init(color: TestColors.lime, width: 4),
            corner: .uniform(0), padding: .init(), shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        view.skinContext = SkinContext(surfaces: surfaces, reactive: snap)
        view.layoutSubtreeIfNeeded()

        let bitmap = renderToBitmap(view)
        // Sample two pixels inside the 4pt border ring.
        let topEdge = sampleColor(of: bitmap, at: CGPoint(x: bitmap.pixelsWide / 2, y: 1))
        let leftEdge = sampleColor(of: bitmap, at: CGPoint(x: 1, y: bitmap.pixelsHigh / 2))
        // At least one of the edge samples must match the skinned border.
        // cacheDisplay coordinate systems can flip; sampling both edges
        // guards against the sampler landing just outside the border ring.
        XCTAssertTrue(
            colorsMatch(topEdge, TestColors.lime) || colorsMatch(leftEdge, TestColors.lime),
            "splitPane.divider border color must reach the rendered pixels — sampled top=\(topEdge), left=\(leftEdge)"
        )
    }

    // MARK: - Rendering helpers

    /// Render `view`'s layer tree directly into a bitmap via
    /// `CALayer.render(in:)`.
    ///
    /// `NSView.cacheDisplay(in:to:)` produces blank bitmaps for
    /// layer-hosted views rendered offscreen without a host window —
    /// `draw(_:in:)` is never called and Core Animation's compositor
    /// doesn't run. `CALayer.render(in:)` bypasses CA's compositing
    /// loop and walks the layer tree into the given `CGContext`, which
    /// is what we actually want for pixel-level assertions.
    private func renderToBitmap(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        // Force layer display so backingColor/border/etc. are committed
        // into the layer's render state before we capture.
        view.layer?.setNeedsDisplay()
        view.layer?.displayIfNeeded()

        let width = max(1, Int(view.bounds.width))
        let height = max(1, Int(view.bounds.height))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
            XCTFail("Failed to create bitmap context for \(type(of: view))")
            return NSBitmapImageRep()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        view.layer?.render(in: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Sample the center pixel of the bitmap. Center avoids sub-view chrome
    /// (scrollers, separators) that might sit at the edges of some views.
    private func sampleCenter(of bitmap: NSBitmapImageRep) -> NSColor {
        let x = bitmap.pixelsWide / 2
        let y = bitmap.pixelsHigh / 2
        return sampleColor(of: bitmap, at: CGPoint(x: x, y: y))
    }

    /// Read the color at a specific pixel coordinate. NSBitmapImageRep's
    /// `colorAt(x:y:)` returns the device-space color, which we normalize
    /// to the sRGB color space so the comparison matches our `srgbRed:`
    /// test fixtures.
    private func sampleColor(of bitmap: NSBitmapImageRep, at point: CGPoint) -> NSColor {
        let xInt = max(0, min(bitmap.pixelsWide - 1, Int(point.x)))
        let yInt = max(0, min(bitmap.pixelsHigh - 1, Int(point.y)))
        guard let color = bitmap.colorAt(x: xInt, y: yInt) else {
            XCTFail("Could not sample pixel at (\(xInt), \(yInt))")
            return .clear
        }
        return color.usingColorSpace(.sRGB) ?? color
    }

    // MARK: - SkinContext construction

    /// Build a SkinContext whose surfaces override the given keys with
    /// the supplied fill colors. Unreferenced keys fall back to
    /// `SkinContext.builtInDefaults`.
    private func makeContext(overrides: [SurfaceKey: NSColor]) -> SkinContext {
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        for (key, color) in overrides {
            surfaces[key] = SkinContext.ResolvedSurface(
                fill: .color(color), border: nil, corner: .uniform(0),
                padding: .init(), shadow: nil, font: nil,
                text: .init(color: color, shadow: nil),
                animation: nil, states: []
            )
        }
        return SkinContext(surfaces: surfaces, reactive: snap)
    }

    /// Extract the solid-color component of the built-in default fill
    /// for a surface key. Used for the negative "defaults don't bleed"
    /// assertion. Non-color defaults (gradient, image) return nil and
    /// the caller falls back to a sentinel value.
    private func builtInDefaultFill(for key: SurfaceKey) -> NSColor {
        let resolved = SkinContext.defaultSurface(for: key)
        if case .color(let color) = resolved.fill {
            return color.usingColorSpace(.sRGB) ?? color
        }
        return .clear
    }

    // MARK: - Assertion helpers

    private func colorsMatch(_ actual: NSColor, _ expected: NSColor, tolerance: CGFloat = 1.0 / 255.0) -> Bool {
        let a = actual.usingColorSpace(.sRGB) ?? actual
        let e = expected.usingColorSpace(.sRGB) ?? expected
        return abs(a.redComponent   - e.redComponent)   <= tolerance
            && abs(a.greenComponent - e.greenComponent) <= tolerance
            && abs(a.blueComponent  - e.blueComponent)  <= tolerance
            && abs(a.alphaComponent - e.alphaComponent) <= tolerance
    }

    private func assertColorMatches(_ actual: NSColor, _ expected: NSColor,
                                    message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        if !colorsMatch(actual, expected) {
            XCTFail("\(message) — actual=\(actual), expected=\(expected)", file: file, line: line)
        }
    }

    private func assertColorDoesNotMatch(_ actual: NSColor, _ other: NSColor,
                                         message: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        if colorsMatch(actual, other) {
            XCTFail("\(message) — actual=\(actual) unexpectedly matched default=\(other)", file: file, line: line)
        }
    }
}
