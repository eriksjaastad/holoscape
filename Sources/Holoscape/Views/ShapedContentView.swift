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
/// Invisible drag strip installed on top of every other subview in a
/// shaped window. `isMovableByWindowBackground = true` is useless in
/// Holoscape because the content view is fully populated with chrome
/// subviews (tab bar, sidebar, terminal) — there is no bare "window
/// background" pixel for AppKit to latch drag onto. This overlay
/// hands a dedicated strip of pixels the sole job of moving the
/// window, Winamp-title-bar-style.
///
/// No fill, no sampler, no interaction beyond performDrag. Installed
/// and torn down by `MainWindowController.applyDragRegions` when a
/// shape is active and the skin declares no explicit drag regions
/// (Req 4.6 fallback — whole-window drag).
final class WindowDragOverlay: NSView {
    override func mouseDown(with event: NSEvent) {
        // `performDrag` drives the native window-move gesture; no
        // need to compute deltas or do anything per-frame. It blocks
        // until the user releases the mouse.
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }

    // Let clicks outside the overlay fall straight through to the
    // subviews beneath. The overlay's job is ONLY to own mouseDown
    // within its own frame — not to block anything outside it.
    // `self` rather than `super.hitTest(point)` inside the bounds is
    // intentional: the overlay has no descendants, so super would
    // always return the overlay anyway, and short-circuiting avoids
    // the traversal. If a descendant is ever added, switch to
    // `super.hitTest(point)` so the click routes to it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if bounds.contains(convert(point, from: superview)) { return self }
        return nil
    }
}

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

    /// Amplify Task 9 — injected by `MainWindowController.applyWindowShape`
    /// when the manifest declares drag regions. Nil means no drag
    /// routing; mouseDown goes to super, cursorUpdate uses the system
    /// default. Installing a new tracker on skin switch is the
    /// controller's responsibility — this view just reads it.
    var dragRegionTracker: DragRegionTracker?

    /// True while the mouse button is held down inside the view. Used
    /// by `cursorUpdate` to pick between `.openHand` (hover) and
    /// `.closedHand` (hover + drag in flight).
    private var isMouseDown: Bool = false

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

    override func mouseDown(with event: NSEvent) {
        // Set isMouseDown unconditionally — not just on the tracker-
        // consumed branch. Otherwise a mouseDown that falls outside
        // every drag region would leave `isMouseDown == false`, and
        // if the cursor subsequently enters a region while the button
        // is still held, `cursorUpdate` would show the openHand glyph
        // instead of closedHand. State machine needs to reflect the
        // ACTUAL button state, not the consumed-by-tracker state.
        isMouseDown = true
        if let tracker = dragRegionTracker, tracker.handleMouseDown(event) {
            // Tracker consumed the event — it invoked performDrag.
            // We must NOT forward to super (which would deliver a
            // spurious click into whatever view is underneath).
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isMouseDown = false
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Register the arrow cursor for the entire content view as the
        // baseline. Without this, moving off a subview that set the
        // I-beam (e.g., the terminal) leaves the cursor as I-beam
        // indefinitely — AppKit only restores it if there's a cursor
        // rect to restore to. Subviews override this for their own
        // regions via their own resetCursorRects.
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let tracker = dragRegionTracker {
            let point = convert(event.locationInWindow, from: nil)
            if let cursor = tracker.cursorForPoint(point, mouseDown: isMouseDown) {
                cursor.set()
                return
            }
        }
        super.cursorUpdate(with: event)
    }
}
