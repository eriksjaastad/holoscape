import XCTest
@testable import Holoscape

@MainActor
final class ComposerChannelStateTests: XCTestCase {
    func testStateIsolatedByStableChannelID() {
        let store = ComposerChannelStateStore()
        let first = UUID()
        let second = UUID()

        store.updateDraft("first draft", for: first)
        store.updateManualMode(.rawTerminal, for: first)
        store.updateDraft("second draft", for: second)

        XCTAssertEqual(
            store.state(for: first),
            ComposerChannelState(draft: "first draft", manualMode: .rawTerminal)
        )
        XCTAssertEqual(store.state(for: second), ComposerChannelState(draft: "second draft"))
    }

    func testAutomaticAlternateScreenUsesRawUntilItExits() {
        let store = ComposerChannelStateStore()
        let id = UUID()

        XCTAssertEqual(store.state(for: id).effectiveMode, .composer)
        store.updateAlternateScreenActive(true, for: id)
        XCTAssertEqual(store.state(for: id).effectiveMode, .rawTerminal)
        store.updateAlternateScreenActive(false, for: id)
        XCTAssertEqual(store.state(for: id).effectiveMode, .composer)
    }

    func testManualModeDominatesAlternateScreenEvidence() {
        let store = ComposerChannelStateStore()
        let id = UUID()

        store.updateAlternateScreenActive(true, for: id)
        store.updateManualMode(.composer, for: id)
        XCTAssertEqual(store.state(for: id).effectiveMode, .composer)

        store.updateAlternateScreenActive(false, for: id)
        store.updateManualMode(.rawTerminal, for: id)
        XCTAssertEqual(store.state(for: id).effectiveMode, .rawTerminal)
    }

    func testRemovingStateDoesNotAffectOtherChannels() {
        let store = ComposerChannelStateStore()
        let first = UUID()
        let second = UUID()
        store.updateDraft("draft", for: first)
        store.updateDraft("other", for: second)

        store.removeState(for: first)

        XCTAssertEqual(store.state(for: first), ComposerChannelState())
        XCTAssertEqual(store.state(for: second).draft, "other")
    }
}

@MainActor
final class TerminalComposerModeSignalTests: XCTestCase {
    func testAlternateScreenProtocolTransitionsAreReported() {
        let view = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var reported: [Bool] = []
        view.onAlternateScreenChanged = { reported.append($0) }

        view.feed(text: "\u{1B}[?1049hfull screen")
        XCTAssertTrue(waitUntil { reported.last == true })
        XCTAssertTrue(view.isAlternateScreenActive)
        XCTAssertEqual(reported.last, true)

        view.feed(text: "\u{1B}[?1049l")
        XCTAssertTrue(waitUntil { reported.last == false })
        XCTAssertFalse(view.isAlternateScreenActive)
        XCTAssertEqual(reported.last, false)
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
