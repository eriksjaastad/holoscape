import AppKit

@MainActor
protocol SessionLauncherDelegate: AnyObject {
    func sessionLauncherWillPresent(_ launcher: SessionLauncherView)
    func sessionLauncher(_ launcher: SessionLauncherView, didSelectBuiltInProfile profile: SessionProfile, root: URL)
    func sessionLauncher(_ launcher: SessionLauncherView, didSelectProfile profile: SessionProfile)
    func sessionLauncher(_ launcher: SessionLauncherView, didSelectRecentSession recent: RecentSession)
    func sessionLauncher(_ launcher: SessionLauncherView, didTypeNewName name: String)
    func sessionLauncherDidRequestRefresh(_ launcher: SessionLauncherView)
}

@MainActor
class SessionLauncherView: NSView, NSSearchFieldDelegate {
    weak var launcherDelegate: SessionLauncherDelegate?

    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    private static let containerBg = NSColor(hex: "#121b27")!.cgColor

    private let searchField = LauncherSearchField()
    private let refreshButton = LauncherButton()
    private let popover = NSPopover()
    private let rootPathLabel = NSTextField(labelWithString: "")
    private let resultsStack = NSStackView()
    private let scrollView = NSScrollView()
    private var representedItems: [String: DirectoryLauncherItem] = [:]
    private var visibleItems: [DirectoryLauncherItem] = []
    private var resultButtons: [NSButton] = []
    private var selectedResultIndex: Int?
    private var snapshot: DirectoryLauncherSnapshot?
    private var configuredProfiles: [SessionProfile] = []
    private var builtInProfiles = SessionProfileManager.builtInProfiles
    private var discoveredProfiles: [SessionProfile] = []
    private var recentSessions: [RecentSession] = []
    private var selectedRoot: URL = DefaultWorkingDirectory.preferredURL
    private var followsSuggestedRoot = true
    private var refreshInProgress = false
    private var refreshFailureDescription: String?

