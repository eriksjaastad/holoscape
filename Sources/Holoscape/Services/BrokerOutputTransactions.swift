import Foundation

/// Owns per-session output transaction state shared by in-process legacy
/// runtimes and broker-host clients.
///
/// Legacy runtimes consume bytes when read, so this store retains the sample
/// until delivery is acknowledged. Host clients keep broker-owned generations
/// unchanged and use the same authority to serialize reads and retry ambiguous
/// acknowledgements. Unrelated sessions retain independent locks.
final class BrokerOutputTransactions: @unchecked Sendable {
    private struct LegacySample {
        let data: Data
        let generation: UInt64
    }

    private final class SessionState: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var nextLegacyGeneration: UInt64 = 0
        var pendingLegacySample: LegacySample?
        var pendingAcknowledgment: UInt64?
        var legacyReplayPresented = false
    }

    private let sessionsLock = NSLock()
    private var sessions: [BrokerSessionID: SessionState] = [:]

    func withSession<T>(_ id: BrokerSessionID, operation: () throws -> T) rethrows -> T {
        let state = state(for: id)
        state.lock.lock()
        defer { state.lock.unlock() }
        return try operation()
    }

    func snapshotLegacy(
        for id: BrokerSessionID,
        read: () throws -> Data
    ) rethrows -> BrokerOutputSnapshot {
        try withSession(id) {
            let state = state(for: id)
            if let pending = state.pendingLegacySample {
                return BrokerOutputSnapshot(data: pending.data, generation: pending.generation)
            }
            let data = try read()
            guard !data.isEmpty else {
                return BrokerOutputSnapshot(data: Data(), generation: nil)
            }
            state.nextLegacyGeneration &+= 1
            let sample = LegacySample(data: data, generation: state.nextLegacyGeneration)
            state.pendingLegacySample = sample
            return BrokerOutputSnapshot(data: sample.data, generation: sample.generation)
        }
    }

    func acknowledgeLegacy(_ id: BrokerSessionID, through generation: UInt64) {
        withSession(id) {
            let state = state(for: id)
            guard let sample = state.pendingLegacySample, sample.generation <= generation else { return }
            state.pendingLegacySample = nil
        }
    }

    func pendingAcknowledgment(id: BrokerSessionID) -> UInt64? {
        withSession(id) { state(for: id).pendingAcknowledgment }
    }

    func deferAcknowledgment(id: BrokerSessionID, generation: UInt64) {
        withSession(id) {
            let state = state(for: id)
            state.pendingAcknowledgment = max(state.pendingAcknowledgment ?? 0, generation)
        }
    }

    func clearAcknowledgment(id: BrokerSessionID, through generation: UInt64) {
        withSession(id) {
            let state = state(for: id)
            if let pending = state.pendingAcknowledgment, pending <= generation {
                state.pendingAcknowledgment = nil
            }
        }
    }

    func claimLegacyReplay(id: BrokerSessionID, hasNewGeneration: Bool, hasData: Bool) -> Bool {
        withSession(id) {
            let state = state(for: id)
            if !hasNewGeneration, state.legacyReplayPresented {
                return false
            }
            if hasData {
                state.legacyReplayPresented = true
            }
            return true
        }
    }

    private func state(for id: BrokerSessionID) -> SessionState {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        if let state = sessions[id] { return state }
        let state = SessionState()
        sessions[id] = state
        return state
    }
}
