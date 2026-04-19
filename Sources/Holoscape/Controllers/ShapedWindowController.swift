import AppKit
import QuartzCore

/// Validated window-shape data the renderer consumes. MVP ships
/// polygons only. The enum shape (rather than a plain `[Polygon]`
/// array) is deliberate — Phase 2's mask-image path adds a
/// `.mask(NSImage)` case without touching call sites.
/// Borderless NSWindow subclass that can still accept keyboard focus.
/// AppKit's default for a `.borderless` window is `canBecomeKey ==
/// false` (only titled windows become key by default), which means
/// key events never reach child responders — shaped windows would
/// look right but refuse to let the user type. Overriding both
/// `canBecomeKey` and `canBecomeMain` restores the expected behavior
/// without sacrificing the borderless style required for shaped
/// rendering.
final class ShapedBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct ResolvedWindowShape: Equatable {
    enum Kind: Equatable {
        case polygons([Polygon])
    }
    let kind: Kind

    /// The axis-aligned bounding box of every polygon in the shape,
    /// with the origin clamped to (0, 0). Treated as the "nominal"
    /// content-view size the skin author targeted — consumers scale
    /// polygons from this nominal size to the live content-view
    /// bounds so the shape adapts to window reconstruction and
    /// resize (card #6037).
    ///
    /// Derived from polygons rather than declared in the manifest
    /// because skin authors overwhelmingly think in pixel terms
    /// against an implicit window size; forcing an explicit
    /// `nominalSize` field would surprise them and duplicate info
    /// that's already present in the polygon coordinates.
    var nominalSize: CGSize {
        switch kind {
        case .polygons(let polys):
            var maxX: CGFloat = 0
            var maxY: CGFloat = 0
            for polygon in polys {
                for point in polygon.points {
                    if point.x > maxX { maxX = point.x }
                    if point.y > maxY { maxY = point.y }
                }
            }
            return CGSize(width: maxX, height: maxY)
        }
    }
}

/// Amplify Task 5 — owns the shape-mask lifecycle: env-flag gating,
/// descriptor validation, `CAShapeLayer` mask construction, and full
/// `NSWindow` reconstruction for the style-mask transition.
///
/// Window reconstruction over in-place `styleMask` mutation is the
/// load-bearing architectural decision (PRD Risk 1). Apps that mutate
/// `styleMask` on a live window (`.titled` → `.borderless`) hit a
/// flicker + focus-loss bug that AppKit has had for years; Sketch and
/// OmniGraffle both reconstruct. Amplify follows the same pattern:
/// build a fresh `NSWindow`, transfer the content view, copy frame
/// and key-window state, release the old.
@MainActor
final class ShapedWindowController {

