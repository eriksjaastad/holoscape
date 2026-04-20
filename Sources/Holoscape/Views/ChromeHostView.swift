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
}
