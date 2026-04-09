import AppKit

@MainActor
class TerminalContainerView: NSView {
    private var currentContentView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0).cgColor
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Delegate hit testing to the content view (terminal) so mouse
        // interaction (selection, scrolling, right-click) works normally.
        // The container itself doesn't become first responder.
        return currentContentView?.hitTest(convert(point, to: currentContentView)) ?? nil
    }

    func showContent(_ view: NSView) {
        currentContentView?.removeFromSuperview()
        currentContentView = view

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func clearContent() {
        currentContentView?.removeFromSuperview()
        currentContentView = nil
    }
}
