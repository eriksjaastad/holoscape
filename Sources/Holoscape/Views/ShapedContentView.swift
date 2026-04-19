import AppKit

/// Content view for a shaped window. Overrides `hitTest(_:)` so
/// points outside the declared polygon region pass through to
/// whatever is behind Holoscape (Amplify Requirement 3.1).
///
/// Without this override, AppKit's default hit testing treats the
/// entire (borderless) window as clickable — the mask makes those
/// regions invisible, but mouse events still land inside the window
/// instead of reaching the app beneath. Returning `nil` from
/// `hitTest(_:)` signals "this point isn't my problem, try the
/// window server's next hit test target," which produces native
/// click-through behavior.
///
/// `sampler` is the injected polygon-or-whatever oracle. When nil,
/// the override short-circuits to `super.hitTest(_:)` — default
/// rectangular behavior. Nil is the legitimate state between
/// reconstruction-to-shaped and the sampler injection that follows
/// in `MainWindowController.applyWindowShape`.
final class ShapedContentView: NSView {
    /// The hit-region oracle driving click-through decisions.
    /// MainWindowController sets this after reconstruction; swapping
    /// in a new sampler is how per-skin shape changes take effect
    /// without rebuilding the view.
    ///
    /// Phase-2 extension hook: this can become a sum type holding
    /// either `HitRegionSampler` (polygons) or `AlphaHitSampler`
    /// (mask image) when mask-image shapes ship. Keeping the property
    /// as a simple optional-of-struct keeps the MVP surface minimal;
    /// the future extension changes the TYPE without changing the
    /// ownership pattern.
    var sampler: HitRegionSampler?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Content-view coordinates on a borderless + fullSizeContentView
        // window match window-content coordinates 1:1, which is what
        // the sampler's polygons are authored against. No coordinate
        // conversion needed.
        if let sampler = sampler, !sampler.contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}
