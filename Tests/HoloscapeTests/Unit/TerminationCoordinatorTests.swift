import XCTest
@testable import Holoscape

@MainActor
final class TerminationCoordinatorTests: XCTestCase {
    func testInitialSaveFailureDeniesQuitWithoutStartingDetach() {
        let host = RecordingTerminationHost(saveResults: [false])
        let coordinator = TerminationCoordinator(host: host)
        var replies: [Bool] = []

        coordinator.begin { replies.append($0) }

        XCTAssertEqual(replies, [false])
        XCTAssertEqual(host.events, ["interaction:false", "save", "interaction:true"])
        XCTAssertFalse(coordinator.hasStarted)
        XCTAssertFalse(coordinator.blocksExternalChannelCreation)
        XCTAssertFalse(coordinator.isComplete)
    }

    func testSuccessfulDetachPersistsFinalTruthBeforeAdmittingQuit() {
        let host = RecordingTerminationHost(saveResults: [true, true])
        host.defersDetach = true
        let coordinator = TerminationCoordinator(host: host)
        var replies: [Bool] = []

        coordinator.begin { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(coordinator.isInProgress)

        host.finishDetach()

        XCTAssertEqual(replies, [true])
        XCTAssertEqual(host.events, ["interaction:false", "save", "detach", "save"])
        XCTAssertTrue(coordinator.hasStarted)
        XCTAssertTrue(coordinator.blocksExternalChannelCreation)
        XCTAssertTrue(coordinator.isComplete)
    }

    func testQuitAfterTimeoutJoinsExistingDetachAndUsesItsCompletion() {
        let host = RecordingTerminationHost(saveResults: [true, true, true])
        host.defersDetach = true
        let coordinator = TerminationCoordinator(host: host, timeout: 0.01)
        var firstReplies: [Bool] = []
        var retryReplies: [Bool] = []

        coordinator.begin { firstReplies.append($0) }
        let deadline = Date().addingTimeInterval(1)
        while firstReplies.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(firstReplies, [false])
        XCTAssertTrue(coordinator.hasStarted, "The timed-out detach retains cleanup authority")
        XCTAssertFalse(coordinator.isInProgress)
        XCTAssertTrue(coordinator.blocksExternalChannelCreation)

        coordinator.begin { retryReplies.append($0) }
        host.finishDetach()

        XCTAssertEqual(retryReplies, [true])
        XCTAssertEqual(
            host.events,
            [
                "interaction:false", "save", "detach", "interaction:false", "save", "save",
            ]
        )
        XCTAssertEqual(host.events.filter { $0 == "detach" }.count, 1)
        XCTAssertTrue(coordinator.isComplete)
    }

    func testLateFinalSaveFailureAfterTimeoutRestoresInteraction() {
        let host = RecordingTerminationHost(saveResults: [true, false])
        host.defersDetach = true
        let coordinator = TerminationCoordinator(host: host, timeout: 0.01)
        var replies: [Bool] = []

        coordinator.begin { replies.append($0) }
        let deadline = Date().addingTimeInterval(1)
        while replies.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(replies, [false])
        XCTAssertTrue(coordinator.blocksExternalChannelCreation)

        host.finishDetach()

        XCTAssertEqual(
            host.events,
            ["interaction:false", "save", "detach", "save", "interaction:true"]
        )
        XCTAssertFalse(coordinator.hasStarted)
        XCTAssertFalse(coordinator.blocksExternalChannelCreation)
    }

    func testLateSuccessfulDetachAfterTimeoutRestoresInteractionWithoutAdmittingQuit() {
        let host = RecordingTerminationHost(saveResults: [true, true])
        host.defersDetach = true
        let coordinator = TerminationCoordinator(host: host, timeout: 0.01)
        var replies: [Bool] = []

        coordinator.begin { replies.append($0) }
        let deadline = Date().addingTimeInterval(1)
        while replies.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(replies, [false])
        XCTAssertTrue(coordinator.blocksExternalChannelCreation)

        host.finishDetach()

        XCTAssertEqual(
            host.events,
            ["interaction:false", "save", "detach", "save", "interaction:true"]
        )
        XCTAssertFalse(coordinator.hasStarted)
        XCTAssertFalse(coordinator.blocksExternalChannelCreation)
    }

    func testApplicationWillTerminateFallbackOnlyPersistsSynchronousSnapshot() {
        let host = RecordingTerminationHost(saveResults: [true])
        let coordinator = TerminationCoordinator(host: host)

        XCTAssertTrue(coordinator.finalizeAtApplicationWillTerminate())
        XCTAssertEqual(host.events, ["save"])
    }

}

@MainActor
private final class RecordingTerminationHost: TerminationCoordinatorHost {
    var events: [String] = []
    var defersDetach = false
    private var saveResults: [Bool]
    private var detachCompletion: (() -> Void)?

    init(saveResults: [Bool]) {
        self.saveResults = saveResults
    }

    func terminationSetInteractionEnabled(_ enabled: Bool) {
        events.append("interaction:\(enabled)")
    }

    func terminationSaveChannelState() -> Bool {
        events.append("save")
        return saveResults.removeFirst()
    }

    func terminationDetachChannels(completion: @escaping @MainActor () -> Void) {
        events.append("detach")
        if defersDetach {
            detachCompletion = completion
        } else {
            completion()
        }
    }

    func finishDetach() {
        let completion = detachCompletion
        detachCompletion = nil
        completion?()
    }
}
