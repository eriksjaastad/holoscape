import AppKit

/// Validated drag-region data ready for runtime hit testing.
/// Built from a `DragRegionDescriptor` at skin-load time; polygons
/// below 3 vertices are dropped per Requirement 13.5.
struct ResolvedDragRegion: Equatable {
    let polygons: [Polygon]
    let modifier: DragRegionDescriptor.Modifier

    /// Axis-aligned bounding box of the union of all polygons.
    /// Used by `DragRegionTracker` to install an `NSTrackingArea`
    /// that covers the entire region (tracking per-polygon would
    /// multiply overhead without changing hover-detection behavior —
    /// the `cursorForPoint` call still tests polygons individually).
    var boundingBox: CGRect {
        guard !polygons.isEmpty else { return .zero }
        var union: CGRect = .null
        for polygon in polygons {
            let bbox = Self.polygonBBox(polygon)
            union = union.union(bbox)
        }
        return union
    }

    private static func polygonBBox(_ polygon: Polygon) -> CGRect {
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
}

/// Amplify Task 9 — installs `NSTrackingArea`s over skin-authored
/// drag regions and routes `mouseDown` inside any region through
/// `NSWindow.performDrag(with:)`. Enables a borderless shaped window
/// to be moved by dragging its skin-painted chrome.
///
/// Ownership: `MainWindowController` owns one tracker per active
/// skin. On skin switch the previous tracker is `teardown`'d and a
/// fresh one is constructed + `install`'d. Trackers are cheap; not
/// worth a reuse pool.
///
/// `contentView` is weak because the tracker's lifetime is bounded
/// by the controller's skin state, not by the view. If the window
/// reconstructs and the content view changes identity, a stale
/// tracker pointing at the dead view is harmless — `handleMouseDown`
/// guards on `contentView?.window`.
@MainActor
final class DragRegionTracker {

    weak var contentView: NSView?
    let regions: [ResolvedDragRegion]

    /// Test-only: read-only view of installed tracking areas so
    /// `DragRegionTrackerTests.testTeardownRemovesAllTrackingAreas`
    /// can count them without probing NSView's internal area list.
    internal var trackingAreas: [NSTrackingArea] { installedAreas }
    private var installedAreas: [NSTrackingArea] = []

    init(contentView: NSView, regions: [ResolvedDragRegion]) {
        self.contentView = contentView
        self.regions = regions
    }

    /// Install one `NSTrackingArea` per region, covering the region's
    /// bounding box. Options combine `mouseEnteredAndExited +
    /// cursorUpdate + activeInActiveApp` so we get both cursor changes
    /// and the hover/leave events that drive `openHand` ↔ `closedHand`.
    func install() {
        guard let contentView else { return }
        teardown()
        for region in regions {
            let area = NSTrackingArea(
                rect: region.boundingBox,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp],
                owner: contentView,
                userInfo: nil
            )
            contentView.addTrackingArea(area)
            installedAreas.append(area)
        }
    }

    /// Remove every installed `NSTrackingArea` from the content view.
    /// Safe to call when nothing is installed (no-op) or when
    /// `contentView` has been released (the weak ref is nil).
    func teardown() {
        if let contentView {
            for area in installedAreas {
                contentView.removeTrackingArea(area)
            }
        }
        installedAreas.removeAll()
    }

    /// Called by `ShapedContentView.mouseDown(with:)`. Returns true
    /// when the event is inside a drag region AND the region's
    /// modifier gate is satisfied — in that case, `window.performDrag`
    /// is invoked and the caller is expected to drop the event.
    /// Returns false when the event falls outside every region (or
    /// fails the modifier gate), letting the caller hand the event
    /// off to `super.mouseDown`.
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let contentView, let window = contentView.window else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let region = regionContaining(point) else { return false }

        // Modifier gate — `.command` requires the Command key to be
        // held at mouseDown time. `.none` is always-allowed.
        switch region.modifier {
        case .none:
            break
        case .command:
            guard event.modifierFlags.contains(.command) else { return false }
        }

        window.performDrag(with: event)
        return true
    }

    /// Called by `ShapedContentView.cursorUpdate(with:)` so hovering
    /// over a drag region produces the open-hand glyph (and the
    /// closed-hand glyph while the mouse button is held down).
    /// Returns nil when `point` is outside every region — caller
    /// then calls `super.cursorUpdate` to pick the system default.
    func cursorForPoint(_ point: CGPoint, mouseDown: Bool) -> NSCursor? {
        guard regionContaining(point) != nil else { return nil }
        return mouseDown ? .closedHand : .openHand
    }

    // MARK: - Private

    /// First region whose polygons contain `point`. Returns nil when
    /// no region does. O(total vertices) worst case — fine for the
    /// skins we expect (PRD §14 budgets 100 µs / 64 vertices).
    private func regionContaining(_ point: CGPoint) -> ResolvedDragRegion? {
        for region in regions {
            let sampler = HitRegionSampler(polygons: region.polygons)
            if sampler.contains(point) { return region }
        }
        return nil
    }
}
