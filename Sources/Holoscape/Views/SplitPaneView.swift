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
    private var compositor: MetalCompositor?

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

    func showContent(_ view: NSView, compiledShader: CompiledShader? = nil) {
        // Skip reparenting if this view is already displayed
        guard contentView !== view else { return }
        contentView?.removeFromSuperview()
        stopCompositor()
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

        if let compiledShader {
            startCompositor(shader: compiledShader, sourceView: view)
        }
    }

    func clearContent() {
        stopCompositor()
        contentView?.removeFromSuperview()
        contentView = nil
    }

    // MARK: - Metal compositor

    private func startCompositor(shader: CompiledShader, sourceView: NSView) {
        do {
            let comp = try MetalCompositor(
                compiledShader: shader,
                sourceView: sourceView,
                hostView: self
            )
            comp.start()
            compositor = comp
        } catch {
            NSLog("MetalCompositor: failed to initialize: \(error)")
        }
    }

    private func stopCompositor() {
        compositor?.stop()
        compositor = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            compositor?.stop()
        }
    }

    override func layout() {
        super.layout()
        compositor?.updateLayout()
    }

    override func mouseDown(with event: NSEvent) {
        paneDelegate?.splitPaneViewDidClick(self)
        super.mouseDown(with: event)
    }
}
