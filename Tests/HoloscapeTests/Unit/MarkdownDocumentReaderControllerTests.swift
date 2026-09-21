import XCTest
@testable import Holoscape

final class MarkdownDocumentReaderControllerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoloscapeMarkdownReaderTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testMarkdownFileURLAcceptsAbsoluteMarkdownPath() throws {
        let url = try writeMarkdown(named: "README.md")

        XCTAssertEqual(
            MarkdownDocumentReaderController.markdownFileURL(from: url.path)?.standardizedFileURL,
            url.standardizedFileURL
        )
    }

    func testMarkdownFileURLAcceptsFileURL() throws {
        let url = try writeMarkdown(named: "notes.markdown")

        XCTAssertEqual(
            MarkdownDocumentReaderController.markdownFileURL(from: url.absoluteString)?.standardizedFileURL,
            url.standardizedFileURL
        )
    }

    func testMarkdownFileURLStripsLineAndColumnSuffix() throws {
        let url = try writeMarkdown(named: "guide.md")

        XCTAssertEqual(
            MarkdownDocumentReaderController.markdownFileURL(from: "\(url.path):42:7")?.standardizedFileURL,
            url.standardizedFileURL
        )
    }

    func testMarkdownFileURLRejectsHTTPMarkdownURL() {
        XCTAssertNil(MarkdownDocumentReaderController.markdownFileURL(from: "https://example.com/README.md"))
    }

    func testMarkdownFileURLRejectsMissingMarkdownPath() {
        XCTAssertNil(MarkdownDocumentReaderController.markdownFileURL(from: tempDir.appendingPathComponent("missing.md").path))
    }

    func testMarkdownFileURLRejectsNonMarkdownPath() throws {
        let url = tempDir.appendingPathComponent("notes.txt")
        try "# Not markdown".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(MarkdownDocumentReaderController.markdownFileURL(from: url.path))
    }

    func testRenderMarkdownProducesAttributedContent() {
        let rendered = MarkdownDocumentReaderController.render(markdown: "# Heading\n\n- One\n- Two")

        XCTAssertGreaterThan(rendered.length, 0)
        XCTAssertTrue(rendered.string.contains("Heading"))
        XCTAssertTrue(rendered.string.contains("One"))
    }

    func testRenderMarkdownPreservesClickableLinks() {
        let rendered = MarkdownDocumentReaderController.render(markdown: "[Guide](https://example.com/guide)")
        var foundLink = false

        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, stop in
            if let url = value as? URL, url.absoluteString == "https://example.com/guide" {
                foundLink = true
                stop.pointee = true
            }
        }

        XCTAssertTrue(foundLink)
    }

    func testRenderMarkdownEmbedsLocalImages() throws {
        let imageURL = tempDir.appendingPathComponent("pixel.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let png = bitmap?.representation(using: .png, properties: [:]) else {
            XCTFail("test image should have PNG data")
            return
        }
        try png.write(to: imageURL)

        let rendered = MarkdownDocumentReaderController.render(
            markdown: "# Screenshot\n\n![Tiny](pixel.png)",
            baseURL: tempDir
        )

        XCTAssertTrue(rendered.string.contains("Screenshot"))
        XCTAssertTrue(rendered.string.contains("Tiny"))
        XCTAssertTrue(containsAttachment(in: rendered), "local markdown image should render as an attachment")
    }

    func testRenderMarkdownFormatsPipeTables() {
        let rendered = MarkdownDocumentReaderController.render(
            markdown: """
            | Command | Status |
            | --- | --- |
            | build | green |
            | test | green |
            """
        )

        XCTAssertTrue(rendered.string.contains("Command"))
        XCTAssertTrue(rendered.string.contains("build"))
        XCTAssertTrue(rendered.string.contains("Status"))
        XCTAssertFalse(rendered.string.contains("---"), "table separator rows should not be shown as content")
    }

    func testDetectUnsupportedExtensionsFindsMermaidMathAndGraphicalHTML() {
        let markdown = """
        # Diagram

        ```mermaid
        graph TD;
        ```

        ```latex
        E = mc^2
        ```

        <iframe src=\"https://example.com\"></iframe>
        """

        let detected = MarkdownDocumentReaderController.detectUnsupportedExtensions(in: markdown)
            .map(\.name)

        XCTAssertEqual(detected, ["Embedded or graphical HTML", "Math / LaTeX", "Mermaid diagrams"])
    }

    func testDetectUnsupportedExtensionsIgnoresStandardCodeBlocks() {
        let markdown = """
        ```swift
        print(\"hello\")
        ```
        """

        XCTAssertTrue(MarkdownDocumentReaderController.detectUnsupportedExtensions(in: markdown).isEmpty)
    }

    private func writeMarkdown(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try "# Title\n\nBody".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func containsAttachment(in attributedString: NSAttributedString) -> Bool {
        var found = false
        attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedString.length)) { value, _, stop in
            if value is NSTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
