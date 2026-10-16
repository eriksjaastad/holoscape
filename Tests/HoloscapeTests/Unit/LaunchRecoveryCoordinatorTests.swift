import XCTest
@testable import Holoscape

@MainActor
final class LaunchRecoveryCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchRecoveryCoordinatorTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Host whose broker inventory stays suspended until the test resolves it.
    private final class SuspendedHost: LaunchRecoveryHost {
        var events: [String] = []
        var restore: () -> Void = {}
        private var pendingInventory: CheckedContinuation<Bool, Never>?

        var isAwaitingInventory: Bool { pendingInventory != nil }

        func resolveInventory(_ succeeded: Bool) {
            pendingInventory?.resume(returning: succeeded)
            pendingInventory = nil
        }

        func launchRecoverySetInteractionEnabled(_ enabled: Bool) { events.append("interaction:\(enabled)") }
        func launchRecoveryPrepareBrokerInventory() async -> Bool {
            events.append("inventory")
            return await withCheckedContinuation { pendingInventory = $0 }
        }
        func launchRecoveryRestoreChannels() {
            events.append("restore")
            restore()
        }
        func launchRecoveryEnsureInitialChannel() { events.append("ensureInitial") }
        func launchRecoveryDidComplete() { events.append("complete") }
    }

    /// Polls until `condition` holds. A missed condition fails the test and
    /// returns, so a regression cannot hang the suite.
    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(message)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForInventoryRequest(
        _ host: SuspendedHost,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil("the broker inventory request", condition: { host.isAwaitingInventory }, file: file, line: line)
    }

    /// Bounded wait so a coordinator that never stops fails instead of hanging the suite.
    private func recoveryFinished(_ coordinator: LaunchRecoveryCoordinator) async throws -> Bool {
        var finished = false
        let task = coordinator.recoveryTask
        Task { await task?.value; finished = true }
        let deadline = Date().addingTimeInterval(2)
        while !finished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return finished
    }

    private func savedLabels(_ configService: ConfigService) -> [String] {
        configService.load().channels.map(\.role)
    }

    private func makeManagerSavingChannel(_ label: String, state: LaunchRecoveryState) -> ChannelManager {
        let manager = ChannelManager(
            configService: ConfigService(configDir: tempDirectory),
            launchRecoveryState: state
        )
        _ = manager.createChannel(type: .shell, role: label, workingDirectory: nil) { id, type, label, number, _ in
            MockChannelController(id: id, type: type, label: label, instanceNumber: number)
        }
        return manager
    }

    func testSavesStayBlockedUntilSavedChannelsAreRestored() async throws {
        let configService = ConfigService(configDir: tempDirectory)
        XCTAssertTrue(makeManagerSavingChannel("Saved", state: LaunchRecoveryState(phase: .completed)).saveState())
        XCTAssertEqual(savedLabels(configService), ["Saved"])

        let host = SuspendedHost()
        let coordinator = LaunchRecoveryCoordinator(
            state: LaunchRecoveryState(phase: .awaitingInventory),
            host: host
        )
        let manager = ChannelManager(configService: configService, launchRecoveryState: coordinator.state)
        host.restore = {
            manager.restoreState { metadata in
                MockChannelController(id: metadata.id, type: metadata.type, label: metadata.role)
            }
        }

        coordinator.begin(restoringSavedChannels: true)
        try await waitForInventoryRequest(host)

        XCTAssertFalse(manager.saveState(), "A blank graph must not replace the persisted tabs")
        XCTAssertEqual(savedLabels(configService), ["Saved"])
        XCTAssertEqual(host.events, ["interaction:false", "inventory"])

        host.resolveInventory(true)
        let finished = try await recoveryFinished(coordinator)
        XCTAssertTrue(finished)

        XCTAssertEqual(host.events, ["interaction:false", "inventory", "restore", "ensureInitial", "interaction:true", "complete"])
        XCTAssertEqual(manager.count, 1)
        XCTAssertTrue(manager.saveState())
        XCTAssertEqual(savedLabels(configService), ["Saved"])
    }

    func testFailedInventoryIsRetriedBeforeRestoring() async throws {
        let host = SuspendedHost()
        let coordinator = LaunchRecoveryCoordinator(
            state: LaunchRecoveryState(phase: .awaitingInventory),
            host: host,
            inventoryRetryDelay: .milliseconds(1)
        )

        coordinator.begin(restoringSavedChannels: true)
        try await waitForInventoryRequest(host)
        host.resolveInventory(false)
        try await waitUntil("the inventory retry") { host.events.filter { $0 == "inventory" }.count >= 2 }
        XCTAssertFalse(host.events.contains("restore"), "An unknown inventory must never be treated as empty")
        try await waitForInventoryRequest(host)
        host.resolveInventory(true)
        let finished = try await recoveryFinished(coordinator)
        XCTAssertTrue(finished)

        XCTAssertTrue(coordinator.state.isCompleted)
        XCTAssertEqual(host.events.suffix(4), ["restore", "ensureInitial", "interaction:true", "complete"])
    }

    func testTerminationDuringInventoryPreventsLateRestoreAndSave() async throws {
        let configService = ConfigService(configDir: tempDirectory)
        XCTAssertTrue(makeManagerSavingChannel("Saved", state: LaunchRecoveryState(phase: .completed)).saveState())

        let host = SuspendedHost()
        let coordinator = LaunchRecoveryCoordinator(
            state: LaunchRecoveryState(phase: .awaitingInventory),
            host: host
        )
        let manager = ChannelManager(configService: configService, launchRecoveryState: coordinator.state)
        coordinator.begin(restoringSavedChannels: true)
        try await waitForInventoryRequest(host)

        coordinator.abandonIfIncomplete()
        host.resolveInventory(true)
        let finished = try await recoveryFinished(coordinator)
        XCTAssertTrue(finished)

        XCTAssertEqual(coordinator.state.phase, .abandoned)
        XCTAssertEqual(host.events, ["interaction:false", "inventory"], "A late completion must not restore or open the app")
        XCTAssertFalse(manager.saveState())
        XCTAssertEqual(savedLabels(configService), ["Saved"])
    }

    func testTerminationStopsInventoryRetryLoop() async throws {
        let host = SuspendedHost()
        let coordinator = LaunchRecoveryCoordinator(
            state: LaunchRecoveryState(phase: .awaitingInventory),
            host: host,
            inventoryRetryDelay: .seconds(60)
        )
        coordinator.begin(restoringSavedChannels: true)
        try await waitForInventoryRequest(host)
        host.resolveInventory(false)

        coordinator.abandonIfIncomplete()
        let finished = try await recoveryFinished(coordinator)
        XCTAssertTrue(finished)

        XCTAssertEqual(host.events, ["interaction:false", "inventory"])
    }
}
