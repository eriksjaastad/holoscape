import Foundation

protocol BrokerSessionCoordinating {
    var requiresOffMainBrokerWork: Bool { get }
    func start(
        _ request: BrokerSessionLaunchRequest,
        channelType: ChannelType,
        label: String?,
        attachedChannelID: UUID?
    ) throws -> BrokerSessionRecord

    func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord
    /// Retire a runtime session whose registry write never succeeded.
    func retireUntrackedSession(_ id: BrokerSessionID) throws
    func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord
    /// Remove a replayed, exited runtime object while preserving durable exit metadata.
    func retireCompletedSession(_ id: BrokerSessionID) throws
    func reattachableSessions() throws -> [BrokerSessionRecord]
    func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord
    func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord
    func updateWorkingDirectory(_ id: BrokerSessionID, to directory: String) throws -> BrokerSessionRecord
    func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws
    func readAvailableOutput(_ id: BrokerSessionID) throws -> Data
    func snapshotAvailableOutput(_ id: BrokerSessionID) throws -> BrokerOutputSnapshot
    func acknowledgeOutput(_ id: BrokerSessionID, through generation: UInt64) throws
    func setOutputAvailabilityHandler(
        _ id: BrokerSessionID,
        handler: (@Sendable (BrokerSessionID) -> Void)?
    ) throws
    func supportsOutputAvailabilityMonitoring(_ id: BrokerSessionID) throws -> Bool
    func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data
    func readScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay
    func snapshotScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot
    func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws
    func isRunning(_ id: BrokerSessionID) throws -> Bool
    func terminationStatus(_ id: BrokerSessionID) throws -> Int32?
    func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord
}

extension BrokerSessionCoordinating {
    var requiresOffMainBrokerWork: Bool { false }

    func setOutputAvailabilityHandler(
        _ id: BrokerSessionID,
        handler: (@Sendable (BrokerSessionID) -> Void)?
    ) throws {}

    func supportsOutputAvailabilityMonitoring(_ id: BrokerSessionID) throws -> Bool { false }

    func retireCompletedSession(_ id: BrokerSessionID) throws {}

    func readScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
        ScrollbackReplay(
            data: try readScrollbackTail(id, maxBytes: maxBytes),
            source: .unknown,
            maxBytes: maxBytes
        )
    }

    func snapshotAvailableOutput(_ id: BrokerSessionID) throws -> BrokerOutputSnapshot {
        BrokerOutputSnapshot(data: try readAvailableOutput(id), generation: nil)
    }

    func acknowledgeOutput(_ id: BrokerSessionID, through generation: UInt64) throws {}

    func snapshotScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
        BrokerScrollbackReplaySnapshot(
            replay: try readScrollbackReplay(id, maxBytes: maxBytes),
            generation: nil
        )
    }
}

/// Coordinates durable metadata transitions for Holoscape-owned broker sessions.
///
/// This service is the UI/app-side contract for #7168: controllers should not
/// mutate registry JSON directly, and lifecycle changes must fail loudly when
/// the referenced broker session is missing or corrupt. The future native PTY
/// broker can sit behind this coordinator without changing channel-controller
/// persistence semantics.
struct BrokerSessionCoordinator: BrokerSessionCoordinating {
    enum CoordinatorError: Error, Equatable {
        case missingSession(BrokerSessionID)
        case staleSession(BrokerSessionID)
        case brokerHostUnavailable(BrokerSessionID, String)
        case retirementRollbackFailed(BrokerSessionID, runtimeFailure: String, registryFailure: String)
        case detachRollbackFailed(BrokerSessionID, runtimeFailure: String, registryFailure: String)
        case reattachRollbackFailed(BrokerSessionID, runtimeFailure: String, registryFailure: String)
        case reattachCleanupFailed(BrokerSessionID, runtimeFailure: String)
        case exitRollbackFailed(BrokerSessionID, runtimeFailure: String, registryFailure: String)
        case exitFinalizationFailed(BrokerSessionID, runtimeFailure: String, registryFailure: String)
        case exitCodeMismatch(BrokerSessionID, expected: Int32, observed: Int32)
        case concurrentSessionTransition(BrokerSessionID)
        case untrackedSession(BrokerSessionID, registryFailure: String, rollbackFailure: String)
    }

