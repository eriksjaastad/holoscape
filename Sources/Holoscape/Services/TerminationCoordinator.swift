import Foundation

/// Application-owned operations used by the bounded termination transaction.
/// Broker/session policy remains behind each channel controller's termination
/// deactivation path.
@MainActor
protocol TerminationCoordinatorHost: AnyObject {
    func terminationSetInteractionEnabled(_ enabled: Bool)
    func terminationSaveChannelState() -> Bool
    func terminationDetachChannels(completion: @escaping @MainActor () -> Void)
}

/// Owns the single bounded transaction that makes an AppKit quit truthful:
/// persist the attached graph, detach every channel, persist final broker truth,
/// and admit termination only after all three steps succeed.
@MainActor
final class TerminationCoordinator {
    private enum Phase {
        case idle
        case detaching(generation: UInt)
        case completed
    }

    private weak var host: (any TerminationCoordinatorHost)?
    private var phase: Phase = .idle
    private var generation: UInt = 0
    private var timeoutWorkItem: DispatchWorkItem?

    var timeout: TimeInterval

    init(host: any TerminationCoordinatorHost, timeout: TimeInterval = 30) {
        self.host = host
        self.timeout = timeout
    }

    var hasStarted: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isInProgress: Bool {
        if case .detaching = phase { return true }
        return false
    }

    var isComplete: Bool {
        if case .completed = phase { return true }
        return false
    }

    func begin(reply: @escaping @MainActor (Bool) -> Void) {
        guard case .idle = phase, let host else { return }

        generation &+= 1
        let admittedGeneration = generation
        phase = .detaching(generation: admittedGeneration)
        timeoutWorkItem?.cancel()
        host.terminationSetInteractionEnabled(false)

        guard host.terminationSaveChannelState() else {
            deny(
                generation: admittedGeneration,
                message: "Channel state could not be saved before broker cleanup; keeping Holoscape open",
                reply: reply
            )
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.deny(
                generation: admittedGeneration,
                message: "Broker session cleanup did not finish before the quit deadline; keeping Holoscape open so cleanup authority is not lost",
                reply: reply
            )
        }
        self.timeoutWorkItem = timeoutWorkItem

        host.terminationDetachChannels { [weak self] in
            guard let self, self.isCurrent(admittedGeneration), let host = self.host else { return }
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            guard host.terminationSaveChannelState() else {
                self.deny(
                    generation: admittedGeneration,
                    message: "Final broker cleanup state could not be saved; keeping Holoscape open",
                    reply: reply
                )
                return
            }
            self.phase = .completed
            reply(true)
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
    }

    private func isCurrent(_ expectedGeneration: UInt) -> Bool {
        guard case let .detaching(activeGeneration) = phase else { return false }
        return activeGeneration == expectedGeneration
    }

    private func deny(
        generation expectedGeneration: UInt,
        message: String,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        guard isCurrent(expectedGeneration), let host else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        phase = .idle
        generation &+= 1
        NSLog("%@", message)
        host.terminationSetInteractionEnabled(true)
        reply(false)
    }
}
