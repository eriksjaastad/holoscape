import AppKit
import XCTest
@testable import Holoscape

/// #7373 — stale broker recovery guidance must stay stable across
/// relaunch/restore.
///
/// These tests drive the real relaunch sequence (`AppDelegate.restoreChannel`,
/// `AppDelegate.restoreSavedChannelsAndRecoveredBrokerSessions`) against a
/// registry-backed coordinator so tab identity, persisted broker metadata, and
/// the guidance a stale tab shows are all exercised together.
@MainActor
final class StaleBrokerRelaunchTests: XCTestCase {

    // MARK: - Runtime double

    /// Broker runtime double. `lostSessionIDs` models broker sessions whose PTY
    /// the host no longer owns (host restart, reaped process); every other
    /// session stays attachable and running.
    private final class RelaunchBrokerRuntime: BrokerSessionRuntime {
        private let lostSessionIDs: Set<BrokerSessionID>
        private(set) var createdIDs: [BrokerSessionID] = []

        init(lostSessionIDs: Set<BrokerSessionID> = []) {
            self.lostSessionIDs = lostSessionIDs
        }

        func listSessions() throws -> [BrokerSessionID] { createdIDs }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            createdIDs.append(id)
        }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            if lostSessionIDs.contains(id) {
                throw NativePTYBrokerSessionRuntime.RuntimeError.missingSession(id)
            }
        }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool {
            if lostSessionIDs.contains(id) {
                throw NativePTYBrokerSessionRuntime.RuntimeError.missingSession(id)
            }
            return true
        }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    // MARK: - Fixtures

    @MainActor
    private final class LaunchFixture {
        let tempDirectory: URL
        let configService: ConfigService
        let registry: BrokerSessionRegistry
        let manager: ChannelManager
        let appDelegate: AppDelegate

        init(
            channels: [ChannelMetadata],
            records: [BrokerSessionRecord],
            runtime: any BrokerSessionRuntime
        ) throws {
            tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("StaleBrokerRelaunchTests-")
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            configService = ConfigService(configDir: tempDirectory)
            registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
            for record in records {
                try registry.upsert(record)
            }
            var config = configService.load()
            config.channels = channels
            configService.save(config)

            manager = ChannelManager(
                configService: configService,
                brokerBackedShellCoordinator: BrokerSessionCoordinator(
                    registry: registry,
                    runtime: runtime,
                    now: { Date(timeIntervalSince1970: 1_000) }
                )
            )
            appDelegate = AppDelegate()
            appDelegate.channelManagerRef = manager
        }

        /// Run the app's launch-time restore path: saved tabs first, then broker
        /// sessions that survived without a saved tab entry.
        func launch() {
            appDelegate.restoreSavedChannelsAndRecoveredBrokerSessions()
        }

        /// Run the app's termination path in the same order as
        /// `applicationWillTerminate`.
        func quit() {
            manager.saveState()
            manager.detachAllChannelsForAppTermination()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    private static let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000007373")!
    private static let lostSessionID = BrokerSessionID(rawValue: "stale-relaunch-broker-session")

    private static func lostSessionRecord(lifecycle: BrokerSessionLifecycle = .running) -> BrokerSessionRecord {
        BrokerSessionRecord(
            id: lostSessionID,
            channelType: .shell,
            label: "holoscape",
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/tmp/stale-relaunch",
            environmentProfile: .shell,
            lifecycle: lifecycle,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            lastAttachedChannelID: tabID
        )
    }

    private static func savedShellTab(brokerSessionID: BrokerSessionID?) -> ChannelMetadata {
        ChannelMetadata(
            id: tabID,
            type: .shell,
            role: "holoscape",
            workingDirectory: "/tmp/stale-relaunch",
            brokerSessionID: brokerSessionID
        )
    }

    /// Fixture whose broker host no longer owns the saved tab's PTY.
    private static func makeLostSessionFixture() throws -> (fixture: LaunchFixture, runtime: RelaunchBrokerRuntime) {
        let runtime = RelaunchBrokerRuntime(lostSessionIDs: [lostSessionID])
        let fixture = try LaunchFixture(
            channels: [savedShellTab(brokerSessionID: lostSessionID)],
            records: [lostSessionRecord()],
            runtime: runtime
        )
        return (fixture, runtime)
    }

    private func savedChannel(_ configService: ConfigService, id: UUID) throws -> ChannelMetadata {
        try XCTUnwrap(configService.load().channels.first { $0.id == id })
    }

    // MARK: - First relaunch after the broker lost the session

    func testStaleBrokerTabKeepsRecreateGuidanceInsteadOfSpawnningReplacement() throws {
        let (fixture, runtime) = try Self.makeLostSessionFixture()
        defer { fixture.cleanup() }

        fixture.launch()

        let tab = try XCTUnwrap(fixture.manager.allChannels().first as? ShellChannelController)
        XCTAssertEqual(tab.channelId, Self.tabID)
        XCTAssertEqual(tab.state, .stale)
        XCTAssertEqual(tab.recoveryAction, .recreateBrokerSession)
        XCTAssertEqual(
            tab.recoveryAction?.operatorGuidance,
            ChannelRecoveryAction.recreateBrokerSession.operatorGuidance
        )
        XCTAssertTrue(
            runtime.createdIDs.isEmpty,
            "A tab whose broker session is missing must wait for the user's Recreate action instead of spawning a replacement"
        )
    }

    func testStaleBrokerTabDoesNotResurrectDeadSessionAsRecoveredTab() throws {
        let (fixture, _) = try Self.makeLostSessionFixture()
        defer { fixture.cleanup() }

        fixture.launch()

        XCTAssertEqual(fixture.manager.count, 1, "A dead broker session must not be surfaced as an extra recovered tab")
        XCTAssertEqual(fixture.manager.allChannels().map(\.channelId), [Self.tabID])
    }

    func testQuittingAStaleTabPersistsItsBrokerIdentityForTheNextLaunch() throws {
        let (fixture, _) = try Self.makeLostSessionFixture()
        defer { fixture.cleanup() }

        fixture.launch()
        fixture.quit()

        let saved = try savedChannel(fixture.configService, id: Self.tabID)
        XCTAssertNil(saved.brokerSessionID, "A stale tab has no live broker handle to reattach")
        XCTAssertEqual(saved.staleBrokerSessionID, Self.lostSessionID)
    }

    // MARK: - Repeated relaunches

    /// The broker registry can lose a session — host restarted with a wiped
    /// registry, record pruned — while the tab still remembers it was stale.
    /// The tab must come back stale with the same guidance instead of quietly
    /// starting a replacement shell.
    func testStaleTabKeepsRecreateGuidanceWhenTheBrokerRegistryLostTheSession() throws {
        let (fixture, runtime) = try Self.makeLostSessionFixture()
        defer { fixture.cleanup() }

        fixture.launch()
        fixture.quit()

        let afterRegistryLoss = try LaunchFixture(
            channels: fixture.configService.load().channels,
            records: [],
            runtime: runtime
        )
        defer { afterRegistryLoss.cleanup() }
        afterRegistryLoss.launch()

        guard let tab = afterRegistryLoss.manager.allChannels().first as? ShellChannelController else {
            return XCTFail("Expected the stale tab to be restored after the registry lost its session")
        }
        XCTAssertEqual(afterRegistryLoss.manager.count, 1)
        XCTAssertEqual(tab.channelId, Self.tabID)
        XCTAssertEqual(tab.state, .stale)
        XCTAssertEqual(tab.recoveryAction, .recreateBrokerSession)
        XCTAssertTrue(
            runtime.createdIDs.isEmpty,
            "A stale tab must not silently spawn a replacement when the registry no longer lists its session"
        )
    }

    func testStaleBrokerGuidanceIsStableAcrossRepeatedRelaunches() throws {
        let (fixture, runtime) = try Self.makeLostSessionFixture()
        defer { fixture.cleanup() }

        fixture.launch()
        fixture.quit()

        let secondLaunch = try LaunchFixture(
            channels: fixture.configService.load().channels,
            records: try fixture.registry.load(),
            runtime: runtime
        )
        defer { secondLaunch.cleanup() }
        secondLaunch.launch()

        guard let tab = secondLaunch.manager.allChannels().first as? ShellChannelController else {
            return XCTFail("Expected the stale tab to be restored on the second launch")
        }
        XCTAssertEqual(secondLaunch.manager.count, 1)
        XCTAssertEqual(tab.channelId, Self.tabID)
        XCTAssertEqual(tab.state, .stale)
        XCTAssertEqual(tab.recoveryAction, .recreateBrokerSession)
        XCTAssertTrue(runtime.createdIDs.isEmpty)

        secondLaunch.quit()
        let saved = try savedChannel(secondLaunch.configService, id: Self.tabID)
        XCTAssertEqual(saved.staleBrokerSessionID, Self.lostSessionID)
    }

    /// The user-facing recovery action from a restored stale tab must still start
    /// a replacement process and persist the new broker session identity.
    func testRecreateFromRestoredStaleTabStartsReplacementAndClearsStaleIdentity() throws {
        let (fixture, runtime) = try Self.makeLostSessionFixture()
        defer { fixture.cleanup() }

        fixture.launch()
        fixture.quit()

        let secondLaunch = try LaunchFixture(
            channels: fixture.configService.load().channels,
            records: try fixture.registry.load(),
            runtime: runtime
        )
        defer { secondLaunch.cleanup() }
        secondLaunch.launch()

        let action = secondLaunch.manager.recoverChannel(id: Self.tabID)

        XCTAssertEqual(action, .recreateBrokerSession)
        let replacementIDs = runtime.createdIDs
        XCTAssertEqual(replacementIDs.count, 1)
        let tab = try XCTUnwrap(secondLaunch.manager.allChannels().first as? ShellChannelController)
        XCTAssertEqual(tab.state, .active)
        XCTAssertEqual(tab.brokerSessionID, replacementIDs.first)
        XCTAssertNil(tab.staleBrokerSessionID)

        let saved = try savedChannel(secondLaunch.configService, id: Self.tabID)
        XCTAssertEqual(saved.brokerSessionID, replacementIDs.first)
        XCTAssertNil(saved.staleBrokerSessionID)
    }

    // MARK: - Regression guards for the neighbouring restore paths

    /// A broker host outage is recoverable by retry, so a tab restored during an
    /// outage must keep the session handle and report the retry guidance.
    func testBrokerHostOutageRelaunchStillReportsRetryGuidance() throws {
        let hostOutageRuntime = ReattachFailingRuntime()
        let fixture = try LaunchFixture(
            channels: [Self.savedShellTab(brokerSessionID: Self.lostSessionID)],
            records: [Self.lostSessionRecord(lifecycle: .detached)],
            runtime: hostOutageRuntime
        )
        defer { fixture.cleanup() }

        fixture.launch()

        let tab = try XCTUnwrap(fixture.manager.allChannels().first as? ShellChannelController)
        XCTAssertEqual(tab.state, .stale)
        XCTAssertEqual(tab.recoveryAction, .retryBrokerHost)
        XCTAssertEqual(tab.brokerSessionID, Self.lostSessionID, "Host outages must keep the broker handle for retry")
        XCTAssertNil(tab.staleBrokerSessionID)

        fixture.quit()
        let saved = try savedChannel(fixture.configService, id: Self.tabID)
        XCTAssertEqual(saved.brokerSessionID, Self.lostSessionID)
        XCTAssertNil(saved.staleBrokerSessionID)
    }

    /// A live session must still come back attached, with no stale guidance.
    func testLiveBrokerSessionRelaunchRestoresActiveTabWithoutStaleGuidance() throws {
        let fixture = try LaunchFixture(
            channels: [Self.savedShellTab(brokerSessionID: Self.lostSessionID)],
            records: [Self.lostSessionRecord(lifecycle: .detached)],
            runtime: RelaunchBrokerRuntime()
        )
        defer { fixture.cleanup() }

        fixture.launch()

        let tab = try XCTUnwrap(fixture.manager.allChannels().first as? ShellChannelController)
        XCTAssertEqual(tab.state, .active)
        XCTAssertNil(tab.recoveryAction)
        XCTAssertEqual(tab.brokerSessionID, Self.lostSessionID)

        fixture.quit()
        let saved = try savedChannel(fixture.configService, id: Self.tabID)
        XCTAssertEqual(saved.brokerSessionID, Self.lostSessionID)
        XCTAssertNil(saved.staleBrokerSessionID)
    }

    /// Broker host that is unreachable (not missing-session), used for the
    /// outage relaunch guard.
    private final class ReattachFailingRuntime: BrokerSessionRuntime {
        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            throw BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")
        }
        func detachSession(id: BrokerSessionID) throws {
            throw BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")
        }
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            throw BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")
        }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool {
            throw BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")
        }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }
}
