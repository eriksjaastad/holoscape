import AppKit
import Darwin

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
    private var fileWatcher: DispatchSourceFileSystemObject?
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
        startWatchingFile()
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
            textView.textStorage?.setAttributedString(Self.render(markdown: markdown, baseURL: fileURL.deletingLastPathComponent()))
            surfaceUnsupportedExtensionsIfNeeded(Self.detectUnsupportedExtensions(in: markdown))
        } catch {
            textView.string = "Unable to open \(fileURL.path):\n\n\(error.localizedDescription)"
        }
    }

    private func startWatchingFile() {
        stopWatchingFile()

        let descriptor = Darwin.open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadDocument()
            let event = source.data
            if event.contains(.rename) || event.contains(.delete) {
                self.stopWatchingFile()
            }
        }
        source.setCancelHandler { [descriptor] in
            Darwin.close(descriptor)
        }
        fileWatcher = source
        source.resume()
    }

    private func stopWatchingFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
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
        render(markdown: markdown, baseURL: nil)
    }

    nonisolated static func render(markdown: String, baseURL: URL?) -> NSAttributedString {
        if let richBlocks = renderWithReaderBlocks(markdown: markdown, baseURL: baseURL) {
            return richBlocks
        }

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

    private nonisolated static func renderWithReaderBlocks(markdown: String, baseURL: URL?) -> NSAttributedString? {
        let lines = markdown.components(separatedBy: .newlines)
        let output = NSMutableAttributedString()
        var markdownBuffer: [String] = []
        var usedReaderBlock = false

        func flushMarkdownBuffer() {
            guard !markdownBuffer.isEmpty else { return }
            output.append(renderMarkdownOnly(markdownBuffer.joined(separator: "\n")))
            output.append(NSAttributedString(string: "\n"))
            markdownBuffer.removeAll()
        }

        var index = 0
        while index < lines.count {
            if let image = imageBlock(from: lines[index], baseURL: baseURL) {
                flushMarkdownBuffer()
                output.append(image)
                output.append(NSAttributedString(string: "\n"))
                usedReaderBlock = true
                index += 1
                continue
            }

            if index + 1 < lines.count,
               isTableRow(lines[index]),
               isTableSeparator(lines[index + 1]) {
                flushMarkdownBuffer()
                var tableLines = [lines[index]]
                index += 2
                while index < lines.count, isTableRow(lines[index]) {
                    tableLines.append(lines[index])
                    index += 1
                }
                output.append(tableBlock(from: tableLines))
                output.append(NSAttributedString(string: "\n"))
                usedReaderBlock = true
                continue
            }

            markdownBuffer.append(lines[index])
            index += 1
        }
        flushMarkdownBuffer()

        return usedReaderBlock ? output : nil
    }

    private nonisolated static func renderMarkdownOnly(_ markdown: String) -> NSAttributedString {
        do {
            let attributed = try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
            return NSAttributedString(attributed)
        } catch {
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ]
            )
        }
    }

    private nonisolated static func imageBlock(from line: String, baseURL: URL?) -> NSAttributedString? {
        let pattern = #"^\s*!\[([^\]]*)\]\(([^)]+)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let altRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let alt = String(line[altRange])
        let rawPath = String(line[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let imageURL: URL
        if let url = URL(string: rawPath), url.scheme != nil {
            guard url.isFileURL else { return nil }
            imageURL = url
        } else if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
            imageURL = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath)
        } else if let baseURL {
            imageURL = baseURL.appendingPathComponent(rawPath)
        } else {
            return nil
        }

        let result = NSMutableAttributedString()
        if let image = NSImage(contentsOf: imageURL) {
            let attachment = NSTextAttachment()
            attachment.image = scaledImage(image, maximumWidth: 720)
            result.append(NSAttributedString(attachment: attachment))
        } else {
            result.append(NSAttributedString(string: "[Missing image: \(rawPath)]"))
        }
        if !alt.isEmpty {
            result.append(NSAttributedString(
                string: "\n\(alt)",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return result
    }

    private nonisolated static func scaledImage(_ image: NSImage, maximumWidth: CGFloat) -> NSImage {
        guard image.size.width > maximumWidth, image.size.width > 0 else { return image }
        let scale = maximumWidth / image.size.width
        let copy = NSImage(size: NSSize(width: maximumWidth, height: image.size.height * scale))
        copy.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: copy.size))
        copy.unlockFocus()
        return copy
    }

    private nonisolated static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.split(separator: "|", omittingEmptySubsequences: false).count >= 3
    }

    private nonisolated static func isTableSeparator(_ line: String) -> Bool {
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private nonisolated static func tableBlock(from lines: [String]) -> NSAttributedString {
        let rows = lines.map { line in
            line.split(separator: "|", omittingEmptySubsequences: false)
                .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .reversed()
                .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .reversed()
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let columnCount = rows.map(\.count).max() ?? 0
        let widths = (0..<columnCount).map { column in
            rows.map { row in column < row.count ? row[column].count : 0 }.max() ?? 0
        }
        let renderedRows = rows.map { row in
            (0..<columnCount).map { column -> String in
                let value = column < row.count ? row[column] : ""
                return value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
        return NSAttributedString(
            string: renderedRows,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor]
        )
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
        stopWatchingFile()
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
