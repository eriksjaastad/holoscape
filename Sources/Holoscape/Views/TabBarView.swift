import AppKit

@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID)
}

@MainActor
class TabBarView: NSView {
    weak var tabDelegate: TabBarViewDelegate?

    private static let barBg = NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0).cgColor
    private static let activeTabBg = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0).cgColor

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
        layer?.backgroundColor = Self.barBg

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setAccessibilityElement(false)
        contentView.setAccessibilityRole(.group)
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

    func updateTabs(channels: [any ChannelController], activeId: UUID?, pinnedIds: Set<UUID> = []) {
        activeChannelId = activeId

        let currentIds = Set(channels.map { $0.channelId })

        // Remove buttons for channels that no longer exist
        for (id, button) in tabButtons where !currentIds.contains(id) {
            button.removeFromSuperview()
            tabButtons.removeValue(forKey: id)
        }

        var xOffset: CGFloat = tabSpacing

        for channel in channels {
            let button: NSButton
            if let existing = tabButtons[channel.channelId] {
                // Update existing button in place
                button = existing
                updateTabButton(button, for: channel)
            } else {
                // Only create new buttons for new channels
                button = makeTabButton(for: channel)
                contentView.addSubview(button)
                tabButtons[channel.channelId] = button
            }
            button.frame = NSRect(x: xOffset, y: 2, width: button.fittingSize.width + tabPadding * 2, height: tabHeight - 4)
            xOffset += button.frame.width + tabSpacing
        }

        contentView.frame = NSRect(x: 0, y: 0, width: max(xOffset, scrollView.contentView.bounds.width), height: tabHeight)
    }

    private func buildTabTitle(for channel: any ChannelController) -> String {
        var title = channel.displayLabel
        if let elapsed = ElapsedTimeFormatter.format(since: channel.activatedAt) {
            title += " (\(elapsed))"
        } else if channel.state == .connecting {
            title += " ..."
        }
        if channel.hasUnread {
            title = "\u{25CF} " + title
        }
        return title
    }

    private func updateTabButton(_ button: NSButton, for channel: any ChannelController) {
        let title = buildTabTitle(for: channel)
        button.title = title

        if channel.channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            button.wantsLayer = true
            button.layer?.backgroundColor = Self.activeTabBg
            button.layer?.cornerRadius = 4
        } else {
            button.contentTintColor = NSColor.lightGray
            button.layer?.backgroundColor = nil
        }

        button.setAccessibilityTitle(title)
        button.setAccessibilityIdentifier("tab-\(channel.displayLabel)")
    }

    private func makeTabButton(for channel: any ChannelController) -> NSButton {
        let title = buildTabTitle(for: channel)

        let button = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        if channel.channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            button.wantsLayer = true
            button.layer?.backgroundColor = Self.activeTabBg
            button.layer?.cornerRadius = 4
        } else {
            button.contentTintColor = NSColor.lightGray
        }

        // Store channel ID as tag via identifier
        button.identifier = NSUserInterfaceItemIdentifier(channel.channelId.uuidString)

        // Expose to accessibility / XCUITest
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityTitle(title)
        button.setAccessibilityIdentifier("tab-\(channel.displayLabel)")
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString) else { return }
        tabDelegate?.tabBarView(self, didSelectChannelWithId: id)
    }
}
