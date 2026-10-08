import XCTest
@testable import Holoscape

@MainActor
final class HistoryBufferTests: XCTestCase {
    private func makePersistenceURL() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBufferTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("history-buffer.json")
    }

    private func makeBuffer() -> HistoryBuffer {
        HistoryBuffer(persistURL: makePersistenceURL(), startsPeriodicFlush: false)
    }

    func testRecordCommandAddsEntry() {
        let buffer = makeBuffer()
        buffer.recordCommand("ls -la", channelName: "Shell")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentCommands.count, 1)
        XCTAssertEqual(snap.recentCommands.first?.command, "ls -la")
        XCTAssertEqual(snap.recentCommands.first?.channelName, "Shell")
        buffer.stopPeriodicFlush()
    }

    func testCommandBufferRolls() {
        let buffer = makeBuffer()
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
        let buffer = makeBuffer()
        buffer.recordChannelSwitch(from: "Shell", to: "Agent")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentChannelSwitches.count, 1)
        XCTAssertEqual(snap.recentChannelSwitches.first?.fromChannel, "Shell")
        XCTAssertEqual(snap.recentChannelSwitches.first?.toChannel, "Agent")
        buffer.stopPeriodicFlush()
    }

    func testChannelSwitchBufferRolls() {
        let buffer = makeBuffer()
        for i in 0..<15 {
            buffer.recordChannelSwitch(from: "ch-\(i)", to: "ch-\(i+1)")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentChannelSwitches.count, 10, "Should keep only last 10 switches")
        buffer.stopPeriodicFlush()
    }

    func testRecordSettingsChangeAddsEntry() {
        let buffer = makeBuffer()
        buffer.recordSettingsChange(setting: "theme", oldValue: "Dark", newValue: "Nord")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentSettingsChanges.count, 1)
        XCTAssertEqual(snap.recentSettingsChanges.first?.setting, "theme")
        buffer.stopPeriodicFlush()
    }

    func testSettingsChangeBufferRolls() {
        let buffer = makeBuffer()
        for i in 0..<8 {
            buffer.recordSettingsChange(setting: "s-\(i)", oldValue: "old", newValue: "new")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentSettingsChanges.count, 5, "Should keep only last 5 changes")
        buffer.stopPeriodicFlush()
    }

    func testRecordErrorAddsEntry() {
        let buffer = makeBuffer()
        buffer.recordError("connection failed", context: "SSH")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentErrors.count, 1)
        XCTAssertEqual(snap.recentErrors.first?.message, "connection failed")
        XCTAssertEqual(snap.recentErrors.first?.context, "SSH")
        buffer.stopPeriodicFlush()
    }

    func testErrorBufferRolls() {
        let buffer = makeBuffer()
        for i in 0..<25 {
            buffer.recordError("err-\(i)")
        }
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.recentErrors.count, 20, "Should keep only last 20 errors")
        buffer.stopPeriodicFlush()
    }

    func testSnapshotCapturesAllCategories() {
        let buffer = makeBuffer()
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
        let buffer = makeBuffer()
        let before = Date()
        let snap = buffer.snapshot()
        let after = Date()
        XCTAssertGreaterThanOrEqual(snap.capturedAt, before)
        XCTAssertLessThanOrEqual(snap.capturedAt, after)
        buffer.stopPeriodicFlush()
    }

    func testFlushWritesToDisk() throws {
        let persistURL = makePersistenceURL()
        let buffer = HistoryBuffer(persistURL: persistURL, startsPeriodicFlush: false)
        buffer.recordCommand("flush-test", channelName: "Shell")
        guard case .success = buffer.flush() else {
            return XCTFail("Flush should report a successful write")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistURL.path), "Flush should write to disk")
        // Verify it's valid JSON
        let data = try Data(contentsOf: persistURL)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        buffer.stopPeriodicFlush()
    }

    func testFlushPreservesUnrelatedLiveHistorySentinel() throws {
        let testHistoryURL = makePersistenceURL()
        let liveHistoryURL = testHistoryURL.deletingLastPathComponent()
            .appendingPathComponent("live-history-buffer.json")
        let sentinel = Data("existing-user-history".utf8)
        try FileManager.default.createDirectory(
            at: liveHistoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sentinel.write(to: liveHistoryURL)

        let buffer = HistoryBuffer(persistURL: testHistoryURL, startsPeriodicFlush: false)
        buffer.recordCommand("isolated-test", channelName: "Shell")
        try buffer.flush().get()

        XCTAssertEqual(try Data(contentsOf: liveHistoryURL), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testHistoryURL.path))
    }

    func testFlushRetriesSameSnapshotAfterWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBufferTests-\(UUID().uuidString)", isDirectory: true)
        let blockedParent = root.appendingPathComponent("not-a-directory")
        let persistURL = blockedParent.appendingPathComponent("history-buffer.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: root) }

        let buffer = HistoryBuffer(persistURL: persistURL, startsPeriodicFlush: false)
        buffer.recordCommand("retry-test", channelName: "Shell")

        guard case .failure = buffer.flush() else {
            return XCTFail("Flush should report the blocked persistence path")
        }

        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)

        guard case .success = buffer.flush() else {
            return XCTFail("A failed flush should stay dirty and retry the same snapshot")
        }
        let loaded = try HistoryBuffer.loadPersistedSnapshot(from: persistURL).get()
        XCTAssertEqual(loaded?.recentCommands.map(\.command), ["retry-test"])
    }

    func testLoadMissingPersistedSnapshotReturnsNil() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBufferTests-\(UUID().uuidString)/history-buffer.json")

        let result = HistoryBuffer.loadPersistedSnapshot(from: missingURL)

        XCTAssertNoThrow(try result.get())
        XCTAssertNil(try result.get())
    }

    func testLoadCorruptPersistedSnapshotReturnsDecodeFailureWithPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBufferTests-\(UUID().uuidString)", isDirectory: true)
        let persistURL = root.appendingPathComponent("history-buffer.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: persistURL)
        defer { try? FileManager.default.removeItem(at: root) }

        guard case let .failure(failure) = HistoryBuffer.loadPersistedSnapshot(from: persistURL) else {
            return XCTFail("Corrupt persisted history must not become a successful empty snapshot")
        }
        XCTAssertEqual(failure.operation, .decode)
        XCTAssertEqual(failure.path, persistURL.path)
        XCTAssertFalse(failure.message.isEmpty)
    }

    func testLoadUnreadablePersistedSnapshotReturnsReadFailureWithPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBufferTests-\(UUID().uuidString)", isDirectory: true)
        let persistURL = root.appendingPathComponent("history-buffer.json", isDirectory: true)
        try FileManager.default.createDirectory(at: persistURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        guard case let .failure(failure) = HistoryBuffer.loadPersistedSnapshot(from: persistURL) else {
            return XCTFail("Unreadable persisted history must not become a successful empty snapshot")
        }
        XCTAssertEqual(failure.operation, .read)
        XCTAssertEqual(failure.path, persistURL.path)
        XCTAssertFalse(failure.message.isEmpty)
    }

    func testLoadPersistedSnapshot() throws {
        let persistURL = makePersistenceURL()
        let buffer = HistoryBuffer(persistURL: persistURL, startsPeriodicFlush: false)
        buffer.recordCommand("persist-test", channelName: "Shell")
        buffer.recordError("persist-error")
        try buffer.flush().get()

        let loaded = try HistoryBuffer.loadPersistedSnapshot(from: persistURL).get()
        XCTAssertNotNil(loaded, "Should load persisted snapshot")
        XCTAssertEqual(loaded?.recentCommands.count, 1)
        XCTAssertEqual(loaded?.recentCommands.first?.command, "persist-test")
        XCTAssertEqual(loaded?.recentErrors.count, 1)
        buffer.stopPeriodicFlush()
    }

    func testEmptyBufferSnapshot() {
        let buffer = makeBuffer()
        let snap = buffer.snapshot()
        XCTAssertTrue(snap.recentCommands.isEmpty)
        XCTAssertTrue(snap.recentChannelSwitches.isEmpty)
        XCTAssertTrue(snap.recentSettingsChanges.isEmpty)
        XCTAssertTrue(snap.recentErrors.isEmpty)
        buffer.stopPeriodicFlush()
    }
}
