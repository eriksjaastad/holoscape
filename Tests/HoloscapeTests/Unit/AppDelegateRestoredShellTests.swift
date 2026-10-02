import XCTest
@testable import Holoscape

@MainActor
final class AppDelegateRestoredShellTests: XCTestCase {
    private enum RecordingError: Error {
        case unexpectedStart
        case missingSession
        case registryUnreadable
    }

    private final class RecordingBrokerSessionCoordinator: BrokerSessionCoordinating {
        var reattachableSessionRecords: [BrokerSessionRecord] = []
        var nextStartRecord: BrokerSessionRecord?
        var reattachError: Error?
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
            if let nextStartRecord {
                return nextStartRecord
            }
            throw RecordingError.unexpectedStart
        }

        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw RecordingError.missingSession }

        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
            reattachCalls.append((id: id, attachedChannelID: attachedChannelID))
            if let reattachError {
                throw reattachError
            }
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
        XCTAssertEqual(
            coordinator.readScrollbackTailCalls.map(\.maxBytes),
            [ScrollbackPersistencePolicy.maxReplayBytesOnReattach],
            "Restored broker-backed agent tabs must replay the documented daily-driver scrollback tail, not the old audit-only 64 KiB cap"
        )
        XCTAssertEqual(controller.state, .active)
    }

    func testRestoreChannelReappliesPersistedAgentAttentionStateAfterActivation() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008169")!
        let brokerSessionID = BrokerSessionID(rawValue: "app-restored-agent-attention-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/app-restored-agent-attention",
                environmentProfile: .agentOAuth,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRestoredAgentAttentionTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            brokerBackedShellCoordinator: coordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let savedState = PersistentChannelState(
            kind: .needsApproval,
            source: .agentAdapter,
            updatedAt: Date(timeIntervalSince1970: 12),
            reason: "Approve command execution",
            recoveryAction: .reconnect
        )
        let metadata = ChannelMetadata(
            id: channelID,
            type: .agentDirect,
            role: "Codex",
            workingDirectory: "/tmp/app-restored-agent-attention",
            command: "codex",
            persistentState: savedState,
            brokerSessionID: brokerSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .active, "Restoring presentation state must not fake process lifecycle")
        XCTAssertEqual(controller.persistentState, savedState)
    }

    func testRestoreChannelDoesNotReplayAttentionWithoutSavedProcessGeneration() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let replacementSessionID = BrokerSessionID(rawValue: "fresh-legacy-agent-session")
        coordinator.nextStartRecord = BrokerSessionRecord(
            id: replacementSessionID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/legacy-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .running,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastAttachedChannelID: nil
        )
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateLegacyAgentAttentionTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            brokerBackedShellCoordinator: coordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let savedState = PersistentChannelState(
            kind: .needsApproval,
            source: .agentAdapter,
            reason: "Approval owned by an unknown legacy process"
        )
        let metadata = ChannelMetadata(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000008172")!,
            type: .agentDirect,
            role: "Codex",
            workingDirectory: "/tmp/legacy-agent",
            command: "codex",
            persistentState: savedState
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.brokerSessionID, replacementSessionID)
        XCTAssertEqual(controller.persistentState.kind, .running)
        XCTAssertEqual(controller.persistentState.source, .processLifecycle)
        XCTAssertNil(controller.adapterPersistentState)
        XCTAssertEqual(coordinator.startCallCount, 1)
    }

    func testRestoreChannelReappliesAdapterStaleAttentionToSameBrokerGeneration() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008173")!
        let brokerSessionID = BrokerSessionID(rawValue: "app-restored-agent-stale-attention-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/app-restored-agent-stale-attention",
                environmentProfile: .agentOAuth,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRestoredAgentStaleAttentionTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            brokerBackedShellCoordinator: coordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let savedState = PersistentChannelState(
            kind: .stale,
            source: .agentAdapter,
            updatedAt: Date(timeIntervalSince1970: 12),
            reason: "codex:session_missing",
            recoveryAction: .recreateBrokerSession
        )
        let metadata = ChannelMetadata(
            id: channelID,
            type: .agentDirect,
            role: "Codex",
            workingDirectory: "/tmp/app-restored-agent-stale-attention",
            command: "codex",
            persistentState: savedState,
            brokerSessionID: brokerSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .active, "Adapter presentation state must not fake process lifecycle")
        XCTAssertEqual(controller.brokerSessionID, brokerSessionID)
        XCTAssertEqual(controller.persistentState, savedState)
        XCTAssertEqual(controller.adapterPersistentState, savedState)
    }

    func testRestoreChannelDoesNotReplayAttentionWhenSavedBrokerProcessIsGone() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008171")!
        let brokerSessionID = BrokerSessionID(rawValue: "exited-app-restored-agent-session")
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateMissingRestoredAgentTests-")
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
            workingDirectory: "/tmp/missing-restored-agent",
            command: "codex",
            persistentState: PersistentChannelState(
                kind: .needsApproval,
                source: .agentAdapter,
                reason: "Approval owned by exited process"
            ),
            brokerSessionID: brokerSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.staleBrokerSessionID, brokerSessionID)
        XCTAssertEqual(controller.persistentState.kind, .stale)
        XCTAssertNil(controller.adapterPersistentState)
        XCTAssertEqual(coordinator.startCallCount, 0, "Restore must not spawn a replacement for a missing saved process")
        XCTAssertTrue(coordinator.reattachCalls.isEmpty)
    }

    func testRestoreChannelPrefersLiveReplacementOverSavedStaleAgentIdentity() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008175")!
        let staleSessionID = BrokerSessionID(rawValue: "stale-agent-generation")
        let replacementSessionID = BrokerSessionID(rawValue: "live-agent-replacement")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: staleSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/live-agent-replacement",
                environmentProfile: .agentOAuth,
                lifecycle: .stale,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            ),
            BrokerSessionRecord(
                id: replacementSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/live-agent-replacement",
                environmentProfile: .agentOAuth,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 21),
                lastAttachedChannelID: channelID
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateLiveAgentReplacementTests-")
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
            workingDirectory: "/tmp/live-agent-replacement",
            command: "codex",
            persistentState: PersistentChannelState(
                kind: .stale,
                source: .brokerRegistry,
                reason: "Saved before replacement identity was persisted",
                recoveryAction: .recreateBrokerSession
            ),
            brokerSessionID: staleSessionID,
            staleBrokerSessionID: staleSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.brokerSessionID, replacementSessionID)
        XCTAssertNil(controller.staleBrokerSessionID)
        XCTAssertEqual(controller.persistentState.kind, .running)
        XCTAssertEqual(coordinator.reattachCalls.map(\.id), [replacementSessionID])
        XCTAssertEqual(coordinator.startCallCount, 0)
    }

    func testRestoreChannelPrefersLiveReplacementOverSavedStaleShellIdentity() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008176")!
        let staleSessionID = BrokerSessionID(rawValue: "stale-shell-generation")
        let replacementSessionID = BrokerSessionID(rawValue: "live-shell-replacement")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: staleSessionID,
                channelType: .shell,
                label: "Shell",
                command: "/bin/zsh",
                arguments: [],
                workingDirectory: "/tmp/live-shell-replacement",
                environmentProfile: .shell,
                lifecycle: .stale,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            ),
            BrokerSessionRecord(
                id: replacementSessionID,
                channelType: .shell,
                label: "Shell",
                command: "/bin/zsh",
                arguments: [],
                workingDirectory: "/tmp/live-shell-replacement",
                environmentProfile: .shell,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 21),
                lastAttachedChannelID: channelID
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateLiveShellReplacementTests-")
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
            type: .shell,
            role: "Shell",
            workingDirectory: "/tmp/live-shell-replacement",
            brokerSessionID: staleSessionID,
            staleBrokerSessionID: staleSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? ShellChannelController)

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.brokerSessionID, replacementSessionID)
        XCTAssertNil(controller.staleBrokerSessionID)
        XCTAssertEqual(coordinator.reattachCalls.map(\.id), [replacementSessionID])
        XCTAssertEqual(coordinator.startCallCount, 0)
    }

    func testRetryAfterRegistryReadFailureReattachesSavedProcessGenerationInPlace() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008174")!
        let brokerSessionID = BrokerSessionID(rawValue: "registry-retry-agent-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/registry-retry-agent",
                environmentProfile: .agentOAuth,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            )
        ]
        coordinator.reattachError = RecordingError.registryUnreadable
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRegistryRetryAgentTests-")
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
            workingDirectory: "/tmp/registry-retry-agent",
            command: "codex",
            brokerSessionID: brokerSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.brokerSessionID, brokerSessionID, "An indeterminate registry failure must preserve the saved process generation")
        XCTAssertEqual(coordinator.startCallCount, 0)

        coordinator.reattachError = nil
        controller.retry()

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.brokerSessionID, brokerSessionID)
        XCTAssertEqual(coordinator.reattachCalls.map(\.id), [brokerSessionID, brokerSessionID])
        XCTAssertEqual(coordinator.startCallCount, 0, "Retry must not spawn a replacement after an indeterminate registry failure")
    }

    func testRestoreChannelDoesNotReapplyOutdatedRuntimeStateOverLiveAgent() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008170")!
        let brokerSessionID = BrokerSessionID(rawValue: "app-restored-agent-runtime-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/app-restored-agent-runtime",
                environmentProfile: .agentOAuth,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastAttachedChannelID: nil
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRestoredAgentRuntimeTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            brokerBackedShellCoordinator: coordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let savedState = PersistentChannelState(
            kind: .running,
            source: .agentAdapter,
            updatedAt: Date(timeIntervalSince1970: 12),
            reason: "Outdated saved activity"
        )
        let metadata = ChannelMetadata(
            id: channelID,
            type: .agentDirect,
            role: "Codex",
            workingDirectory: "/tmp/app-restored-agent-runtime",
            command: "codex",
            persistentState: savedState,
            brokerSessionID: brokerSessionID
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.persistentState.kind, .running)
        XCTAssertEqual(controller.persistentState.source, .processLifecycle)
        XCTAssertNil(controller.persistentState.reason)
        XCTAssertNotEqual(controller.persistentState, savedState)
    }

    func testRestoreChannelDoesNotReapplyAttentionWhenActivationIsSkipped() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateSkippedAgentAttentionTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            brokerBackedShellCoordinator: RecordingBrokerSessionCoordinator()
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let savedState = PersistentChannelState(
            kind: .needsApproval,
            source: .terminalOutput,
            reason: "Outdated approval prompt"
        )
        let metadata = ChannelMetadata(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000008171")!,
            type: .agentDirect,
            role: "Codex",
            workingDirectory: "/Volumes/TeamShare/project",
            command: "codex",
            persistentState: savedState
        )

        let controller = try XCTUnwrap(appDelegate.restoreChannel(from: metadata) as? AgentChannelController)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.persistentState.kind, .disconnected)
        XCTAssertEqual(controller.persistentState.source, .processLifecycle)
        XCTAssertNotEqual(controller.persistentState, savedState)
    }

    func testRestoreUnmatchedBrokerBackedSessionsAsTabsReattachesAndPersistsRecoveredShell() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let brokerSessionID = BrokerSessionID(rawValue: "app-unmatched-shell-broker-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .shell,
                label: "Recovered Shell",
                command: "/bin/zsh",
                arguments: [],
                workingDirectory: "/tmp/app-unmatched-shell",
                environmentProfile: .shell,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 21),
                lastAttachedChannelID: nil
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateUnmatchedBrokerRestoreTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let configService = ConfigService(configDir: tempDirectory)
        let manager = ChannelManager(
            configService: configService,
            brokerBackedShellCoordinator: coordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager

        let restoredCount = appDelegate.restoreUnmatchedBrokerBackedSessionsAsTabs()

        XCTAssertEqual(restoredCount, 1)
        let restoredShell = try XCTUnwrap(manager.allChannels().first as? ShellChannelController)
        XCTAssertEqual(restoredShell.state, .active)
        XCTAssertEqual(restoredShell.brokerSessionID, brokerSessionID)
        XCTAssertEqual(restoredShell.workingDirectory, "/tmp/app-unmatched-shell")
        XCTAssertEqual(coordinator.startCallCount, 0)
        XCTAssertEqual(coordinator.reattachCalls.map(\.id), [brokerSessionID])
        XCTAssertEqual(coordinator.readScrollbackTailCalls.map(\.id), [brokerSessionID])

        let savedChannels = configService.load().channels
        XCTAssertEqual(savedChannels.count, 1)
        XCTAssertEqual(savedChannels.first?.brokerSessionID, brokerSessionID)
        XCTAssertEqual(savedChannels.first?.workingDirectory, "/tmp/app-unmatched-shell")
    }

    func testRecoveredUnmatchedBrokerSessionDoesNotDuplicateAcrossRepeatedRelaunches() throws {
        let coordinator = RecordingBrokerSessionCoordinator()
        let brokerSessionID = BrokerSessionID(rawValue: "app-repeated-relaunch-unmatched-shell-session")
        coordinator.reattachableSessionRecords = [
            BrokerSessionRecord(
                id: brokerSessionID,
                channelType: .shell,
                label: "Recovered Shell",
                command: "/bin/zsh",
                arguments: [],
                workingDirectory: "/tmp/app-repeated-relaunch-shell",
                environmentProfile: .shell,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 30),
                updatedAt: Date(timeIntervalSince1970: 31),
                lastAttachedChannelID: nil
            )
        ]
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRepeatedBrokerRestoreTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let configService = ConfigService(configDir: tempDirectory)

        let firstLaunchManager = ChannelManager(
            configService: configService,
            brokerBackedShellCoordinator: coordinator
        )
        let firstLaunchDelegate = AppDelegate()
        firstLaunchDelegate.channelManagerRef = firstLaunchManager

        XCTAssertEqual(firstLaunchDelegate.restoreUnmatchedBrokerBackedSessionsAsTabs(), 1)
        XCTAssertEqual(firstLaunchManager.count, 1)
        XCTAssertEqual(configService.load().channels.map(\.brokerSessionID), [brokerSessionID])

        let secondLaunchManager = ChannelManager(
            configService: configService,
            brokerBackedShellCoordinator: coordinator
        )
        let secondLaunchDelegate = AppDelegate()
        secondLaunchDelegate.channelManagerRef = secondLaunchManager
        secondLaunchManager.restoreState { metadata in
            guard let controller = secondLaunchDelegate.createChannelFromMetadata(metadata) else { return nil }
            controller.activate()
            return controller
        }

        XCTAssertEqual(secondLaunchDelegate.restoreUnmatchedBrokerBackedSessionsAsTabs(), 0)
        XCTAssertEqual(secondLaunchManager.count, 1)
        let secondLaunchChannels = secondLaunchManager.allChannels()
        XCTAssertEqual(secondLaunchChannels.count, 1)
        let restoredShell = try XCTUnwrap(secondLaunchChannels.first as? ShellChannelController)
        XCTAssertEqual(restoredShell.brokerSessionID, brokerSessionID)
        XCTAssertEqual(restoredShell.workingDirectory, "/tmp/app-repeated-relaunch-shell")
        XCTAssertEqual(configService.load().channels.map(\.brokerSessionID), [brokerSessionID])
        XCTAssertEqual(coordinator.startCallCount, 0, "Repeated relaunch must reattach the recovered session, not spawn a replacement")
        XCTAssertEqual(coordinator.reattachCalls.map(\.id), [brokerSessionID, brokerSessionID])
    }

    func testRestoredAgentPreservesRawProfileLabel() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRawAgentLabelRestoreTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manager = ChannelManager(configService: ConfigService(configDir: tempDirectory))
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .agentDirect,
            role: "mini-claude",
            command: "claude"
        )

        let controller = try XCTUnwrap(appDelegate.createChannelFromMetadata(metadata) as? AgentChannelController)

        XCTAssertEqual(controller.displayLabel, "mini-claude")
    }

    func testRestoredAgentPreservesPersistedInferredLabelSemantics() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateInferredAgentLabelRestoreTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manager = ChannelManager(configService: ConfigService(configDir: tempDirectory))
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = manager
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .agentDirect,
            role: "mini-claude",
            useRawLabel: false,
            command: "claude"
        )

        let controller = try XCTUnwrap(appDelegate.createChannelFromMetadata(metadata) as? AgentChannelController)

        XCTAssertEqual(controller.displayLabel, "MIN")
    }

    func testRestoredAPIAgentPreservesRawProfileLabel() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .agentAPI,
            role: "mini-claude",
            useRawLabel: true,
            command: "claude"
        )

        let controller = AppDelegate.restoredAgentController(
            from: metadata,
            authType: .apiKey("test-key"),
            existingBrokerSessionID: nil,
            restoredStaleBrokerSessionID: metadata.staleBrokerSessionID,
            coordinator: RecordingBrokerSessionCoordinator()
        )

        XCTAssertEqual(controller.channelType, .agentAPI)
        XCTAssertEqual(controller.displayLabel, "mini-claude")
    }

    func testRestoredGroupChatPreservesProfileAndInstanceIdentity() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .groupChat,
            role: "Team Chat",
            instanceNumber: 3,
            apiURL: "https://chat.example.com",
            apiKeyEnv: "TEAM_CHAT_KEY"
        )

        let controller = AppDelegate.restoredGroupChatController(
            from: metadata,
            apiURL: "https://chat.example.com",
            apiKey: "test-key"
        )

        XCTAssertEqual(controller.displayLabel, "Team Chat 3")
        XCTAssertEqual(controller.instanceNumber, 3)
        XCTAssertEqual(controller.apiKeyEnv, "TEAM_CHAT_KEY")
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

    func testRestoredShellOnNetworkVolumeDoesNotAutoActivateWithoutBrokerSession() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Network Project",
            workingDirectory: "/Volumes/TeamShare/project"
        )

        XCTAssertFalse(
            AppDelegate.shouldAutoActivateRestoredChannel(metadata),
            "Restoring an old local tab on /Volumes must not launch a new process at app startup, because setting that directory as cwd re-triggers macOS network-volume TCC prompts every launch."
        )
    }

    func testRestoredAgentOnNetworkVolumeDoesNotAutoActivateWithoutBrokerSession() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .agentDirect,
            role: "Claude-TeamShare",
            workingDirectory: "file:///Volumes/TeamShare/project",
            command: "claude"
        )

        XCTAssertFalse(AppDelegate.shouldAutoActivateRestoredChannel(metadata))
    }

    func testRestoredNetworkVolumeTabWithBrokerSessionCanReattach() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Network Project",
            workingDirectory: "/Volumes/TeamShare/project",
            brokerSessionID: BrokerSessionID(rawValue: "network-volume-survivor")
        )

        XCTAssertTrue(
            AppDelegate.shouldAutoActivateRestoredChannel(metadata),
            "A broker-backed survivor should still reattach; the prompt loop risk is launching a new process with /Volumes as cwd."
        )
    }
}
