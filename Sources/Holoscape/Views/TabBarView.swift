import AppKit

@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID)
}

@MainActor
class TabBarView: NSView {
    weak var tabDelegate: TabBarViewDelegate?

    /// When non-nil, surfaces are resolved from the skin context. When
    /// nil, falls back to the pre-skinning hardcoded constants below so
    /// this view still renders standalone (used in XCUITest fixtures).
    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    // Built-in defaults matching the pre-skinning colors. Used only when
    // `skinContext == nil`; the SkinContext path produces identical
    // colors because `SkinContext.builtInDefaults` seeds the same values.
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
        setupSkinObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollView()
        setupSkinObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    /// Re-resolve the container background and every existing tab
    /// button so a SkinContext swap (or a skin hot-reload) takes
    /// effect without needing a full `updateTabs(…)` pass.
    private func refreshFromSkin() {
        layer?.backgroundColor = cgFill(for: .tabBarContainer) ?? Self.barBg
        for (id, button) in tabButtons {
            // Re-apply per-button state using the current skin.
            applyTabStyle(button, channelId: id)
        }
    }

    /// Resolve a surface to its background `CGColor` via SkinContext,
    /// or nil if no skin is wired (caller falls back to the hardcoded
    /// constant) or the fill isn't a color. Image/gradient handling for
    /// tab surfaces lands in Task 9.x follow-ups — for now we log loudly
    /// so a skin author who ships a gradient tab doesn't silently get
    /// the pre-skinning color instead.
    private func cgFill(for key: SurfaceKey) -> CGColor? {
        guard let ctx = skinContext else { return nil }
        let fill = ctx.currentState(for: key).fill
        if case .color(let ns) = fill {
            return ns.cgColor
        }
        NSLog("TabBarView: non-color fill for '\(key.rawValue)' not yet supported; falling back to hardcoded default")
        return nil
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

        applyTabStyle(button, channelId: channel.channelId)

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

    /// Apply the correct background fill and text tint for a tab based
    /// on its current state (active / permission / idle / normal). Each
    /// branch reads from the skin context when available and falls back
    /// to the hardcoded constant otherwise.
    private func applyTabStyle(_ button: NSButton, channelId: UUID) {
        if channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = cgFill(for: .tabBarTabActive) ?? Self.activeTabBg
        } else if notifications[channelId] == "permission_prompt" {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = cgFill(for: .tabBarTabPermission) ?? Self.permissionBg
        } else if notifications[channelId] == "idle_prompt" {
            button.contentTintColor = NSColor.white
            button.layer?.backgroundColor = cgFill(for: .tabBarTabIdle) ?? Self.idleBg
        } else {
            button.contentTintColor = NSColor.lightGray
            // `.tabBarTabNormal` has no hardcoded fallback — built-in
            // default is transparent (no background). A nil here means
            // "no background", not "something went wrong". Do NOT add
            // `?? Self.someConstant` — that would diverge from the
            // built-in default.
            button.layer?.backgroundColor = cgFill(for: .tabBarTabNormal)
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
