import XCTest
import SwiftTerm

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

    private func makeTerminal() -> Terminal {
        Terminal(
            delegate: LinkTestTerminalDelegate(),
            options: TerminalOptions(cols: 100, rows: 5, scrollback: 100)
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
