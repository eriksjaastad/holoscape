import AppKit

/// Read-only maintenance window that lists persisted per-session scrollback
/// tails and lets the user remove them individually or in bulk.
///
/// Backed exclusively by the public `DiskBackedScrollbackStore` API. Removing a
/// tail only deletes the persisted `.scrollback` file; it never reaches into
/// broker internals or touches a live running session. This surface is
/// plugin-free and performs no network access.
@MainActor
final class ScrollbackMaintenanceWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let store: DiskBackedScrollbackStore
    private var tails: [DiskBackedScrollbackStore.StoredScrollbackTail] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "No stored scrollback")
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let removeAllButton = NSButton(title: "Remove All…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    init(
        store: DiskBackedScrollbackStore = DiskBackedScrollbackStore(
            directory: ScrollbackPersistencePolicy.defaultDiskDirectory
        )
    ) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scrollback Storage"

        super.init(window: window)
        setupUI()
        refreshListing()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let header = NSTextField(wrappingLabelWithString:
            "Persisted scrollback tails hold saved terminal output for reattached sessions. Removing a tail only deletes the saved file; live sessions are unaffected.")
        header.font = NSFont.systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor

        let sessionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        sessionColumn.title = "Session ID"
        sessionColumn.width = 300
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 100
        let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modifiedColumn.title = "Last Modified"
        modifiedColumn.width = 140

        tableView.addTableColumn(sessionColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(modifiedColumn)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityIdentifier("scrollback-tails-table")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.setAccessibilityIdentifier("scrollback-remove-button")

        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll(_:))
        removeAllButton.setAccessibilityIdentifier("scrollback-remove-all-button")

        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(removeButton)
        buttonRow.addArrangedSubview(removeAllButton)
        buttonRow.addArrangedSubview(refreshButton)

        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13)

        for view in [header, scrollView, buttonRow, emptyStateLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            emptyStateLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    // MARK: - Listing

    /// Reloads the persisted-tail listing from disk so the UI reflects reality.
    /// Called on open and after any removal.
    func refreshListing() {
        do {
            tails = try store.listStoredTails()
        } catch {
            tails = []
            presentMessage(
                "Could Not List Scrollback",
                message: "Holoscape could not read the stored scrollback directory: \(error)"
            )
        }
        tableView.reloadData()
        scrollView.isHidden = tails.isEmpty
        emptyStateLabel.isHidden = !tails.isEmpty
        updateButtonState()
    }

    private func updateButtonState() {
        let selected = tableView.selectedRow
        removeButton.isEnabled = selected >= 0 && selected < tails.count
        removeAllButton.isEnabled = !tails.isEmpty
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        tails.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < tails.count, let tableColumn else { return nil }
        let tail = tails[row]

        let text: String
        switch tableColumn.identifier.rawValue {
        case "session":
            text = tail.sessionID.rawValue
        case "size":
            text = ScrollbackMaintenanceFormatting.byteSize(tail.byteCount)
        case "modified":
            text = ScrollbackMaintenanceFormatting.modifiedAt(tail.modifiedAt)
        default:
            text = ""
        }

        let identifier = tableColumn.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    // MARK: - Actions

    @objc private func removeSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < tails.count else { return }
        let tail = tails[row]
        let size = ScrollbackMaintenanceFormatting.byteSize(tail.byteCount)

        confirmRemoval(
            title: "Remove Persisted Scrollback?",
            message: "Delete the persisted scrollback tail for session “\(tail.sessionID.rawValue)” (\(size))? This only removes the saved file and does not affect any live session.",
            confirmTitle: "Remove"
        ) { [weak self] in
            guard let self else { return }
            do {
                try self.store.remove(for: tail.sessionID)
            } catch {
                self.refreshListing()
                self.presentMessage(
                    "Could Not Remove Scrollback",
                    message: "Holoscape could not remove scrollback for session \(tail.sessionID.rawValue): \(error)"
                )
                return
            }
            self.refreshListing()
        }
    }

    @objc private func removeAll(_ sender: Any?) {
        guard !tails.isEmpty else { return }
        let count = tails.count
        let totalBytes = tails.reduce(0) { $0 + $1.byteCount }
        let size = ScrollbackMaintenanceFormatting.byteSize(totalBytes)

        confirmRemoval(
            title: "Remove All Persisted Scrollback?",
            message: "Delete all \(count) persisted scrollback tails (\(size) total)? This only removes saved files and does not affect any live session.",
            confirmTitle: "Remove All"
        ) { [weak self] in
            guard let self else { return }
            do {
                for tail in self.tails {
                    try self.store.remove(for: tail.sessionID)
                }
            } catch {
                self.refreshListing()
                self.presentMessage(
                    "Could Not Remove All Scrollback",
                    message: "Holoscape removed some tails before failing: \(error)"
                )
                return
            }
            self.refreshListing()
        }
    }

    @objc private func refresh(_ sender: Any?) {
        refreshListing()
    }

    // MARK: - Alerts

    private func confirmRemoval(
        title: String,
        message: String,
        confirmTitle: String,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    completion()
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                completion()
            }
        }
    }

    private func presentMessage(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
