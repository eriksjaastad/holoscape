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
        spy.finishSubmission()

        XCTAssertEqual(spy.submissions, ["printf 'x'  \nsecond line  "])
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(spy.drafts.last, "")
    }

    func testKeypadEnterSubmitsExactText() {
        let spy = InputBoxDelegateSpy()
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.inputDelegate = spy
        view.string = "echo keypad"

        view.keyDown(with: keyEvent(keyCode: 76, characters: "\r"))
        spy.finishSubmission()

        XCTAssertEqual(spy.submissions, ["echo keypad"])
        XCTAssertEqual(view.string, "")
    }

    func testRejectedSubmissionPreservesDraft() {
        let spy = InputBoxDelegateSpy()
        spy.acceptsSubmissions = false
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.inputDelegate = spy
        view.string = "not ready"

        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))
        spy.finishSubmission()

        XCTAssertEqual(spy.submissions, ["not ready"])
        XCTAssertEqual(view.string, "not ready")
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

    func testReturnDoesNotSubmitWhileIMEHasMarkedText() {
        let spy = InputBoxDelegateSpy()
        let view = MarkedTextInputBoxView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.inputDelegate = spy
        view.reportsMarkedText = true

        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertTrue(spy.submissions.isEmpty)
    }

    func testNativeUndoRevertsComposerEdit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))

        view.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "hello")

        view.undoManager?.undo()

        XCTAssertEqual(view.string, "")
    }

    func testProgrammaticDraftReplacementClearsPriorUndoActions() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = InputBoxView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.insertText("alpha", replacementRange: NSRange(location: 0, length: 0))

        view.replaceComposerText("beta")
        view.undoManager?.undo()

        XCTAssertEqual(view.string, "beta")
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
    var acceptsSubmissions = true
    var drafts: [String] = []
    var previousRequests = 0
    var nextRequests = 0
    private var pendingCompletion: (@MainActor (Bool) -> Void)?

    func inputBoxView(
        _ inputBox: InputBoxView,
        didSubmitText text: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        submissions.append(text)
        pendingCompletion = completion
    }

    func finishSubmission() {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(acceptsSubmissions)
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

@MainActor
private final class MarkedTextInputBoxView: InputBoxView {
    var reportsMarkedText = false
    override var hasActiveMarkedText: Bool { reportsMarkedText }
}
