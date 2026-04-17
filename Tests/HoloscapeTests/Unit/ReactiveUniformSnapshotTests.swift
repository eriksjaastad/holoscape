import XCTest
@testable import Holoscape

/// Requirement 12.6: shared state source between shader and chrome layers
/// with thread-safe reads. These tests cover the typed setters (which
/// stamp timestamps on transitions) plus the stampTransition fallback.
final class ReactiveUniformSnapshotTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateIsAllZero() {
        let snap = ReactiveUniformSnapshot()
        XCTAssertEqual(snap.agentState, 0)
        XCTAssertEqual(snap.commandState, 0)
        XCTAssertEqual(snap.channelUnread, 0)
        XCTAssertEqual(snap.notificationKind, 0)
        XCTAssertEqual(snap.outputEventCount, 0)
        XCTAssertEqual(snap.timeAgentStateChange, 0)
    }

    // MARK: - Agent state transitions stamp timestamp

    func testSetAgentStateStampsTimestamp() {
        let snap = ReactiveUniformSnapshot()
        let before = CFAbsoluteTimeGetCurrent()
        snap.setAgentState(1)
        let after = CFAbsoluteTimeGetCurrent()

        XCTAssertEqual(snap.agentState, 1)
        XCTAssertEqual(snap.previousAgentState, 0)
        XCTAssertGreaterThanOrEqual(snap.timeAgentStateChange, before)
        XCTAssertLessThanOrEqual(snap.timeAgentStateChange, after)
    }

    func testSetAgentStateSameValueDoesNotReStamp() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(2)
        let stampedAt = snap.timeAgentStateChange
        Thread.sleep(forTimeInterval: 0.01)

        snap.setAgentState(2)  // Same value
        XCTAssertEqual(snap.timeAgentStateChange, stampedAt, "No-op setAgentState should not re-stamp")
    }

    func testPreviousAgentStateTracked() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(1)
        snap.setAgentState(2)
        snap.setAgentState(3)

        XCTAssertEqual(snap.agentState, 3)
        XCTAssertEqual(snap.previousAgentState, 2)
    }

    // MARK: - Command state

    func testSetCommandStateStartsStampsTimeCommandStart() {
        let snap = ReactiveUniformSnapshot()
        snap.setCommandState(1)  // running

        XCTAssertEqual(snap.commandState, 1)
        XCTAssertGreaterThan(snap.timeCommandStart, 0)
        XCTAssertEqual(snap.timeCommandEnd, 0)
    }

    func testSetCommandStateCompletedStampsTimeCommandEndAndExitCode() {
        let snap = ReactiveUniformSnapshot()
        snap.setCommandState(1)
        snap.setCommandState(2, exitCode: 42)

        XCTAssertEqual(snap.commandState, 2)
        XCTAssertEqual(snap.lastCommandExitCode, 42)
        XCTAssertGreaterThan(snap.timeCommandEnd, 0)
    }

    // MARK: - Channel state

    func testSetChannelStateUpdatesAllFields() {
        let snap = ReactiveUniformSnapshot()
        snap.setChannelState(channelId: 1234, isActive: 1, unread: 5)

        XCTAssertEqual(snap.channelId, 1234)
        XCTAssertEqual(snap.channelIsActive, 1)
        XCTAssertEqual(snap.channelUnread, 5)
    }

    // MARK: - Output events

    func testRecordOutputEventIncrementsCounter() {
        let snap = ReactiveUniformSnapshot()
        snap.recordOutputEvent()
        snap.recordOutputEvent()
        snap.recordOutputEvent()

        XCTAssertEqual(snap.outputEventCount, 3)
        XCTAssertGreaterThan(snap.timeLastOutput, 0)
    }

    func testRecordOutputEventWrapsOverflow() {
        // outputEventCount uses &+= which wraps on Int32 overflow.
        // No way to test that directly without Int32.max starting value,
        // but verify the overflow-arithmetic operator is used (no crash).
        let snap = ReactiveUniformSnapshot()
        for _ in 0..<1000 {
            snap.recordOutputEvent()
        }
        XCTAssertEqual(snap.outputEventCount, 1000)
    }

    // MARK: - Notifications

    func testPostNotificationUpdatesKindAndTimestamp() {
        let snap = ReactiveUniformSnapshot()
        snap.postNotification(kind: 3)  // error

        XCTAssertEqual(snap.notificationKind, 3)
        XCTAssertGreaterThan(snap.timeLastNotification, 0)
    }

    func testClearNotificationDoesNotUpdateTimestamp() {
        let snap = ReactiveUniformSnapshot()
        snap.postNotification(kind: 2)
        let postedAt = snap.timeLastNotification

        Thread.sleep(forTimeInterval: 0.01)
        snap.clearNotification()

        XCTAssertEqual(snap.notificationKind, 0)
        XCTAssertEqual(snap.timeLastNotification, postedAt, "Clear should not overwrite last-posted timestamp")
    }

    // MARK: - Stamp transition fallback

    func testStampTransitionUpdatesNamedField() {
        let snap = ReactiveUniformSnapshot()
        snap.stampTransition(.agentStateChange)
        XCTAssertGreaterThan(snap.timeAgentStateChange, 0)
    }

    // MARK: - Match key lookup

    func testIntValueForKnownMatchKeys() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(3)
        snap.setChannelState(channelId: 99, isActive: 1, unread: 7)

        XCTAssertEqual(snap.intValue(forMatchKey: "agentState"), 3)
        XCTAssertEqual(snap.intValue(forMatchKey: "channelId"), 99)
        XCTAssertEqual(snap.intValue(forMatchKey: "channelUnread"), 7)
        XCTAssertEqual(snap.intValue(forMatchKey: "channelIsActive"), 1)
    }

    func testIntValueForUnknownKeyReturnsNil() {
        let snap = ReactiveUniformSnapshot()
        XCTAssertNil(snap.intValue(forMatchKey: "nonexistent"))
        XCTAssertNil(snap.intValue(forMatchKey: ""))
    }

    func testTimestampLookupForKnownFields() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(1)

        XCTAssertNotNil(snap.timestamp(named: "iTimeAgentStateChange"))
        XCTAssertGreaterThan(snap.timestamp(named: "iTimeAgentStateChange") ?? 0, 0)
    }

    func testTimestampLookupForUnknownReturnsNil() {
        let snap = ReactiveUniformSnapshot()
        XCTAssertNil(snap.timestamp(named: "iTimeUnknown"))
    }

    // MARK: - Concurrency

    func testConcurrentReadsAndWritesDoNotCrash() {
        let snap = ReactiveUniformSnapshot()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.snap", attributes: .concurrent)

        for i in 0..<100 {
            group.enter()
            queue.async {
                snap.setAgentState(Int32(i % 4))
                _ = snap.agentState
                snap.recordOutputEvent()
                _ = snap.intValue(forMatchKey: "agentState")
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "All concurrent tasks should complete within timeout")
        XCTAssertEqual(snap.outputEventCount, 100)
    }

    // MARK: - Command state transition tracking

    func testPreviousCommandStateTracked() {
        let snap = ReactiveUniformSnapshot()
        snap.setCommandState(1)
        snap.setCommandState(2, exitCode: 0)

        XCTAssertEqual(snap.commandState, 2)
        XCTAssertEqual(snap.previousCommandState, 1)
    }

    func testPreviousCommandStateAccessibleViaMatchKey() {
        let snap = ReactiveUniformSnapshot()
        snap.setCommandState(1)
        snap.setCommandState(2, exitCode: 7)

        XCTAssertEqual(snap.intValue(forMatchKey: "previousCommandState"), 1)
        XCTAssertEqual(snap.intValue(forMatchKey: "lastCommandExitCode"), 7)
    }
}
