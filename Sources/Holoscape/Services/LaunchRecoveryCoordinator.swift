import Foundation

enum LaunchRecoveryInventoryFailureResolution: Equatable {
    case retry
    case quit
}

/// Launch-recovery phase shared by the coordinator that advances it and every
/// consumer that must not act on a half-restored channel graph.
@MainActor
final class LaunchRecoveryState {
    enum Phase: Equatable {
        /// Saved tabs are not registered yet; the persisted list is still the only truth.
        case awaitingInventory
        /// Saved tabs and broker survivors are being registered synchronously.
        case restoring
        case completed
        /// The app terminated before recovery finished; nothing may restore or save.
        case abandoned
    }

    fileprivate(set) var phase: Phase

    init(phase: Phase) {
        self.phase = phase
    }

    var isCompleted: Bool { phase == .completed }

    /// Saving before the saved graph is registered would replace the persisted
    /// tabs with a blank or partial list, and saving after abandonment would
    /// overwrite the state the terminated session left behind.
    var allowsChannelPersistence: Bool { phase == .restoring || phase == .completed }
}

/// Integration points launch recovery drives; `AppDelegate` is the production host.
@MainActor
protocol LaunchRecoveryHost: AnyObject {
    func launchRecoverySetInteractionEnabled(_ enabled: Bool)
    /// `false` means the broker inventory is unknown, never empty.
    func launchRecoveryPrepareBrokerInventory() async -> Bool
    func launchRecoveryRestoreChannels()
    func launchRecoveryEnsureInitialChannel()
    func launchRecoveryDidComplete()
    func launchRecoveryResolveInventoryFailure() async -> LaunchRecoveryInventoryFailureResolution
    func launchRecoveryQuit()
}

/// Owns launch-recovery orchestration: gate interaction, wait for a trustworthy
/// broker inventory, restore the saved graph, then open the app to the user.
@MainActor
final class LaunchRecoveryCoordinator {
    let state: LaunchRecoveryState
    private weak var host: (any LaunchRecoveryHost)?
    private let inventoryRetryDelay: Duration
    private let automaticInventoryAttemptLimit: Int
    private(set) var recoveryTask: Task<Void, Never>?

    init(
        state: LaunchRecoveryState,
        host: any LaunchRecoveryHost,
        inventoryRetryDelay: Duration = .milliseconds(500),
        automaticInventoryAttemptLimit: Int = 2
    ) {
        precondition(automaticInventoryAttemptLimit > 0)
        self.state = state
        self.host = host
        self.inventoryRetryDelay = inventoryRetryDelay
        self.automaticInventoryAttemptLimit = automaticInventoryAttemptLimit
    }

    func begin(restoringSavedChannels: Bool) {
        guard let host else { return }
        guard restoringSavedChannels else {
            host.launchRecoveryEnsureInitialChannel()
            complete(host)
            return
        }
        host.launchRecoverySetInteractionEnabled(false)
        recoveryTask = Task { @MainActor [weak self] in
            await self?.recover()
        }
    }

    /// Termination admitted before recovery finished. The persisted tab list
    /// stays the only truth: the suspended recovery is cancelled and any
    /// completion that still arrives restores, saves and launches nothing.
    func abandonIfIncomplete() {
        guard state.phase == .awaitingInventory else { return }
        state.phase = .abandoned
        recoveryTask?.cancel()
        NSLog("Abandoned launch recovery because the application is terminating")
    }

    private func recover() async {
        guard let host else { return }
        while state.phase == .awaitingInventory {
            for attempt in 1...automaticInventoryAttemptLimit {
                if await host.launchRecoveryPrepareBrokerInventory() {
                    restore(host)
                    return
                }
                guard state.phase == .awaitingInventory else { return }
                guard attempt < automaticInventoryAttemptLimit else { break }
                do {
                    try await Task.sleep(for: inventoryRetryDelay)
                } catch {
                    return
                }
            }
            guard state.phase == .awaitingInventory else { return }
            switch await host.launchRecoveryResolveInventoryFailure() {
            case .retry:
                continue
            case .quit:
                guard state.phase == .awaitingInventory else { return }
                state.phase = .abandoned
                host.launchRecoveryQuit()
                return
            }
        }
    }

    private func restore(_ host: any LaunchRecoveryHost) {
        guard state.phase == .awaitingInventory else { return }
        state.phase = .restoring
        host.launchRecoveryRestoreChannels()
        host.launchRecoveryEnsureInitialChannel()
        complete(host)
    }

    private func complete(_ host: any LaunchRecoveryHost) {
        state.phase = .completed
        host.launchRecoverySetInteractionEnabled(true)
        host.launchRecoveryDidComplete()
    }
}
