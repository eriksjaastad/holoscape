import XCTest
@testable import Holoscape

/// Card #6021 — pin the top-tab-bar / sidebar mutual-exclusion invariant.
///
/// The expanded sidebar already renders the channel/tab list. When the
/// sidebar is expanded, the top (Warp-style) tab strip must be hidden
/// AND collapse its 32pt height so the terminal doesn't leave a gap.
/// When the sidebar is collapsed, the top strip is the only place the
/// tab list appears, so it must be visible at 32pt.
///
/// PR #98 (tabs-in-titlebar) intentionally removed this toggle. This
/// test pins the restored invariant so the next person who refactors
/// the layout can't silently regress it again.
///
/// Headless — exercises `MainWindowController.tabBarVisibility(forSidebarExpanded:)`
/// directly. Does NOT spin up an NSWindow.
@MainActor
final class TopTabBarSidebarMutualExclusionTests: XCTestCase {

    func testSidebarExpandedHidesAndCollapsesTopTabBar() {
        let state = MainWindowController.tabBarVisibility(forSidebarExpanded: true)
        XCTAssertTrue(state.isHidden,
                      "Expanded sidebar already shows the tab list; top strip must be hidden")
        XCTAssertEqual(state.height, 0,
                       "Hidden top strip must collapse its height so the top chrome band doesn't leave a 32pt gap")
    }

    func testSidebarCollapsedShowsTopTabBarAtFullHeight() {
        let state = MainWindowController.tabBarVisibility(forSidebarExpanded: false)
        XCTAssertFalse(state.isHidden,
                       "Collapsed sidebar makes the top strip the only tab-list surface; must be visible")
        XCTAssertEqual(state.height, 32,
                       "Visible top strip renders at the spec'd 32pt titlebar strip height")
    }

    /// Both states return distinct (isHidden, height) tuples — the
    /// mapping is a total function with no overlap. Catches a future
    /// refactor that accidentally hardcodes one shape.
    func testVisibilityStatesAreDistinct() {
        let expanded = MainWindowController.tabBarVisibility(forSidebarExpanded: true)
        let collapsed = MainWindowController.tabBarVisibility(forSidebarExpanded: false)
        XCTAssertNotEqual(expanded.isHidden, collapsed.isHidden)
        XCTAssertNotEqual(expanded.height, collapsed.height)
    }
}