    private let registry: BrokerSessionRegistry
    private let runtime: any BrokerSessionRuntime
    private let now: () -> Date

    init(
        registry: BrokerSessionRegistry = BrokerSessionRegistry(),
        runtime: any BrokerSessionRuntime = MetadataOnlyBrokerSessionRuntime(),
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.runtime = runtime
        self.now = now
    }

    var requiresOffMainBrokerWork: Bool { runtime is BrokerSessionHostClientRuntime }

    func loadAll() throws -> [BrokerSessionRecord] {
        try registry.load()
    }

    func reattachableSessions() throws -> [BrokerSessionRecord] {
        let records = try registry.load()
        let recordedIDs = Set(records.map(\.id))
        let runtimeSessionIDs = Set(try runtime.listSessions())
        // A failed-start generation may outlive the UI controller that knew its
        // ID (for example after tab close or app termination). The broker's live
        // inventory is the durable fallback authority: retire any generation
        // that has no registry record before offering sessions for restore.
        for orphanID in runtimeSessionIDs where !recordedIDs.contains(orphanID) {
            try retireUntrackedSession(orphanID)
        }
        return try records.compactMap { record in
            switch record.lifecycle {
            case .running, .detached, .reattaching, .stale:
                let reconciled = try reconcileRuntimeStatus(record.id)
                switch reconciled.lifecycle {
                case .running, .detached, .stale:
                    return reconciled
                case .exited:
                    return runtimeSessionIDs.contains(reconciled.id) ? reconciled : nil
                case .reattaching:
                    // A durable reattach lease has no in-process owner after
                    // relaunch. Revoke it to detached so normal restore can
                    // safely acquire a fresh lease for the still-live child.
                    var current = reconciled
                    while current.lifecycle == .reattaching {
                        let detached = current.withLifecycle(
                            .detached,
                            exitCode: nil,
                            updatedAt: now(),
                            lastAttachedChannelID: nil
                        )
                        if try registry.replace(detached, ifUnchangedFrom: current) {
                            return detached
                        }
                        current = try reconcileRuntimeStatus(record.id)
                    }
                    switch current.lifecycle {
                    case .running, .detached, .stale:
                        return current
                    case .exited:
                        return runtimeSessionIDs.contains(current.id) ? current : nil
                    case .creating, .reattaching, .errored, .exiting, .terminating:
                        return nil
                    }
                case .creating, .errored, .exiting, .terminating:
                    return nil
                }
            case .exiting:
                guard runtimeSessionIDs.contains(record.id) else {
                    _ = try markErrored(record.id)
                    return nil
                }
                var reconciled = try reconcileRuntimeStatus(record.id)
                if reconciled.lifecycle == .exiting, try runtime.isRunning(id: record.id) {
                    // A lost graceful-exit request may not have reached the broker.
                    // Retry it without asserting an expected code, then retain the
                    // runtime object until final output and observed status are ready.
                    try runtime.terminateSession(id: record.id, exitCode: nil)
                    reconciled = try reconcileRuntimeStatus(record.id)
                }
                return reconciled.lifecycle == .exited || reconciled.lifecycle == .exiting
                    ? reconciled
                    : nil
            case .terminating:
                // A prior retirement may have reached the broker without its
                // response reaching Holoscape. Relaunch must finish this
                // idempotent transition before restore can classify the saved
                // identity as stale and permit a replacement process.
                _ = try markErrored(record.id)
                return nil
            case .exited:
                // Native broker sessions retain their completed scrollback until
                // explicit retirement. Offer that exited generation once more so
                // restore can replay its final bytes before publishing exit to the
                // controller. An exited record without a runtime owner has no live
                // replay authority and remains final.
                return runtimeSessionIDs.contains(record.id) ? record : nil
            case .creating, .errored:
                return nil
            }
        }
    }