    /// Env-flag gate read ONCE at init. `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS`
    /// must equal `"1"` for shaped rendering to activate; any other value
    /// (absent / `"0"` / garbage) leaves the window titled + rectangular
    /// per Requirement 2.8. Cached rather than re-read because shape
    /// transitions require window reconstruction anyway — a runtime
    /// flip would behave identically to a relaunch.
    let featureFlagEnabled: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.featureFlagEnabled = Self.isFeatureFlagEnabled(in: environment)
    }

    /// Static accessor for the flag. Callers that only need to check
    /// the flag at one moment (like `SkinEngine.resolveWindowShape`)
    /// read it here rather than allocating a throwaway
    /// `ShapedWindowController`. The instance-cached `featureFlagEnabled`
    /// property remains for long-lived owners (`MainWindowController`)
    /// that want a single-read-at-init guarantee.
    static func isFeatureFlagEnabled(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS"] == "1"
    }

    // MARK: - Descriptor validation

    /// Validate a `WindowShapeDescriptor` against the nominal content-
    /// view bounds. Returns a `ResolvedWindowShape` on success, nil +
    /// logged reason on failure.
    ///
    /// Rejection rules:
    /// - `kind: mask` is post-MVP. The enum case is accepted so v3
    ///   manifests round-trip, but the loader rejects any manifest
    ///   declaring it (Requirement 2.9).
    /// - Polygon sets with any polygon whose bounding box lies
    ///   entirely outside the nominal content-view bounds (Requirement 2.4).
    /// - Polygons with fewer than 3 vertices are dropped; if zero
    ///   valid polygons remain, the whole descriptor is rejected.
    ///
    /// `static` so the loader can validate before any renderer state
    /// exists.
    static func validate(
        _ shape: WindowShapeDescriptor,
        against nominalBounds: CGRect
    ) -> ResolvedWindowShape? {
        switch shape.kind {
        case .mask:
            // Requirement 2.9 — mask-image shapes are deferred to post-MVP.
            // Logged with an explicit message so Console.app makes the
            // "skin author declared an unsupported shape" case obvious.
            NSLog("ShapedWindowController: kind: mask is post-MVP; ignoring shape")
            return nil
        case .polygons:
            break
        }

        guard let rawPolygons = shape.polygons, !rawPolygons.isEmpty else {
            NSLog("ShapedWindowController: polygons kind with empty polygon list; ignoring shape")
            return nil
        }

        // Keep only polygons with ≥3 vertices (dropping bad ones is
        // Requirement 13.5's graceful-degradation rule). Each retained
        // polygon must also have its bounding box at least partially
        // inside the nominal content-view bounds — a polygon whose
        // bbox lies entirely outside is rejected per Requirement 2.4.
        var validPolygons: [Polygon] = []
        for (index, polygon) in rawPolygons.enumerated() {
            guard polygon.isValid() else {
                NSLog("ShapedWindowController: polygon[\(index)] has fewer than 3 vertices; dropping")
                continue
            }
            let bbox = Self.boundingBox(of: polygon)
            if !bbox.intersects(nominalBounds) {
                NSLog("ShapedWindowController: polygon[\(index)] bounding box \(bbox) lies entirely outside content bounds \(nominalBounds); rejecting shape")
                return nil
            }
            validPolygons.append(polygon)
        }

        guard !validPolygons.isEmpty else {
            NSLog("ShapedWindowController: no valid polygons remain; ignoring shape")
            return nil
        }

        return ResolvedWindowShape(kind: .polygons(validPolygons))
    }

    /// Axis-aligned bounding box of a polygon's vertices. Used by
    /// `validate` and `buildMaskLayer` to size the mask layer.
    static func boundingBox(of polygon: Polygon) -> CGRect {
        guard let first = polygon.points.first else { return .zero }
        var minX = first.x, minY = first.y
        var maxX = first.x, maxY = first.y
        for p in polygon.points.dropFirst() {
            if p.x < minX { minX = p.x }
            if p.y < minY { minY = p.y }
            if p.x > maxX { maxX = p.x }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Polygon scaling

    /// Scale every polygon's vertices from `nominal` space into `target`
    /// space. Degenerate source dimensions (zero width or height) skip
    /// the corresponding axis — otherwise we'd divide by zero and the
    /// scale collapses the polygon. Preserves vertex count and order
    /// so every downstream consumer (mask, sampler, drag tracker) sees
    /// the same polygon in the same space (card #6037).
    static func scale(
        polygons: [Polygon],
        from nominal: CGSize,
        to target: CGSize
    ) -> [Polygon] {
        let sx: CGFloat = nominal.width  > 0 ? target.width  / nominal.width  : 1
        let sy: CGFloat = nominal.height > 0 ? target.height / nominal.height : 1
        if sx == 1 && sy == 1 { return polygons }
        return polygons.map { polygon in
            Polygon(points: polygon.points.map { Point(x: $0.x * sx, y: $0.y * sy) })
        }
    }

    // MARK: - Mask construction

    /// Build a `CAShapeLayer` whose path is the union of `shape`'s
    /// polygons, sized to `contentBounds`. Install as
    /// `contentView.layer.mask` — anywhere the mask path is transparent,
    /// the window renders transparent and click-through (Requirement 3.1)
    /// applies.
    ///
    /// When Reduce Transparency is enabled (Requirement 2.6), the mask
    /// layer still clips to the polygon silhouette, but the caller is
    /// expected to fill the mask's complement with opaque system-gray
    /// at the window-background level. This keeps the shape outline
    /// visible while removing visual transparency.
    func buildMaskLayer(
        for shape: ResolvedWindowShape,
        in contentBounds: CGRect
    ) -> CALayer? {
        guard case .polygons(let polygons) = shape.kind else { return nil }
        guard !polygons.isEmpty else { return nil }

        let path = CGMutablePath()
        for polygon in polygons {
            guard let first = polygon.points.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in polygon.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
        }

        let mask = CAShapeLayer()
        mask.frame = contentBounds
        mask.path = path
        // Non-zero fill rule matches CoreGraphics default and does the
        // right thing for overlapping polygon unions; even-odd would
        // carve holes out of overlaps which is not what "union of
        // silhouettes" means.
        mask.fillRule = .nonZero
        mask.fillColor = NSColor.black.cgColor
        return mask
    }

    // MARK: - Window reconstruction

    /// Result of `reconstructWindow`. The caller is responsible for
    /// ordering the new window front (or key-and-front) and closing
    /// the old one. This function stays pure-construction so it can
    /// be called from tests without AppKit display-path side effects.
    struct ReconstructionResult {
        let newWindow: NSWindow
        /// Was the old window the key window at reconstruction time?
        /// Callers use this to decide between `orderFront` and
        /// `makeKeyAndOrderFront` on the new window.
        let wasKey: Bool
    }

    /// Build a fresh `NSWindow` in the right style mask for `targetShape`.
    /// Content view is moved across, frame is preserved, first-responder
    /// state is restored on the new window.
    ///
    /// `targetShape == nil` → rectangular (titled / closable / resizable
    /// / miniaturizable / fullSizeContentView). Matches pre-Amplify
    /// defaults so the "transition out of shaped mode" path reproduces
    /// the exact pre-skinning window configuration.
    ///
    /// `targetShape != nil` → borderless with `.fullSizeContentView`,
    /// `isOpaque = false`, `backgroundColor = .clear`. Caller installs
    /// the mask layer on the reconstructed window's content view.
    ///
    /// This method does NOT install the mask, transfer the delegate,
    /// close the old window, or order the new one front. The caller
    /// (MainWindowController.applyWindowShape) owns each of those
    /// concerns. Keeping them out of this function means it stays
    /// deterministic and test-friendly — reconstructing via a real
    /// NSWindow + NSView in tests doesn't trip AppKit's display path.
    func reconstructWindow(
        currentWindow: NSWindow,
        contentView: NSView,
        targetShape: ResolvedWindowShape?
    ) -> ReconstructionResult {
        let frame = currentWindow.frame
        let wasKey = currentWindow.isKeyWindow
        let firstResponder = currentWindow.firstResponder

        let newStyleMask: NSWindow.StyleMask
        let isOpaque: Bool
        let backgroundColor: NSColor
        if targetShape != nil {
            // Borderless shaped window. `.fullSizeContentView` keeps the
            // content view's bounds equal to the window frame so mask
            // coordinates match content-view coordinates 1:1.
            newStyleMask = [.borderless, .resizable, .fullSizeContentView]
            isOpaque = false
            backgroundColor = .clear
        } else {
            newStyleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            isOpaque = true
            // Use the system default. The pre-Amplify rectangular window
            // hardcoded a dark `(0.1, 0.1, 0.18, 1.0)`, but that color
            // is the parent chrome-skinning spec's default — when a skin
            // repaints `window.background` via `applyWindowSurfaces`,
            // the caller clobbers this value shortly after reconstruction.
            // Using `windowBackgroundColor` means a user in light mode
            // with no skin doesn't get a jarring dark flash during the
            // reconstruction gap.
            backgroundColor = .windowBackgroundColor
        }

        // `.borderless` windows cannot become key by default — see
        // `ShapedBorderlessWindow`. Use the subclass only when the
        // target is shaped so the rectangular path stays on the stock
        // `NSWindow` class (no behavior change for non-Amplify users).
        let newWindow: NSWindow
        if targetShape != nil {
            newWindow = ShapedBorderlessWindow(
                contentRect: frame,
                styleMask: newStyleMask,
                backing: .buffered,
                defer: false
            )
        } else {
            newWindow = NSWindow(
                contentRect: frame,
                styleMask: newStyleMask,
                backing: .buffered,
                defer: false
            )
        }
        // Match the bootstrap window (MainWindowController.init): opt
        // out of AppKit's legacy auto-release-on-close so ARC is the
        // sole owner. Without this, `oldWindow.close()` in
        // applyWindowShape double-releases and a scheduled
        // _NSWindowTransformAnimation dealloc crashes on a zombie.
        newWindow.isReleasedWhenClosed = false
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isOpaque = isOpaque
        newWindow.backgroundColor = backgroundColor
        newWindow.setFrame(frame, display: false)

        // Move the content view over. Setting contentView re-parents
        // the entire subview tree in one call — subviews keep their
        // frames and constraints.
        newWindow.contentView = contentView

        // Restore first-responder. Only if it's an NSView now rooted in
        // the new window (because we just moved the content tree). A
        // stale non-view responder (from a closing window) would crash
        // makeFirstResponder; we drop it rather than preserve.
        newWindow.makeFirstResponder(nil)
        if let responder = firstResponder as? NSView, responder.window === newWindow {
            newWindow.makeFirstResponder(responder)
        }

        return ReconstructionResult(newWindow: newWindow, wasKey: wasKey)
    }
}
