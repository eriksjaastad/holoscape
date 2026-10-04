import Foundation

/// Durable JSON registry for broker-owned session metadata.
///
/// This is intentionally metadata-only: records identify the launch intent,
/// lifecycle, and last UI attachment without persisting raw environment values
/// or process handles. Corrupt data is surfaced to callers instead of being
/// silently treated as an empty registry, because process-survival state must
/// fail loudly when it cannot be trusted.
struct BrokerSessionRegistry {
    enum RegistryError: Error, Equatable {
        case invalidRecord(BrokerSessionID, BrokerSessionRecord.ValidationError)
    }

    let fileURL: URL
    /// Registry mutations are load-modify-save transactions shared by the GUI
    /// and broker host processes. Atomic replacement protects the file bytes;
    /// this persistent advisory authority protects whole transactions.
    private let operationLocks = PersistentFileOperationLocks.shared

    init(fileURL: URL = BrokerSessionRegistry.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> [BrokerSessionRecord] {
        try operationLocks.withLock(for: fileURL) { try loadUnlocked() }
    }

    func save(_ records: [BrokerSessionRecord]) throws {
        try operationLocks.withLock(for: fileURL) { try saveUnlocked(records) }
    }

    func upsert(_ record: BrokerSessionRecord) throws {
        try operationLocks.withLock(for: fileURL) {
            var records = try loadUnlocked().filter { $0.id != record.id }
            records.append(record)
            try saveUnlocked(records)
        }
    }

    /// Replace one record only when the caller's snapshot is still current.
    /// This prevents a delayed lifecycle operation from reviving state that a
    /// concurrent recovery already advanced to terminating or final.
    func replace(
        _ record: BrokerSessionRecord,
        ifUnchangedFrom expected: BrokerSessionRecord
    ) throws -> Bool {
        try operationLocks.withLock(for: fileURL) {
            var records = try loadUnlocked()
            let persistedExpected = try canonicalized(expected)
            guard let index = records.firstIndex(where: { $0.id == expected.id }),
                  records[index] == persistedExpected else { return false }
            records[index] = record
            try saveUnlocked(records)
            return true
        }
    }

    func update(
        _ id: BrokerSessionID,
        transform: (BrokerSessionRecord) -> BrokerSessionRecord
    ) throws -> BrokerSessionRecord? {
        try operationLocks.withLock(for: fileURL) {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            let updated = transform(records[index])
            records[index] = updated
            try saveUnlocked(records)
            return updated
        }
    }

    /// Removes records that are both terminal and older than the caller-owned cutoff.
    ///
    /// This is deliberately an explicit primitive, not a launch-time cleanup policy:
    /// callers choose the retention window, and reattachable recovery records remain
    /// durable regardless of age so Holoscape never silently loses resumable sessions.
    @discardableResult
    func pruneFinalRecords(updatedBefore cutoff: Date) throws -> [BrokerSessionRecord] {
        try operationLocks.withLock(for: fileURL) {
            let records = try loadUnlocked()
            let removed = records.filter { record in
                record.updatedAt < cutoff && record.lifecycle.isFinalForPruning
            }
            guard !removed.isEmpty else {
                return []
            }
            let removedIDs = Set(removed.map(\.id))
            let retained = records.filter { record in
                !removedIDs.contains(record.id)
            }
            try saveUnlocked(retained)
            return removed.sortedBySessionID()
        }
    }

    private func loadUnlocked() throws -> [BrokerSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([BrokerSessionRecord].self, from: data)
        try validate(records)
        return records.sortedBySessionID()
    }

    private func saveUnlocked(_ records: [BrokerSessionRecord]) throws {
        try validate(records)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records.sortedBySessionID())

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    private func validate(_ records: [BrokerSessionRecord]) throws {
        for record in records {
            do {
                try record.validate()
            } catch let error as BrokerSessionRecord.ValidationError {
                throw RegistryError.invalidRecord(record.id, error)
            }
        }
    }

    /// Compare snapshots in the registry's persisted representation. ISO-8601
    /// encoding rounds `Date` values to whole seconds, so comparing a freshly
    /// constructed in-memory record directly with its reload would reject the
    /// caller's own write whenever `Date.init` supplied subsecond precision.
    private func canonicalized(_ record: BrokerSessionRecord) throws -> BrokerSessionRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrokerSessionRecord.self, from: encoder.encode(record))
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Holoscape", isDirectory: true)
            .appendingPathComponent("BrokerSessions", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }
}

private extension BrokerSessionLifecycle {
    var isFinalForPruning: Bool {
        switch self {
        case .exited, .errored:
            return true
        case .creating, .running, .detached, .reattaching, .stale, .terminating:
            return false
        }
    }
}

private extension Array where Element == BrokerSessionRecord {
    func sortedBySessionID() -> [BrokerSessionRecord] {
        sorted { left, right in
            left.id.rawValue < right.id.rawValue
        }
    }
}
