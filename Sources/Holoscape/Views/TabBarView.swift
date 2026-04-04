import AppKit

@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID)
}

@MainActor
class TabBarView: NSView {
    weak var tabDelegate: TabBarViewDelegate?

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private var tabButtons: [UUID: NSButton] = [:]
    private var activeChannelId: UUID?

    private let tabHeight: CGFloat = 32
    private let tabPadding: CGFloat = 8
    private let tabSpacing: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupScrollView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollView()
    }

    private func setupScrollView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    func updateTabs(channels: [any ChannelController], activeId: UUID?) {
        activeChannelId = activeId

        // Remove old buttons
        for (_, button) in tabButtons {
            button.removeFromSuperview()
        }
        tabButtons.removeAll()

        var xOffset: CGFloat = tabSpacing

        for channel in channels {
            let button = makeTabButton(for: channel)
            button.frame = NSRect(x: xOffset, y: 2, width: button.fittingSize.width + tabPadding * 2, height: tabHeight - 4)
            contentView.addSubview(button)
            tabButtons[channel.channelId] = button
            xOffset += button.frame.width + tabSpacing
        }

        contentView.frame = NSRect(x: 0, y: 0, width: max(xOffset, scrollView.contentView.bounds.width), height: tabHeight)
    }

    private func makeTabButton(for channel: any ChannelController) -> NSButton {
        var title = channel.displayLabel
        if channel.hasUnread {
            title = "\u{25CF} " + title  // Bullet dot for unread
        }

        let button = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        if channel.channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0).cgColor
            button.layer?.cornerRadius = 4
        } else {
            button.contentTintColor = NSColor.lightGray
        }

        // Store channel ID as tag via identifier
        button.identifier = NSUserInterfaceItemIdentifier(channel.channelId.uuidString)
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString) else { return }
        tabDelegate?.tabBarView(self, didSelectChannelWithId: id)
    }
}
