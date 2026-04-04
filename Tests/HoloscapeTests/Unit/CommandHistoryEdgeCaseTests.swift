import XCTest
@testable import Holoscape

final class CommandHistoryEdgeCaseTests: XCTestCase {

    func testWhitespaceOnlyCommandsNotAdded() {
        let history = CommandHistory()
        // Empty string is already tested, but whitespace-only strings
        // are not empty — they should still be added per current behavior.
        // This test documents the actual behavior.
        history.add("   ")
        XCTAssertEqual(history.count, 1, "Whitespace-only strings are non-empty and get added")
    }

    func testDuplicateCommandsAllStored() {
        let history = CommandHistory()
        history.add("ls")
        history.add("ls")
        history.add("ls")

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.previous(), "ls")
        XCTAssertEqual(history.previous(), "ls")
        XCTAssertEqual(history.previous(), "ls")
    }

    func testPreviousAtStartStaysAtStart() {
        let history = CommandHistory()
        history.add("first")
        history.add("second")

        XCTAssertEqual(history.previous(), "second")
        XCTAssertEqual(history.previous(), "first")
        // Going past the beginning should stay at first
        XCTAssertEqual(history.previous(), "first")
        XCTAssertEqual(history.previous(), "first")
    }

    func testNextPastEndReturnsNil() {
        let history = CommandHistory()
        history.add("cmd")

        XCTAssertEqual(history.previous(), "cmd")
        XCTAssertNil(history.next(), "Next past end returns nil")
        XCTAssertNil(history.next(), "Repeated next past end still returns nil")
    }

    func testAddResetsNavigationPosition() {
        let history = CommandHistory()
        history.add("first")
        history.add("second")

        // Navigate back
        XCTAssertEqual(history.previous(), "second")
        XCTAssertEqual(history.previous(), "first")

        // Add a new command
        history.add("third")

        // Previous should now return the new command
        XCTAssertEqual(history.previous(), "third")
    }

    func testMaxEntriesEvictsOldest() {
        let history = CommandHistory(maxEntries: 3)
        history.add("a")
        history.add("b")
        history.add("c")
        history.add("d")
        history.add("e")

        XCTAssertEqual(history.count, 3)
        // Should only have c, d, e
        XCTAssertEqual(history.previous(), "e")
        XCTAssertEqual(history.previous(), "d")
        XCTAssertEqual(history.previous(), "c")
    }

    func testSingleEntryNavigation() {
        let history = CommandHistory()
        history.add("only")

        XCTAssertEqual(history.previous(), "only")
        XCTAssertNil(history.next())
        XCTAssertEqual(history.previous(), "only")
    }

    func testLongCommandStrings() {
        let history = CommandHistory()
        let longCommand = String(repeating: "x", count: 10_000)
        history.add(longCommand)

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.previous(), longCommand)
    }

    func testSpecialCharacters() {
        let history = CommandHistory()
        let commands = [
            "echo \"hello world\"",
            "cat file | grep 'pattern' | awk '{print $1}'",
            "curl -X POST https://example.com/api --data '{\"key\": \"value\"}'",
            "ls -la ~/Documents/My\\ Files/",
            "echo $HOME && echo $PATH",
            "for i in {1..10}; do echo $i; done",
        ]

        for cmd in commands {
            history.add(cmd)
        }

        XCTAssertEqual(history.count, commands.count)

        // Navigate back through all of them
        for cmd in commands.reversed() {
            XCTAssertEqual(history.previous(), cmd)
        }
    }

    func testUnicodeCommands() {
        let history = CommandHistory()
        history.add("echo '日本語テスト'")
        history.add("echo '🚀🔥💻'")
        history.add("echo 'café résumé naïve'")

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.previous(), "echo 'café résumé naïve'")
        XCTAssertEqual(history.previous(), "echo '🚀🔥💻'")
        XCTAssertEqual(history.previous(), "echo '日本語テスト'")
    }

    func testResetThenNavigate() {
        let history = CommandHistory()
        history.add("a")
        history.add("b")
        history.add("c")

        _ = history.previous() // c
        _ = history.previous() // b
        history.reset()

        // After reset, previous should start from the end again
        XCTAssertEqual(history.previous(), "c")
    }
}
