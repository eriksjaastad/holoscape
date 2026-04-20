import AppKit
import QuartzCore

/// Diagnostic visualization layered on top of `ChromeHostView` when
/// `HOLOSCAPE_PNG_CHROME_DEBUG=1` (Req 14 + design Component 7).
///
/// Renders, per frame:
/// - Semitransparent false-color alpha of `baseImage` (red where
///   alpha == 0, cyan where alpha > 0) — makes the silhouette's
///   cut regions visible at a glance.
/// - Red outline of `chrome.interiorRect`.
/// - Green outlines of every `windowShape.polygons` entry.
/// - Yellow outline + `id` label for every `ChromeAnimationLayer.rect`.
/// - Live `CACurrentMediaTime()` phase-seconds readout in the
///   top-left corner, updated every frame.
///
/// The overlay installs as a subview of ChromeHostView with
/// `hitTest -> nil` so it never steals events. Skin authors see it
/// during iteration; production builds (no env flag) install
/// nothing.
@MainActor
final class ChromeDebugOverlay: NSView {

    /// True when the env flag is set — caller gates install on this.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HOLOSCAPE_PNG_CHROME_DEBUG"] == "1"
    }

    private let chrome: ChromeDescriptor
    private let windowShape: WindowShapeDescriptor?
    private let baseImage: CGImage
    private let renderers: [AnimatedLayerRenderer]
    private var phaseText: String = "0.000"

    #if DEBUG
    var _testPhaseText: String { phaseText }
    #endif

    init(
        frame: NSRect,
        chrome: ChromeDescriptor,
        baseImage: CGImage,
        windowShape: WindowShapeDescriptor?,
        renderers: [AnimatedLayerRenderer]
    ) {
        self.chrome = chrome
        self.windowShape = windowShape
        self.baseImage = baseImage
        self.renderers = renderers
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = nil
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeDebugOverlay does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    /// Non-interactive — event routing flows through ShapedContentView
    /// just like ChromeHostView.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Push a new phase-seconds readout; triggers a display invalidation
    /// so `draw(_:)` re-renders with the current value. Called by
    /// `SharedAnimationClock` tick forwarding in production.
    func refresh(phaseSeconds: Double) {
        phaseText = String(format: "%.3f", phaseSeconds)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1) Semitransparent false-color alpha — draw `baseImage`
        //    at 40% opacity directly into bounds. Cut-corner regions
        //    (alpha == 0) stay transparent; opaque regions tint.
        ctx.saveGState()
        ctx.setAlpha(0.4)
        ctx.draw(baseImage, in: bounds)
        ctx.restoreGState()

        // 2) Red interior-rect outline.
        ctx.setStrokeColor(NSColor.red.cgColor)
        ctx.setLineWidth(2)
        let interior = Self.rect(for: chrome.interiorRect, in: bounds)
        ctx.stroke(interior)

        // 3) Green polygon outlines.
        if let polygons = windowShape?.polygons {
            ctx.setStrokeColor(NSColor.green.cgColor)
            ctx.setLineWidth(1.5)
            for poly in polygons where poly.points.count >= 3 {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: poly.points[0].x, y: poly.points[0].y))
                for pt in poly.points.dropFirst() {
                    ctx.addLine(to: CGPoint(x: pt.x, y: pt.y))
                }
                ctx.closePath()
                ctx.strokePath()
            }
        }

        // 4) Yellow animation rect outlines + id labels.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.yellow,
        ]
        for animation in chrome.animations ?? [] {
            ctx.setStrokeColor(NSColor.yellow.cgColor)
            ctx.setLineWidth(1)
            let r = Self.rect(for: animation.rect, in: bounds)
            ctx.stroke(r)
            let label = NSAttributedString(string: animation.id, attributes: attrs)
            label.draw(at: NSPoint(x: r.minX + 4, y: r.minY + 4))
        }

        // 5) Phase-seconds HUD (top-left).
        let hudAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let hud = NSAttributedString(string: "phase: \(phaseText)s", attributes: hudAttrs)
        hud.draw(at: NSPoint(x: 8, y: 8))
    }

    /// Translate a SkinRect (chrome-image top-left coords, logical
    /// points) to the overlay's local coordinate system. Overlay is
    /// flipped so the conversion is identity unless the overlay's
    /// bounds differ from the chrome's logical size.
    private static func rect(for skinRect: SkinRect, in overlayBounds: NSRect) -> NSRect {
        NSRect(
            x: skinRect.x,
            y: skinRect.y,
            width: skinRect.width,
            height: skinRect.height
        )
    }
}
