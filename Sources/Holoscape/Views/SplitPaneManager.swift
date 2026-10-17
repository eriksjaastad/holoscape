import AppKit

@MainActor
protocol SplitPaneManagerDelegate: AnyObject {
    func splitPaneManager(_ manager: SplitPaneManager, activePaneDidChange channelId: UUID?)
}

@MainActor
class SplitPaneManager: NSView, SplitPaneViewDelegate {
    weak var splitDelegate: SplitPaneManagerDelegate?

    /// Forward-propagated to every `SplitPaneView` we spawn. Assigning
    /// after the fact also retrofits any existing panes so a skin swap
    /// from MainWindowController reaches deep into the split graph.
    var skinContext: SkinContext? {
        didSet {
            for pane in panes {
                pane.skinContext = skinContext
            }
        }
    }

    private var panes: [SplitPaneView] = []
    private var rootSplitView: NSSplitView?
    private(set) var activePaneId: UUID?

    var activeChannelId: UUID? {
        panes.first { $0.paneId == activePaneId }?.channelId
    }

    var paneCount: Int { panes.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Show content in the single pane (or active pane if split).
    func showContent(_ view: NSView, channelId: UUID, compiledShader: CompiledShader? = nil) {
        if panes.isEmpty {
            // Create initial single pane
            let pane = createPane()
            pane.channelId = channelId
            pane.showContent(view, compiledShader: compiledShader)
            pane.isActivePane = true
            activePaneId = pane.paneId
            installPaneHierarchy()
        } else if let existingPane = panes.first(where: { $0.channelId == channelId }) {
            // Channel already displayed — activate its pane, update compositor
            setActivePane(existingPane.paneId)
            existingPane.showContent(view, compiledShader: compiledShader)
        } else if let activePane = panes.first(where: { $0.paneId == activePaneId }) {
            activePane.channelId = channelId
            activePane.showContent(view, compiledShader: compiledShader)
        }
    }

    func clearContent() {
        for pane in panes {
            pane.clearContent()
            pane.removeFromSuperview()
        }
        panes.removeAll()
        rootSplitView?.removeFromSuperview()
        rootSplitView = nil
        activePaneId = nil
    }

    /// Split the active pane horizontally (left/right).
    func splitHorizontal() {
        split(isVertical: true)
    }

    /// Split the active pane vertically (top/bottom).
    func splitVertical() {
        split(isVertical: false)
    }

    private func split(isVertical: Bool) {
        guard panes.count < 4 else { return }
        guard let activePane = panes.first(where: { $0.paneId == activePaneId }) else { return }

        let newPane = createPane()

        if panes.count == 1 {
            // First split: wrap in NSSplitView
            activePane.removeFromSuperview()

            let splitView = NSSplitView()
            splitView.isVertical = isVertical
            splitView.dividerStyle = .thin
            splitView.translatesAutoresizingMaskIntoConstraints = false

            splitView.addArrangedSubview(activePane)
            splitView.addArrangedSubview(newPane)

            addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.topAnchor.constraint(equalTo: topAnchor),
                splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
                splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            rootSplitView = splitView
        } else if let rootSplit = rootSplitView {
            // Subsequent splits: add to root
            rootSplit.addArrangedSubview(newPane)
        }

        setActivePane(newPane.paneId)
    }

    /// Close the active pane.
    func closeActivePane() {
        guard panes.count > 1, let activePaneId else { return }
        removePane(id: activePaneId)
    }

    /// Remove the pane displaying a specific channel.
    func removeChannel(channelId: UUID) {
        if let pane = panes.first(where: { $0.channelId == channelId }) {
            if panes.count > 1 {
                removePane(id: pane.paneId)
            } else {
                pane.clearContent()
                pane.channelId = nil
            }
        }
    }

    private func removePane(id: UUID) {
        guard let index = panes.firstIndex(where: { $0.paneId == id }) else { return }
        let pane = panes[index]
        pane.removeFromSuperview()
        panes.remove(at: index)

        if panes.count == 1 {
            // Return to single pane — remove split view
            let remaining = panes[0]
            rootSplitView?.removeFromSuperview()
            rootSplitView = nil

            remaining.translatesAutoresizingMaskIntoConstraints = false
            addSubview(remaining)
            NSLayoutConstraint.activate([
                remaining.topAnchor.constraint(equalTo: topAnchor),
                remaining.bottomAnchor.constraint(equalTo: bottomAnchor),
                remaining.leadingAnchor.constraint(equalTo: leadingAnchor),
                remaining.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        // Activate first remaining pane
        if let first = panes.first {
            setActivePane(first.paneId)
        }
    }

    func setActivePane(_ paneId: UUID) {
        activePaneId = paneId
        for pane in panes {
            pane.isActivePane = pane.paneId == paneId
        }
        if let channelId = activeChannelId {
            splitDelegate?.splitPaneManager(self, activePaneDidChange: channelId)
        }
    }

    /// Export layout for persistence.
    func exportLayout() -> SplitLayoutConfig {
        let paneConfigs = panes.compactMap { pane -> PaneConfig? in
            guard let channelId = pane.channelId else { return nil }
            return PaneConfig(paneId: pane.paneId, channelId: channelId)
        }
        return SplitLayoutConfig(panes: paneConfigs, activePaneId: activePaneId)
    }

    /// Restore the persisted panes whose channels are still available.
    ///
    /// Persisted channel metadata and live controller registration are the
    /// authority: stale or duplicate pane entries are ignored rather than
    /// creating blank panes or moving one channel view between two panes.
    @discardableResult
    func restoreLayout(
        _ layout: SplitLayoutConfig,
        compiledShader: CompiledShader? = nil,
        contentForChannel: (UUID) -> NSView?
    ) -> Bool {
        var restored: [(config: PaneConfig, content: NSView)] = []
        var paneIDs: Set<UUID> = []
        var channelIDs: Set<UUID> = []

        for config in layout.panes where restored.count < 4 {
            guard let content = contentForChannel(config.channelId),
                  !paneIDs.contains(config.paneId),
                  !channelIDs.contains(config.channelId) else { continue }
            paneIDs.insert(config.paneId)
            channelIDs.insert(config.channelId)
            restored.append((config, content))
        }
        guard !restored.isEmpty else { return false }

        clearContent()
        for entry in restored {
            let pane = createPane(id: entry.config.paneId)
            pane.channelId = entry.config.channelId
            pane.showContent(entry.content, compiledShader: compiledShader)
        }
        installPaneHierarchy()

        let restoredPaneIDs = Set(restored.map { $0.config.paneId })
        setActivePane(
            layout.activePaneId.flatMap { restoredPaneIDs.contains($0) ? $0 : nil }
                ?? restored[0].config.paneId
        )
        return true
    }

    private func createPane(id: UUID = UUID()) -> SplitPaneView {
        let pane = SplitPaneView(paneId: id)
        pane.paneDelegate = self
        pane.skinContext = skinContext
        panes.append(pane)
        return pane
    }

    private func installPaneHierarchy() {
        guard let first = panes.first else { return }
        if panes.count == 1 {
            first.translatesAutoresizingMaskIntoConstraints = false
            addSubview(first)
            NSLayoutConstraint.activate([
                first.topAnchor.constraint(equalTo: topAnchor),
                first.bottomAnchor.constraint(equalTo: bottomAnchor),
                first.leadingAnchor.constraint(equalTo: leadingAnchor),
                first.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            return
        }

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        for pane in panes {
            splitView.addArrangedSubview(pane)
        }
        addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rootSplitView = splitView
    }

    // MARK: - SplitPaneViewDelegate

    func splitPaneViewDidClick(_ pane: SplitPaneView) {
        setActivePane(pane.paneId)
    }
}
