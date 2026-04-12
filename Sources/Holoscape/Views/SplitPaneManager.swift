import AppKit

@MainActor
protocol SplitPaneManagerDelegate: AnyObject {
    func splitPaneManager(_ manager: SplitPaneManager, activePaneDidChange channelId: UUID?)
}

@MainActor
class SplitPaneManager: NSView, SplitPaneViewDelegate {
    weak var splitDelegate: SplitPaneManagerDelegate?

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
    func showContent(_ view: NSView, channelId: UUID) {
        if panes.isEmpty {
            // Create initial single pane
            let pane = createPane()
            pane.channelId = channelId
            pane.showContent(view)
            pane.isActivePane = true
            activePaneId = pane.paneId

            pane.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: topAnchor),
                pane.bottomAnchor.constraint(equalTo: bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        } else if let existingPane = panes.first(where: { $0.channelId == channelId }) {
            // A channel has a single live content view. If the requested
            // channel is already displayed in another pane, activate that pane
            // instead of trying to reparent the same NSView across panes.
            setActivePane(existingPane.paneId)
        } else if let activePane = panes.first(where: { $0.paneId == activePaneId }) {
            activePane.channelId = channelId
            activePane.showContent(view)
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

    private func createPane() -> SplitPaneView {
        let pane = SplitPaneView(paneId: UUID())
        pane.paneDelegate = self
        panes.append(pane)
        return pane
    }

    // MARK: - SplitPaneViewDelegate

    func splitPaneViewDidClick(_ pane: SplitPaneView) {
        setActivePane(pane.paneId)
    }
}
