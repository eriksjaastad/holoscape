import AppKit

/// Interior app-content region of a v4 PNG-chrome skin (Component 2 of
/// `claude-specs/chrome/design.md`). Sibling of `ChromeHostView` under
/// `ShapedContentView`; pinned to `chrome.interiorRect` in chrome-image
/// top-left coordinates. Every app subview (TabBarView, NSSplitView,
/// SidebarView, SplitPaneManager, HoloscapeTerminalView, InputBoxView,
/// SessionLauncherView) reparents here under PR #5's Chrome_Mode_Branch
/// — app content lives inside InteriorView, decorative chrome lives
/// above it in ChromeHostView.
///
/// `interiorPath`, when non-nil, installs a `CAShapeLayer` mask so
/// concave interiors clip app content to the declared shape (Req 2.6 /
/// 2.8). For the common rectangular case, `interiorPath` is nil and
/// the view's normal rectangular bounds apply — no mask allocated.
///
/// Property 3 (InteriorView frame tracks interiorRect exactly) is the
/// load-bearing invariant: `layout()` asserts the frame matches the
/// computed-from-`interiorRect` frame so a subview add or superview
/// resize can't silently shift app content off the chrome.
@MainActor
final class InteriorView: NSView {

    // MARK: - Configuration

    /// Pinned position in chrome-image top-left coords. Kept as a
    /// value, not a computed property, so hot reload of the descriptor
    /// can swap this via `updateInteriorRect` (PR #18).
    private(set) var interiorRect: SkinRect

    /// Concave-interior mask path. When non-nil, drives
    /// `layer.mask` rebuild on every `layout()` / `updateInteriorPath`.
    private(set) var interiorPath: [Polygon]?

    /// Active mask layer. Retained so `updateInteriorPath(nil)` can
    /// remove it cleanly without leaking.
    private var interiorMask: CAShapeLayer?

    // MARK: - Init

    init(rect: SkinRect, interiorPath: [Polygon]?) {
        self.interiorRect = rect
        self.interiorPath = interiorPath
        super.init(frame: NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        wantsLayer = true
        layer!.backgroundColor = nil
        // Top-left coords so app subviews laid out inside use the same
        // coordinate convention as the chrome-image geometry the view
        // is pinned to.
        rebuildMaskIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("InteriorView does not support NSCoder initialization")
    }

    // MARK: - Public interface (Component 2)

    /// Swap the interior path (PR #18 hot reload). Rebuilds the mask;
    /// passing `nil` clears any existing mask.
    func updateInteriorPath(_ path: [Polygon]?) {
        self.interiorPath = path
        rebuildMaskIfNeeded()
    }

    // MARK: - Layout

    /// Compute the AppKit frame for `interiorRect` given the
    /// superview's bounds. InteriorView is pinned in chrome-image
    /// top-left coords. `ChromeHostView` (its sibling) has
    /// `isFlipped = true`, so if `superview` is also flipped the rect
    /// applies directly. If not, flip Y against superview height.
    /// Callers pass the superview bounds explicitly so the test suite
    /// can assert the conversion without a full view tree.
    static func computedFrame(interiorRect rect: SkinRect, in superviewBounds: NSRect, superviewIsFlipped: Bool) -> NSRect {
        let originX = rect.x + superviewBounds.origin.x
        let originY: Double
        if superviewIsFlipped {
            originY = rect.y + Double(superviewBounds.origin.y)
        } else {
            // Bottom-left origin: translate top-left y to bottom-left.
            originY = Double(superviewBounds.origin.y)
                + Double(superviewBounds.height)
                - rect.y
                - rect.height
        }
        return NSRect(
            x: originX,
            y: originY,
            width: rect.width,
            height: rect.height
        )
    }

    override func layout() {
        super.layout()
        if let superview {
            let expected = Self.computedFrame(
                interiorRect: interiorRect,
                in: superview.bounds,
                superviewIsFlipped: superview.isFlipped
            )
            if frame != expected {
                frame = expected
            }
        }
        rebuildMaskIfNeeded()
    }

    // MARK: - Mask

    private func rebuildMaskIfNeeded() {
        guard let path = interiorPath, !path.isEmpty else {
            // Transition from masked to unmasked: tear down.
            if interiorMask != nil {
                layer?.mask = nil
                interiorMask = nil
            }
            return
        }

        // Build a single CGPath covering every polygon in local
        // coordinates. `interiorRect.x/y` are the superview offsets; the
        // mask runs in layer-local space, so subtract those.
        let cgPath = CGMutablePath()
        for poly in path {
            guard poly.points.count >= 3 else { continue }
            let first = poly.points[0]
            cgPath.move(to: CGPoint(x: first.x - interiorRect.x, y: first.y - interiorRect.y))
            for pt in poly.points.dropFirst() {
                cgPath.addLine(to: CGPoint(x: pt.x - interiorRect.x, y: pt.y - interiorRect.y))
            }
            cgPath.closeSubpath()
        }

        // Every polygon was degenerate (< 3 vertices). An empty
        // CGPath installed as CAShapeLayer.path clips the view to
        // nothing — install no mask at all instead, matching the
        // graceful-degradation contract that invalid masks are
        // ignored rather than crashing the render (Req 13.5).
        if cgPath.isEmpty {
            if interiorMask != nil {
                layer?.mask = nil
                interiorMask = nil
            }
            return
        }

        let mask = interiorMask ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = cgPath
        mask.fillRule = .evenOdd
        if interiorMask == nil {
            layer?.mask = mask
            interiorMask = mask
        }
    }

    // MARK: - NSView overrides

    /// Top-left origin matches the chrome-image coordinate convention
    /// so subviews reparented from `ShapedContentView` into
    /// `InteriorView` continue to lay out against the same y-axis
    /// direction.
    override var isFlipped: Bool { true }

    // MARK: - Test hooks (internal)

    #if DEBUG
    var _testInteriorMask: CAShapeLayer? { interiorMask }
    var _testInteriorRect: SkinRect { interiorRect }
    #endif
}
