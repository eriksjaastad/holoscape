import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that preserves text selection during output
/// and notifies when new output arrives (for unread tab indicators).
@MainActor
open class HoloscapeTerminalView: LocalProcessTerminalView {

    /// Called when the terminal receives new output. Set by the channel controller.
    var onOutput: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        notifyUpdateChanges = true
        configureAccessibility()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        notifyUpdateChanges = true
        configureAccessibility()
    }

    private func configureAccessibility() {
        setAccessibilityIdentifier("terminal-view")
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
    }

    open override func linefeed(source: Terminal) {
        if terminal.mouseMode != .off {
            selectNone()
        }
    }

    open override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        onOutput?()
    }
}
