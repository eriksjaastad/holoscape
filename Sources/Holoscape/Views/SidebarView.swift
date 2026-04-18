import AppKit

@MainActor
protocol SidebarViewDelegate: AnyObject {
    func sidebarView(_ sidebar: SidebarView, didSelectChannelWithId id: UUID)
    func sidebarView(_ sidebar: SidebarView, contextMenuForChannelWithId id: UUID) -> NSMenu?
}

@MainActor
class SidebarView: NSView {
    weak var sidebarDelegate: SidebarViewDelegate?

    /// Skin context source. When set, propagates to every existing and
    /// newly created `SidebarTabEntry` so a skin swap reaches the rows.
    /// Nil falls back to the pre-skinning hardcoded constants.
    var skinContext: SkinContext? {
        didSet {
            refreshFromSkin()
            for entry in tabEntries.values {
                entry.skinContext = skinContext
            }
        }
    }

    private static let containerBg = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var tabEntries: [UUID: SidebarTabEntry] = [:]
    private var activeChannelId: UUID?

    private let entryHeight: CGFloat = 36
    private let sidebarWidth: CGFloat = 220

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
        setupSkinObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
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
        guard let ctx = skinContext else {
            layer?.backgroundColor = Self.containerBg
            return
        }
        if case .color(let ns) = ctx.currentState(for: .sidebarContainer).fill {
            layer?.backgroundColor = ns.cgColor
        } else {
            NSLog("SidebarView: non-color fill for 'sidebar.container' not yet supported; falling back")
            layer?.backgroundColor = Self.containerBg
        }
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = Self.containerBg

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = stackView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])
    }

    func updateTabs(channels: [any ChannelController], activeId: UUID?, pinnedIds: Set<UUID> = [], notifications: [UUID: String] = [:]) {
        activeChannelId = activeId

        let currentIds = Set(channels.map { $0.channelId })

        // Remove entries for channels that no longer exist
        for (id, entry) in tabEntries where !currentIds.contains(id) {
            stackView.removeArrangedSubview(entry)
            entry.removeFromSuperview()
            tabEntries.removeValue(forKey: id)
        }

        // Update existing entries in-place, create new ones as needed
        for (index, channel) in channels.enumerated() {
            let isPinned = pinnedIds.contains(channel.channelId)
            let notificationType = notifications[channel.channelId]

            if let existing = tabEntries[channel.channelId] {
                // Update in place — no alloc, no constraint churn
                existing.configure(
                    label: channel.displayLabel,
                    channelType: channel.channelType,
                    hasUnread: channel.hasUnread,
                    state: channel.state,
                    isActive: channel.channelId == activeId,
                    elapsedTime: ElapsedTimeFormatter.format(since: channel.activatedAt),
                    isPinned: isPinned,
                    notificationType: notificationType
                )
                // Reorder if needed
                let arrangedViews = stackView.arrangedSubviews
                if index < arrangedViews.count && arrangedViews[index] !== existing {
                    stackView.removeArrangedSubview(existing)
                    stackView.insertArrangedSubview(existing, at: index)
                }
            } else {
                // New channel — create entry
                let entry = SidebarTabEntry(frame: .zero)
                entry.skinContext = skinContext
                entry.configure(
                    label: channel.displayLabel,
                    channelType: channel.channelType,
                    hasUnread: channel.hasUnread,
                    state: channel.state,
                    isActive: channel.channelId == activeId,
                    elapsedTime: ElapsedTimeFormatter.format(since: channel.activatedAt),
                    isPinned: isPinned,
                    notificationType: notificationType
                )
                entry.channelId = channel.channelId
                entry.target = self
                entry.action = #selector(entryClicked(_:))
                entry.translatesAutoresizingMaskIntoConstraints = false

                stackView.insertArrangedSubview(entry, at: index)
                NSLayoutConstraint.activate([
                    entry.heightAnchor.constraint(equalToConstant: entryHeight),
                    entry.widthAnchor.constraint(equalTo: stackView.widthAnchor),
                ])

                tabEntries[channel.channelId] = entry
            }
        }

        // Force layout then auto-scroll to the active entry
        stackView.layoutSubtreeIfNeeded()
        if let activeId, let activeEntry = tabEntries[activeId] {
            activeEntry.scrollToVisible(activeEntry.bounds)
        }
    }

    @objc private func entryClicked(_ sender: SidebarTabEntry) {
        guard let id = sender.channelId else { return }
        sidebarDelegate?.sidebarView(self, didSelectChannelWithId: id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        for (id, entry) in tabEntries {
            if entry.frame.contains(convert(point, to: entry.superview ?? self)) {
                return sidebarDelegate?.sidebarView(self, contextMenuForChannelWithId: id)
            }
        }
        return nil
    }
}

