import AppKit

@MainActor
protocol AppearanceSettingsDelegate: AnyObject {
    func appearanceSettingsDidChange(_ settings: AppearanceConfig)
}

@MainActor
class AppearanceSettingsWindowController: NSWindowController {
    weak var settingsDelegate: AppearanceSettingsDelegate?
    private var config: AppearanceConfig
    private let configService: ConfigService

    private let colorWell = NSColorWell()
    private let transparencySlider = NSSlider()
    private let fontFamilyPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()

    init(config: AppearanceConfig, configService: ConfigService) {
        self.config = config
        self.configService = configService

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
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
        stack.addArrangedSubview(transRow)

        // Font family
        let fontRow = makeRow(label: "Font Family:", control: fontFamilyPopup)
        let monoFonts = ["SF Mono", "Menlo", "Monaco", "Courier New", "Fira Code", "JetBrains Mono"]
        fontFamilyPopup.addItems(withTitles: monoFonts)
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontChanged(_:))
        stack.addArrangedSubview(fontRow)

        // Font size
        let sizeRow = makeRow(label: "Font Size:", control: fontSizeField)
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged(_:))
        stack.addArrangedSubview(sizeRow)
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
        if let color = NSColor(hexString: config.backgroundColor) {
            colorWell.color = color
        }
        transparencySlider.doubleValue = config.transparency
        fontFamilyPopup.selectItem(withTitle: config.fontFamily)
        fontSizeField.stringValue = String(config.fontSize)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        config.backgroundColor = sender.color.hexString
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
        config.fontSize = sender.doubleValue
        applyAndSave()
    }

    private func applyAndSave() {
        settingsDelegate?.appearanceSettingsDidChange(config)
        var fullConfig = configService.load()
        fullConfig.appearance = config
        configService.save(fullConfig)
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
