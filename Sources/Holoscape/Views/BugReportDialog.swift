import AppKit

@MainActor
protocol BugReportDialogDelegate: AnyObject {
    func bugReportDialog(_ dialog: BugReportDialog, didSubmitDescription description: String, screenshot: Data?)
}

@MainActor
final class BugReportDialog {
    weak var delegate: BugReportDialogDelegate?

    private var panel: NSPanel?
    private var descriptionField: NSTextView!
    private var contextTextView: NSTextView!
    private var screenshotData: Data?
    private var screenshotButton: NSButton!
    private var submitButton: NSButton!

    struct Context {
        let activeChannelName: String
        let activeChannelType: String
        let allChannelStates: [ChannelStateInfo]
        let lastOutputLines: [String]
        let appearanceConfig: String
        let splitLayout: String?
        let appVersion: String
        let macOSVersion: String
        let hardwareModel: String
        let uptime: TimeInterval
    }

    func show(in parentWindow: NSWindow, context: Context) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Report Bug"
        panel.setAccessibilityIdentifier("bug-report-dialog")
        panel.isReleasedWhenClosed = false
        self.panel = panel

        let contentView = NSView(frame: panel.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        // Description label
        let descLabel = NSTextField(labelWithString: "What happened?")
        descLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(descLabel)

        // Description field
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        descriptionField = NSTextView()
        descriptionField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        descriptionField.isEditable = true
        descriptionField.isSelectable = true
        descriptionField.isRichText = false
        descriptionField.setAccessibilityIdentifier("bug-description-field")
        scrollView.documentView = descriptionField
        contentView.addSubview(scrollView)

        // Context disclosure
        let contextLabel = NSTextField(labelWithString: "Auto-Captured Context")
        contextLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contextLabel)

        // Context text view
        let contextScroll = NSScrollView()
        contextScroll.translatesAutoresizingMaskIntoConstraints = false
        contextScroll.hasVerticalScroller = true
        contextScroll.borderType = .bezelBorder

        contextTextView = NSTextView()
        contextTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        contextTextView.isEditable = false
        contextTextView.isSelectable = true
        contextTextView.isRichText = false
        contextTextView.textColor = .secondaryLabelColor
        contextTextView.setAccessibilityIdentifier("bug-context-view")
        contextScroll.documentView = contextTextView
        contentView.addSubview(contextScroll)

        // Populate context
        contextTextView.string = formatContext(context)

        // Screenshot button
        screenshotButton = NSButton(title: "Attach Screenshot", target: self, action: #selector(captureScreenshot))
        screenshotButton.bezelStyle = .rounded
        screenshotButton.translatesAutoresizingMaskIntoConstraints = false
        screenshotButton.setAccessibilityIdentifier("bug-screenshot-button")
        contentView.addSubview(screenshotButton)

        // Cancel button
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        contentView.addSubview(cancelButton)

        // Submit button
        submitButton = NSButton(title: "Submit Report", target: self, action: #selector(submit))
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r" // Enter
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.setAccessibilityIdentifier("bug-submit-button")
        contentView.addSubview(submitButton)

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.heightAnchor.constraint(equalToConstant: 100),

            contextLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            contextLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            contextScroll.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 4),
            contextScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contextScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contextScroll.bottomAnchor.constraint(equalTo: screenshotButton.topAnchor, constant: -12),

            screenshotButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            screenshotButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            submitButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            submitButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: submitButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        parentWindow.beginSheet(panel)
        panel.makeFirstResponder(descriptionField)
    }

    private func formatContext(_ ctx: Context) -> String {
        var lines: [String] = []
        lines.append("Active Channel: \(ctx.activeChannelName) (\(ctx.activeChannelType))")
        lines.append("App Version: \(ctx.appVersion)")
        lines.append("macOS: \(ctx.macOSVersion)")
        lines.append("Hardware: \(ctx.hardwareModel)")
        lines.append("Uptime: \(formatUptime(ctx.uptime))")
        lines.append("")

        lines.append("--- All Channels ---")
        for ch in ctx.allChannelStates {
            lines.append("  \(ch.channelName) [\(ch.channelType.rawValue)] — \(ch.state)")
        }
        lines.append("")

        lines.append("--- Appearance ---")
        lines.append(ctx.appearanceConfig)
        if let layout = ctx.splitLayout {
            lines.append("Split Layout: \(layout)")
        }
        lines.append("")

        lines.append("--- Last 50 Lines of Output ---")
        for line in ctx.lastOutputLines.suffix(50) {
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    private func formatUptime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    @objc private func captureScreenshot() {
        guard let window = panel?.sheetParent else { return }
        // Capture window content using NSBitmapImageRep
        guard let contentView = window.contentView else { return }
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        screenshotData = bitmap.representation(using: .png, properties: [:])
        screenshotButton.title = "Screenshot Attached"
        screenshotButton.setAccessibilityLabel("Screenshot Attached")
        screenshotButton.isEnabled = false
    }

    @objc private func cancel() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
        self.panel = nil
    }

    @objc private func submit() {
        guard let panel else { return }
        let desc = descriptionField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else {
            presentAlert(
                messageText: "Please describe what happened",
                informativeText: "A brief description helps us understand the issue.",
                style: .warning
            )
            return
        }

        panel.sheetParent?.endSheet(panel)
        self.panel = nil
        delegate?.bugReportDialog(self, didSubmitDescription: desc, screenshot: screenshotData)
    }

    private func presentAlert(messageText: String, informativeText: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")

        if let parent = panel?.sheetParent {
            alert.beginSheetModal(for: parent) { _ in }
        } else if let panel {
            alert.beginSheetModal(for: panel) { _ in }
        } else {
            alert.runModal()
        }
    }
}