// MARK: - SidebarTabEntry

/// Sidebar entry backed by NSButton for native accessibility hit-test support.
/// Custom NSControl subclasses are not recognized by XCTest's isHittable check
/// after dynamic insertion (e.g., post-NSAlert.runModal()), because the
/// accessibility system only provides full hit-test integration for standard
/// AppKit control classes. NSButton gets this natively.
@MainActor
class SidebarTabEntry: NSButton {
    // Pre-computed CGColors — avoids NSColor→CGColor conversion on every configure() call.
    //
    // Migration status (Task 9.2): `activeBg` and the clear-row state
    // are resolved from `SkinContext` when one is wired. The four
    // notification-state colors below (permission/idle/unread + their
    // text colors) and the three status-indicator colors remain
    // hardcoded — they correspond to state variants on the
    // `sidebar.row.*` surfaces that aren't yet wired through to
    // `ReactiveUniformSnapshot`. Lands with Task 11 hot-reload /
    // reactive plumbing.
    private static let defaultActiveBg = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0).cgColor
    private static let permissionBg = NSColor(red: 0.4, green: 0.25, blue: 0.05, alpha: 1.0).cgColor
    private static let permissionText = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
    private static let idleBg = NSColor(red: 0.05, green: 0.25, blue: 0.1, alpha: 1.0).cgColor
    private static let idleText = NSColor(red: 0.4, green: 1.0, blue: 0.5, alpha: 1.0)
    private static let unreadBg = NSColor(red: 0.1, green: 0.1, blue: 0.22, alpha: 1.0).cgColor
    private static let greenStatus = NSColor.systemGreen.cgColor
    private static let yellowStatus = NSColor.systemYellow.cgColor
    private static let redStatus = NSColor.systemRed.cgColor

    /// Skin context source. Drives `sidebar.row.selected` and
    /// `sidebar.row.normal` fills; notification-state variants stay
    /// hardcoded until the reactive-match plumbing lands.
    var skinContext: SkinContext? {
        didSet { configureLast() }
    }

    /// Cached last-configure arguments so a skin swap can re-apply
    /// the current state without the caller re-running updateTabs.
    private var lastConfigure: (() -> Void)?

    var channelId: UUID?
    private var stableTypePrefix = "Shell"

    private let labelField = NSTextField(labelWithString: "")
    private let statusTextField = NSTextField(labelWithString: "")
    private let unreadDot = NSView()
    private let statusIndicator = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
        setupSkinObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
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
        configureLast()
    }

    /// Re-run the most recent configure call so skin changes take effect.
    /// No-op before the first `configure(...)` lands.
    private func configureLast() {
        lastConfigure?()
    }

    /// Resolve a row fill via SkinContext; nil when no context is wired
    /// or the fill isn't a color.
    private func cgRowFill(for key: SurfaceKey) -> CGColor? {
        guard let ctx = skinContext else { return nil }
        if case .color(let ns) = ctx.currentState(for: key).fill {
            return ns.cgColor
        }
        NSLog("SidebarTabEntry: non-color fill for '\(key.rawValue)' not yet supported; falling back")
        return nil
    }

    private func setupViews() {
        // Suppress default NSButton chrome — we draw everything with custom subviews
        title = ""
        isBordered = false
        imagePosition = .noImage

        wantsLayer = true
        layer?.cornerRadius = 4

        labelField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        labelField.textColor = NSColor.lightGray
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false

        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        unreadDot.layer?.cornerRadius = 4
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.isHidden = true

        statusIndicator.wantsLayer = true
        statusIndicator.layer?.cornerRadius = 3
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusTextField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusTextField.textColor = NSColor.gray
        statusTextField.lineBreakMode = .byTruncatingTail
        statusTextField.translatesAutoresizingMaskIntoConstraints = false

        // Subviews are decorative parts of a single accessible button — they must
        // not be accessibility elements, otherwise the hit test resolves to the
        // child NSTextField instead of the entry.
        for child in [unreadDot, statusIndicator, labelField, statusTextField] as [NSView] {
            child.setAccessibilityElement(false)
        }

        addSubview(unreadDot)
        addSubview(statusIndicator)
        addSubview(labelField)
        addSubview(statusTextField)

        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),

            statusIndicator.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: 6),
            statusIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 6),
            statusIndicator.heightAnchor.constraint(equalToConstant: 6),

            labelField.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: 6),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusTextField.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 4),
            statusTextField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            statusTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(label: String, channelType: ChannelType = .shell, hasUnread: Bool, state: ChannelState, isActive: Bool, elapsedTime: String? = nil, isPinned: Bool = false, notificationType: String? = nil) {
        // Stash the call so a later skin swap can re-apply the same
        // state without the caller re-running updateTabs.
        lastConfigure = { [weak self] in
            self?.applyConfigure(
                label: label, channelType: channelType, hasUnread: hasUnread,
                state: state, isActive: isActive, elapsedTime: elapsedTime,
                isPinned: isPinned, notificationType: notificationType
            )
        }
        lastConfigure?()
    }

    private func applyConfigure(label: String, channelType: ChannelType, hasUnread: Bool, state: ChannelState, isActive: Bool, elapsedTime: String?, isPinned: Bool, notificationType: String?) {
        self.stableTypePrefix = channelType.sidebarPrefix
        labelField.stringValue = isPinned ? "\u{1F4CC} \(label)" : label
        unreadDot.isHidden = true  // No dots — use background colors

        switch state {
        case .active:
            statusIndicator.layer?.backgroundColor = Self.greenStatus
            statusTextField.stringValue = elapsedTime ?? ""
        case .connecting:
            statusIndicator.layer?.backgroundColor = Self.yellowStatus
            statusTextField.stringValue = "connecting..."
        case .disconnected:
            statusIndicator.layer?.backgroundColor = Self.redStatus
            statusTextField.stringValue = "disconnected"
        }

        if isActive {
            layer?.backgroundColor = cgRowFill(for: .sidebarRowSelected) ?? Self.defaultActiveBg
            labelField.textColor = NSColor.white
        } else if notificationType == "permission_prompt" {
            layer?.backgroundColor = Self.permissionBg
            labelField.textColor = Self.permissionText
            statusTextField.stringValue = "needs approval"
        } else if notificationType == "idle_prompt" {
            layer?.backgroundColor = Self.idleBg
            labelField.textColor = Self.idleText
            statusTextField.stringValue = "ready"
        } else if hasUnread {
            layer?.backgroundColor = Self.unreadBg
            labelField.textColor = NSColor.white
        } else {
            // Normal row — skin-specified fill on `sidebar.row.normal` if
            // present; otherwise transparent (matching pre-migration).
            layer?.backgroundColor = cgRowFill(for: .sidebarRowNormal)
            labelField.textColor = NSColor.lightGray
        }

        // NSButton provides native accessibility — just set the metadata.
        // The title shows the dynamic display label (may change with directory).
        // The identifier uses the label for test discoverability.
        setAccessibilityTitle(isPinned ? "\u{1F4CC} \(label)" : label)
        setAccessibilityIdentifier("sidebar-\(label)")

        if let notificationType {
            switch notificationType {
            case "idle_prompt": setAccessibilityValue("ready")
            case "permission_prompt": setAccessibilityValue("needs-approval")
            default: setAccessibilityValue(notificationType)
            }
        } else if state == .disconnected {
            setAccessibilityValue("disconnected")
        } else {
            setAccessibilityValue(isActive ? "active" : "normal")
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let action, let target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return superview?.superview?.superview?.menu(for: event)
    }
}