    func start(
        _ request: BrokerSessionLaunchRequest,
        channelType: ChannelType,
        label: String?,
        attachedChannelID: UUID?
    ) throws -> BrokerSessionRecord {
        let timestamp = now()
        let id = BrokerSessionID()
        let ownerTokenWasApplied: Bool
        do {
            if request.agentStatusOwnerToken != nil,
               let acknowledgingRuntime = runtime as? BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime {
                ownerTokenWasApplied = try acknowledgingRuntime.createSessionAcknowledgingAgentStatusOwnerToken(
                    id: id,
                    request: request
                )
            } else {
                try runtime.createSession(id: id, request: request)
                ownerTokenWasApplied = false
            }
        } catch let clientError as BrokerSessionHostClientRuntime.ClientError
            where clientError.ambiguousCreateFailureReason != nil {
            let message = clientError.ambiguousCreateFailureReason!
            // A lost or malformed response does not prove create failed: the
            // broker may own a
            // live process under this generated ID. Retire that exact generation
            // before returning, or preserve its identity in a typed failure so a
            // retry cannot create a duplicate while the outcome is uncertain.
            do {
                try retireUntrackedSession(id)
            } catch let rollbackFailure {
                throw CoordinatorError.untrackedSession(
                    id,
                    registryFailure: "broker create outcome uncertain: \(message)",
                    rollbackFailure: String(describing: rollbackFailure)
                )
            }
            throw CoordinatorError.brokerHostUnavailable(id, message)
        }
        let record = BrokerSessionRecord(
            id: id,
            channelType: channelType,
            label: label,
            command: request.command,
            arguments: request.arguments,
            workingDirectory: request.workingDirectory,
            environmentProfile: request.environmentProfile,
            agentStatusOwnerToken: ownerTokenWasApplied ? request.agentStatusOwnerToken : nil,
            lifecycle: .running,
            exitCode: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAttachedChannelID: attachedChannelID
        )
        do {
            try registry.upsert(record)
        } catch let registryFailure {
            // The runtime session exists but Holoscape could not record it, so it
            // could never be reattached, exited, or recovered: roll it back before
            // surfacing the failure, otherwise the broker is left owning an
            // untracked process.
            do {
                try runtime.markSessionErrored(id: id)
                NSLog("Broker session start was rolled back (unrecordable session \(id.rawValue)): \(registryFailure)")
            } catch {
                throw CoordinatorError.untrackedSession(
                    id,
                    registryFailure: String(describing: registryFailure),
                    rollbackFailure: String(describing: error)
                )
            }
            throw registryFailure
        }
        return record
    }

    func retireUntrackedSession(_ id: BrokerSessionID) throws {
        do {
            try runtime.markSessionErrored(id: id)
        } catch let error where isMissingRuntimeSessionError(error, id: id) {
            return
        }
    }

    func retireCompletedSession(_ id: BrokerSessionID) throws {
        let existing = try record(for: id)
        guard existing.lifecycle == .exited else {
            throw CoordinatorError.concurrentSessionTransition(id)
        }
        do {
            try runtime.markSessionErrored(id: id)
        } catch let error where isMissingRuntimeSessionError(error, id: id) {
            return
        }
    }


    func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
        // Publish the reversible metadata transition before contacting the
        // runtime. A concurrent retirement either wins first (and detach becomes
        // a no-op) or observes `.detached` and advances it to `.terminating`.
        // In neither ordering can teardown erase durable retirement intent.
        var transitionToRollback: (existing: BrokerSessionRecord, detached: BrokerSessionRecord)?
        detachTransition: while true {
            let existing = try record(for: id)
            switch existing.lifecycle {
            case .exiting, .terminating, .exited, .errored, .stale:
                return existing
            case .detached:
                break detachTransition
            case .creating, .running, .reattaching:
                let candidate = existing.withLifecycle(
                    .detached,
                    exitCode: nil,
                    updatedAt: now(),
                    lastAttachedChannelID: nil
                )
                if try registry.replace(candidate, ifUnchangedFrom: existing) {
                    transitionToRollback = (existing, candidate)
                    break detachTransition
                }
                continue
            }
        }

