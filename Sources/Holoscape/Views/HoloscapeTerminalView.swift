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

    init(frame: CGRect, options: TerminalOptions) {
        super.init(frame: frame, options: options)
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

    open override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if MarkdownDocumentReaderController.openIfMarkdown(link: link) {
            return
        }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    open override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let markdownLink = markdownLinkForContextMenu(event: event) else {
            return menu.items.isEmpty ? nil : menu
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: "Open in Holoscape Reader",
            action: #selector(openMarkdownLinkFromContextMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = markdownLink
        menu.addItem(item)
        return menu
    }

    @objc private func openMarkdownLinkFromContextMenu(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String else { return }
        _ = MarkdownDocumentReaderController.openIfMarkdown(link: link)
    }

    func markdownLinkForContextMenu(atBufferPosition position: Position) -> String? {
        guard let link = terminal.link(at: .buffer(position), mode: .explicitAndImplicit),
              MarkdownDocumentReaderController.markdownFileURL(from: link) != nil else {
            return nil
        }
        return link
    }

    private func markdownLinkForContextMenu(event: NSEvent) -> String? {
        guard terminal.cols > 0, terminal.rows > 0, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let point = convert(event.locationInWindow, from: nil)
        let col = min(max(0, Int(point.x / (bounds.width / CGFloat(terminal.cols)))), terminal.cols - 1)
        let visibleRow = min(max(0, Int((bounds.height - point.y) / (bounds.height / CGFloat(terminal.rows)))), terminal.rows - 1)
        let bufferRow = visibleRow + terminal.buffer.yDisp
        return markdownLinkForContextMenu(atBufferPosition: Position(col: col, row: bufferRow))
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
