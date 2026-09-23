import AppKit

@MainActor
final class SetupDiagnosticsWindowController: NSWindowController {
    private let diagnosticsService: SetupDiagnosticsService
    private let stackView = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Loading setup diagnostics…")

    init(diagnosticsService: SetupDiagnosticsService) {
        self.diagnosticsService = diagnosticsService

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 460))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Holoscape Setup Diagnostics"
        window.contentView = contentView
        super.init(window: window)
        buildContent(in: contentView)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        statusLabel.stringValue = "Checking setup diagnostics…"
        diagnosticsService.snapshot { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.render(snapshot)
            }
        }
    }

    private func buildContent(in contentView: NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshButtonPressed))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(refreshButton)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),

            refreshButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            refreshButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    private func render(_ snapshot: SetupDiagnosticsSnapshot) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        statusLabel.stringValue = snapshot.hasProblems
            ? "Setup diagnostics found items that may need attention."
            : "Setup diagnostics are clear."
        for item in snapshot.items {
            stackView.addArrangedSubview(row(for: item))
        }
    }

    private func row(for item: SetupDiagnosticItem) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "\(icon(for: item.severity)) \(item.title)")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.textColor = color(for: item.severity)

        let detail = NSTextField(wrappingLabelWithString: item.detail)
        detail.translatesAutoresizingMaskIntoConstraints = false

        let recovery = NSTextField(wrappingLabelWithString: item.recovery ?? "")
        recovery.translatesAutoresizingMaskIntoConstraints = false
        recovery.textColor = .secondaryLabelColor
        recovery.isHidden = item.recovery == nil

        let settingsButton: NSButton? = item.settingsURL.map { url in
            let button = NSButton(title: "Open System Settings", target: self, action: #selector(openSystemSettingsPane(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.toolTip = url.absoluteString
            return button
        }

        view.addSubview(title)
        view.addSubview(detail)
        view.addSubview(recovery)
        if let settingsButton {
            view.addSubview(settingsButton)
        }

        var constraints = [
            title.topAnchor.constraint(equalTo: view.topAnchor),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            recovery.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 4),
            recovery.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            recovery.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]

        if let settingsButton {
            constraints.append(contentsOf: [
                settingsButton.topAnchor.constraint(equalTo: recovery.bottomAnchor, constant: 8),
                settingsButton.leadingAnchor.constraint(equalTo: recovery.leadingAnchor),
                settingsButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
            constraints.append(recovery.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        }

        NSLayoutConstraint.activate(constraints)
        return view
    }

    @objc private func refreshButtonPressed() {
        refresh()
    }

    @objc private func openSystemSettingsPane(_ sender: NSButton) {
        guard let urlString = sender.toolTip, let url = URL(string: urlString) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func icon(for severity: SetupDiagnosticItem.Severity) -> String {
        switch severity {
        case .ok: return "✓"
        case .warning: return "⚠"
        case .failure: return "✕"
        }
    }

    private func color(for severity: SetupDiagnosticItem.Severity) -> NSColor {
        switch severity {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .failure: return .systemRed
        }
    }
}
