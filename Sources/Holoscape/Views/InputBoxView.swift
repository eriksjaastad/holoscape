import AppKit

@MainActor
protocol InputBoxViewDelegate: AnyObject {
    func inputBoxView(_ inputBox: InputBoxView, didSubmitText text: String)
    func inputBoxViewDidRequestPreviousHistory(_ inputBox: InputBoxView)
    func inputBoxViewDidRequestNextHistory(_ inputBox: InputBoxView)
    func inputBoxView(_ inputBox: InputBoxView, didChangeDraft text: String)
}

@MainActor
class InputBoxView: NSTextView {
    weak var inputDelegate: InputBoxViewDelegate?
    private var isNavigatingHistory = false
    private var draftBeforeHistory: String?

    /// Skin context source. When nil, the view renders with the hardcoded
    /// the modern built-in Default constants — the standalone fallback path for
    /// XCUITest fixtures that don't build a full window controller.
    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    // Built-in Default constants used when no SkinContext is wired.
    // `skinContext == nil`; the skinned path produces the same values
    // because `SkinContext.builtInDefaults` seeds the same values.
    private static let fieldBg = NSColor(hex: "#182331")!
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
        registerForDraggedTypes(TerminalFileInput.readableTypes)
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
            let text = string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            inputDelegate?.inputBoxView(self, didSubmitText: text)
            self.string = ""
            isNavigatingHistory = false
            draftBeforeHistory = nil
            // Force layout recalculation so the height constraint updates
            didChangeText()
            return
        }

        // History is only requested at the first/last logical boundary. This
        // leaves ordinary caret movement intact for multiline drafts.
        if event.keyCode == 126 && (isNavigatingHistory || isAtFirstLogicalBoundary) {
            if !isNavigatingHistory { draftBeforeHistory = string }
            inputDelegate?.inputBoxViewDidRequestPreviousHistory(self)
            return
        }

        if event.keyCode == 125 && (isNavigatingHistory || isAtLastLogicalBoundary) {
            inputDelegate?.inputBoxViewDidRequestNextHistory(self)
            return
        }

        if event.keyCode == 53 && isNavigatingHistory {
            restoreDraftAfterHistory()
            return
        }

        isNavigatingHistory = false
        super.keyDown(with: event)
    }

    func setHistoryText(_ text: String) {
        self.string = text
        isNavigatingHistory = !text.isEmpty
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func restoreDraftAfterHistory() {
        guard isNavigatingHistory else { return }
        string = draftBeforeHistory ?? ""
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        isNavigatingHistory = false
        draftBeforeHistory = nil
        didChangeText()
    }

    func exitHistoryNavigation() {
        isNavigatingHistory = false
        draftBeforeHistory = nil
    }

    override func didChangeText() {
        super.didChangeText()
        inputDelegate?.inputBoxView(self, didChangeDraft: string)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFileInput(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertFileInput(from: sender.draggingPasteboard)
    }

    @objc override func paste(_ sender: Any?) {
        if insertFileInput(from: .general) { return }
        super.paste(sender)
    }

    private func canAcceptFileInput(from pasteboard: NSPasteboard) -> Bool {
        if !TerminalFileInput.fileURLs(from: pasteboard).isEmpty { return true }
        return pasteboard.availableType(from: [TerminalFileInput.imageType, .png, .tiff]) != nil
    }

    @discardableResult
    func insertFileInput(from pasteboard: NSPasteboard) -> Bool {
        do {
            guard let text = try TerminalFileInput.inputText(from: pasteboard) else { return false }
            insertText(text, replacementRange: selectedRange())
            return true
        } catch {
            NSLog("InputBoxView: failed to persist pasted image: \(error)")
            NSSound.beep()
            return false
        }
    }

    private var isAtFirstLogicalBoundary: Bool {
        guard selectedRange.length == 0 else { return false }
        return selectedRange.location == 0
    }

    private var isAtLastLogicalBoundary: Bool {
        guard selectedRange.length == 0 else { return false }
        return selectedRange.location == (string as NSString).length
    }
}
