import Foundation

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
}

/// Owns launch-recovery orchestration: gate interaction, wait for a trustworthy
/// broker inventory, restore the saved graph, then open the app to the user.
@MainActor
final class LaunchRecoveryCoordinator {
    let state: LaunchRecoveryState
    private weak var host: (any LaunchRecoveryHost)?
    private let inventoryRetryDelay: Duration
    private(set) var recoveryTask: Task<Void, Never>?

    init(
        state: LaunchRecoveryState,
        host: any LaunchRecoveryHost,
        inventoryRetryDelay: Duration = .milliseconds(500)
    ) {
        self.state = state
        self.host = host
        self.inventoryRetryDelay = inventoryRetryDelay
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
        while await host.launchRecoveryPrepareBrokerInventory() == false {
            do {
                try await Task.sleep(for: inventoryRetryDelay)
            } catch {
                return
            }
            guard state.phase == .awaitingInventory else { return }
        }
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
