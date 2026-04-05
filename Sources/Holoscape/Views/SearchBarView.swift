import AppKit

@MainActor
protocol SearchBarDelegate: AnyObject {
    func searchBar(_ searchBar: SearchBarView, didChangeQuery query: String)
    func searchBarDidRequestNext(_ searchBar: SearchBarView)
    func searchBarDidRequestPrevious(_ searchBar: SearchBarView)
    func searchBarDidClose(_ searchBar: SearchBarView)
}

@MainActor
class SearchBarView: NSView, NSTextFieldDelegate {
    weak var searchDelegate: SearchBarDelegate?

    private let searchField = NSTextField()
    private let matchCountLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var matchCount: Int = 0
    private var currentMatch: Int = 0

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
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0).cgColor

        searchField.placeholderString = "Search..."
        searchField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        matchCountLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        matchCountLabel.textColor = NSColor.gray
        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false

        prevButton.bezelStyle = .recessed
        prevButton.isBordered = false
        prevButton.title = "\u{25B2}"  // ▲
        prevButton.target = self
        prevButton.action = #selector(prevClicked)
        prevButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.bezelStyle = .recessed
        nextButton.isBordered = false
        nextButton.title = "\u{25BC}"  // ▼
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.title = "\u{2715}"  // ✕
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(matchCountLabel)
        addSubview(prevButton)
        addSubview(nextButton)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            matchCountLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            matchCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            prevButton.leadingAnchor.constraint(equalTo: matchCountLabel.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityTitle("Search Bar")
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    func clear() {
        searchField.stringValue = ""
        matchCount = 0
        currentMatch = 0
        updateMatchLabel()
    }

    func updateMatchInfo(total: Int, current: Int) {
        matchCount = total
        currentMatch = current
        updateMatchLabel()
    }

    private func updateMatchLabel() {
        if matchCount == 0 && !searchField.stringValue.isEmpty {
            matchCountLabel.stringValue = "No matches"
        } else if matchCount > 0 {
            matchCountLabel.stringValue = "\(currentMatch) of \(matchCount)"
        } else {
            matchCountLabel.stringValue = ""
        }
    }

    // MARK: - NSTextFieldDelegate

    nonisolated func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated {
            searchDelegate?.searchBar(self, didChangeQuery: searchField.stringValue)
        }
    }

    nonisolated func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        return MainActor.assumeIsolated {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                searchDelegate?.searchBarDidRequestNext(self)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                searchDelegate?.searchBarDidClose(self)
                return true
            }
            return false
        }
    }

    @objc private func prevClicked() {
        searchDelegate?.searchBarDidRequestPrevious(self)
    }

    @objc private func nextClicked() {
        searchDelegate?.searchBarDidRequestNext(self)
    }

    @objc private func closeClicked() {
        searchDelegate?.searchBarDidClose(self)
    }
}
