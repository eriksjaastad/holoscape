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
        XCTAssertFalse(coordinator.blocksExternalChannelCreation)

        coordinator.begin { retryReplies.append($0) }
        host.finishDetach()

        XCTAssertEqual(retryReplies, [true])
        XCTAssertEqual(
            host.events,
            [
                "interaction:false", "save", "detach", "interaction:true",
                "interaction:false", "save", "save",
            ]
        )
        XCTAssertEqual(host.events.filter { $0 == "detach" }.count, 1)
        XCTAssertTrue(coordinator.isComplete)
    }

    func testRealBrokerProcessSurvivesCoordinatorDetachAndReattaches() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminationCoordinatorBrokerTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let configService = ConfigService(configDir: tempDirectory.appendingPathComponent("config"))
        let manager = ChannelManager(configService: configService)
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let runtime = NativePTYBrokerSessionRuntime()
        let broker = BrokerSessionCoordinator(registry: registry, runtime: runtime)
        var createdTerminal: BrokerBackedTerminalProcess?
        _ = manager.createChannel(
            type: .shell,
            role: "termination-cat",
            workingDirectory: nil
        ) { id, _, label, instanceNumber, _ in
            let process = BrokerBackedTerminalProcess(
                channelID: id,
                channelType: .shell,
                label: label,
                environmentProfile: .shell,
                coordinator: broker
            )
            createdTerminal = process
            return ShellChannelController(
                id: id,
                instanceNumber: instanceNumber,
                label: label,
                terminal: process
            )
        }
        let terminal = try XCTUnwrap(createdTerminal)
        terminal.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: "cat",
            currentDirectory: "/tmp"
        )
        let sessionID = try XCTUnwrap(terminal.brokerSessionID)
        defer { try? runtime.terminateSession(id: sessionID, exitCode: nil) }

        let host = ChannelManagerTerminationHost(manager: manager)
        let coordinator = TerminationCoordinator(host: host, timeout: 2)
        var replies: [Bool] = []
        coordinator.begin { replies.append($0) }
        try waitUntil { replies == [true] }

        let detachedRecords = try registry.load()
        XCTAssertEqual(detachedRecords.count, 1)
        XCTAssertEqual(detachedRecords.first?.lifecycle, .detached)
        XCTAssertTrue(try broker.isRunning(sessionID), "App termination must detach, not kill, the broker-owned child")

        try runtime.sendInput(id: sessionID, bytes: Array("same-process-after-quit\n".utf8))
        try waitUntil {
            let tail = try runtime.readScrollbackTail(id: sessionID, maxBytes: 4_096)
            return String(decoding: tail, as: UTF8.self).contains("same-process-after-quit")
        }

        let restored = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "termination-cat",
            environmentProfile: .shell,
            existingBrokerSessionID: sessionID,
            coordinator: broker
        )
        var outputCount = 0
        restored.setOutputHandler { outputCount += 1 }
        restored.startProcess(
            executable: "/bin/false",
            args: [],
            environment: nil,
            execName: "false",
            currentDirectory: "/tmp"
        )
        try waitUntil {
            restored.pollOutputOnce()
            return outputCount > 0
        }

        XCTAssertEqual(restored.brokerSessionID, sessionID)
        XCTAssertTrue(restored.lastLines(20).joined(separator: "\n").contains("same-process-after-quit"))
        XCTAssertTrue(try broker.isRunning(sessionID))
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try condition())
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

@MainActor
private final class ChannelManagerTerminationHost: TerminationCoordinatorHost {
    private let manager: ChannelManager

    init(manager: ChannelManager) {
        self.manager = manager
    }

    func terminationSetInteractionEnabled(_ enabled: Bool) {}
    func terminationSaveChannelState() -> Bool { manager.saveState() }

    func terminationDetachChannels(completion: @escaping @MainActor () -> Void) {
        manager.detachAllChannelsForAppTermination(completion: completion)
    }
}
