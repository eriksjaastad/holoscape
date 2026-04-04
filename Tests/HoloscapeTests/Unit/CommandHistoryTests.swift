import XCTest
@testable import Holoscape

final class CommandHistoryTests: XCTestCase {
    func testAddAndPrevious() {
        let history = CommandHistory()
        history.add("ls")
        history.add("pwd")

        XCTAssertEqual(history.previous(), "pwd")
        XCTAssertEqual(history.previous(), "ls")
    }

    func testPreviousThenNext() {
        let history = CommandHistory()
        history.add("first")
        history.add("second")
        history.add("third")

        XCTAssertEqual(history.previous(), "third")
        XCTAssertEqual(history.previous(), "second")
        XCTAssertEqual(history.next(), "third")
    }

    func testEmptyHistory() {
        let history = CommandHistory()
        XCTAssertNil(history.previous())
        XCTAssertNil(history.next())
    }

    func testEmptyCommandNotAdded() {
        let history = CommandHistory()
        history.add("")
        XCTAssertEqual(history.count, 0)
    }

    func testMaxEntries() {
        let history = CommandHistory(maxEntries: 3)
        history.add("a")
        history.add("b")
        history.add("c")
        history.add("d")

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.previous(), "d")
        XCTAssertEqual(history.previous(), "c")
        XCTAssertEqual(history.previous(), "b")
    }

    func testReset() {
        let history = CommandHistory()
        history.add("first")
        history.add("second")
        _ = history.previous()
        history.reset()
        XCTAssertNil(history.next())
        XCTAssertEqual(history.previous(), "second")
    }
}
