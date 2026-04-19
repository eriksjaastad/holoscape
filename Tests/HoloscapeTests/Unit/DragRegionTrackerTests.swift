import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 9.5 — DragRegionTracker unit tests.
///
/// Covers the four load-bearing contracts:
/// 1. `handleMouseDown` returns true inside a polygon, false outside
/// 2. Cursor: openHand on hover; closedHand on hover+mouseDown
/// 3. Modifier gate: `.command` rejects mouseDown without ⌘
/// 4. `teardown()` removes every installed tracking area
///
/// `performDrag` is an AppKit black box — we can't assert it ran
/// without spinning up a real key window. Inside-polygon returning
/// true is the proxy: the tracker has done its work.
@MainActor
final class DragRegionTrackerTests: XCTestCase {

    // MARK: - handleMouseDown

    func testMouseDownInsidePolygonReturnsTrue() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ShapedContentView(frame: window.contentView!.bounds)
        window.contentView = view

        let region = ResolvedDragRegion(
            polygons: [Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ])],
            modifier: .none
        )
        let tracker = DragRegionTracker(contentView: view, regions: [region])

        // Mouse event at (50, 25) — inside the triangle. Location is
        // in window coordinates; convert inside the tracker.
        let event = try Self.syntheticMouseEvent(
            at: NSPoint(x: 50, y: 25),
            in: window,
            modifiers: []
        )
        XCTAssertTrue(tracker.handleMouseDown(event))
    }

    func testMouseDownOutsidePolygonReturnsFalse() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ShapedContentView(frame: window.contentView!.bounds)
        window.contentView = view

        let region = ResolvedDragRegion(
            polygons: [Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ])],
            modifier: .none
        )
        let tracker = DragRegionTracker(contentView: view, regions: [region])

        // (180, 100) — well outside the triangle.
        let event = try Self.syntheticMouseEvent(
            at: NSPoint(x: 180, y: 100),
            in: window,
            modifiers: []
        )
        XCTAssertFalse(tracker.handleMouseDown(event))
    }

    // MARK: - Cursor selection

    func testCursorReturnsOpenHandOnHoverWithoutMouseDown() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tracker = DragRegionTracker(
            contentView: view,
            regions: [ResolvedDragRegion(
                polygons: [Polygon(points: [
                    Point(x: 0, y: 0),
                    Point(x: 100, y: 0),
                    Point(x: 50, y: 100),
                ])],
                modifier: .none
            )]
        )
        XCTAssertEqual(tracker.cursorForPoint(CGPoint(x: 50, y: 25), mouseDown: false), .openHand)
    }

    func testCursorReturnsClosedHandOnHoverWithMouseDown() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tracker = DragRegionTracker(
            contentView: view,
            regions: [ResolvedDragRegion(
                polygons: [Polygon(points: [
                    Point(x: 0, y: 0),
                    Point(x: 100, y: 0),
                    Point(x: 50, y: 100),
                ])],
                modifier: .none
            )]
        )
        XCTAssertEqual(tracker.cursorForPoint(CGPoint(x: 50, y: 25), mouseDown: true), .closedHand)
    }

    func testCursorReturnsNilOutsideRegion() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tracker = DragRegionTracker(
            contentView: view,
            regions: [ResolvedDragRegion(
                polygons: [Polygon(points: [
                    Point(x: 0, y: 0),
                    Point(x: 10, y: 0),
                    Point(x: 5, y: 10),
                ])],
                modifier: .none
            )]
        )
        XCTAssertNil(tracker.cursorForPoint(CGPoint(x: 150, y: 150), mouseDown: false),
                     "Outside-region points return nil so the caller falls back to system cursor")
    }

    // MARK: - Modifier gate

    func testCommandModifierRequiredForCommandGatedRegion() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ShapedContentView(frame: window.contentView!.bounds)
        window.contentView = view

        let region = ResolvedDragRegion(
            polygons: [Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ])],
            modifier: .command
        )
        let tracker = DragRegionTracker(contentView: view, regions: [region])

        // Inside the triangle, but NO Command held — gate rejects.
        let noCmd = try Self.syntheticMouseEvent(
            at: NSPoint(x: 50, y: 25),
            in: window,
            modifiers: []
        )
        XCTAssertFalse(tracker.handleMouseDown(noCmd))

        // Command held — gate passes.
        let withCmd = try Self.syntheticMouseEvent(
            at: NSPoint(x: 50, y: 25),
            in: window,
            modifiers: [.command]
        )
        XCTAssertTrue(tracker.handleMouseDown(withCmd))
    }

    // MARK: - teardown

    func testTeardownRemovesAllTrackingAreas() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tracker = DragRegionTracker(
            contentView: view,
            regions: [
                ResolvedDragRegion(
                    polygons: [Polygon(points: [
                        Point(x: 0, y: 0), Point(x: 50, y: 0), Point(x: 25, y: 50),
                    ])],
                    modifier: .none
                ),
                ResolvedDragRegion(
                    polygons: [Polygon(points: [
                        Point(x: 100, y: 0), Point(x: 200, y: 0), Point(x: 150, y: 50),
                    ])],
                    modifier: .none
                ),
            ]
        )
        tracker.install()
        XCTAssertEqual(tracker.trackingAreas.count, 2)
        XCTAssertEqual(view.trackingAreas.count, 2,
                       "NSTrackingAreas are attached to the view — count must match")

        tracker.teardown()
        XCTAssertEqual(tracker.trackingAreas.count, 0)
        XCTAssertEqual(view.trackingAreas.count, 0,
                       "teardown must remove every installed area from the view")
    }

    func testInstallReplacesExistingTrackingAreas() {
        // Calling install() twice must not leak areas — a skin switch
        // that re-runs install through the MainWindowController path
        // would otherwise accumulate stale areas on every reload.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tracker = DragRegionTracker(
            contentView: view,
            regions: [
                ResolvedDragRegion(
                    polygons: [Polygon(points: [
                        Point(x: 0, y: 0), Point(x: 50, y: 0), Point(x: 25, y: 50),
                    ])],
                    modifier: .none
                ),
            ]
        )
        tracker.install()
        tracker.install()
        XCTAssertEqual(tracker.trackingAreas.count, 1)
        XCTAssertEqual(view.trackingAreas.count, 1,
                       "Second install must not leak the first call's tracking area")
    }

    // MARK: - Helpers

    /// Build a synthetic `NSEvent` for mouseDown at a window-local
    /// point. AppKit can return nil when the window hasn't been
    /// ordered front (windowNumber may be invalid). Use XCTUnwrap
    /// at the call site to produce a clean test failure with a
    /// named assertion instead of a SIGILL-style crash.
    nonisolated static func syntheticMouseEvent(
        at point: NSPoint,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        return try XCTUnwrap(event,
                             "NSEvent.mouseEvent returned nil — windowNumber may be invalid for an unordered window")
    }
}
