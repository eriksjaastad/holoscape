import Darwin
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
        case persistenceAndCleanupFailed(operation: String, cleanup: String)
        /// The atomic replacement is already visible, but synchronizing its
        /// containing directory failed. Callers must preserve the committed
        /// records instead of compensating as if the mutation never happened.
        case replacementCommitted(records: [BrokerSessionRecord], durabilityFailure: String)
        /// A prune replacement is already visible, but its durability or lock
        /// cleanup failed. Preserve both sides of the mutation so callers do
        /// not retry it as a falsely successful empty prune.
        case pruneCommitted(
            removedRecords: [BrokerSessionRecord],
            retainedRecords: [BrokerSessionRecord],
            durabilityFailure: String
        )
    }

    struct Persistence: @unchecked Sendable {
        let writeAndSynchronizeTemporaryFile: (Data, URL) throws -> Void
        let writeAndSynchronizeTemporaryFileAtDescriptor: ((Data, Int32, String) throws -> Void)?
        let replaceFile: (URL, URL) throws -> Void
        let synchronizeDirectory: (URL) throws -> Void
        let removeTemporaryFile: (URL) throws -> Void
        let removeTemporaryFileAtDescriptor: (Int32, String) throws -> Void
        let closeDirectoryDescriptor: (Int32) -> Int32
        let unlockFileLock: (Int32) -> Int32
        let closeFileLock: (Int32) -> Int32

        init(
            writeAndSynchronizeTemporaryFile: @escaping (Data, URL) throws -> Void,
            writeAndSynchronizeTemporaryFileAtDescriptor: ((Data, Int32, String) throws -> Void)? = nil,
            replaceFile: @escaping (URL, URL) throws -> Void,
            synchronizeDirectory: @escaping (URL) throws -> Void,
            removeTemporaryFile: @escaping (URL) throws -> Void,
            removeTemporaryFileAtDescriptor: @escaping (Int32, String) throws -> Void = DurableAtomicFileCommitter.removeTemporaryFile,
            closeDirectoryDescriptor: @escaping (Int32) -> Int32 = Darwin.close,
            unlockFileLock: @escaping (Int32) -> Int32 = { flock($0, LOCK_UN) },
            closeFileLock: @escaping (Int32) -> Int32 = Darwin.close
        ) {
            self.writeAndSynchronizeTemporaryFile = writeAndSynchronizeTemporaryFile
            self.writeAndSynchronizeTemporaryFileAtDescriptor = writeAndSynchronizeTemporaryFileAtDescriptor
            self.replaceFile = replaceFile
            self.synchronizeDirectory = synchronizeDirectory
            self.removeTemporaryFile = removeTemporaryFile
            self.removeTemporaryFileAtDescriptor = removeTemporaryFileAtDescriptor
            self.closeDirectoryDescriptor = closeDirectoryDescriptor
            self.unlockFileLock = unlockFileLock
            self.closeFileLock = closeFileLock
        }

        static let live = Persistence(
            writeAndSynchronizeTemporaryFile: DurableAtomicFileCommitter.writeAndSynchronizeTemporaryFile,
            writeAndSynchronizeTemporaryFileAtDescriptor: DurableAtomicFileCommitter.writeAndSynchronizeTemporaryFile,
            replaceFile: DurableAtomicFileCommitter.replaceFile,
            synchronizeDirectory: DurableAtomicFileCommitter.synchronizeDirectory,
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
    }

    let fileURL: URL
    /// Registry mutations are load-modify-save transactions shared by the GUI
    /// and broker host processes. Atomic replacement protects the file bytes;
    /// this persistent advisory authority protects whole transactions.
    private let operationLocks = PersistentFileOperationLocks.shared
    private let persistence: Persistence

    init(
        fileURL: URL = BrokerSessionRegistry.defaultFileURL(),
        persistence: Persistence = .live
    ) {
        self.fileURL = fileURL
        self.persistence = persistence
    }

    func load() throws -> [BrokerSessionRecord] {
        try withOperationLock { try loadUnlocked() }
    }

    func save(_ records: [BrokerSessionRecord]) throws {
        try withMutationLock {
            let committedRecords = try saveUnlocked(records)
            return ((), committedRecords)
        }
    }

    func upsert(_ record: BrokerSessionRecord) throws {
        try withMutationLock {
            var records = try loadUnlocked().filter { $0.id != record.id }
            records.append(record)
            let committedRecords = try saveUnlocked(records)
            return ((), committedRecords)
        }
    }

    /// Replace one record only when the caller's snapshot is still current.
    /// This prevents a delayed lifecycle operation from reviving state that a
    /// concurrent recovery already advanced to terminating or final.
    func replace(
        _ record: BrokerSessionRecord,
        ifUnchangedFrom expected: BrokerSessionRecord
    ) throws -> Bool {
        try withMutationLock {
            var records = try loadUnlocked()
            let persistedExpected = try canonicalized(expected)
            guard let index = records.firstIndex(where: { $0.id == expected.id }),
                  records[index] == persistedExpected else { return (false, nil) }
            records[index] = record
            let committedRecords = try saveUnlocked(records)
            return (true, committedRecords)
        }
    }

    func update(
        _ id: BrokerSessionID,
        transform: (BrokerSessionRecord) -> BrokerSessionRecord
    ) throws -> BrokerSessionRecord? {
        try withMutationLock {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
            let updated = transform(records[index])
            records[index] = updated
            let committedRecords = try saveUnlocked(records)
            return (updated, committedRecords)
        }
    }

    /// Removes records that are both terminal and older than the caller-owned cutoff.
    ///
    /// This is deliberately an explicit primitive, not a launch-time cleanup policy:
    /// callers choose the retention window, and reattachable recovery records remain
    /// durable regardless of age so Holoscape never silently loses resumable sessions.
    @discardableResult
    func pruneFinalRecords(updatedBefore cutoff: Date) throws -> [BrokerSessionRecord] {
        var intendedRemoval: [BrokerSessionRecord] = []
        do {
            return try withMutationLock {
                let records = try loadUnlocked()
                let removed = records.filter { record in
                    record.updatedAt < cutoff && record.lifecycle.isFinalForPruning
                }.sortedBySessionID()
                guard !removed.isEmpty else {
                    return ([], nil)
                }
                intendedRemoval = removed
                let removedIDs = Set(removed.map(\.id))
                let retained = records.filter { record in
                    !removedIDs.contains(record.id)
                }
                let committedRecords = try saveUnlocked(retained)
                return (removed, committedRecords)
            }
        } catch let RegistryError.replacementCommitted(retainedRecords, durabilityFailure)
            where !intendedRemoval.isEmpty {
            throw RegistryError.pruneCommitted(
                removedRecords: intendedRemoval,
                retainedRecords: retainedRecords,
                durabilityFailure: durabilityFailure
            )
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

    private func withOperationLock<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operationLocks.withLock(
                for: fileURL,
                synchronizeCreatedDirectoryEntries: persistence.synchronizeDirectory,
                unlockDescriptor: persistence.unlockFileLock,
                closeDescriptor: persistence.closeFileLock,
                operation
            )
        } catch let lockError as PersistentFileOperationLocks.LockError {
            if case let RegistryError.replacementCommitted(records, durabilityFailure)? = lockError.operationError {
                throw RegistryError.replacementCommitted(
                    records: records,
                    durabilityFailure: durabilityFailure + "; lock cleanup failed: " + lockError.message
                )
            }
            throw lockError
        }
    }

    private func withMutationLock<T>(
        _ operation: () throws -> (value: T, committedRecords: [BrokerSessionRecord]?)
    ) throws -> T {
        var committedRecords: [BrokerSessionRecord]?
        do {
            return try withOperationLock {
                let result = try operation()
                committedRecords = result.committedRecords
                return result.value
            }
        } catch let lockError as PersistentFileOperationLocks.LockError {
            guard lockError.operationSucceeded,
                  let committedRecords else {
                throw lockError
            }
            throw RegistryError.replacementCommitted(
                records: committedRecords,
                durabilityFailure: "lock cleanup failed after committed mutation: \(lockError.message)"
            )
        }
    }

    @discardableResult
    private func saveUnlocked(_ records: [BrokerSessionRecord]) throws -> [BrokerSessionRecord] {
        try validate(records)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sortedRecords = records.sortedBySessionID()
        let data = try encoder.encode(sortedRecords)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let committedRecords = try decoder.decode([BrokerSessionRecord].self, from: data)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try persist(data, committedRecords: committedRecords)
        return committedRecords
    }

    /// Commit registry bytes in crash-safe order: fully synchronize a sibling
    /// temporary file, atomically rename it over the registry, then synchronize
    /// the containing directory so the rename itself is durable.
    private func persist(_ data: Data, committedRecords: [BrokerSessionRecord]) throws {
        let committer = DurableAtomicFileCommitter(
            persistence: .init(
                writeAndSynchronizeTemporaryFile: persistence.writeAndSynchronizeTemporaryFile,
                writeAndSynchronizeTemporaryFileAtDescriptor: persistence.writeAndSynchronizeTemporaryFileAtDescriptor,
                replaceFile: persistence.replaceFile,
                synchronizeDirectory: persistence.synchronizeDirectory,
                removeTemporaryFile: persistence.removeTemporaryFile,
                removeTemporaryFileAtDescriptor: persistence.removeTemporaryFileAtDescriptor,
                closeDirectoryDescriptor: persistence.closeDirectoryDescriptor
            )
        )
        do {
            let directoryIdentity = try DurableDirectoryIdentity.read(at: fileURL.deletingLastPathComponent())
            try committer.commit(
                data,
                to: fileURL,
                directoryIdentity: directoryIdentity
            )
        } catch let error as DurableAtomicFileCommitter.CommitError {
            switch error {
            case let .replacementCommitted(durabilityFailure):
                throw RegistryError.replacementCommitted(
                    records: committedRecords,
                    durabilityFailure: durabilityFailure
                )
            case let .persistenceAndCleanupFailed(operation, cleanup):
                throw RegistryError.persistenceAndCleanupFailed(
                    operation: operation,
                    cleanup: cleanup
                )
            }
        } catch {
            throw error
        }
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
    func canonicalized(_ record: BrokerSessionRecord) throws -> BrokerSessionRecord {
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
        case .creating, .running, .detached, .reattaching, .stale, .exiting, .terminating:
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
