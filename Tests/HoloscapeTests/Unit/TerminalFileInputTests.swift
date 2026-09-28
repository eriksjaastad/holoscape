import AppKit
import SwiftTerm
import XCTest
@testable import Holoscape

@MainActor
final class TerminalFileInputTests: XCTestCase {
    func testShellQuotedPathsProtectWhitespaceAndSingleQuotes() {
        let urls = [
            URL(fileURLWithPath: "/tmp/screenshot one.png"),
            URL(fileURLWithPath: "/tmp/Erik's image.png"),
        ]

        XCTAssertEqual(
            TerminalFileInput.shellQuotedPaths(urls),
            "'/tmp/screenshot one.png' '/tmp/Erik'\\''s image.png'"
        )
    }

    func testFileURLsUsesOnlyFileURLPasteboardEntries() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TerminalFileInputTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: "/tmp/example.png") as NSURL
        let remoteURL = NSURL(string: "https://example.com/image.png")!
        XCTAssertTrue(pasteboard.writeObjects([fileURL, remoteURL]))

        XCTAssertEqual(TerminalFileInput.fileURLs(from: pasteboard), [fileURL as URL])
    }

    func testPersistPNGCreatesUniqueFileWithOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalFileInputTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        let first = try TerminalFileInput.persistImageData(
            bytes,
            fileExtension: "png",
            in: directory
        )
        let second = try TerminalFileInput.persistImageData(
            bytes,
            fileExtension: "png",
            in: directory
        )

        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertNotEqual(first, second)
    }

    func testBitmapPasteboardPersistsImageAndReturnsQuotedPath() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TerminalFileInputTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(pasteboard.setData(bytes, forType: .png))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalFileInputTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try XCTUnwrap(
            TerminalFileInput.inputText(from: pasteboard, imageDirectory: directory)
        )
        XCTAssertTrue(input.hasPrefix("'"))
        XCTAssertTrue(input.hasSuffix(".png'"))
        let path = String(input.dropFirst().dropLast())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    func testTerminalViewInsertsDroppedFilePathAsInputWithoutNewline() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TerminalFileInputTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: "/tmp/screenshot one.png") as NSURL
        XCTAssertTrue(pasteboard.writeObjects([fileURL]))
        let terminal = CapturingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        XCTAssertTrue(terminal.insertFileInput(from: pasteboard))
        XCTAssertEqual(String(decoding: terminal.sentBytes, as: UTF8.self), "'/tmp/screenshot one.png'")
    }
}

@MainActor
private final class CapturingTerminalView: HoloscapeTerminalView {
    var sentBytes: [UInt8] = []

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sentBytes.append(contentsOf: data)
    }
}
