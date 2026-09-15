import Foundation

/// Coordinates durable metadata transitions for Holoscape-owned broker sessions.
///
/// This service is the UI/app-side contract for #7168: controllers should not
/// mutate registry JSON directly, and lifecycle changes must fail loudly when
/// the referenced broker session is missing or corrupt. The future native PTY
/// broker can sit behind this coordinator without changing channel-controller
/// persistence semantics.
struct BrokerSessionCoordinator {
    enum CoordinatorError: Error, Equatable {
        case missingSession(BrokerSessionID)
    }

    private let registry: BrokerSessionRegistry
    private let now: () -> Date

    init(
        registry: BrokerSessionRegistry = BrokerSessionRegistry(),
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.now = now
    }

    func loadAll() throws -> [BrokerSessionRecord] {
        try registry.load()
    }

    func reattachableSessions() throws -> [BrokerSessionRecord] {
        try registry.load().filter { record in
            switch record.lifecycle {
            case .running, .detached, .stale:
                return true
            case .creating, .reattaching, .exited, .errored, .terminating:
                return false
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
        let record = BrokerSessionRecord(
            id: BrokerSessionID(),
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
        try update(id) { record in
            record.withLifecycle(
                .detached,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
        }
    }

    func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
        try update(id) { record in
            record.withLifecycle(
                .running,
                exitCode: nil,
                updatedAt: now(),
                lastAttachedChannelID: attachedChannelID
            )
        }
    }

    func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord {
        try update(id) { record in
            record.withLifecycle(
                .exited,
                exitCode: exitCode,
                updatedAt: now(),
                lastAttachedChannelID: nil
            )
        }
    }

    private func update(
        _ id: BrokerSessionID,
        transform: (BrokerSessionRecord) -> BrokerSessionRecord
    ) throws -> BrokerSessionRecord {
        let records = try registry.load()
        guard let existing = records.first(where: { $0.id == id }) else {
            throw CoordinatorError.missingSession(id)
        }
        let updated = transform(existing)
        try registry.upsert(updated)
        return updated
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
