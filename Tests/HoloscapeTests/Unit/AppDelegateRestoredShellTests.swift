import XCTest
@testable import Holoscape

@MainActor
final class AppDelegateRestoredShellTests: XCTestCase {
    private enum RecordingError: Error {
        case unexpectedStart
        case missingSession
    }

    private final class RecordingBrokerSessionCoordinator: BrokerSessionCoordinating {
        var reattachableSessionRecords: [BrokerSessionRecord] = []
        var startCallCount = 0
        var reattachCalls: [(id: BrokerSessionID, attachedChannelID: UUID)] = []
        var readScrollbackTailCalls: [(id: BrokerSessionID, maxBytes: Int)] = []

        func start(
            _ request: BrokerSessionLaunchRequest,
            channelType: ChannelType,
            label: String?,
            attachedChannelID: UUID?
        ) throws -> BrokerSessionRecord {
            startCallCount += 1
            throw RecordingError.unexpectedStart
        }

        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw RecordingError.missingSession }

        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
            reattachCalls.append((id: id, attachedChannelID: attachedChannelID))
            guard let record = reattachableSessionRecords.first(where: { $0.id == id }) else {
                throw RecordingError.missingSession
            }
            return BrokerSessionRecord(
                id: record.id,
                channelType: record.channelType,
                label: record.label,
                command: record.command,
                arguments: record.arguments,
                workingDirectory: record.workingDirectory,
                environmentProfile: record.environmentProfile,
                lifecycle: .running,
                exitCode: nil,
                createdAt: record.createdAt,
                updatedAt: Date(timeIntervalSince1970: 12),
                lastAttachedChannelID: attachedChannelID
            )
        }

        func reattachableSessions() throws -> [BrokerSessionRecord] { reattachableSessionRecords }
        func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord { throw RecordingError.missingSession }
        func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw RecordingError.missingSession }
        func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(_ id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data {
            readScrollbackTailCalls.append((id: id, maxBytes: maxBytes))
            return Data("restored-agent-scrollback".utf8)
        }
        func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(_ id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(_ id: BrokerSessionID) throws -> Int32? { nil }
        func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
            guard let record = reattachableSessionRecords.first(where: { $0.id == id }) else {
                throw RecordingError.missingSession
            }
            return record
        }
    }

    func testRestoredAgentUsesChannelManagerBrokerCoordinatorForExistingSession() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008168")!
        let brokerSessionID = BrokerSessionID(rawValue: "app-restored-agent-broker-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/app-restored-agent",
                environmentProfile: .agentOAuth,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRestoredAgentTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            brokerBackedShellCoordinator: coordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let metadata = ChannelMetadata(
            id: channelID,
            type: .agentDirect,
            role: "Codex",
            workingDirectory: "/tmp/app-restored-agent",
            command: "codex",
            brokerSessionID: brokerSessionID
        )

        let controller = try XCTUnwrap(appDelegate.createChannelFromMetadata(metadata) as? AgentChannelController)
        controller.activate()

        XCTAssertEqual(controller.brokerSessionID, brokerSessionID)
        XCTAssertEqual(coordinator.startCallCount, 0, "Restoring a saved broker-backed agent must reattach the existing session instead of spawning a replacement")
        XCTAssertEqual(coordinator.reattachCalls.map(\.id), [brokerSessionID])
        XCTAssertEqual(coordinator.reattachCalls.map(\.attachedChannelID), [channelID])
        XCTAssertEqual(coordinator.readScrollbackTailCalls.map(\.id), [brokerSessionID])
        XCTAssertEqual(controller.state, .active)
    }

    func testRestoredLegacyRootShellMigratesToDefaultProjectDirectory() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "/",
            workingDirectory: "/"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertNil(restored.label)
        XCTAssertEqual(restored.workingDirectory, DefaultWorkingDirectory.preferredPath)
    }

    func testRestoredFileURLRootShellMigratesToDefaultProjectDirectory() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Shell",
            workingDirectory: "file:///"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertNil(restored.label)
        XCTAssertEqual(restored.workingDirectory, DefaultWorkingDirectory.preferredPath)
    }

    func testRestoredNamedDirectoryIsPreserved() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "holoscape",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertEqual(restored.label, "holoscape")
        XCTAssertEqual(restored.workingDirectory, "/Users/test/projects/holoscape")
    }

    func testRestoredGenericShellLabelBecomesDynamicDirectoryLabel() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Shell",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertNil(restored.label)
        XCTAssertEqual(restored.workingDirectory, "/Users/test/projects/holoscape")
    }
}
