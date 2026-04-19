import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 11.3 + 11.5 — sprite state publishing.
///
/// TabBarView and SessionLauncherView now track hover + pressed state
/// per interactive element and pass the resolved SpriteState to
/// applyFill. The load-bearing invariant this pins:
///
///   pressed wins > hover > active > normal
///
/// Plus: the handlers are idempotent — a mouseExited on a tab that's
/// not the current hoveredTabId must be a no-op (otherwise a rapid
/// hover sequence would leave stale state). These invariants are
/// exercised via the handler entry points rather than real NSEvents,
/// keeping tests headless + deterministic.
///
/// Task 11.4 (SidebarTabEntry) is deferred to a follow-up PR — the
/// sidebar row render path doesn't yet route through
/// `SkinContext.applyFill` (it uses `cgRowFill` with CSS-cascade
/// state-variant handling), so "publish sprite state" needs a
/// render-path migration first.
@MainActor
final class SpriteStatePublishingTests: XCTestCase {

    // MARK: - TabBarView resolution rule

    func testTabSpriteStateIsNormalByDefault() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let id = UUID()
        XCTAssertEqual(bar.spriteState(forTab: id), .normal,
                       "With no hover/press/active tracking, every tab resolves to .normal")
    }

    func testHoverPromotesTabFromNormalToHover() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let id = UUID()
        bar.handleTabButtonMouseEntered(id)
        XCTAssertEqual(bar.spriteState(forTab: id), .hover)
    }

    func testPressedBeatsHover() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let id = UUID()
        bar.handleTabButtonMouseEntered(id)
        bar.handleTabButtonMouseDown(id)
        XCTAssertEqual(bar.spriteState(forTab: id), .pressed,
                       "A pressed tab must render as .pressed even while the cursor is also inside it")
    }

    func testMouseExitedClearsHover() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let id = UUID()
        bar.handleTabButtonMouseEntered(id)
        bar.handleTabButtonMouseExited(id)
        XCTAssertEqual(bar.spriteState(forTab: id), .normal,
                       "mouseExited must clear the hover slot so the tab returns to .normal")
    }

    func testMouseUpClearsPressed() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let id = UUID()
        bar.handleTabButtonMouseDown(id)
        bar.handleTabButtonMouseUp(id)
        XCTAssertEqual(bar.spriteState(forTab: id), .normal)
    }

    /// A mouseExited event on a tab that's NOT the currently-hovered
    /// one must not clobber the real hover slot. Rapid hover
    /// transitions between tabs could otherwise leave stale state
    /// (the "exit" event arriving after the next "enter" is normal
    /// AppKit behavior on fast cursor motion).
    func testMouseExitedOnNonHoveredTabIsNoOp() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let a = UUID()
        let b = UUID()
        bar.handleTabButtonMouseEntered(a)
        bar.handleTabButtonMouseExited(b)  // stale exit on a DIFFERENT tab
        XCTAssertEqual(bar.spriteState(forTab: a), .hover,
                       "Stale mouseExited on a non-hovered tab must not clear the real hover")
    }

    /// Same idempotency rule for mouseUp.
    func testMouseUpOnNonPressedTabIsNoOp() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let a = UUID()
        let b = UUID()
        bar.handleTabButtonMouseDown(a)
        bar.handleTabButtonMouseUp(b)
        XCTAssertEqual(bar.spriteState(forTab: a), .pressed,
                       "Stale mouseUp on a non-pressed tab must not clear the real pressed slot")
    }

    // MARK: - SessionLauncherView resolution rule

    func testLauncherRefreshButtonStateIsNormalByDefault() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let (key, state) = launcher.refreshButtonSurfaceAndState()
        XCTAssertEqual(key, .sessionLauncherButtonNormal)
        XCTAssertEqual(state, .normal)
    }

    func testLauncherRefreshButtonHoverMapping() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        launcher.handleRefreshButtonMouseEntered()
        let (key, state) = launcher.refreshButtonSurfaceAndState()
        XCTAssertEqual(key, .sessionLauncherButtonHover)
        XCTAssertEqual(state, .hover)
    }

    func testLauncherRefreshButtonPressedMapping() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        launcher.handleRefreshButtonMouseDown()
        let (key, state) = launcher.refreshButtonSurfaceAndState()
        XCTAssertEqual(key, .sessionLauncherButtonPressed)
        XCTAssertEqual(state, .pressed)
    }

    func testLauncherPressedBeatsHover() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        launcher.handleRefreshButtonMouseEntered()
        launcher.handleRefreshButtonMouseDown()
        let (key, state) = launcher.refreshButtonSurfaceAndState()
        XCTAssertEqual(key, .sessionLauncherButtonPressed,
                       "Pressed surface key must win over hover when both are set")
        XCTAssertEqual(state, .pressed)
    }

    func testLauncherMouseUpReturnsToHoverWhenCursorStillInside() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        launcher.handleRefreshButtonMouseEntered()
        launcher.handleRefreshButtonMouseDown()
        launcher.handleRefreshButtonMouseUp()
        // Cursor is still inside — hover stays, pressed cleared.
        let (key, state) = launcher.refreshButtonSurfaceAndState()
        XCTAssertEqual(key, .sessionLauncherButtonHover)
        XCTAssertEqual(state, .hover)
    }

    func testLauncherMouseExitedClearsHoverCleanly() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        launcher.handleRefreshButtonMouseEntered()
        launcher.handleRefreshButtonMouseExited()
        let (key, state) = launcher.refreshButtonSurfaceAndState()
        XCTAssertEqual(key, .sessionLauncherButtonNormal)
        XCTAssertEqual(state, .normal)
    }
}
