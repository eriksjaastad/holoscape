import XCTest
@testable import Holoscape

@MainActor
final class ChannelManagerTests: XCTestCase {
    private final class RecordingBrokerSessionCoordinator: BrokerSessionCoordinating {
        struct StartCall: Equatable {
            let request: BrokerSessionLaunchRequest
            let channelType: ChannelType
            let label: String?
            let attachedChannelID: UUID?
        }

        var startCalls: [StartCall] = []
        var detachCalls: [BrokerSessionID] = []

        func start(
            _ request: BrokerSessionLaunchRequest,
            channelType: ChannelType,
            label: String?,
            attachedChannelID: UUID?
        ) throws -> BrokerSessionRecord {
            startCalls.append(StartCall(
                request: request,
                channelType: channelType,
                label: label,
                attachedChannelID: attachedChannelID
            ))
            return BrokerSessionRecord(
                id: BrokerSessionID(rawValue: "recording-channel-manager-broker-session"),
                channelType: channelType,
                label: label,
                command: request.command,
                arguments: request.arguments,
                workingDirectory: request.workingDirectory,
                environmentProfile: request.environmentProfile,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                lastAttachedChannelID: attachedChannelID
            )
        }

        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
            detachCalls.append(id)
            return BrokerSessionRecord(
                id: id,
                channelType: .shell,
                label: nil,
                command: "/bin/zsh",
                arguments: [],
                workingDirectory: nil,
                environmentProfile: .shell,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastAttachedChannelID: nil
            )
        }

        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(_ id: BrokerSessionID) throws -> Data { Data() }
        func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(_ id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(_ id: BrokerSessionID) throws -> Int32? { nil }
        func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
    }

    private var configService: ConfigService!
    private var manager: ChannelManager!

    override func setUp() {
        super.setUp()
        configService = ConfigService()
        manager = ChannelManager(configService: configService)
    }

    // MARK: - Channel Creation

    func testCreateChannelAddsToRegistry() {
        let channel = createMockChannel(type: .shell, role: "Shell")

        XCTAssertEqual(manager.count, 1)
        XCTAssertNotNil(manager.channel(for: channel.channelId))
    }

    func testCreateMultipleChannels() {
        _ = createMockChannel(type: .shell, role: "Shell")
        _ = createMockChannel(type: .shell, role: "Shell")
        _ = createMockChannel(type: .agentDirect, role: "Agent")

        XCTAssertEqual(manager.count, 3)
    }

