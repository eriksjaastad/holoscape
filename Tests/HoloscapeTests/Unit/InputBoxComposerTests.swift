import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class InputBoxComposerTests: XCTestCase {
    func testEnterSubmitsExactTextAndClearsDraft() {
        let spy = InputBoxDelegateSpy()
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.inputDelegate = spy
        view.string = "printf 'x'  \nsecond line  "

        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertEqual(spy.submissions, ["printf 'x'  \nsecond line  "])
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(spy.drafts.last, "")
    }

    func testEnterRejectsWhitespaceOnlyDraft() {
        let spy = InputBoxDelegateSpy()
        let view = InputBoxView(frame: .zero)
        view.inputDelegate = spy
        view.string = "  \n\t"

        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertTrue(spy.submissions.isEmpty)
        XCTAssertEqual(view.string, "  \n\t")
    }

    func testHistoryOnlyInterceptsAtDocumentEdgesAndRestoresDraft() {
        let spy = InputBoxDelegateSpy()
        let view = InputBoxView(frame: .zero)
        view.inputDelegate = spy
        view.string = "first\nsecond"
        view.setSelectedRange(NSRange(location: 3, length: 0))

        view.keyDown(with: keyEvent(keyCode: 126))
        XCTAssertEqual(spy.previousRequests, 0)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.keyDown(with: keyEvent(keyCode: 126))
        XCTAssertEqual(spy.previousRequests, 1)

        view.setHistoryText("older")
        view.restoreDraftAfterHistory()
        XCTAssertEqual(view.string, "first\nsecond")
    }

    func testFilePasteInsertsQuotedPathIntoDraftWithoutSubmitting() throws {
        let spy = InputBoxDelegateSpy()
        let view = InputBoxView(frame: .zero)
        view.inputDelegate = spy
        view.string = "open "
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("composer file.txt")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        XCTAssertTrue(view.insertFileInput(from: pasteboard))

        XCTAssertEqual(view.string, "open '\(url.path)'")
        XCTAssertTrue(spy.submissions.isEmpty)
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

@MainActor
private final class InputBoxDelegateSpy: InputBoxViewDelegate {
    var submissions: [String] = []
    var drafts: [String] = []
    var previousRequests = 0
    var nextRequests = 0

    func inputBoxView(_ inputBox: InputBoxView, didSubmitText text: String) {
        submissions.append(text)
    }

    func inputBoxViewDidRequestPreviousHistory(_ inputBox: InputBoxView) {
        previousRequests += 1
    }

    func inputBoxViewDidRequestNextHistory(_ inputBox: InputBoxView) {
        nextRequests += 1
    }

    func inputBoxView(_ inputBox: InputBoxView, didChangeDraft text: String) {
        drafts.append(text)
    }
}
