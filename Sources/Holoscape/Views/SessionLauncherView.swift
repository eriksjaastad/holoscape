import AppKit

@MainActor
protocol SessionLauncherDelegate: AnyObject {
    func sessionLauncher(_ launcher: SessionLauncherView, didSelectProfile label: String)
    func sessionLauncher(_ launcher: SessionLauncherView, didTypeNewName name: String)
    func sessionLauncherDidRequestRefresh(_ launcher: SessionLauncherView)
}

@MainActor
class SessionLauncherView: NSView, NSComboBoxDelegate, NSComboBoxDataSource {
    weak var launcherDelegate: SessionLauncherDelegate?

    /// Skin context source. Nil falls back to the hardcoded default
    /// below (standalone rendering path).
    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    private static let containerBg = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor

    private let comboBox = NSComboBox()
    /// Amplify Task 11.5 — subclassed refresh button so hover + pressed
    /// transitions flow back into the launcher's sprite-state tracking.
    /// Nil skinContext = no-op; state tracking still runs harmlessly.
    private let refreshButton = LauncherButton()
    private var items: [LauncherItem] = []

    /// Amplify Task 11.5 — hover + pressed state for the refresh button.
    /// Only one button, so we keep simple flags rather than a per-button
    /// dict (TabBarView's approach). `private(set)` + `internal` so
    /// tests can inspect without writing.
    private(set) var refreshButtonHovered: Bool = false
    private(set) var refreshButtonPressed: Bool = false

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

    /// Apply the container fill (color / gradient / image) via
    /// `SkinContext.applyFill` so gradient and ninepatch skins render
    /// correctly. Nil skinContext falls back to the hardcoded
    /// pre-skinning color.
    private func refreshFromSkin() {
        guard let layer else { return }
        guard let ctx = skinContext else {
            layer.backgroundColor = Self.containerBg
            return
        }
        let resolved = ctx.currentState(for: .sessionLauncherContainer)
        let backingScale = window?.backingScaleFactor ?? 2.0
        ctx.applyFill(to: layer, from: resolved, backingScale: backingScale)
        // Amplify Task 13 — combo box font from the skin. Applies to
        // both the visible field and the dropdown list. Nil = retain
        // init's monospaced default.
        if let font = ctx.resolvedFont(for: .sessionLauncherContainer) {
            comboBox.font = font
        }
        // Amplify Task 15 — border/corner/shadow on the launcher
        // container layer. Shadow on the container gives the launcher
        // visual separation from the sidebar; border gives a skin
        // authoring-friendly outline option.
        ctx.applyBorderAndCorner(to: layer, from: resolved)
        // Amplify Task 11.5 — paint the refresh button from a per-
        // state sprite-capable surface. Each state maps to a distinct
        // SurfaceKey so a skin author can declare `sessionLauncher.button.hover`
        // as a solid color OR use `.sessionLauncher.button.normal` with
        // a sprite descriptor and pass state through the spriteState
        // channel. Both work; `applyRefreshButtonFill` handles both.
        applyRefreshButtonFill()
    }

    /// Amplify Task 11.5 — resolve and apply the refresh button's
    /// fill based on current hover + pressed state. Also applies
    /// border/corner/shadow per Task 15 conventions so the button
    /// participates in skin chrome.
    private func applyRefreshButtonFill() {
        guard let ctx = skinContext,
              let buttonLayer = refreshButton.layer else {
            return
        }
        let (key, state) = refreshButtonSurfaceAndState()
        let resolved = ctx.currentState(for: key)
        let backingScale = window?.backingScaleFactor ?? 2.0
        ctx.applyFill(
            to: buttonLayer,
            from: resolved,
            backingScale: backingScale,
            spriteState: state
        )
        ctx.applyBorderAndCorner(
            to: buttonLayer,
            from: resolved,
            clampCornerToHalfHeight: refreshButton.bounds.height
        )
    }

    /// Map the refresh button's hover + pressed flags to a (surfaceKey,
    /// spriteState) pair. Pressed > hover > normal. Exposed at internal
    /// visibility so the sprite-publishing tests can verify the
    /// mapping without driving real NSEvents.
    func refreshButtonSurfaceAndState() -> (SurfaceKey, SpriteState) {
        if refreshButtonPressed {
            return (.sessionLauncherButtonPressed, .pressed)
        }
        if refreshButtonHovered {
            return (.sessionLauncherButtonHover, .hover)
        }
        return (.sessionLauncherButtonNormal, .normal)
    }

    // MARK: - Amplify Task 11.5 event handlers

