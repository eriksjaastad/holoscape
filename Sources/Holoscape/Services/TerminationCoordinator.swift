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
    private var pendingReply: (@MainActor (Bool) -> Void)?
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
        pendingReply != nil
    }

    var blocksExternalChannelCreation: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// AppKit calls `applicationWillTerminate` only after admission, so a
    /// coordinator that was never admitted cannot truthfully start asynchronous
    /// cleanup at that point. Persist the latest synchronous snapshot and report
    /// failure; channel detachment remains owned by `begin`.
    @discardableResult
    func finalizeAtApplicationWillTerminate() -> Bool {
        guard case .idle = phase else { return true }
        guard let host else {
            NSLog("Termination final snapshot could not be saved: termination host is unavailable")
            return false
        }
        let saved = host.terminationSaveChannelState()
        if !saved {
            NSLog("Termination final snapshot could not be saved before application exit")
        } else {
            NSLog("Application terminated without coordinator admission; no asynchronous channel detach was claimed")
        }
        return saved
    }

    var isComplete: Bool {
        if case .completed = phase { return true }
        return false
    }

    func begin(reply: @escaping @MainActor (Bool) -> Void) {
        guard let host else {
            reply(false)
            return
        }

        switch phase {
        case .completed:
            reply(true)
        case .detaching:
            guard pendingReply == nil else { return }
            beginAttempt(host: host, reply: reply, startsDetach: false)
        case .idle:
            generation &+= 1
            phase = .detaching(generation: generation)
            beginAttempt(host: host, reply: reply, startsDetach: true)
        }
    }

    private func beginAttempt(
        host: any TerminationCoordinatorHost,
        reply: @escaping @MainActor (Bool) -> Void,
        startsDetach: Bool
    ) {
        guard case let .detaching(activeGeneration) = phase else { return }
        pendingReply = reply
        timeoutWorkItem?.cancel()
        host.terminationSetInteractionEnabled(false)

        guard host.terminationSaveChannelState() else {
            denyPendingAttempt(
                generation: activeGeneration,
                keepDetachAuthority: !startsDetach,
                message: "Channel state could not be saved before broker cleanup; keeping Holoscape open"
            )
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.denyPendingAttempt(
                generation: activeGeneration,
                keepDetachAuthority: true,
                message: "Broker session cleanup did not finish before the quit deadline; keeping Holoscape open so cleanup authority is not lost"
            )
        }
        self.timeoutWorkItem = timeoutWorkItem

        if startsDetach {
            host.terminationDetachChannels { [weak self] in
                self?.finishDetach(generation: activeGeneration)
            }
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
    }

    private func finishDetach(generation expectedGeneration: UInt) {
        guard isCurrent(expectedGeneration), let host else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        guard host.terminationSaveChannelState() else {
            let reply = pendingReply
            pendingReply = nil
            phase = .idle
            NSLog("Final broker cleanup state could not be saved; keeping Holoscape open")
            if let reply {
                host.terminationSetInteractionEnabled(true)
                reply(false)
            }
            return
        }

        if let reply = pendingReply {
            pendingReply = nil
            phase = .completed
            reply(true)
        } else {
            // A timed-out request already kept the app open. The late completion
            // still persists authoritative detach truth, then releases the
            // transaction so a later quit can start from that truth.
            phase = .idle
            host.terminationSetInteractionEnabled(true)
        }
    }

    private func isCurrent(_ expectedGeneration: UInt) -> Bool {
        guard case let .detaching(activeGeneration) = phase else { return false }
        return activeGeneration == expectedGeneration
    }

    private func denyPendingAttempt(
        generation expectedGeneration: UInt,
        keepDetachAuthority: Bool,
        message: String
    ) {
        guard isCurrent(expectedGeneration), let host, let reply = pendingReply else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        pendingReply = nil
        if !keepDetachAuthority {
            phase = .idle
        }
        NSLog("%@", message)
        if !keepDetachAuthority {
            host.terminationSetInteractionEnabled(true)
        }
        reply(false)
    }
}
