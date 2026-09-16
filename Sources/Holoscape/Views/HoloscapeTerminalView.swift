import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that preserves text selection during output
/// and notifies when new output arrives (for unread tab indicators).
@MainActor
open class HoloscapeTerminalView: LocalProcessTerminalView, TerminalProcess {

    /// Called when the terminal receives new output. Set by the channel controller.
    var onOutput: (() -> Void)?
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    var terminalContentView: NSView { self }
    var currentGridSize: TerminalGridSize {
        TerminalGridSize(columns: terminal.cols, rows: terminal.rows)
    }

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

    open override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    func setOutputHandler(_ handler: (() -> Void)?) {
        onOutput = handler
    }

    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?) {
        onUserInput = handler
    }

    func lastLines(_ count: Int) -> [String] {
        // SwiftTerm's getText(start:end:) uses buffer-absolute row indexing.
        // Read from row 0 up to the bottom of the visible area — getText
        // returns empty for rows beyond the cursor, so this is safe even when
        // the buffer has fewer lines than `count`. We take the last `count`
        // lines from the result via .suffix().
        let bottomRow = terminal.buffer.yDisp + terminal.rows - 1
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols - 1, row: bottomRow)
        )
        let lines = text.components(separatedBy: "\n")
        return Array(lines.suffix(count))
    }
}
