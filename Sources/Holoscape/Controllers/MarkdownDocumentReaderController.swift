import AppKit

/// Bare-bones Markdown document reader used by Cmd-clicked `.md` file links.
///
/// This is intentionally separate from terminal Reader Mode. It opens a plain
/// document window with no toolbar/sidebar/tabs and no terminal skin surfaces so
/// Markdown stays legible even when the terminal chrome is heavily themed.
@MainActor
final class MarkdownDocumentReaderController: NSObject, NSWindowDelegate {
    private static var openReaders: [URL: MarkdownDocumentReaderController] = [:]

    private let fileURL: URL
    private var window: NSWindow?
    private weak var textView: NSTextView?

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
        } catch {
            textView.string = "Unable to open \(fileURL.path):\n\n\(error.localizedDescription)"
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

    func windowWillClose(_ notification: Notification) {
        MarkdownDocumentReaderController.openReaders[fileURL.standardizedFileURL] = nil
    }
}
