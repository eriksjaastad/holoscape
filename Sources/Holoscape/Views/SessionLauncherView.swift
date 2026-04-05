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

    private let comboBox = NSComboBox()
    private let refreshButton = NSButton()
    private var items: [LauncherItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor

        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = true
        comboBox.dataSource = self
        comboBox.delegate = self
        comboBox.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        comboBox.placeholderString = "Open session..."
        comboBox.setAccessibilityIdentifier("session-launcher-combo")
        comboBox.translatesAutoresizingMaskIntoConstraints = false

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