    func testAllChannelsReturnsInCreationOrder() {
        let first = createMockChannel(type: .shell, role: "Shell")
        let second = createMockChannel(type: .agentDirect, role: "Agent")
        let third = createMockChannel(type: .shell, role: "Shell")

        let all = manager.allChannels()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].channelId, first.channelId)
        XCTAssertEqual(all[1].channelId, second.channelId)
        XCTAssertEqual(all[2].channelId, third.channelId)
    }

    func testCreateLocalShellProfileUsesProfileDirectory() {
        let profile = SessionProfile(
            label: "Shell",
            connection: .local,
            command: "/bin/zsh",
            directory: DefaultWorkingDirectory.preferredPath
        )

        let channel = manager.createChannel(from: profile)
        let shell = channel as? ShellChannelController

        XCTAssertEqual(shell?.workingDirectory, DefaultWorkingDirectory.preferredPath)
        XCTAssertEqual(channel.displayLabel, DefaultWorkingDirectory.preferredURL.lastPathComponent)
    }

    func testCreateLocalShellProfileUsesInjectedBrokerBackedShellCoordinator() {
        let recordingCoordinator = RecordingBrokerSessionCoordinator()
        let manager = ChannelManager(
            configService: configService,
            brokerBackedShellCoordinator: recordingCoordinator
        )
        let profile = SessionProfile(
            label: "Project Shell",
            connection: .local,
            command: "/bin/zsh",
            directory: "/tmp/channel-manager-broker"
        )

        let channel = manager.createChannel(from: profile)
        channel.activate()
        defer { channel.deactivate() }

        XCTAssertEqual(recordingCoordinator.startCalls.count, 1)
        let call = recordingCoordinator.startCalls[0]
        XCTAssertEqual(call.channelType, .shell)
        XCTAssertEqual(call.label, "Project Shell")
        XCTAssertEqual(call.request.command, "/bin/zsh")
        XCTAssertEqual(call.request.workingDirectory, "/tmp/channel-manager-broker")
        XCTAssertEqual(call.request.environmentProfile, .shell)
    }

    // MARK: - Channel Lookup

    func testChannelForIdReturnsCorrectChannel() {
        let channel = createMockChannel(type: .shell, role: "Shell")
        let found = manager.channel(for: channel.channelId)
        XCTAssertEqual(found?.channelId, channel.channelId)
    }

    func testChannelForUnknownIdReturnsNil() {
        XCTAssertNil(manager.channel(for: UUID()))
    }

    // MARK: - Close Channel

    func testCloseChannelRemovesFromRegistry() {
        let channel = createMockChannel(type: .shell, role: "Shell")
        manager.closeChannel(id: channel.channelId)

        XCTAssertEqual(manager.count, 0)
        XCTAssertNil(manager.channel(for: channel.channelId))
    }

    func testCloseChannelCallsDeactivate() {
        let channel = createMockChannel(type: .shell, role: "Shell") as! MockChannelController
        channel.activate()
        manager.closeChannel(id: channel.channelId)

        XCTAssertEqual(channel.deactivateCallCount, 1)
    }

    func testCloseChannelRemovesFromOrder() {
        let first = createMockChannel(type: .shell, role: "Shell")
        let second = createMockChannel(type: .shell, role: "Shell")
        let third = createMockChannel(type: .shell, role: "Shell")

        manager.closeChannel(id: second.channelId)

        let all = manager.allChannels()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].channelId, first.channelId)
        XCTAssertEqual(all[1].channelId, third.channelId)
    }

    func testCloseNonexistentChannelIsNoOp() {
        _ = createMockChannel(type: .shell, role: "Shell")
        manager.closeChannel(id: UUID())
        XCTAssertEqual(manager.count, 1)
    }

    // MARK: - Close Confirmation

    func testNeedsCloseConfirmationWhenActive() {
        let channel = createMockChannel(type: .shell, role: "Shell") as! MockChannelController
        channel.activate()

        XCTAssertTrue(manager.needsCloseConfirmation(id: channel.channelId))
    }

    func testNoCloseConfirmationWhenDisconnected() {
        let channel = createMockChannel(type: .shell, role: "Shell")
        XCTAssertFalse(manager.needsCloseConfirmation(id: channel.channelId))
    }

    func testNoCloseConfirmationForUnknownId() {
        XCTAssertFalse(manager.needsCloseConfirmation(id: UUID()))
    }

    // MARK: - Unread Ordering

    func testMoveUnreadToFrontReordersChannel() {
        let first = createMockChannel(type: .shell, role: "Shell")
        let second = createMockChannel(type: .shell, role: "Shell")
        let third = createMockChannel(type: .shell, role: "Shell")

        manager.moveUnreadToFront(id: third.channelId)

        let all = manager.allChannels()
        XCTAssertEqual(all[0].channelId, third.channelId)
        XCTAssertEqual(all[1].channelId, first.channelId)
        XCTAssertEqual(all[2].channelId, second.channelId)
    }

    func testMoveUnreadToFrontWithAlreadyFirstIsNoOp() {
        let first = createMockChannel(type: .shell, role: "Shell")
        let second = createMockChannel(type: .shell, role: "Shell")

        manager.moveUnreadToFront(id: first.channelId)

        let all = manager.allChannels()
        XCTAssertEqual(all[0].channelId, first.channelId)
        XCTAssertEqual(all[1].channelId, second.channelId)
    }

    func testMoveUnreadToFrontWithUnknownIdIsNoOp() {
        _ = createMockChannel(type: .shell, role: "Shell")
        manager.moveUnreadToFront(id: UUID())
        XCTAssertEqual(manager.count, 1)
    }

    // MARK: - State Persistence

    func testSaveAndRestoreState() {
        let channel = createMockChannel(type: .shell, role: "Shell")
        manager.saveState()

        let newManager = ChannelManager(configService: configService)
        newManager.restoreState { metadata -> (any ChannelController)? in
            return MockChannelController(
                id: metadata.id,
                type: metadata.type,
                label: metadata.role
            )
        }

        XCTAssertEqual(newManager.count, 1)
        let restored = newManager.allChannels().first
        XCTAssertEqual(restored?.channelId, channel.channelId)
    }

    func testRestoreStateWithEmptyConfig() {
        let newManager = ChannelManager(configService: configService)
        newManager.restoreState { _ in nil }
        XCTAssertEqual(newManager.count, 0)
    }

    func testRestoreStateSkipsFailedFactoryCalls() {
        _ = createMockChannel(type: .shell, role: "Shell")
        _ = createMockChannel(type: .agentDirect, role: "Agent")
        manager.saveState()

        let newManager = ChannelManager(configService: configService)
        var callCount = 0
        newManager.restoreState { metadata -> (any ChannelController)? in
            callCount += 1
            // Only restore the first one
            if callCount == 1 {
                return MockChannelController(id: metadata.id, type: metadata.type, label: metadata.role)
            }
            return nil
        }

        XCTAssertEqual(newManager.count, 1)
    }

    // MARK: - Helpers

    @discardableResult
    private func createMockChannel(type: ChannelType, role: String) -> any ChannelController {
        return manager.createChannel(type: type, role: role, workingDirectory: nil) { id, _, _, instanceNum, _ in
            MockChannelController(id: id, type: type, label: role)
        }
    }
}