        do {
            try runtime.detachSession(id: id)
        } catch {
            // Detach is advisory in the native runtime. Restore the attached
            // claim only if no concurrent transition has advanced the record;
            // notably, a retirement that won the race remains authoritative.
            if let transitionToRollback {
                do {
                    _ = try registry.replace(
                        transitionToRollback.existing,
                        ifUnchangedFrom: transitionToRollback.detached
                    )
                } catch let registryError {
                    throw CoordinatorError.detachRollbackFailed(
                        id,
                        runtimeFailure: String(describing: error),
                        registryFailure: String(describing: registryError)
                    )
                }
            }
            throw error
        }
        return try record(for: id)
    }

    func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
        let existing = try record(for: id)
        if existing.lifecycle == .terminating {
            // A prior retirement may have removed the runtime session before its
            // final metadata write or response completed. Finish that idempotent
            // retirement before allowing the caller to replace this generation.
            _ = try markErrored(id)
            throw CoordinatorError.staleSession(id)
        }
        if existing.lifecycle == .exited || existing.lifecycle == .exiting {
            // Reattach to the retained broker object only long enough to replay
            // final output. Preserve durable exit truth; for `.exiting`, the
            // output lane publishes the observed status after pending final I/O.
            try runtime.attachSession(id: id, channelID: attachedChannelID)
            return existing
        }
        guard existing.lifecycle != .errored,
              existing.lifecycle != .stale else {
            throw CoordinatorError.staleSession(id)
        }
        guard existing.lifecycle != .reattaching else {
            throw CoordinatorError.concurrentSessionTransition(id)
        }

        // Publish a durable lease before the broker attach. Detach can revoke
        // this lease by advancing `.reattaching` to `.detached`; a late attach
        // must then clean up runtime ownership instead of republishing `.running`.
        let lease = existing.withLifecycle(
            .reattaching,
            exitCode: nil,
            updatedAt: now(),
            lastAttachedChannelID: nil
        )
        guard try registry.replace(lease, ifUnchangedFrom: existing) else {
            throw CoordinatorError.concurrentSessionTransition(id)
        }
        do {
            try runtime.attachSession(id: id, channelID: attachedChannelID)
        } catch BrokerSessionHostClientRuntime.ClientError.transportFailed(let message) {
            try rollbackReattach(id, lease: lease, to: existing, runtimeFailure: message)
            throw CoordinatorError.brokerHostUnavailable(id, message)
        } catch let error where isMissingRuntimeSessionError(error, id: id) {
            while true {
                let current = try record(for: id)
                guard current.lifecycle == .reattaching else {
                    throw CoordinatorError.staleSession(id)
                }
                let stale = current.withLifecycle(
                    .stale,
                    exitCode: nil,
                    updatedAt: now(),
                    lastAttachedChannelID: nil
                )
                if try registry.replace(stale, ifUnchangedFrom: current) { break }
            }
            throw CoordinatorError.staleSession(id)
        } catch {
            try rollbackReattach(id, lease: lease, to: existing, runtimeFailure: String(describing: error))
            throw error
        }

        do {
            while true {
                let current = try record(for: id)
                guard current.lifecycle == .reattaching else {
                    do {
                        try runtime.detachSession(id: id)
                    } catch {
                        throw CoordinatorError.reattachCleanupFailed(
                            id,
                            runtimeFailure: String(describing: error)
                        )
                    }
                    throw CoordinatorError.concurrentSessionTransition(id)
                }
                let attached = current.withLifecycle(
                    .running,
                    exitCode: nil,
                    updatedAt: now(),
                    lastAttachedChannelID: attachedChannelID
                )
                if try registry.replace(attached, ifUnchangedFrom: current) {
                    return attached
                }
            }
        } catch let error as CoordinatorError {
            throw error
        } catch let registryFailure {
            // Runtime attach already succeeded, but durable ownership could not
            // be published. Revoke runtime ownership before returning so the tab
            // cannot remain invisibly attached behind a failed completion. The
            // durable lease is left for relaunch discovery to revoke once
            // registry I/O is healthy again.
            do {
                try runtime.detachSession(id: id)
            } catch {
                throw CoordinatorError.reattachCleanupFailed(
                    id,
                    runtimeFailure: "registry failure: \(registryFailure); detach failure: \(error)"
                )
            }
            throw CoordinatorError.reattachRollbackFailed(
                id,
                runtimeFailure: "runtime attach succeeded; runtime ownership was revoked",
                registryFailure: String(describing: registryFailure)
            )
        }
    }

    private func rollbackReattach(
        _ id: BrokerSessionID,
        lease: BrokerSessionRecord,
        to previous: BrokerSessionRecord,
        runtimeFailure: String
    ) throws {
        do {
            while true {
                let current = try record(for: id)
                guard current.lifecycle == .reattaching else { return }
                let rolledBack = current == lease
                    ? previous
                    : current.withLifecycle(
                        previous.lifecycle,
                        exitCode: previous.exitCode,
                        updatedAt: current.updatedAt,
                        lastAttachedChannelID: previous.lastAttachedChannelID
                    )
                if try registry.replace(rolledBack, ifUnchangedFrom: current) { return }
            }
        } catch let registryFailure {
            throw CoordinatorError.reattachRollbackFailed(
                id,
                runtimeFailure: runtimeFailure,
                registryFailure: String(describing: registryFailure)
            )
        }
    }

    func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord {
        var previousRecord: BrokerSessionRecord?
        while true {
            let current = try record(for: id)
            switch current.lifecycle {
            case .exited:
                let expectedExitCode = current.requestedExitCode ?? exitCode
                if let observedExitCode = current.exitCode, observedExitCode != expectedExitCode {
                    throw CoordinatorError.exitCodeMismatch(
                        id,
                        expected: expectedExitCode,
                        observed: observedExitCode
                    )
                }
                return current
            case .errored:
                return current
            case .exiting:
                if let observedExitCode = try runtime.terminationStatus(id: id) {
                    let expectedExitCode = current.requestedExitCode ?? exitCode
                    let finalized = try finalizeExit(id, exitCode: observedExitCode)
                    if finalized.lifecycle == .exited, observedExitCode != expectedExitCode {
                        throw CoordinatorError.exitCodeMismatch(
                            id,
                            expected: expectedExitCode,
                            observed: observedExitCode
                        )
                    }
                    return finalized
                }
                return current
            case .terminating:
                // Another retirement already owns this generation. Do not
                // issue a competing runtime action or overwrite its outcome.
                return current
            case .creating, .running, .detached, .reattaching, .stale:
                let terminating = current.withLifecycle(
                    .exiting,
                    exitCode: nil,
                    requestedExitCode: exitCode,
                    updatedAt: now(),
                    lastAttachedChannelID: nil
                )
                if try registry.replace(terminating, ifUnchangedFrom: current) {
                    previousRecord = current
                    break
                }
                continue
            }
            break
        }

        do {
            try runtime.terminateSession(id: id, exitCode: exitCode)
        } catch let runtimeFailure {
            do {
                if let observedExitCode = try runtime.terminationStatus(id: id) {
                    do {
                        _ = try finalizeExit(id, exitCode: observedExitCode)
                    } catch let registryFailure {
                        throw CoordinatorError.exitFinalizationFailed(
                            id,
                            runtimeFailure: String(describing: runtimeFailure),
                            registryFailure: String(describing: registryFailure)
                        )
                    }
                } else if !isAmbiguousTerminationFailure(runtimeFailure),
                          try runtime.isRunning(id: id),
                          let previousRecord {
                    do {
                        try rollbackExit(id, to: previousRecord)
                    } catch let registryFailure {
                        throw CoordinatorError.exitRollbackFailed(
                            id,
                            runtimeFailure: String(describing: runtimeFailure),
                            registryFailure: String(describing: registryFailure)
                        )
                    }
                }
            } catch let coordinatorFailure as CoordinatorError {
                throw coordinatorFailure
            } catch {
                // Failure to inspect the result leaves termination ambiguous.
                // Keep durable `.exiting` intent so relaunch reconciliation can
                // drain final output without reviving a child that may have exited.
                NSLog(
                    "Broker session exit outcome remains ambiguous for \(id.rawValue): "
                        + "termination failure: \(runtimeFailure); status failure: \(error)"
                )
            }
            throw runtimeFailure
        }

        return try finalizeExit(id, exitCode: exitCode)
    }

    private func finalizeExit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord {
        // The runtime action is irreversible. Rebase the final state on any
        // concurrent metadata-only mutation so a successful termination cannot
        // be left durably `.running` or `.detached` after a lost CAS.
        while true {
            let current = try record(for: id)
            switch current.lifecycle {
            case .exited:
                return current
            case .errored, .terminating:
                // Retirement owns the stronger final truth and may already be
                // removing the retained runtime object needed for final replay.
                return current
            case .creating, .running, .detached, .reattaching, .stale, .exiting:
                let candidate = current.withLifecycle(
                    .exited,
                    exitCode: exitCode,
                    requestedExitCode: current.requestedExitCode,
                    updatedAt: now(),
                    lastAttachedChannelID: nil
                )
                if try registry.replace(candidate, ifUnchangedFrom: current) {
                    return candidate
                }
            }
        }
    }

    private func rollbackExit(_ id: BrokerSessionID, to previous: BrokerSessionRecord) throws {
        while true {
            let current = try record(for: id)
            guard current.lifecycle == .exiting else { return }
            let rolledBack = current.withLifecycle(
                previous.lifecycle,
                exitCode: previous.exitCode,
                requestedExitCode: previous.requestedExitCode,
                updatedAt: current.updatedAt,
                lastAttachedChannelID: previous.lastAttachedChannelID
            )
            if try registry.replace(rolledBack, ifUnchangedFrom: current) { return }
        }
    }

    private func isAmbiguousTerminationFailure(_ error: Error) -> Bool {
        guard let clientError = error as? BrokerSessionHostClientRuntime.ClientError else { return false }
        switch clientError {
        case .transportFailed, .unexpectedResponse:
            return true
        case .hostFailure:
            return false
        }
    }

    func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
        let existing = try record(for: id)
        let retiring: BrokerSessionRecord
        if existing.lifecycle == .terminating {
            retiring = existing
        } else {
            retiring = existing.withLifecycle(
                .terminating,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
            // Persist intent before the irreversible runtime action. If the
            // final write or host response is lost, durable state never claims
            // that the retired child is still running.
            guard try registry.replace(retiring, ifUnchangedFrom: existing) else {
                return try markErrored(id)
            }
        }
        do {
            try runtime.markSessionErrored(id: id)
        } catch let error where isMissingRuntimeSessionError(error, id: id) {
            // Retirement is idempotent. A prior request may have removed the
            // runtime session before its response or metadata write was lost.
        } catch let error as BrokerSessionHostClientRuntime.ClientError {
            if case .transportFailed = error {
                // The host may have retired the child before its response was
                // lost. Preserve the durable intent so retry can finish the
                // idempotent transition instead of reviving a dead session.
                throw error
            }
            do {
                guard try registry.replace(existing, ifUnchangedFrom: retiring) else {
                    throw CoordinatorError.concurrentSessionTransition(id)
                }
            } catch let registryError {
                throw CoordinatorError.retirementRollbackFailed(
                    id,
                    runtimeFailure: String(describing: error),
                    registryFailure: String(describing: registryError)
                )
            }
            throw error
        } catch {
            // Runtime retirement did not complete. Restore the prior lifecycle
            // when possible so a live child remains reattachable.
            do {
                guard try registry.replace(existing, ifUnchangedFrom: retiring) else {
                    throw CoordinatorError.concurrentSessionTransition(id)
                }
            } catch let registryError {
                throw CoordinatorError.retirementRollbackFailed(
                    id,
                    runtimeFailure: String(describing: error),
                    registryFailure: String(describing: registryError)
                )
            }
            throw error
        }
        let updated: BrokerSessionRecord
        // Runtime retirement may overlap metadata-only mutations (for example a
        // working-directory update). Rebase the final lifecycle transition on
        // the current record instead of losing the truthful `.errored` state
        // merely because an unrelated field changed.
        while true {
            let current = try record(for: id)
            guard current.lifecycle == .terminating else {
                if current.lifecycle == .errored { return current }
                throw CoordinatorError.concurrentSessionTransition(id)
            }
            let candidate = current.withLifecycle(
                .errored,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
            if try registry.replace(candidate, ifUnchangedFrom: current) {
                updated = candidate
                break
            }
        }
        return updated
    }

    func updateWorkingDirectory(_ id: BrokerSessionID, to directory: String) throws -> BrokerSessionRecord {
        guard let updated = try registry.update(id, transform: { existing in
            guard existing.workingDirectory != directory else { return existing }
            return existing.withWorkingDirectory(directory, updatedAt: now())
        }) else {
            throw CoordinatorError.missingSession(id)
        }
        return updated
    }

    /// Prune terminal lifecycle records after an explicit caller-owned retention decision.
    ///
    /// This intentionally does not run from coordinator init or app launch. Recovery
    /// records that might still represent resumable user work stay durable; only
    /// final `.exited` / `.errored` metadata older than the supplied cutoff is removed.
    @discardableResult
    func pruneFinalRecords(updatedBefore cutoff: Date) throws -> [BrokerSessionRecord] {
        try registry.pruneFinalRecords(updatedBefore: cutoff)
    }

    func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {
        _ = try record(for: id)
        try runtime.sendInput(id: id, bytes: bytes)
    }

    func readAvailableOutput(_ id: BrokerSessionID) throws -> Data {
        _ = try record(for: id)
        return try runtime.readAvailableOutput(id: id)
    }

    func snapshotAvailableOutput(_ id: BrokerSessionID) throws -> BrokerOutputSnapshot {
        _ = try record(for: id)
        if let transactionalRuntime = runtime as? BrokerTransactionalOutputRuntime {
            return try transactionalRuntime.snapshotAvailableOutput(
                id: id,
                maxBytes: BrokerSessionHostProtocolLimits.maximumOutputPayloadSize
            )
        }
        return BrokerOutputSnapshot(data: try runtime.readAvailableOutput(id: id), generation: nil)
    }

    func acknowledgeOutput(_ id: BrokerSessionID, through generation: UInt64) throws {
        _ = try record(for: id)
        guard let transactionalRuntime = runtime as? BrokerTransactionalOutputRuntime else { return }
        try transactionalRuntime.acknowledgeOutput(id: id, through: generation)
    }

    func setOutputAvailabilityHandler(
        _ id: BrokerSessionID,
        handler: (@Sendable (BrokerSessionID) -> Void)?
    ) throws {
        _ = try record(for: id)
        guard let runtime = runtime as? BrokerOutputAvailabilityMonitoringRuntime else { return }
        try runtime.setOutputAvailabilityHandler(id: id, handler: handler)
    }

    func supportsOutputAvailabilityMonitoring(_ id: BrokerSessionID) throws -> Bool {
        _ = try record(for: id)
        return (runtime as? BrokerOutputAvailabilityMonitoringRuntime)?.supportsOutputAvailabilityMonitoring == true
    }

    func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data {
        _ = try record(for: id)
        return try runtime.readScrollbackTail(id: id, maxBytes: maxBytes)
    }

    func readScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
        _ = try record(for: id)
        if let replayRuntime = runtime as? ScrollbackReplayReportingRuntime {
            return try replayRuntime.readScrollbackReplay(id: id, maxBytes: maxBytes)
        }
        // A plain tail read cannot atomically establish which unread bytes it
        // represents. Replaying it would let the output pump emit them again.
        // Still perform the read so persistence/corruption failures remain
        // observable to the reattach recovery path.
        _ = try runtime.readScrollbackTail(id: id, maxBytes: maxBytes)
        return ScrollbackReplay(
            data: Data(),
            source: .unknown,
            maxBytes: maxBytes
        )
    }

    func snapshotScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
        _ = try record(for: id)
        if let transactionalRuntime = runtime as? BrokerTransactionalOutputRuntime {
            return try transactionalRuntime.snapshotScrollbackReplay(id: id, maxBytes: maxBytes)
        }
        return BrokerScrollbackReplaySnapshot(
            replay: try readScrollbackReplay(id, maxBytes: maxBytes),
            generation: nil
        )
    }

    func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {
        _ = try record(for: id)
        try runtime.resizeSession(id: id, size: size)
    }

    func isRunning(_ id: BrokerSessionID) throws -> Bool {
        _ = try record(for: id)
        return try runtime.isRunning(id: id)
    }

    func terminationStatus(_ id: BrokerSessionID) throws -> Int32? {
        _ = try record(for: id)
        return try runtime.terminationStatus(id: id)
    }

    /// Reconciles durable metadata with the broker/runtime's observed process state.
    ///
    /// This is the tab-truth hook for #7168/#7169: callers can refresh a broker
    /// record after relaunch or before presenting attachable sessions without
    /// inventing state from stale JSON. Metadata-only runtimes cannot answer
    /// process liveness, so they intentionally leave the record unchanged instead
    /// of silently marking it failed.
    func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
        let existing = try record(for: id)
        switch existing.lifecycle {
        case .exited, .errored, .stale:
            return existing
        case .creating, .running, .detached, .reattaching, .exiting, .terminating:
            break
        }

        do {
            if try runtime.isRunning(id: id) {
                return existing
            }
            if let exitCode = try runtime.terminationStatus(id: id) {
                if existing.lifecycle == .exiting {
                    // Relaunch recovery has no active caller to receive the
                    // original mismatch yet. Preserve comparison authority in
                    // the exited record; the final-output lane surfaces it.
                    return try finalizeExit(id, exitCode: exitCode)
                }
                return try exit(id, exitCode: exitCode)
            }
            // A terminated child may still have a final PTY read or scrollback
            // append in flight. Keep the durable record reattachable until the
            // runtime can report a final status or a loud persistence failure.
            return existing
        } catch MetadataOnlyBrokerSessionRuntime.RuntimeError.unsupportedPTYOperation {
            return existing
        } catch BrokerSessionHostClientRuntime.ClientError.transportFailed {
            return existing
        } catch let error where isMissingRuntimeSessionError(error, id: id) {
            return try updateMetadataOnly(id) { record in
                record.withLifecycle(
                    .stale,
                    exitCode: nil,
                    updatedAt: now(),
                    lastAttachedChannelID: nil
                )
            }
        } catch let error where isUnrecoverableRuntimeSessionError(error, id: id) {
            // A persistence-broken runtime is still owned, unlike a missing
            // session. Retire it before publishing a final lifecycle record.
            return try markErrored(id)
        }
    }

    private func update(
        _ id: BrokerSessionID,
        runtimeAction: () throws -> Void = {},
        transform: (BrokerSessionRecord) -> BrokerSessionRecord
    ) throws -> BrokerSessionRecord {
        let records = try registry.load()
        guard let existing = records.first(where: { $0.id == id }) else {
            throw CoordinatorError.missingSession(id)
        }
        try runtimeAction()
        let updated = transform(existing)
        guard try registry.replace(updated, ifUnchangedFrom: existing) else {
            throw CoordinatorError.concurrentSessionTransition(id)
        }
        return updated
    }

    private func updateMetadataOnly(
        _ id: BrokerSessionID,
        transform: (BrokerSessionRecord) -> BrokerSessionRecord
    ) throws -> BrokerSessionRecord {
        try update(id, runtimeAction: {}, transform: transform)
    }

    private func record(for id: BrokerSessionID) throws -> BrokerSessionRecord {
        let records = try registry.load()
        guard let existing = records.first(where: { $0.id == id }) else {
            throw CoordinatorError.missingSession(id)
        }
        return existing
    }

    private func isMissingRuntimeSessionError(_ error: Error, id: BrokerSessionID) -> Bool {
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError {
            return runtimeError == .missingSession(id)
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error,
           code == "missing-session",
           message.contains(id.rawValue) {
            return true
        }
        return false
    }

    private func isUnrecoverableRuntimeSessionError(_ error: Error, id: BrokerSessionID) -> Bool {
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case let .scrollbackPersistenceFailed(failedID, _) = runtimeError {
            return failedID == id
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error {
            return code == "scrollback-persistence-failed" && message.contains(id.rawValue)
        }
        return false
    }
}

private extension BrokerSessionRecord {
    func withWorkingDirectory(_ workingDirectory: String, updatedAt: Date) -> BrokerSessionRecord {
        BrokerSessionRecord(
            id: id,
            channelType: channelType,
            label: label,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentProfile: environmentProfile,
            agentStatusOwnerToken: agentStatusOwnerToken,
            lifecycle: lifecycle,
            exitCode: exitCode,
            requestedExitCode: requestedExitCode,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAttachedChannelID: lastAttachedChannelID
        )
    }

    func withLifecycle(
        _ lifecycle: BrokerSessionLifecycle,
        exitCode: Int32?,
        requestedExitCode: Int32? = nil,
        updatedAt: Date,
        lastAttachedChannelID: UUID?
    ) -> BrokerSessionRecord {
        BrokerSessionRecord(
            id: id,
            channelType: channelType,
            label: label,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentProfile: environmentProfile,
            agentStatusOwnerToken: agentStatusOwnerToken,
            lifecycle: lifecycle,
            exitCode: exitCode,
            requestedExitCode: requestedExitCode,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAttachedChannelID: lastAttachedChannelID
        )
    }
}
