import AppKit

@MainActor
protocol SplitPaneViewDelegate: AnyObject {
    func splitPaneViewDidClick(_ pane: SplitPaneView)
}

@MainActor
class SplitPaneView: NSView {
    let paneId: UUID
    var channelId: UUID?
    weak var paneDelegate: SplitPaneViewDelegate?
    private var contentView: NSView?

    var isActivePane: Bool = false {
        didSet {
            layer?.borderColor = isActivePane
                ? NSColor.systemBlue.withAlphaComponent(0.6).cgColor
                : NSColor.clear.cgColor
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
        contentView?.removeFromSuperview()
        contentView = view
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
        contentView?.removeFromSuperview()
        contentView = nil
    }

    override func mouseDown(with event: NSEvent) {
        paneDelegate?.splitPaneViewDidClick(self)
        super.mouseDown(with: event)
    }
}
