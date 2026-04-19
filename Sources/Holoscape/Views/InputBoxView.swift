import AppKit

@MainActor
protocol InputBoxViewDelegate: AnyObject {
    func inputBoxView(_ inputBox: InputBoxView, didSubmitText text: String)
    func inputBoxViewDidRequestPreviousHistory(_ inputBox: InputBoxView)
    func inputBoxViewDidRequestNextHistory(_ inputBox: InputBoxView)
}

@MainActor
class InputBoxView: NSTextView {
    weak var inputDelegate: InputBoxViewDelegate?
    private var isNavigatingHistory = false

    /// Skin context source. When nil, the view renders with the hardcoded
    /// pre-skinning constants — the standalone fallback path for
    /// XCUITest fixtures that don't build a full window controller.
    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    // Built-in defaults matching the pre-skinning colors. Used when
    // `skinContext == nil`; the skinned path produces the same values
    // because `SkinContext.builtInDefaults` seeds the same values.
    private static let fieldBg = NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0)
    private static let fieldText = NSColor.white

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
        setupSkinObserver()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setup()
        setupSkinObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
        setupSkinObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        return result
    }

    private func setup() {
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        backgroundColor = Self.fieldBg
        textColor = Self.fieldText
        insertionPointColor = Self.fieldText
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false

        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityIdentifier("input-box")
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

    /// Re-resolve field background, text color, and insertion-point
    /// color from the current skin context. When the surface fill
    /// isn't a color (image/gradient), logs and falls back to the
    /// built-in constant so we never silently degrade.
    private func refreshFromSkin() {
        guard let ctx = skinContext else {
            backgroundColor = Self.fieldBg
            textColor = Self.fieldText
            insertionPointColor = Self.fieldText
            return
        }

        let field = ctx.currentState(for: .inputBoxField)
        switch field.fill {
        case .color(let ns):
            backgroundColor = ns
        case .image, .gradient:
            NSLog("InputBoxView: non-color fill for '\(SurfaceKey.inputBoxField.rawValue)' not yet supported; falling back")
            backgroundColor = Self.fieldBg
        }
        textColor = field.text.color
        insertionPointColor = field.text.color
        // Amplify Task 13 — skin-defined font on the input field.
        // Nil means the manifest doesn't declare a font; preserve
        // whatever the init assigned.
        if let font = ctx.resolvedFont(for: .inputBoxField) {
            self.font = font
        }
        // Amplify Task 15 — border/corner/shadow on the input field's
        // backing layer. NSTextView's layer exists when wantsLayer is
        // set by the scroll-view host; guarded for safety.
        if let layer = self.layer {
            ctx.applyBorderAndCorner(to: layer, from: field)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Enter key — send input
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            inputDelegate?.inputBoxView(self, didSubmitText: text)
            self.string = ""
            isNavigatingHistory = false
            // Force layout recalculation so the height constraint updates
            didChangeText()
            return
        }

        // Up arrow — previous history (when empty or already navigating)
        if event.keyCode == 126 && (string.isEmpty || isNavigatingHistory) {
            isNavigatingHistory = true
            inputDelegate?.inputBoxViewDidRequestPreviousHistory(self)
            return
        }

        // Down arrow — next history (when empty or already navigating)
        if event.keyCode == 125 && (string.isEmpty || isNavigatingHistory) {
            inputDelegate?.inputBoxViewDidRequestNextHistory(self)
            return
        }

        isNavigatingHistory = false
        super.keyDown(with: event)
    }

    func setHistoryText(_ text: String) {
        self.string = text
        isNavigatingHistory = !text.isEmpty
        setSelectedRange(NSRange(location: text.count, length: 0))
    }
}
