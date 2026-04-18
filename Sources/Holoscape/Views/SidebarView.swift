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
    // Fallback colors for the standalone rendering path (no SkinContext
    // wired). The skinned path reproduces these exact values through
    // `SkinContext.builtInDefaults` state variants on `sidebarRowNormal`
    // and `sidebarRowIndicator`, so per-row notification / connection
    // state flows through state-variant resolution driven by this
    // entry's own `ReactiveUniformSnapshot` — two rows can paint
    // different colors at the same moment without a shared snapshot
    // lighting them both up.
    private static let defaultActiveBg = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0).cgColor
    private static let defaultPermissionBg = NSColor(red: 0.4, green: 0.25, blue: 0.05, alpha: 1.0).cgColor
    private static let defaultPermissionText = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
    private static let defaultIdleBg = NSColor(red: 0.05, green: 0.25, blue: 0.1, alpha: 1.0).cgColor
    private static let defaultIdleText = NSColor(red: 0.4, green: 1.0, blue: 0.5, alpha: 1.0)
    private static let defaultUnreadBg = NSColor(red: 0.1, green: 0.1, blue: 0.22, alpha: 1.0).cgColor

    // Per-entry reactive snapshot. Isolated from the shared snapshot
    // that drives global animations — writes here affect ONLY this
    // row's state-variant resolution.
    private let snapshot = ReactiveUniformSnapshot()

    /// Skin context source. Drives all per-state row colors (selected,
    /// unread, permission, idle) plus the connection-state indicator,
    /// via state variants evaluated against this entry's own snapshot.
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

    /// Resolve a row fill via SkinContext against this entry's own
    /// snapshot — so state variants (unread, permission, idle) read the
    /// per-row values written in `applyConfigure`. Returns nil when no
    /// context is wired or the fill isn't a color.
    private func cgRowFill(for key: SurfaceKey) -> CGColor? {
        guard let ctx = skinContext else { return nil }
        if case .color(let ns) = ctx.currentState(for: key, with: snapshot).fill {
            return ns.cgColor
        }
        NSLog("SidebarTabEntry: non-color fill for '\(key.rawValue)' not yet supported; falling back")
        return nil
    }

    /// Resolve the text color driven by the current row's state variants
    /// (e.g. permission-prompt rows get a gold label, idle-prompt rows
    /// get a green label). Falls back to nil when no skin is wired.
    private func nsRowText(for key: SurfaceKey) -> NSColor? {
        guard let ctx = skinContext else { return nil }
        return ctx.currentState(for: key, with: snapshot).text.color
    }

    // MARK: - Standalone-rendering fallbacks
    //
    // When no SkinContext is wired (XCUITest fixtures, previews,
    // standalone harnesses), these reproduce the pre-skinning per-
    // state colors so the row still renders correctly. The skinned
    // path produces identical colors via `SkinContext.builtInDefaults`
    // state variants — Task 11 hot reload can override any of these.

    private func fallbackNormalBg(hasUnread: Bool, notificationType: String?) -> CGColor? {
        if notificationType == "permission_prompt" { return Self.defaultPermissionBg }
        if notificationType == "idle_prompt" { return Self.defaultIdleBg }
        if hasUnread { return Self.defaultUnreadBg }
        return nil  // Transparent — the pre-skinning default.
    }

    private func fallbackText(isActive: Bool, hasUnread: Bool, notificationType: String?) -> NSColor {
        if isActive { return .white }
        if notificationType == "permission_prompt" { return Self.defaultPermissionText }
        if notificationType == "idle_prompt" { return Self.defaultIdleText }
        if hasUnread { return .white }
        return .lightGray
    }

    private func fallbackIndicator(state: ChannelState) -> CGColor {
        switch state {
        case .active:       return NSColor.systemGreen.cgColor
        case .connecting:   return NSColor.systemYellow.cgColor
        case .disconnected: return NSColor.systemRed.cgColor
        }
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

        // Map the incoming view-level state into this row's snapshot
        // so state-variant resolution picks the right fill + text.
        //   notificationKind: 0 none, 1 idle_prompt, 2 permission_prompt
        //   channelConnectionState: 0 active, 1 connecting, 2 disconnected
        //   channelUnread: 0/1
        //   channelIsActive: 0/1 (the currently-focused tab)
        let notificationKind: Int32
        switch notificationType {
        case "idle_prompt":       notificationKind = 1
        case "permission_prompt": notificationKind = 2
        default:                  notificationKind = 0
        }
        let connectionState: Int32
        switch state {
        case .active:       connectionState = 0
        case .connecting:   connectionState = 1
        case .disconnected: connectionState = 2
        }
        snapshot.setChannelState(
            channelId: channelId.map { Int32(truncatingIfNeeded: $0.hashValue) } ?? 0,
            isActive: isActive ? 1 : 0,
            unread: hasUnread ? 1 : 0
        )
        snapshot.setChannelConnectionState(connectionState)
        snapshot.setNotificationKind(notificationKind)

        // Status text is view-level content (not a color) — drive it here.
        switch state {
        case .active:       statusTextField.stringValue = elapsedTime ?? ""
        case .connecting:   statusTextField.stringValue = "connecting..."
        case .disconnected: statusTextField.stringValue = "disconnected"
        }
        if notificationType == "permission_prompt" {
            statusTextField.stringValue = "needs approval"
        } else if notificationType == "idle_prompt" {
            statusTextField.stringValue = "ready"
        }

        // Row fill + text: when this tab is the focused one, paint
        // `sidebar.row.selected` (which has no notification variants —
        // selection wins over notification). Otherwise paint
        // `sidebar.row.normal`, whose state variants express unread /
        // permission / idle via this entry's private snapshot.
        let rowKey: SurfaceKey = isActive ? .sidebarRowSelected : .sidebarRowNormal
        layer?.backgroundColor = cgRowFill(for: rowKey) ?? (isActive ? Self.defaultActiveBg : fallbackNormalBg(hasUnread: hasUnread, notificationType: notificationType))
        labelField.textColor = nsRowText(for: rowKey) ?? fallbackText(isActive: isActive, hasUnread: hasUnread, notificationType: notificationType)

        // Status indicator dot flows from `sidebarRowIndicator`'s
        // connection-state variants.
        statusIndicator.layer?.backgroundColor = cgRowFill(for: .sidebarRowIndicator)
            ?? fallbackIndicator(state: state)

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
