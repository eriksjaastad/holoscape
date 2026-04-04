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

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        return result
    }

    private func setup() {
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0)
        textColor = NSColor.white
        insertionPointColor = NSColor.white
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false

        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityIdentifier("input-box")
    }

    override func keyDown(with event: NSEvent) {
        // Enter key — send input
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            inputDelegate?.inputBoxView(self, didSubmitText: text)
            self.string = ""
            isNavigatingHistory = false
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
