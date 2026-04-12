import AppKit

@MainActor
protocol AppearanceSettingsDelegate: AnyObject {
    func appearanceSettingsDidChange(_ settings: AppearanceConfig)
}

@MainActor
class AppearanceSettingsWindowController: NSWindowController, NSMenuDelegate {
    weak var settingsDelegate: AppearanceSettingsDelegate?
    private var config: AppearanceConfig
    private let configService: ConfigService

    private let themePopup = NSPopUpButton()
    private let skinPopup = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let transparencySlider = NSSlider()
    private let fontFamilyPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let skinEngine = SkinEngine()
    private let notifEnabledCheckbox = NSButton(checkboxWithTitle: "Enable Notifications", target: nil, action: nil)
    private let notifShellCheckbox = NSButton(checkboxWithTitle: "Shell", target: nil, action: nil)
    private let notifAgentCheckbox = NSButton(checkboxWithTitle: "Agent", target: nil, action: nil)
    private let notifSSHCheckbox = NSButton(checkboxWithTitle: "SSH", target: nil, action: nil)
    private let notifMCPCheckbox = NSButton(checkboxWithTitle: "MCP", target: nil, action: nil)
    private let notifGroupChatCheckbox = NSButton(checkboxWithTitle: "Group Chat", target: nil, action: nil)

    init(config: AppearanceConfig, configService: ConfigService) {
        self.config = config
        self.configService = configService

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Appearance Settings"

        super.init(window: window)
        setupUI()
        loadCurrentValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
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

    private func loadCurrentValues() {
        refreshSkinPopupItems(selectedTitle: config.skinName ?? skinPopup.titleOfSelectedItem)
        let themeName = config.themeName ?? "Dark"
        themePopup.selectItem(withTitle: themeName)
        let skinName = config.skinName ?? "Default"
        skinPopup.selectItem(withTitle: skinName)
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
    }

    @objc private func skinChanged(_ sender: NSPopUpButton) {
        let skinName = sender.titleOfSelectedItem ?? "Default"
        config.skinName = skinName
        if skinName != "Default", let skin = skinEngine.loadSkin(named: skinName) {
            config = skinEngine.apply(skin: skin, to: config)
        }
        loadCurrentValues()
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
        let skins = skinEngine.availableSkins()
        skinPopup.removeAllItems()
        skinPopup.addItems(withTitles: skins)
        for item in skinPopup.itemArray {
            item.identifier = NSUserInterfaceItemIdentifier("skin-\(item.title)")
        }
        if let selectedTitle, skins.contains(selectedTitle) {
            skinPopup.selectItem(withTitle: selectedTitle)
        } else {
            skinPopup.selectItem(withTitle: "Default")
        }
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
