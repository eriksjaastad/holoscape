import XCTest
import SwiftTerm
import ObjectiveC.runtime
@testable import Holoscape

final class TerminalImplicitLinkIntegrationTests: XCTestCase {
    func testHTTPURLIsDetectedForCmdClickLinkHandling() {
        let terminal = makeTerminal()
        terminal.feed(text: "open https://example.com/docs?q=1\r\n")

        XCTAssertEqual(
            terminal.link(at: .screen(Position(col: 8, row: 0)), mode: .explicitAndImplicit),
            "https://example.com/docs?q=1"
        )
    }

    func testFileURLIsDetectedForCmdClickLinkHandling() {
        let terminal = makeTerminal()
        terminal.feed(text: "open file:///tmp/holoscape-link-target.md\r\n")

        XCTAssertEqual(
            terminal.link(at: .screen(Position(col: 12, row: 0)), mode: .explicitAndImplicit),
            "file:///tmp/holoscape-link-target.md"
        )
    }

    func testAbsolutePathWithLineSuffixIsDetectedForCmdClickLinkHandling() {
        let terminal = makeTerminal()
        terminal.feed(text: "failed /tmp/holoscape-link-target.swift:42:7\r\n")

        XCTAssertEqual(
            terminal.link(at: .screen(Position(col: 10, row: 0)), mode: .explicitAndImplicit),
            "/tmp/holoscape-link-target.swift:42:7"
        )
    }

    func testTildeRelativePathIsDetectedForCmdClickLinkHandling() {
        let terminal = makeTerminal()
        terminal.feed(text: "read ~/projects/holoscape-agent/README.md\r\n")

        XCTAssertEqual(
            terminal.link(at: .screen(Position(col: 8, row: 0)), mode: .explicitAndImplicit),
            "~/projects/holoscape-agent/README.md"
        )
    }

    @MainActor
    func testMarkdownContextMenuLinkResolvesOnlyLocalMarkdownTargets() throws {
        let tempDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("holo-md-menu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let markdown = tempDir.appendingPathComponent("README.md")
        let text = tempDir.appendingPathComponent("notes.txt")
        try "# Title".write(to: markdown, atomically: true, encoding: .utf8)
        try "Plain".write(to: text, atomically: true, encoding: .utf8)

        let view = makeHoloscapeTerminalView()
        view.feed(text: "read \(markdown.path) and \(text.path)\r\n")

        XCTAssertEqual(
            view.markdownLinkForContextMenu(atBufferPosition: Position(col: 8, row: 0)),
            markdown.path
        )
        XCTAssertNil(view.markdownLinkForContextMenu(atBufferPosition: Position(col: markdown.path.count + 14, row: 0)))
    }

    @MainActor
    func testHoloscapeTerminalViewKeepsSwiftTermTextInputClientPath() {
        let view = makeHoloscapeTerminalView()
        let textInputClient: NSTextInputClient = view

        XCTAssertEqual(textInputClient.validAttributesForMarkedText(), view.validAttributesForMarkedText())
    }

    @MainActor
    func testMarkedTextCompositionRemainsHandledByInheritedSwiftTermImplementation() {
        let view = makeHoloscapeTerminalView()

        XCTAssertFalse(view.hasMarkedText())
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText())
        XCTAssertNotEqual(view.markedRange().location, NSNotFound)

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }

    @MainActor
    func testHoloscapeTerminalViewDoesNotOverrideSwiftTermIMEEntryPoints() {
        assertImplementationInherited(
            #selector(NSResponder.keyDown(with:)),
            "keyDown(with:) must keep SwiftTerm/AppKit's interpretKeyEvents path for IME composition"
        )
        assertImplementationInherited(
            #selector(NSTextInputClient.insertText(_:replacementRange:)),
            "insertText(_:replacementRange:) must keep SwiftTerm's typed-input path for committed IME text"
        )
        assertImplementationInherited(
            #selector(NSTextInputClient.setMarkedText(_:selectedRange:replacementRange:)),
            "setMarkedText must keep SwiftTerm's marked/preedit storage and overlay"
        )
        assertImplementationInherited(
            #selector(NSTextInputClient.firstRect(forCharacterRange:actualRange:)),
            "firstRect(forCharacterRange:) must keep SwiftTerm's candidate-window cursor geometry unless replaced intentionally"
        )
        assertImplementationInherited(
            #selector(NSResponder.doCommand(by:)),
            "doCommand(by:) must keep SwiftTerm's composition-aware AppKit command handling unless replaced intentionally"
        )
    }

    private func makeTerminal() -> Terminal {
        Terminal(
            delegate: LinkTestTerminalDelegate(),
            options: TerminalOptions(cols: 100, rows: 5, scrollback: 100)
        )
    }

    @MainActor
    private func makeHoloscapeTerminalView() -> HoloscapeTerminalView {
        HoloscapeTerminalView(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 100),
            options: TerminalOptions(cols: 120, rows: 5, scrollback: 100)
        )
    }

    private func assertImplementationInherited(_ selector: Selector, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let holoscapeMethod = class_getInstanceMethod(HoloscapeTerminalView.self, selector),
              let swiftTermMethod = class_getInstanceMethod(LocalProcessTerminalView.self, selector) else {
            XCTFail("Expected both HoloscapeTerminalView and LocalProcessTerminalView to respond to \(selector)", file: file, line: line)
            return
        }

        XCTAssertEqual(
            method_getImplementation(holoscapeMethod),
            method_getImplementation(swiftTermMethod),
            message,
            file: file,
            line: line
        )
    }
}

private final class LinkTestTerminalDelegate: TerminalDelegate {
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func scrolled(source: Terminal, position: Double) {}
    func clear(source: Terminal) {}
    func bell(source: Terminal) {}
    func rangeChanged(source: Terminal, startY: Int, endY: Int) {}
    func clipboardCopy(source: Terminal, content: Data) {}
    func clipboardRead(source: Terminal) -> Data? { nil }
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
}
