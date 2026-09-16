import Foundation

protocol BrokerSessionCoordinating {
    func start(
        _ request: BrokerSessionLaunchRequest,
        channelType: ChannelType,
        label: String?,
        attachedChannelID: UUID?
    ) throws -> BrokerSessionRecord

    func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord
    func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord
    func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord
    func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord
    func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws
    func readAvailableOutput(_ id: BrokerSessionID) throws -> Data
    func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data
    func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws
    func isRunning(_ id: BrokerSessionID) throws -> Bool
    func terminationStatus(_ id: BrokerSessionID) throws -> Int32?
    func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord
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

    func loadAll() throws -> [BrokerSessionRecord] {
        try registry.load()
    }

    func reattachableSessions() throws -> [BrokerSessionRecord] {
        try registry.load().compactMap { record in
            switch record.lifecycle {
            case .running, .detached, .stale:
                let reconciled = try reconcileRuntimeStatus(record.id)
                switch reconciled.lifecycle {
                case .running, .detached, .stale:
                    return reconciled
                case .creating, .reattaching, .exited, .errored, .terminating:
                    return nil
                }
            case .creating, .reattaching, .exited, .errored, .terminating:
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
        try runtime.createSession(id: id, request: request)
        let record = BrokerSessionRecord(
            id: id,
            channelType: channelType,
            label: label,
            command: request.command,
            arguments: request.arguments,
            workingDirectory: request.workingDirectory,
            environmentProfile: request.environmentProfile,
            lifecycle: .running,
            exitCode: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAttachedChannelID: attachedChannelID
        )
        try registry.upsert(record)
        return record
    }

    func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
        try update(id, runtimeAction: { try runtime.detachSession(id: id) }) { record in
            record.withLifecycle(
                .detached,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
        }
    }

    func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
        try update(id, runtimeAction: { try runtime.attachSession(id: id, channelID: attachedChannelID) }) { record in
            record.withLifecycle(
                .running,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: attachedChannelID
            )
        }
    }

    func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord {
        try update(id, runtimeAction: { try runtime.terminateSession(id: id, exitCode: exitCode) }) { record in
            record.withLifecycle(
                .exited,
                exitCode: exitCode,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
        }
    }

    func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
        try update(id, runtimeAction: { try runtime.markSessionErrored(id: id) }) { record in
            record.withLifecycle(
                .errored,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
        }
    }

    func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {
        _ = try record(for: id)
        try runtime.sendInput(id: id, bytes: bytes)
    }

    func readAvailableOutput(_ id: BrokerSessionID) throws -> Data {
        _ = try record(for: id)
        return try runtime.readAvailableOutput(id: id)
    }

    func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data {
        _ = try record(for: id)
        return try runtime.readScrollbackTail(id: id, maxBytes: maxBytes)
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
        case .exited, .errored:
            return existing
        case .creating, .running, .detached, .reattaching, .stale, .terminating:
            break
        }

        do {
            if try runtime.isRunning(id: id) {
                return existing
            }
            if let exitCode = try runtime.terminationStatus(id: id) {
                return try exit(id, exitCode: exitCode)
            }
            return try updateMetadataOnly(id) { record in
                record.withLifecycle(
                    .errored,
                    exitCode: nil,
                    updatedAt: now(),
                    lastAttachedChannelID: nil
                )
            }
        } catch MetadataOnlyBrokerSessionRuntime.RuntimeError.unsupportedPTYOperation {
            return existing
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
        try registry.upsert(updated)
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
}

private extension BrokerSessionRecord {
    func withLifecycle(
        _ lifecycle: BrokerSessionLifecycle,
        exitCode: Int32?,
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
            lifecycle: lifecycle,
            exitCode: exitCode,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAttachedChannelID: lastAttachedChannelID
        )
    }
}
