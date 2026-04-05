import XCTest
@testable import Holoscape

@MainActor
final class HistoryBufferTests: XCTestCase {

    func testRecordCommandAddsEntry() {
        let buffer = HistoryBuffer()
        buffer.recordCommand("ls -la", channelName: "Shell")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentCommands.count, 1)
        XCTAssertEqual(snap.recentCommands.first?.command, "ls -la")
        XCTAssertEqual(snap.recentCommands.first?.channelName, "Shell")
        buffer.stopPeriodicFlush()
    }

    func testCommandBufferRolls() {
        let buffer = HistoryBuffer()
        for i in 0..<25 {
            buffer.recordCommand("cmd-\(i)", channelName: "Shell")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentCommands.count, 20, "Should keep only last 20 commands")
        XCTAssertEqual(snap.recentCommands.first?.command, "cmd-5", "First should be cmd-5 after rolling")
        XCTAssertEqual(snap.recentCommands.last?.command, "cmd-24")
        buffer.stopPeriodicFlush()
    }

    func testRecordChannelSwitchAddsEntry() {
        let buffer = HistoryBuffer()
        buffer.recordChannelSwitch(from: "Shell", to: "Agent")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentChannelSwitches.count, 1)
        XCTAssertEqual(snap.recentChannelSwitches.first?.fromChannel, "Shell")
        XCTAssertEqual(snap.recentChannelSwitches.first?.toChannel, "Agent")
        buffer.stopPeriodicFlush()
    }

    func testChannelSwitchBufferRolls() {
        let buffer = HistoryBuffer()
        for i in 0..<15 {
            buffer.recordChannelSwitch(from: "ch-\(i)", to: "ch-\(i+1)")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentChannelSwitches.count, 10, "Should keep only last 10 switches")
        buffer.stopPeriodicFlush()
    }

    func testRecordSettingsChangeAddsEntry() {
        let buffer = HistoryBuffer()
        buffer.recordSettingsChange(setting: "theme", oldValue: "Dark", newValue: "Nord")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentSettingsChanges.count, 1)
        XCTAssertEqual(snap.recentSettingsChanges.first?.setting, "theme")
        buffer.stopPeriodicFlush()
    }

    func testSettingsChangeBufferRolls() {
        let buffer = HistoryBuffer()
        for i in 0..<8 {
            buffer.recordSettingsChange(setting: "s-\(i)", oldValue: "old", newValue: "new")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentSettingsChanges.count, 5, "Should keep only last 5 changes")
        buffer.stopPeriodicFlush()
    }

    func testRecordErrorAddsEntry() {
        let buffer = HistoryBuffer()
        buffer.recordError("connection failed", context: "SSH")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentErrors.count, 1)
        XCTAssertEqual(snap.recentErrors.first?.message, "connection failed")
        XCTAssertEqual(snap.recentErrors.first?.context, "SSH")
        buffer.stopPeriodicFlush()
    }

    func testErrorBufferRolls() {
        let buffer = HistoryBuffer()
        for i in 0..<25 {
            buffer.recordError("err-\(i)")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentErrors.count, 20, "Should keep only last 20 errors")
        buffer.stopPeriodicFlush()
    }

    func testSnapshotCapturesAllCategories() {
        let buffer = HistoryBuffer()
        buffer.recordCommand("test", channelName: "Shell")
        buffer.recordChannelSwitch(from: nil, to: "Shell")
        buffer.recordSettingsChange(setting: "theme", oldValue: "Dark", newValue: "Nord")
        buffer.recordError("test error")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentCommands.count, 1)
        XCTAssertEqual(snap.recentChannelSwitches.count, 1)
        XCTAssertEqual(snap.recentSettingsChanges.count, 1)
        XCTAssertEqual(snap.recentErrors.count, 1)
        buffer.stopPeriodicFlush()
    }

    func testSnapshotTimestamp() {
        let buffer = HistoryBuffer()
        let before = Date()
        let snap = buffer.snapshot()
        let after = Date()
        XCTAssertGreaterThanOrEqual(snap.capturedAt, before)
        XCTAssertLessThanOrEqual(snap.capturedAt, after)
        buffer.stopPeriodicFlush()
    }

    func testFlushWritesToDisk() {
        let buffer = HistoryBuffer()
        buffer.recordCommand("flush-test", channelName: "Shell")
        buffer.flush()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".holoscape/history-buffer.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Flush should write to disk")
        // Verify it's valid JSON
        let data = try! Data(contentsOf: url)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        buffer.stopPeriodicFlush()
    }

    func testLoadPersistedSnapshot() {
        let buffer = HistoryBuffer()
        buffer.recordCommand("persist-test", channelName: "Shell")
        buffer.recordError("persist-error")
        buffer.flush()

        let loaded = HistoryBuffer.loadPersistedSnapshot()
        XCTAssertNotNil(loaded, "Should load persisted snapshot")
        XCTAssertEqual(loaded?.recentCommands.count, 1)
        XCTAssertEqual(loaded?.recentCommands.first?.command, "persist-test")
        XCTAssertEqual(loaded?.recentErrors.count, 1)
        buffer.stopPeriodicFlush()
    }

    func testEmptyBufferSnapshot() {
        let buffer = HistoryBuffer()
        let snap = buffer.snapshot()
        XCTAssertTrue(snap.recentCommands.isEmpty)
        XCTAssertTrue(snap.recentChannelSwitches.isEmpty)
        XCTAssertTrue(snap.recentSettingsChanges.isEmpty)
        XCTAssertTrue(snap.recentErrors.isEmpty)
        buffer.stopPeriodicFlush()
    }
}