    func handleRefreshButtonMouseEntered() {
        refreshButtonHovered = true
        applyRefreshButtonFill()
    }

    func handleRefreshButtonMouseExited() {
        refreshButtonHovered = false
        applyRefreshButtonFill()
    }

    func handleRefreshButtonMouseDown() {
        refreshButtonPressed = true
        applyRefreshButtonFill()
    }

    func handleRefreshButtonMouseUp() {
        refreshButtonPressed = false
        applyRefreshButtonFill()
    }

    override func layout() {
        super.layout()
        // Re-apply so gradient sublayers track the launcher's bounds.
        refreshFromSkin()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = Self.containerBg

        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = true
        comboBox.dataSource = self
        comboBox.delegate = self
        comboBox.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        comboBox.placeholderString = "Open session..."
        comboBox.setAccessibilityIdentifier("session-launcher-combo")
        comboBox.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.launcher = self
        refreshButton.wantsLayer = true
        refreshButton.bezelStyle = .recessed
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "Refresh project list"
        refreshButton.setAccessibilityIdentifier("refresh-sessions")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(comboBox)
        addSubview(refreshButton)

        NSLayoutConstraint.activate([
            comboBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            comboBox.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
            comboBox.centerYAnchor.constraint(equalTo: centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// Update the items shown in the dropdown.
    func updateItems(preconfigured: [SessionProfile], discovered: [SessionProfile], recent: [RecentSession]) {
        items.removeAll()

        if !preconfigured.isEmpty {
            items.append(LauncherItem(label: "--- Sessions ---", isHeader: true))
            for profile in preconfigured {
                items.append(LauncherItem(label: profile.label, isHeader: false))
            }
        }

        if !discovered.isEmpty {
            items.append(LauncherItem(label: "--- Projects ---", isHeader: true))
            for profile in discovered {
                items.append(LauncherItem(label: profile.label, isHeader: false))
            }
        }

        if !recent.isEmpty {
            items.append(LauncherItem(label: "--- Recent ---", isHeader: true))
            for session in recent {
                items.append(LauncherItem(label: session.label, isHeader: false))
            }
        }

        comboBox.reloadData()
    }

    /// Focus the combobox for keyboard input.
    func focus() {
        window?.makeFirstResponder(comboBox)
    }

    @objc private func refreshClicked() {
        launcherDelegate?.sessionLauncherDidRequestRefresh(self)
    }

    // MARK: - NSComboBoxDataSource

    nonisolated func numberOfItems(in comboBox: NSComboBox) -> Int {
        return MainActor.assumeIsolated { items.count }
    }

    nonisolated func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        return MainActor.assumeIsolated { items[index].label }
    }

    // MARK: - NSComboBoxDelegate

    nonisolated func comboBoxSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            let index = comboBox.indexOfSelectedItem
            guard index >= 0, index < items.count else { return }
            let item = items[index]
            guard !item.isHeader else { return }
            launcherDelegate?.sessionLauncher(self, didSelectProfile: item.label)
            comboBox.stringValue = ""
        }
    }

    // Handle Enter key on typed text
    nonisolated func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        return MainActor.assumeIsolated {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let text = comboBox.stringValue.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return true }

                // Check if it matches an existing item
                let matchesExisting = items.contains { !$0.isHeader && $0.label.lowercased() == text.lowercased() }
                if matchesExisting {
                    launcherDelegate?.sessionLauncher(self, didSelectProfile: text)
                } else {
                    launcherDelegate?.sessionLauncher(self, didTypeNewName: text)
                }
                comboBox.stringValue = ""
                return true
            }
            return false
        }
    }
}

// MARK: - LauncherItem

struct LauncherItem {
    let label: String
    let isHeader: Bool
}

// MARK: - LauncherButton (Amplify Task 11.5)

/// NSButton subclass that forwards hover + pressed transitions to
/// its owning `SessionLauncherView`. NSTrackingArea is installed in
/// `updateTrackingAreas` so the rect always matches the button's
/// current bounds even after auto-layout resizes.
///
/// `mouseDown` runs AppKit's modal tracking loop — when it returns
/// the button has already released, so the "pressed" flag is
/// cleared right after `super.mouseDown` rather than via a separate
/// `mouseUp` override (AppKit eats mouseUp events during the
/// tracking loop).
@MainActor
final class LauncherButton: NSButton {
    weak var launcher: SessionLauncherView?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        launcher?.handleRefreshButtonMouseEntered()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        launcher?.handleRefreshButtonMouseExited()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        launcher?.handleRefreshButtonMouseDown()
        super.mouseDown(with: event)
        launcher?.handleRefreshButtonMouseUp()
    }
}
