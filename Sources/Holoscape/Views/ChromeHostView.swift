import AppKit

/// PNG-chrome architecture, PR #1 — minimal alpha-aware compositing host
/// for the transparency prototype (claude-specs/chrome/tasks.md Task 1.1,
/// docs/png-chrome-prd.md §15 Risk #1 mitigation).
///
/// This version installs a single static RGBA image on the layer's
/// `contents` and lets AppKit honor the image's alpha channel as the
/// window shape. PR #3 evolves it into the full compositing host with
/// z-ordered animated sublayers (design.md Component 1); this class is
/// deliberately minimal so the alpha-is-the-window-shape assumption can
/// be validated without any of the downstream machinery in the way.
final class ChromeHostView: NSView {
    init(frame: NSRect, baseImage: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        // `layer` is guaranteed non-nil after wantsLayer = true on an
        // explicit-backing NSView, but the optional accessor still
        // requires unwrap. Force is safe here.
        layer!.contents = baseImage
        layer!.contentsGravity = .resize
        // Don't paint a background color — the alpha from layer.contents
        // IS the window shape. Any non-nil backgroundColor would fill the
        // cut-corner regions with an opaque pixel and defeat the test.
        layer!.backgroundColor = nil
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeHostView does not support NSCoder initialization")
    }

    /// ChromeHostView is non-interactive by design (see design.md Component 1).
    /// Returning nil here means PR #3 can install ChromeHostView as a subview of
    /// ShapedContentView and get click-through routing for free — clicks inside
    /// ChromeHostView's frame fall through to ShapedContentView, whose polygon
    /// sampler decides whether the click is inside the silhouette or should
    /// escape the window entirely. In the PR #1 prototype, ChromeHostView is
    /// installed directly as contentView (no ShapedContentView above it), so
    /// this override does not produce desktop click-through at cut corners;
    /// true click-through lands in PR #3 when the full view graph is wired up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
