import AppKit

/// Bare-bones Markdown document reader used by Cmd-clicked `.md` file links.
///
/// This is intentionally separate from terminal Reader Mode. It opens a plain
/// document window with no toolbar/sidebar/tabs and no terminal skin surfaces so
/// Markdown stays legible even when the terminal chrome is heavily themed.
@MainActor
final class MarkdownDocumentReaderController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private static var openReaders: [URL: MarkdownDocumentReaderController] = [:]

    struct UnsupportedExtension: Equatable {
        let name: String
        let reason: String
    }

    private let fileURL: URL
    private var window: NSWindow?
    private weak var textView: NSTextView?
    private var surfacedUnsupportedExtensions = false

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        super.init()
    }

    static func openIfMarkdown(link: String) -> Bool {
        guard let fileURL = markdownFileURL(from: link) else {
            return false
        }

        let key = fileURL.standardizedFileURL
        if let existing = openReaders[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return true
        }

        let controller = MarkdownDocumentReaderController(fileURL: key)
        openReaders[key] = controller
        controller.open()
        return true
    }

    nonisolated static func markdownFileURL(from link: String, fileManager: FileManager = .default) -> URL? {
        let path: String
        if let url = URL(string: link), let scheme = url.scheme {
            guard scheme == "file" else { return nil }
            path = url.path
        } else {
            path = NSString(string: link).expandingTildeInPath
        }

        let candidate = stripLineLocationSuffix(from: path)
        guard isMarkdownPath(candidate), fileManager.fileExists(atPath: candidate) else {
            return nil
        }
        return URL(fileURLWithPath: candidate)
    }

    private nonisolated static func stripLineLocationSuffix(from path: String) -> String {
        guard let locationRange = path.range(
            of: #":[0-9]+(?::[0-9]+)?$"#,
            options: .regularExpression
        ) else {
            return path
        }
        return String(path[..<locationRange.lowerBound])
    }

    private nonisolated static func isMarkdownPath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["md", "markdown", "mdown"].contains(ext)
    }

    private func open() {
        let window = buildWindow()
        self.window = window
        reloadDocument()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 28, height: 28)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .systemFont(ofSize: 15)
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        window.contentView = scrollView
        self.textView = textView
        return window
    }

    private func reloadDocument() {
        guard let textView else { return }
        do {
            let markdown = try String(contentsOf: fileURL, encoding: .utf8)
            textView.textStorage?.setAttributedString(Self.render(markdown: markdown))
            surfaceUnsupportedExtensionsIfNeeded(Self.detectUnsupportedExtensions(in: markdown))
        } catch {
            textView.string = "Unable to open \(fileURL.path):\n\n\(error.localizedDescription)"
        }
    }

    private func surfaceUnsupportedExtensionsIfNeeded(_ extensions: [UnsupportedExtension]) {
        guard !extensions.isEmpty, !surfacedUnsupportedExtensions else { return }
        surfacedUnsupportedExtensions = true

        let alert = NSAlert()
        alert.messageText = "This Markdown file uses unsupported extensions"
        alert.informativeText = extensions
            .map { "• \($0.name): \($0.reason)" }
            .joined(separator: "\n")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Install When Available")

        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn {
                    Self.surfacePluginInstallUnavailable(for: extensions, attachedTo: window)
                }
            }
        } else if alert.runModal() == .alertSecondButtonReturn {
            Self.surfacePluginInstallUnavailable(for: extensions, attachedTo: nil)
        }
    }

    private static func surfacePluginInstallUnavailable(for extensions: [UnsupportedExtension], attachedTo window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Markdown plugins are not installed yet"
        alert.informativeText = "Holoscape detected \(extensions.map(\.name).joined(separator: ", ")), but plugin installation is not available in this build."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    nonisolated static func render(markdown: String) -> NSAttributedString {
        do {
            let attributed = try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
            return NSAttributedString(attributed)
        } catch {
            let fallback = NSMutableAttributedString(string: markdown)
            fallback.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ],
                range: NSRange(location: 0, length: fallback.length)
            )
            return fallback
        }
    }

    nonisolated static func detectUnsupportedExtensions(in markdown: String) -> [UnsupportedExtension] {
        var found: [String: UnsupportedExtension] = [:]

        for language in fencedCodeLanguages(in: markdown) {
            switch language.lowercased() {
            case "mermaid":
                found["mermaid"] = UnsupportedExtension(
                    name: "Mermaid diagrams",
                    reason: "diagram rendering requires a Markdown plugin"
                )
            case "math", "tex", "latex", "katex":
                found["math"] = UnsupportedExtension(
                    name: "Math / LaTeX",
                    reason: "math rendering requires a Markdown plugin"
                )
            default:
                continue
            }
        }

        if markdown.range(of: #"(?is)<(iframe|script|canvas|svg)\b"#, options: .regularExpression) != nil {
            found["embed"] = UnsupportedExtension(
                name: "Embedded or graphical HTML",
                reason: "interactive or graphical embeds require a Markdown plugin"
            )
        }

        return found.values.sorted { $0.name < $1.name }
    }

    private nonisolated static func fencedCodeLanguages(in markdown: String) -> [String] {
        let pattern = #"(?m)^\s*`{3,}\s*([A-Za-z0-9_+.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.matches(in: markdown, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: markdown) else {
                return nil
            }
            return String(markdown[range])
        }
    }

    func windowWillClose(_ notification: Notification) {
        MarkdownDocumentReaderController.openReaders[fileURL.standardizedFileURL] = nil
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            return openReaderLink(url.absoluteString)
        }
        if let string = link as? String {
            return openReaderLink(string)
        }
        return false
    }

    private func openReaderLink(_ link: String) -> Bool {
        if Self.openIfMarkdown(link: link) {
            return true
        }
        guard let url = URL(string: link) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
