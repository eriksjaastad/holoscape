import AppKit

@MainActor
protocol SplitPaneViewDelegate: AnyObject {
    func splitPaneViewDidClick(_ pane: SplitPaneView)
}

@MainActor
class SplitPaneView: NSView {
    private static let defaultActiveBorder = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
    private static let clearBorder = NSColor.clear.cgColor

    let paneId: UUID
    var channelId: UUID?
    weak var paneDelegate: SplitPaneViewDelegate?
    private var contentView: NSView?
    private var compositor: MetalCompositor?

    /// Skin context source. Nil falls back to the hardcoded active-border
    /// color below (standalone rendering path).
    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    var isActivePane: Bool = false {
        didSet { applyBorder() }
    }

    private func applyBorder() {
        let active = activeBorderColor()
        layer?.borderColor = isActivePane ? active : Self.clearBorder
        layer?.borderWidth = isActivePane ? 2 : 0
    }

    /// Resolve the active-pane border color from the splitPane.divider
    /// surface's `border` field if a skin defines one; otherwise use
    /// the hardcoded system-blue default.
    private func activeBorderColor() -> CGColor {
        guard let ctx = skinContext,
              let border = ctx.currentState(for: .splitPaneDivider).border else {
            return Self.defaultActiveBorder
        }
        return border.color.cgColor
    }

    init(paneId: UUID) {
        self.paneId = paneId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        setupSkinObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupSkinObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinDidChange(_:)),
            name: .skinDidChange,
            object: nil
        )
    }

    @objc private func skinDidChange(_ note: Notification) {
        refreshFromSkin()
    }

    private func refreshFromSkin() {
        // Re-apply the current active/inactive state so a skin change
        // picks up a new active-border color without any other push.
        applyBorder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func showContent(_ view: NSView, compiledShader: CompiledShader? = nil) {
        if contentView === view {
            // Same view — just update the compositor
            stopCompositor()
            if let compiledShader {
                startCompositor(shader: compiledShader, sourceView: view)
            }
            return
        }
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
        NSLog("[SHADER] SplitPaneView.startCompositor called, MSL length: \(shader.mslSource.count)")
        do {
            let comp = try MetalCompositor(
                compiledShader: shader,
                sourceView: sourceView,
                hostView: self
            )
            comp.start()
            compositor = comp
            NSLog("[SHADER] compositor started successfully")
        } catch {
            NSLog("[SHADER] MetalCompositor init FAILED: \(error)")
        }
    }

    private func stopCompositor() {
        if compositor != nil {
            NSLog("[SHADER] stopping compositor")
        }
        compositor?.stop()
        compositor = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopCompositor()
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
