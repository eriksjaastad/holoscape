import XCTest
@testable import Holoscape

final class BrokerSessionCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionCoordinatorTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testStartCreatesDurableRunningRecordFromSafeLaunchRequest() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = makeCoordinator(now: { now })
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/Users/test/project",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 120, rows: 40)
        )

        let record = try coordinator.start(
            request,
            channelType: .shell,
            label: "project",
            attachedChannelID: channelID
        )

        XCTAssertEqual(record.channelType, .shell)
        XCTAssertEqual(record.label, "project")
        XCTAssertEqual(record.command, "/bin/zsh")
        XCTAssertEqual(record.arguments, ["--login"])
        XCTAssertEqual(record.workingDirectory, "/Users/test/project")
        XCTAssertEqual(record.environmentProfile, .shell)
        XCTAssertEqual(record.lifecycle, .running)
        XCTAssertNil(record.exitCode)
        XCTAssertEqual(record.createdAt, now)
        XCTAssertEqual(record.updatedAt, now)
        XCTAssertEqual(record.lastAttachedChannelID, channelID)
        XCTAssertEqual(try coordinator.loadAll(), [record])
    }

    func testDetachAndReattachUpdateLifecycleWithoutChangingLaunchIntent() throws {
        var now = Date(timeIntervalSince1970: 10)
        let coordinator = makeCoordinator(now: { now })
        let firstChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: nil,
            environmentProfile: .agentOAuth,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let started = try coordinator.start(
            request,
            channelType: .agentDirect,
            label: "codex",
            attachedChannelID: firstChannel
        )

        now = Date(timeIntervalSince1970: 20)
        let detached = try coordinator.detach(started.id)

        XCTAssertEqual(detached.lifecycle, .detached)
        XCTAssertNil(detached.lastAttachedChannelID)
        XCTAssertEqual(detached.command, started.command)
        XCTAssertEqual(detached.arguments, started.arguments)
        XCTAssertEqual(detached.environmentProfile, started.environmentProfile)
        XCTAssertEqual(detached.createdAt, started.createdAt)
        XCTAssertEqual(detached.updatedAt, now)

        now = Date(timeIntervalSince1970: 30)
        let reattached = try coordinator.reattach(started.id, attachedChannelID: secondChannel)

        XCTAssertEqual(reattached.lifecycle, .running)
        XCTAssertEqual(reattached.lastAttachedChannelID, secondChannel)
        XCTAssertEqual(reattached.createdAt, started.createdAt)
        XCTAssertEqual(reattached.updatedAt, now)
    }

    func testExitRecordsExitCodeAndRemovesFromReattachableList() throws {
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = makeCoordinator(now: { now })
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )

        XCTAssertEqual(try coordinator.reattachableSessions(), [record])

        now = Date(timeIntervalSince1970: 101)
        let exited = try coordinator.exit(record.id, exitCode: 0)

        XCTAssertEqual(exited.lifecycle, .exited)
        XCTAssertEqual(exited.exitCode, 0)
        XCTAssertEqual(exited.updatedAt, now)
        XCTAssertEqual(try coordinator.reattachableSessions(), [])
    }

    func testMarkErroredRemovesSessionFromReattachableListWithoutInventingExitCode() throws {
        var now = Date(timeIntervalSince1970: 200)
        let coordinator = makeCoordinator(now: { now })
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )

        XCTAssertEqual(try coordinator.reattachableSessions(), [record])

        now = Date(timeIntervalSince1970: 201)
        let errored = try coordinator.markErrored(record.id)

        XCTAssertEqual(errored.lifecycle, .errored)
        XCTAssertNil(errored.exitCode)
        XCTAssertEqual(errored.updatedAt, now)
        XCTAssertEqual(try coordinator.reattachableSessions(), [])
    }

    func testUpdatingMissingSessionFailsLoudly() throws {
        let coordinator = makeCoordinator(now: { Date(timeIntervalSince1970: 1) })

        XCTAssertThrowsError(try coordinator.detach(BrokerSessionID(rawValue: "missing"))) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .missingSession(BrokerSessionID(rawValue: "missing")))
        }
    }

    private func makeCoordinator(now: @escaping () -> Date) -> BrokerSessionCoordinator {
        BrokerSessionCoordinator(
            registry: BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json")),
            now: now
        )
    }
}
