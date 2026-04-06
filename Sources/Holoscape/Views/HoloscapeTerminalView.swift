import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that preserves text selection during output.
///
/// SwiftTerm's default `linefeed()` clears the active selection whenever
/// `allowMouseReporting` is true, which means any shell output destroys the
/// user's selection. We override this to only clear selection when a program
/// is actively using mouse reporting (e.g. vim, tmux).
@MainActor
open class HoloscapeTerminalView: LocalProcessTerminalView {

    open override func linefeed(source: Terminal) {
        // Only clear selection when the program inside the terminal is actively
        // using mouse mode. For a plain shell, mouseMode is .off and we preserve
        // the user's text selection through output.
        if terminal.mouseMode != .off {
            selectNone()
        }
    }
}
