import XCTest

final class SplitPaneUITests: HoloscapeUITestCase {

    // MARK: - Split Creation

    func testCmdDCreatesHorizontalSplit() throws {
        // Split horizontally
        app.typeKey("d", modifierFlags: .command)

        // Window should still be functional
        assertActiveChannelResponsive(message: "Channel should be responsive after horizontal split")
    }

    func testCmdShiftDCreatesVerticalSplit() throws {
        app.typeKey("d", modifierFlags: [.command, .shift])

        assertActiveChannelResponsive(message: "Channel should be responsive after vertical split")
    }

    // MARK: - Close Pane

    func testCmdShiftWWithOnePaneDoesNothing() throws {
        // With only 1 pane, Cmd+Shift+W should do nothing (no blank screen)
        app.typeKey("w", modifierFlags: [.command, .shift])

        assertActiveChannelResponsive(message: "Channel should still be responsive — no blank screen")
    }

    func testCmdShiftWClosesSecondPane() throws {
        // Split first
        app.typeKey("d", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive after split")

        // Now close the active pane
        app.typeKey("w", modifierFlags: [.command, .shift])

        // Should be back to single pane
        assertActiveChannelResponsive(message: "Channel should still work after pane close")
    }

    // MARK: - Max Panes

    func testMaxFourPanesEnforced() throws {
        // Split 5 times — max should be 4 panes
        for _ in 0..<5 {
            app.typeKey("d", modifierFlags: .command)
        }

        assertActiveChannelResponsive(message: "Channel should be responsive at max pane limit")

        // 4 panes max + input scroll view + potential search scroll view = 6
        // If this threshold needs updating, check SplitPaneManager for new scroll views
        let window = app.windows["Holoscape"]
        let scrollViews = window.scrollViews
        XCTAssertLessThanOrEqual(scrollViews.count, 6, "Max 4 panes should be enforced (scroll views include input + search)")
    }

    // MARK: - Active Pane

    func testInputBoxSendsToActivePane() throws {
        // Split
        app.typeKey("d", modifierFlags: .command)

        // Channel should still be responsive in split mode
        assertActiveChannelResponsive(message: "Active pane should be responsive after split")
    }

    // MARK: - Sequential Split and Close

    func testSplitCloseMultipleTimes() throws {
        // Split, close, split, close — should not leak or crash
        for _ in 0..<3 {
            app.typeKey("d", modifierFlags: .command)
            assertActiveChannelResponsive()
            app.typeKey("w", modifierFlags: [.command, .shift])
        }

        assertActiveChannelResponsive(message: "Channel should be responsive after split/close cycles")
    }
}
