import AppKit

@MainActor
protocol SplitPaneViewDelegate: AnyObject {
    func splitPaneViewDidClick(_ pane: SplitPaneView)
}

@MainActor
class SplitPaneView: NSView {
    private static let activeBorder = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
    private static let clearBorder = NSColor.clear.cgColor

    let paneId: UUID
    var channelId: UUID?
    weak var paneDelegate: SplitPaneViewDelegate?
    private var contentView: NSView?

    var isActivePane: Bool = false {
        didSet {
            layer?.borderColor = isActivePane ? Self.activeBorder : Self.clearBorder
            layer?.borderWidth = isActivePane ? 2 : 0
        }
    }

    init(paneId: UUID) {
        self.paneId = paneId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func showContent(_ view: NSView) {
        // Skip reparenting if this view is already displayed
        guard contentView !== view else { return }
        contentView?.removeFromSuperview()
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let inset: CGFloat = 6
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
    }

    func clearContent() {
        contentView?.removeFromSuperview()
        contentView = nil
    }

    override func mouseDown(with event: NSEvent) {
        paneDelegate?.splitPaneViewDidClick(self)
        super.mouseDown(with: event)
    }
}