    var comboBoxForTesting: NSSearchField { searchField }
    var refreshButtonForTesting: NSButton { refreshButton }
    var selectedRootURL: URL { selectedRoot }
    var rootPathForTesting: String { selectedRoot.path }
    var selectedItemLabelForTesting: String? {
        guard let selectedResultIndex, visibleItems.indices.contains(selectedResultIndex) else { return nil }
        return visibleItems[selectedResultIndex].label
    }
    var selectedItemAccessibilitySelectedForTesting: Bool? {
        guard let selectedResultIndex, resultButtons.indices.contains(selectedResultIndex) else { return nil }
        return resultButtons[selectedResultIndex].isAccessibilitySelected()
    }
    var firstResultFontForTesting: NSFont? {
        resultButtons.first?.font
    }
    var visibleSectionTitlesForTesting: [String] {
        snapshot?.filtered(by: searchField.stringValue).sections.map(\.title) ?? []
    }
    var resultsStartAtTopForTesting: Bool {
        scrollView.documentView?.isFlipped == true
            && !resultsStack.isFlipped
            && scrollView.contentView.bounds.origin == .zero
    }
    var resultsFitViewportForTesting: Bool {
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView.documentView?.frame.width ?? .greatestFiniteMagnitude)
            <= scrollView.contentView.bounds.width + 0.5
    }
    var refreshStatusTextForTesting: String? { refreshStatusText }
    var refreshFailureDescriptionForTesting: String? { refreshFailureDescription }

    private(set) var refreshButtonHovered = false
    private(set) var refreshButtonPressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
        setupPopover()
        setupSkinObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        setupPopover()
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
        guard let layer else { return }
        guard let ctx = skinContext else {
            layer.backgroundColor = Self.containerBg
            return
        }
        let resolved = ctx.currentState(for: .sessionLauncherContainer)
        let backingScale = window?.backingScaleFactor ?? 2.0
        ctx.applyFill(to: layer, from: resolved, backingScale: backingScale)
        if let font = ctx.resolvedFont(for: .sessionLauncherContainer) {
            searchField.font = font
        }
        ctx.applyBorderAndCorner(to: layer, from: resolved)
        applyRefreshButtonFill()
    }

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

    func refreshButtonSurfaceAndState() -> (SurfaceKey, SpriteState) {
        if refreshButtonPressed {
            return (.sessionLauncherButtonPressed, .pressed)
        }
        if refreshButtonHovered {
            return (.sessionLauncherButtonHover, .hover)
        }
        return (.sessionLauncherButtonNormal, .normal)
    }

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
        refreshFromSkin()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = Self.containerBg

        searchField.onActivate = { [weak self] in self?.showPopover() }
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.placeholderString = "New channel, directory, or ssh host"
        searchField.toolTip = "Search channel actions, child directories, saved sessions, or type a command such as ssh host."
        searchField.setAccessibilityLabel("New channel launcher")
        searchField.setAccessibilityHelp(searchField.toolTip)
        searchField.setAccessibilityIdentifier("session-launcher-combo")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.launcher = self
        refreshButton.wantsLayer = true
        refreshButton.bezelStyle = .recessed
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.toolTip = "Refresh launcher directories and sessions"
        refreshButton.setAccessibilityLabel("Refresh launcher")
        refreshButton.setAccessibilityHelp("Reload the current root directory and configured sessions")
        refreshButton.setAccessibilityIdentifier("refresh-sessions")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(refreshButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 440, height: 520)

        let contentController = NSViewController()
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        contentView.setAccessibilityElement(false)

        let rootTitle = NSTextField(labelWithString: "CURRENT ROOT")
        rootTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        rootTitle.textColor = .secondaryLabelColor
        rootTitle.setAccessibilityElement(true)
        rootTitle.setAccessibilityRole(.staticText)
        rootTitle.setAccessibilityIdentifier("launcher-root-title")
        rootTitle.translatesAutoresizingMaskIntoConstraints = false

        rootPathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        rootPathLabel.lineBreakMode = .byTruncatingMiddle
        rootPathLabel.setAccessibilityLabel("Current launcher root")
        rootPathLabel.setAccessibilityIdentifier("launcher-root-path")
        rootPathLabel.translatesAutoresizingMaskIntoConstraints = false

        let chooseRootButton = NSButton(title: "Choose…", target: self, action: #selector(chooseRoot))
        chooseRootButton.bezelStyle = .inline
        chooseRootButton.setAccessibilityIdentifier("launcher-choose-root")
        chooseRootButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 4
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = LauncherResultsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(resultsStack)
        NSLayoutConstraint.activate([
            resultsStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            resultsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 12),
            resultsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),
            resultsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -12),
            resultsStack.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -24),
        ])

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        contentView.addSubview(rootTitle)
        contentView.addSubview(rootPathLabel)
        contentView.addSubview(chooseRootButton)
        contentView.addSubview(separator)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            rootTitle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            rootTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootPathLabel.topAnchor.constraint(equalTo: rootTitle.bottomAnchor, constant: 3),
            rootPathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootPathLabel.trailingAnchor.constraint(equalTo: chooseRootButton.leadingAnchor, constant: -10),
            chooseRootButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            chooseRootButton.centerYAnchor.constraint(equalTo: rootPathLabel.centerYAnchor),
            separator.topAnchor.constraint(equalTo: rootPathLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        contentController.view = contentView
        popover.contentViewController = contentController
    }

    func updateItems(
        configured: [SessionProfile],
        builtIn: [SessionProfile],
        discovered: [SessionProfile],
        recent: [RecentSession],
        root: URL = DefaultWorkingDirectory.preferredURL
    ) {
        configuredProfiles = configured
        builtInProfiles = builtIn
        discoveredProfiles = discovered
        recentSessions = recent
        if followsSuggestedRoot {
            selectedRoot = root.standardizedFileURL
        }
        reloadSnapshot()
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    func presentChoices() {
        focus()
        showPopover()
    }

    func beginInlineAgentChannelDraft(kindLabel: String, directory: URL) {
        let defaultLabel = directory.lastPathComponent.isEmpty ? "Agent" : directory.lastPathComponent
        searchField.stringValue = "\(kindLabel) \(directory.path) as \(defaultLabel)"
        searchField.placeholderString = "\(kindLabel) <directory> as <label>"
        presentChoices()
        if let editor = window?.fieldEditor(true, for: searchField) as? NSTextView {
            editor.selectAll(nil)
        }
    }

    @objc private func refreshClicked() {
        guard beginRefresh() else { return }
        showPopover()
        launcherDelegate?.sessionLauncherDidRequestRefresh(self)
    }

    func requestRefreshForTesting() {
        guard beginRefresh() else { return }
        launcherDelegate?.sessionLauncherDidRequestRefresh(self)
    }

    private func beginRefresh() -> Bool {
        guard !refreshInProgress, launcherDelegate != nil else { return false }
        refreshInProgress = true
        refreshFailureDescription = nil
        refreshButton.isEnabled = false
        refreshButton.setAccessibilityLabel("Refreshing launcher")
        refreshButton.setAccessibilityHelp("Launcher directories and configured sessions are refreshing")
        reloadSnapshot()
        return true
    }

    func completeRefresh(errorDescription: String?) {
        guard refreshInProgress else { return }
        refreshInProgress = false
        refreshFailureDescription = errorDescription
        refreshButton.isEnabled = true
        refreshButton.setAccessibilityLabel("Refresh launcher")
        refreshButton.setAccessibilityHelp("Reload the current root directory and configured sessions")
        renderResults()
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedRoot
        panel.prompt = "Use as Root"
        panel.message = "Choose the directory whose immediate child folders should appear in the launcher."

        let applySelection: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.followsSuggestedRoot = false
            self?.selectedRoot = url.standardizedFileURL
            self?.reloadSnapshot()
            self?.showPopover()
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: applySelection)
        } else {
            applySelection(panel.runModal())
        }
    }

    private func reloadSnapshot() {
        snapshot = DirectoryLauncherModel.snapshot(
            root: selectedRoot,
            configured: configuredProfiles,
            builtIn: builtInProfiles,
            discovered: discoveredProfiles,
            recent: recentSessions
        )
        if let directoryError = snapshot?.directoryError {
            NSLog("SessionLauncher: unable to read root '%@': %@", selectedRoot.path, directoryError)
        }
        rootPathLabel.stringValue = selectedRoot.path
        rootPathLabel.toolTip = selectedRoot.path
        renderResults()
    }

    private func showPopover() {
        guard !popover.isShown else { return }
        launcherDelegate?.sessionLauncherWillPresent(self)
        if snapshot == nil {
            reloadSnapshot()
        }
        renderResults()
        popover.show(relativeTo: searchField.bounds, of: searchField, preferredEdge: .maxY)
        scrollResultsToTop()
    }

    private func renderResults() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        representedItems.removeAll()
        visibleItems.removeAll()
        resultButtons.removeAll()
        selectedResultIndex = nil

        if let refreshStatusText {
            let message = NSTextField(labelWithString: refreshStatusText)
            message.textColor = refreshInProgress ? .secondaryLabelColor : .systemOrange
            message.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            message.toolTip = refreshFailureDescription
            message.setAccessibilityIdentifier("launcher-refresh-status")
            resultsStack.addArrangedSubview(message)
        }

        let filtered = snapshot?.filtered(by: searchField.stringValue)
        if let directoryError = filtered?.directoryError {
            let text = filtered?.hasAvailableDirectories == true
                ? "Some directories could not be loaded. Available results remain usable."
                : "Directories unavailable. Channel actions and saved sessions remain available."
            let message = NSTextField(labelWithString: text)
            message.textColor = .systemOrange
            message.font = NSFont.systemFont(ofSize: 11)
            message.toolTip = directoryError
            message.setAccessibilityIdentifier("launcher-directory-error")
            resultsStack.addArrangedSubview(message)
        }
        guard let sections = filtered?.sections, !sections.isEmpty else {
            let message = NSTextField(labelWithString: "No matches. Press Return to launch the typed command.")
            message.textColor = .secondaryLabelColor
            message.font = NSFont.systemFont(ofSize: 12)
            message.setAccessibilityIdentifier("launcher-empty-state")
            resultsStack.addArrangedSubview(message)
            return
        }

        for section in sections {
            let heading = NSTextField(labelWithString: section.title.uppercased())
            heading.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            heading.setAccessibilityIdentifier("launcher-section-\(identifierFragment(section.title))")
            resultsStack.addArrangedSubview(heading)

            for item in section.items {
                let identifier = UUID().uuidString
                representedItems[identifier] = item
                visibleItems.append(item)
                let button = NSButton(title: rowTitle(for: item), target: self, action: #selector(selectResult(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(identifier)
                button.bezelStyle = .inline
                button.isBordered = false
                button.alignment = .left
                button.font = skinContext?.resolvedFont(for: .sessionLauncherContainer)
                    ?? NSFont.systemFont(ofSize: 12)
                button.lineBreakMode = .byTruncatingTail
                button.setAccessibilityLabel(item.label)
                button.setAccessibilityHelp(item.detail)
                button.setAccessibilityIdentifier("launcher-item-\(identifierFragment(item.label))")
                button.translatesAutoresizingMaskIntoConstraints = false
                resultsStack.addArrangedSubview(button)
                resultButtons.append(button)
                button.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: item.detail == nil ? 26 : 38).isActive = true
            }
        }
        if !visibleItems.isEmpty {
            selectedResultIndex = 0
            updateSelectionAppearance()
        }
        scrollResultsToTop()
    }

    private var refreshStatusText: String? {
        if refreshInProgress {
            return "Refreshing channels and sessions…"
        }
        if refreshFailureDescription != nil {
            return "Refresh failed. Showing last known sessions."
        }
        return nil
    }

    func moveSelectionForTesting(by delta: Int) {
        moveSelection(by: delta)
    }

    private func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        selectedResultIndex = min(max((selectedResultIndex ?? 0) + delta, 0), visibleItems.count - 1)
        updateSelectionAppearance()
        if let selectedResultIndex {
            resultButtons[selectedResultIndex].scrollToVisible(resultButtons[selectedResultIndex].bounds)
        }
    }

    private func updateSelectionAppearance() {
        for (index, button) in resultButtons.enumerated() {
            let selected = index == selectedResultIndex
            button.isBordered = selected
            button.bezelStyle = selected ? .recessed : .inline
            button.setAccessibilitySelected(selected)
        }
    }

    private func scrollResultsToTop() {
        scrollView.documentView?.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func rowTitle(for item: DirectoryLauncherItem) -> String {
        guard let detail = item.detail, !detail.isEmpty else { return item.label }
        return "\(item.label)\n\(detail)"
    }

    private func identifierFragment(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "/", with: "-")
    }

    @objc private func selectResult(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let item = representedItems[identifier] else { return }
        select(item)
    }

    private func select(_ item: DirectoryLauncherItem) {
        popover.close()
        searchField.stringValue = ""
        switch item.kind {
        case .builtIn:
            if let profile = item.profile {
                launcherDelegate?.sessionLauncher(self, didSelectBuiltInProfile: profile, root: selectedRoot)
            }
        case .profile:
            if let profile = item.profile {
                launcherDelegate?.sessionLauncher(self, didSelectProfile: profile)
            }
        case .recent:
            if let recent = item.recent {
                launcherDelegate?.sessionLauncher(self, didSelectRecentSession: recent)
            }
        }
    }


    nonisolated func controlTextDidBeginEditing(_ notification: Notification) {
        MainActor.assumeIsolated { showPopover() }
    }

    nonisolated func controlTextDidChange(_ notification: Notification) {
        MainActor.assumeIsolated { renderResults() }
    }

    nonisolated func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        MainActor.assumeIsolated {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let selectedResultIndex, visibleItems.indices.contains(selectedResultIndex) {
                    let item = visibleItems[selectedResultIndex]
                    select(item)
                } else {
                    let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return true }
                    popover.close()
                    launcherDelegate?.sessionLauncher(self, didTypeNewName: text)
                    searchField.stringValue = ""
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                moveSelection(by: 1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                moveSelection(by: -1)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                popover.close()
                searchField.stringValue = ""
                return false
            }
            return false
        }
    }
}

@MainActor
final class LauncherResultsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LauncherSearchField: NSSearchField {
    var onActivate: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.onActivate?() }
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onActivate?()
    }
}

@MainActor
final class LauncherButton: HoverTrackingButton {
    weak var launcher: SessionLauncherView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        publishHoverStateForUITesting()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        publishHoverStateForUITesting()
    }

    override func hoverStateDidChange(isInside: Bool) {
        publishHoverStateForUITesting()
        if isInside {
            launcher?.handleRefreshButtonMouseEntered()
        } else {
            launcher?.handleRefreshButtonMouseExited()
        }
    }

    override func mouseDown(with event: NSEvent) {
        launcher?.handleRefreshButtonMouseDown()
        super.mouseDown(with: event)
        launcher?.handleRefreshButtonMouseUp()
    }

    private func publishHoverStateForUITesting() {
        guard CommandLine.arguments.contains("--ui-testing") else { return }
        setAccessibilityValue(isPointerInside ? "hovered" : "not hovered")
    }
}
