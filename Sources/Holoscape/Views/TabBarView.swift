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
    private static let idleBg = NSColor(red: 0.10, green: 0.22, blue: 0.12, alpha: 1.0).cgColor
    private static let permissionBg = NSColor(red: 0.24, green: 0.16, blue: 0.08, alpha: 1.0).cgColor

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private var tabButtons: [UUID: NSButton] = [:]
    private var activeChannelId: UUID?
    private var notifications: [UUID: String] = [:]

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

    func updateTabs(channels: [any ChannelController], activeId: UUID?, pinnedIds: Set<UUID> = [], notifications: [UUID: String] = [:]) {
        activeChannelId = activeId
        self.notifications = notifications

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
        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        if channel.channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = Self.activeTabBg
        } else if notifications[channel.channelId] == "permission_prompt" {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = Self.permissionBg
        } else if notifications[channel.channelId] == "idle_prompt" {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = Self.idleBg
        } else {
            button.contentTintColor = NSColor.lightGray
            button.layer?.backgroundColor = nil
        }

        button.setAccessibilityTitle(title)
        button.setAccessibilityIdentifier("tab-\(channel.displayLabel)")
        if let notificationType = notifications[channel.channelId] {
            switch notificationType {
            case "idle_prompt":
                button.setAccessibilityValue("ready")
            case "permission_prompt":
                button.setAccessibilityValue("needs-approval")
            default:
                button.setAccessibilityValue(notificationType)
            }
        } else {
            button.setAccessibilityValue(channel.channelId == activeChannelId ? "active" : "normal")
        }
    }

    private func makeTabButton(for channel: any ChannelController) -> NSButton {
        let title = buildTabTitle(for: channel)

        let button = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        if channel.channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = Self.activeTabBg
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
        updateTabButton(button, for: channel)
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString) else { return }
        tabDelegate?.tabBarView(self, didSelectChannelWithId: id)
    }
}
