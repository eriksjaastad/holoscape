import AppKit

@MainActor
protocol AppearanceSettingsDelegate: AnyObject {
    func appearanceSettingsDidChange(_ settings: AppearanceConfig)

    /// The skin picker selected a skin. Receiver should reload the v2
    /// chrome pipeline for `name` — load images, register fonts (while
    /// unregistering the previous bundle), convert surfaces, and call
    /// `MainWindowController.applySkin(_:)`. Implemented in
    /// `MainWindowController` as `reloadSkin(named:)`.
    ///
    /// Kept separate from `appearanceSettingsDidChange` because that
    /// hook covers AppearanceConfig-level edits (background color,
    /// font, ANSI palette — the v1 path). The v2 chrome pipeline needs
    /// its own signal so this PR can wire it without disturbing any
    /// existing observers of `didChange`.
    func appearanceSettingsDidSelectSkin(_ name: String)

    /// The settings surface requested the scrollback storage maintenance window.
    /// Implemented in `AppDelegate`, which owns and retains the
    /// `ScrollbackMaintenanceWindowController`.
    func appearanceSettingsDidRequestScrollbackStorage()
}

@MainActor
class AppearanceSettingsWindowController: NSWindowController, NSMenuDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var settingsDelegate: AppearanceSettingsDelegate?
    private var config: AppearanceConfig
    private let configService: ConfigService

    private let themePopup = NSPopUpButton()
    private let skinPopup = NSPopUpButton()
    private let skinLibrary = NSTableView()
    private let settingsScrollView = NSScrollView()
    private var skinCatalog: [SkinCatalogEntry] = []
    private var isRefreshingSkinControls = false
    private let createSkinButton = NSButton(title: "Create…", target: nil, action: nil)
    private let duplicateSkinButton = NSButton(title: "Duplicate…", target: nil, action: nil)
    private let revealSkinButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let deleteSkinButton = NSButton(title: "Delete", target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let transparencySlider = NSSlider()
    private let fontFamilyPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let shaderPopup = NSPopUpButton()
    private let skinEngine: SkinEngine
    private let skinLibraryService: SkinLibraryService

    /// Internal read-only accessor exposing the current density gate wiring
    /// for test verification. Production code must not rely on this.
    var _densityManagerOnSkinEngine: DensityModeManager? { skinEngine.densityModeManager }
    /// Internal read-only accessor for deterministic layout verification.
    var _storageButtonForTesting: NSButton { storageButton }
    var _skinPopupForTesting: NSPopUpButton { skinPopup }
    var _skinLibraryForTesting: NSTableView { skinLibrary }
    var _skinCatalogForTesting: [SkinCatalogEntry] { skinCatalog }
    var _settingsScrollViewForTesting: NSScrollView { settingsScrollView }
    var _createSkinButtonForTesting: NSButton { createSkinButton }
    var _duplicateSkinButtonForTesting: NSButton { duplicateSkinButton }
    var _revealSkinButtonForTesting: NSButton { revealSkinButton }
    var _deleteSkinButtonForTesting: NSButton { deleteSkinButton }
    private let notifEnabledCheckbox = NSButton(checkboxWithTitle: "Enable Notifications", target: nil, action: nil)
    private let notifShellCheckbox = NSButton(checkboxWithTitle: "Shell", target: nil, action: nil)
    private let notifAgentCheckbox = NSButton(checkboxWithTitle: "Agent", target: nil, action: nil)
    private let notifSSHCheckbox = NSButton(checkboxWithTitle: "SSH", target: nil, action: nil)
    private let notifMCPCheckbox = NSButton(checkboxWithTitle: "MCP", target: nil, action: nil)
    private let notifGroupChatCheckbox = NSButton(checkboxWithTitle: "Group Chat", target: nil, action: nil)
    private let storageButton = NSButton(title: "Manage Stored Scrollback…", target: nil, action: nil)

    init(
        config: AppearanceConfig,
        configService: ConfigService,
        densityModeManager: DensityModeManager? = nil,
        skinEngine: SkinEngine? = nil,
        skinLibraryService: SkinLibraryService? = nil
    ) {
        self.config = config
        self.configService = configService
        let resolvedEngine = skinEngine ?? SkinEngine()
        self.skinEngine = resolvedEngine
        self.skinLibraryService = skinLibraryService ?? SkinLibraryService(engine: resolvedEngine)

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Appearance Settings"
        window.minSize = NSSize(width: 520, height: 520)

        super.init(window: window)
        // Wire the density gate on our SkinEngine so a user with mode=.off
        // sees skin.apply() return config unchanged rather than paint colors.
        self.skinEngine.densityModeManager = densityModeManager
        setupUI()
        loadCurrentValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        settingsScrollView.translatesAutoresizingMaskIntoConstraints = false
        settingsScrollView.hasVerticalScroller = true
        settingsScrollView.drawsBackground = false
        settingsScrollView.setAccessibilityIdentifier("appearance-settings-scroll-view")
        contentView.addSubview(settingsScrollView)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        settingsScrollView.documentView = documentView

        NSLayoutConstraint.activate([
            settingsScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            settingsScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            settingsScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            settingsScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: settingsScrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: settingsScrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: settingsScrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: settingsScrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        // Theme
        let themeRow = makeRow(label: "Theme:", control: themePopup)
        themePopup.addItems(withTitles: ColorTheme.allThemes.map(\.name))
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        themePopup.setAccessibilityIdentifier("theme-popup")
        stack.addArrangedSubview(themeRow)

        // Skin
        let skinRow = makeRow(label: "Skin:", control: skinPopup)
        refreshSkinPopupItems()
        skinPopup.target = self
        skinPopup.action = #selector(skinChanged(_:))
        skinPopup.setAccessibilityIdentifier("skin-popup")
        skinPopup.menu?.delegate = self
        stack.addArrangedSubview(skinRow)

        let libraryHeader = NSTextField(labelWithString: "Skin Library")
        libraryHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(libraryHeader)

        let libraryScrollView = NSScrollView()
        libraryScrollView.hasVerticalScroller = true
        libraryScrollView.borderType = .bezelBorder
        libraryScrollView.translatesAutoresizingMaskIntoConstraints = false
        libraryScrollView.heightAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(libraryScrollView)
        libraryScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        skinLibrary.headerView = nil
        skinLibrary.rowHeight = 54
        skinLibrary.intercellSpacing = NSSize(width: 0, height: 1)
        skinLibrary.selectionHighlightStyle = .regular
        skinLibrary.allowsEmptySelection = false
        skinLibrary.dataSource = self
        skinLibrary.delegate = self
        skinLibrary.setAccessibilityIdentifier("skin-library")
        skinLibrary.setAccessibilityLabel("Skin Library")
        let skinColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("skin-library-column"))
        skinColumn.resizingMask = .autoresizingMask
        skinLibrary.addTableColumn(skinColumn)
        libraryScrollView.documentView = skinLibrary

        let skinActionSpacer = NSView()
        skinActionSpacer.widthAnchor.constraint(equalToConstant: 148).isActive = true
        let skinActions = NSStackView(views: [skinActionSpacer, createSkinButton, duplicateSkinButton, revealSkinButton, deleteSkinButton])
        skinActions.orientation = .horizontal
        skinActions.spacing = 8
        skinActions.setAccessibilityIdentifier("skin-actions")
        configureSkinAction(createSkinButton, identifier: "skin-create-button", tooltip: "Create a new skin from the modern starter")
        configureSkinAction(duplicateSkinButton, identifier: "skin-duplicate-button", tooltip: "Duplicate the selected skin into your skin library")
        configureSkinAction(revealSkinButton, identifier: "skin-reveal-button", tooltip: "Reveal the selected skin in Finder")
        configureSkinAction(deleteSkinButton, identifier: "skin-delete-button", tooltip: "Delete an inactive skin from your skin library")
        createSkinButton.target = self
        createSkinButton.action = #selector(createSkin(_:))
        duplicateSkinButton.target = self
        duplicateSkinButton.action = #selector(duplicateSkin(_:))
        revealSkinButton.target = self
        revealSkinButton.action = #selector(revealSkin(_:))
        deleteSkinButton.target = self
        deleteSkinButton.action = #selector(deleteSkin(_:))
        stack.addArrangedSubview(skinActions)

        // Shader
        let shaderRow = makeRow(label: "Shader:", control: shaderPopup)
        shaderPopup.addItems(withTitles: ["None", "Identity", "Scanlines"])
        shaderPopup.target = self
        shaderPopup.action = #selector(shaderChanged(_:))
        shaderPopup.setAccessibilityIdentifier("shader-popup")
        stack.addArrangedSubview(shaderRow)

        // Background color
        let colorRow = makeRow(label: "Background Color:", control: colorWell)
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        stack.addArrangedSubview(colorRow)

        // Transparency
        let transRow = makeRow(label: "Transparency:", control: transparencySlider)
        transparencySlider.minValue = 0.3
        transparencySlider.maxValue = 1.0
        transparencySlider.target = self
        transparencySlider.action = #selector(transparencyChanged(_:))
        transparencySlider.setAccessibilityIdentifier("transparency-slider")
        stack.addArrangedSubview(transRow)

        // Font family
        let fontRow = makeRow(label: "Font Family:", control: fontFamilyPopup)
        let monoFonts = ["SF Mono", "Menlo", "Monaco", "Courier New", "Fira Code", "JetBrains Mono"]
        fontFamilyPopup.addItems(withTitles: monoFonts)
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontChanged(_:))
        fontFamilyPopup.setAccessibilityIdentifier("font-family-popup")
        stack.addArrangedSubview(fontRow)

        // Font size
        let sizeRow = makeRow(label: "Font Size:", control: fontSizeField)
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged(_:))
        fontSizeField.setAccessibilityIdentifier("font-size-field")
        stack.addArrangedSubview(sizeRow)

        // Notifications section
        let notifHeader = NSTextField(labelWithString: "Notifications")
        notifHeader.font = NSFont.boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(notifHeader)

        notifEnabledCheckbox.target = self
        notifEnabledCheckbox.action = #selector(notificationToggled(_:))
        stack.addArrangedSubview(notifEnabledCheckbox)

        let channelTypeStack = NSStackView()
        channelTypeStack.orientation = .vertical
        channelTypeStack.alignment = .leading
        channelTypeStack.spacing = 4
        for checkbox in [notifShellCheckbox, notifAgentCheckbox, notifSSHCheckbox, notifMCPCheckbox, notifGroupChatCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(notificationToggled(_:))
            channelTypeStack.addArrangedSubview(checkbox)
        }
        let indentedRow = NSStackView()
        indentedRow.orientation = .horizontal
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 20).isActive = true
        indentedRow.addArrangedSubview(spacer)
        indentedRow.addArrangedSubview(channelTypeStack)
        stack.addArrangedSubview(indentedRow)

        // Storage section — opens the scrollback maintenance window.
        let storageHeader = NSTextField(labelWithString: "Storage")
        storageHeader.font = NSFont.boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(storageHeader)

        storageButton.target = self
        storageButton.action = #selector(openScrollbackStorage(_:))
        storageButton.setAccessibilityIdentifier("storage-button")
        stack.addArrangedSubview(storageButton)

    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row.addArrangedSubview(labelView)

        control.widthAnchor.constraint(equalToConstant: 200).isActive = true
        row.addArrangedSubview(control)

        return row
    }

    private static let shaderPathMap: [String: String?] = [
        "None": nil,
        "Identity": "demos/identity.glsl",
        "Scanlines": "demos/scanlines.glsl",
    ]

    private func loadCurrentValues() {
        refreshSkinPopupItems(selectedTitle: config.skinName ?? skinPopup.titleOfSelectedItem)

        // Shader
        let selectedShader = Self.shaderPathMap.first { $0.value == config.customShaderPath }?.key ?? "None"
        shaderPopup.selectItem(withTitle: selectedShader)

        let themeName = config.themeName ?? "Dark"
        themePopup.selectItem(withTitle: themeName)
        if let color = NSColor(hexString: config.backgroundColor) {
            colorWell.color = color
        }
        transparencySlider.doubleValue = config.transparency
        fontFamilyPopup.selectItem(withTitle: config.fontFamily)
        // Display as integer when there's no fractional part (e.g., "16" not "16.0")
        fontSizeField.stringValue = config.fontSize.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(config.fontSize))
            : String(config.fontSize)

        // Notification state
        let fullConfig = configService.load()
        let notifConfig = fullConfig.notifications ?? .default
        notifEnabledCheckbox.state = notifConfig.enabled ? .on : .off
        let perType = notifConfig.perChannelType ?? [:]
        notifShellCheckbox.state = (perType["shell"] ?? false) ? .on : .off
        notifAgentCheckbox.state = (perType["agent"] ?? true) ? .on : .off
        notifSSHCheckbox.state = (perType["ssh"] ?? true) ? .on : .off
        notifMCPCheckbox.state = (perType["mcp"] ?? true) ? .on : .off
        notifGroupChatCheckbox.state = (perType["groupChat"] ?? true) ? .on : .off

        let notifEnabled = notifConfig.enabled
        for cb in [notifShellCheckbox, notifAgentCheckbox, notifSSHCheckbox, notifMCPCheckbox, notifGroupChatCheckbox] {
            cb.isEnabled = notifEnabled
        }
        updateSkinActionStates()
    }

    @objc private func skinChanged(_ sender: NSPopUpButton) {
        guard !isRefreshingSkinControls else { return }
        applySelectedSkin(named: selectedSkinIdentifier() ?? "Default")
    }

    private func applySelectedSkin(named skinName: String) {
        config.skinName = skinName
        // v1 path — transfers `windowBackground` / `ansiColors` /
        // `textForeground` from the skin manifest to the AppearanceConfig.
        if skinName != "Default", let skin = skinEngine.loadSkin(named: skinName) {
            config = skinEngine.apply(skin: skin, to: config)
        } else if let theme = ColorTheme.named(config.themeName ?? "Dark") ?? ColorTheme.named("Dark") {
            // Default is not a skin manifest: restore its terminal palette from
            // the selected theme, while retaining deliberate user overrides.
            config = theme.apply(to: config, overrides: config.themeOverrides)
        }
        settingsDelegate?.appearanceSettingsDidSelectSkin(skinName)
        loadCurrentValues()
        applyAndSave()
    }

    private func configureSkinAction(_ button: NSButton, identifier: String, tooltip: String) {
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = tooltip
        button.setAccessibilityLabel(button.title)
    }

    private func updateSkinActionStates() {
        let selected = selectedSkinIdentifier() ?? "Default"
        let isDefault = selected == "Default"
        revealSkinButton.isEnabled = !isDefault
        duplicateSkinButton.isEnabled = !isDefault
        deleteSkinButton.isEnabled = !deletableSkinNames().isEmpty
    }

    @objc private func createSkin(_ sender: NSButton) {
        guard let name = promptForSkinName(title: "Create Skin", message: "Enter a name for the new skin:") else { return }
        do {
            _ = try skinLibraryService.create(name: name)
            refreshSkinPopupItems(selectedTitle: name)
            applySelectedSkin(named: name)
        } catch {
            showSkinError(error)
        }
    }

    @objc private func duplicateSkin(_ sender: NSButton) {
        let source = selectedSkinIdentifier() ?? "Default"
        guard source != "Default", let name = promptForSkinName(title: "Duplicate Skin", message: "Enter a name for the copy of \"\(source)\":") else { return }
        do {
            _ = try skinLibraryService.create(name: name, from: .existing(source))
            refreshSkinPopupItems(selectedTitle: name)
            applySelectedSkin(named: name)
        } catch {
            showSkinError(error)
        }
    }

    @objc private func revealSkin(_ sender: NSButton) {
        do {
            let url = try skinLibraryService.revealURL(for: selectedSkinIdentifier() ?? "Default")
            revealSkinURL(url)
        } catch {
            showSkinError(error)
        }
    }

    @objc private func deleteSkin(_ sender: NSButton) {
        let candidates = deletableSkinNames()
        guard deleteSkinButton.isEnabled,
              let name = chooseSkinForDeletion(from: candidates),
              confirmSkinDeletion(name: name) else { return }
        do {
            try skinLibraryService.delete(name: name, activeSkinName: config.skinName)
            refreshSkinPopupItems(selectedTitle: config.skinName ?? "Default")
        } catch {
            showSkinError(error)
        }
    }

    internal func _performCreateForTesting() { createSkin(createSkinButton) }
    internal func _performDuplicateForTesting() { duplicateSkin(duplicateSkinButton) }
    internal func _performRevealForTesting() { revealSkin(revealSkinButton) }
    internal func _performDeleteForTesting() { deleteSkin(deleteSkinButton) }
    internal func _applySelectedSkinForTesting(named name: String) { applySelectedSkin(named: name) }
    internal func _selectSkinLibraryItemForTesting(identifier: String) {
        guard let row = skinCatalog.firstIndex(where: { $0.identifier == identifier }) else { return }
        isRefreshingSkinControls = true
        skinLibrary.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRefreshingSkinControls = false
        applySelectedSkin(named: identifier)
    }

    private func deletableSkinNames() -> [String] {
        let active = config.skinName ?? "Default"
        return skinEngine.availableSkins().filter {
            $0.caseInsensitiveCompare(active) != .orderedSame && skinLibraryService.isUserManaged(name: $0)
        }
    }

    internal func promptForSkinName(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    internal func confirmSkinDeletion(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Skin?"
        alert.informativeText = "Delete the inactive skin \"\(name)\"? This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    internal func chooseSkinForDeletion(from names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Choose a Skin to Delete"
        alert.informativeText = "Only inactive skins from your skin library are listed."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: names)
        popup.setAccessibilityIdentifier("skin-delete-picker")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil
    }

    internal func revealSkinURL(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    internal func showSkinError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Skin Operation Failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.runModal()
    }

    @objc private func shaderChanged(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? "None"
        config.customShaderPath = Self.shaderPathMap[title] ?? nil
        applyAndSave()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let themeName = sender.titleOfSelectedItem ?? "Dark"
        guard let theme = ColorTheme.named(themeName) else { return }
        config.themeName = themeName
        config.themeOverrides = nil  // Clear overrides on theme switch
        config = theme.apply(to: config, overrides: nil)
        loadCurrentValues()
        applyAndSave()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        config.backgroundColor = sender.color.hexString
        // Store as theme override
        var overrides = config.themeOverrides ?? [:]
        overrides["backgroundColor"] = sender.color.hexString
        config.themeOverrides = overrides
        applyAndSave()
    }

    @objc private func transparencyChanged(_ sender: NSSlider) {
        config.transparency = sender.doubleValue
        applyAndSave()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        config.fontFamily = sender.titleOfSelectedItem ?? "SF Mono"
        applyAndSave()
    }

    @objc private func fontSizeChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let size = Double(text), size > 0 else {
            // Reject non-numeric input — revert to current value
            sender.stringValue = config.fontSize.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(config.fontSize))
                : String(config.fontSize)
            return
        }
        config.fontSize = size
        applyAndSave()
    }

    @objc private func notificationToggled(_ sender: NSButton) {
        var fullConfig = configService.load()
        var notifConfig = fullConfig.notifications ?? .default
        notifConfig.enabled = notifEnabledCheckbox.state == .on
        notifConfig.perChannelType = [
            "shell": notifShellCheckbox.state == .on,
            "agent": notifAgentCheckbox.state == .on,
            "ssh": notifSSHCheckbox.state == .on,
            "mcp": notifMCPCheckbox.state == .on,
            "groupChat": notifGroupChatCheckbox.state == .on,
        ]
        fullConfig.notifications = notifConfig
        configService.save(fullConfig)

        // Enable/disable per-type checkboxes based on master toggle
        let enabled = notifConfig.enabled
        for cb in [notifShellCheckbox, notifAgentCheckbox, notifSSHCheckbox, notifMCPCheckbox, notifGroupChatCheckbox] {
            cb.isEnabled = enabled
        }
    }

    @objc private func openScrollbackStorage(_ sender: NSButton) {
        settingsDelegate?.appearanceSettingsDidRequestScrollbackStorage()
    }

    private func applyAndSave() {
        settingsDelegate?.appearanceSettingsDidChange(config)
        var fullConfig = configService.load()
        fullConfig.appearance = config
        configService.save(fullConfig)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == skinPopup.menu else { return }
        refreshSkinPopupItems(selectedTitle: skinPopup.titleOfSelectedItem)
    }

    private func refreshSkinPopupItems(selectedTitle: String? = nil) {
        skinCatalog = skinEngine.availableSkinCatalog()
        let selectedIdentifier = selectedTitle.flatMap { title in
            skinCatalog.first(where: { $0.identifier == title || $0.displayName == title })?.identifier
        } ?? "Default"
        isRefreshingSkinControls = true
        defer { isRefreshingSkinControls = false }
        skinPopup.removeAllItems()
        for entry in skinCatalog {
            skinPopup.addItem(withTitle: entry.displayName)
            guard let item = skinPopup.lastItem else { continue }
            item.representedObject = entry.identifier
            item.identifier = NSUserInterfaceItemIdentifier("skin-\(entry.identifier)")
        }
        if let popupIndex = skinPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedIdentifier }) {
            skinPopup.selectItem(at: popupIndex)
        }
        skinLibrary.reloadData()
        if let row = skinCatalog.firstIndex(where: { $0.identifier == selectedIdentifier }) {
            skinLibrary.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            skinLibrary.scrollRowToVisible(row)
        }
        updateSkinActionStates()
    }

    private func selectedSkinIdentifier() -> String? {
        skinPopup.selectedItem?.representedObject as? String
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        skinCatalog.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard skinCatalog.indices.contains(row) else { return nil }
        let entry = skinCatalog[row]
        let identifier = NSUserInterfaceItemIdentifier("skin-library-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        cell.subviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: entry.displayName)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let source = NSTextField(labelWithString: entry.source.displayName.uppercased())
        source.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        source.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: entry.detailText)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let heading = NSStackView(views: [title, source])
        heading.orientation = .horizontal
        heading.spacing = 8
        let content = NSStackView(views: [heading, detail])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            heading.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
        ])
        cell.setAccessibilityIdentifier("skin-library-\(entry.identifier)")
        cell.setAccessibilityLabel("\(entry.displayName), \(entry.source.displayName), \(entry.detailText)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshingSkinControls,
              skinCatalog.indices.contains(skinLibrary.selectedRow) else { return }
        let selected = skinCatalog[skinLibrary.selectedRow]
        if let popupIndex = skinPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected.identifier }) {
            isRefreshingSkinControls = true
            skinPopup.selectItem(at: popupIndex)
            isRefreshingSkinControls = false
        }
        applySelectedSkin(named: selected.identifier)
    }
}

// MARK: - NSColor hex output

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
