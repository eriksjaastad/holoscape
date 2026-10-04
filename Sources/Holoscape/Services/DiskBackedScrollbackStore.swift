import Darwin
import CryptoKit
import Foundation

/// Bounded raw-byte scrollback persistence for broker-owned terminal sessions.
///
/// This store is intentionally keyed only by broker session id and stores bytes in
/// opaque `.scrollback` files. It does not serialize environment, commands, or
/// IPC frames; those remain in `BrokerSessionRegistry`. Retention is enforced on
/// every append so disk state obeys the same per-session cap as the in-memory
/// runtime ring.
struct DiskBackedScrollbackStore: Sendable {
    enum CompactionCheckpoint: String, Sendable {
        case journalSynced
        case mainOverwriteStarted
        case mainTruncated
        case mainSynced
    }

    enum StoreError: Error, Equatable {
        case invalidSessionID(String)
        case unsafeScrollbackFile(String)
        case fileOperationAndCloseFailed(operation: String, close: String)
    }

    /// Maintenance-facing metadata for one persisted per-session scrollback tail.
    struct StoredScrollbackTail: Equatable, Sendable {
        let sessionID: BrokerSessionID
        let byteCount: Int
        let modifiedAt: Date?
    }

    let directory: URL
    private let maxRetainedBytes: Int
    private let operationLocks = ScrollbackSessionOperationLocks.shared
    private let compactionCheckpoint: (@Sendable (CompactionCheckpoint) throws -> Void)?

    init(
        directory: URL,
        maxRetainedBytes: Int = ScrollbackPersistencePolicy.maxRetainedBytesPerSession,
        compactionCheckpoint: (@Sendable (CompactionCheckpoint) throws -> Void)? = nil
    ) {
        self.directory = directory
        self.maxRetainedBytes = maxRetainedBytes
        self.compactionCheckpoint = compactionCheckpoint
    }

    func append(_ data: Data, for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        guard !data.isEmpty else {
            try validateExistingLeaf(at: url)
            return
        }
        try operationLocks.withLock(for: url) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try withOpenRegularFile(
                at: url,
                flags: O_CREAT | O_RDWR | O_NONBLOCK,
                mode: S_IRUSR | S_IWUSR,
                missingIsAbsent: false
            ) { descriptor in
                try recoverCompactionIfNeeded(mainDescriptor: descriptor, at: url)
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try prune(descriptor: descriptor, at: url)
            }
        }
    }

    func readTail(for id: BrokerSessionID, maxBytes: Int) throws -> Data {
        let url = try fileURL(for: id)
        guard maxBytes > 0, maxRetainedBytes > 0 else {
            try validateExistingLeaf(at: url)
            return Data()
        }
        return try operationLocks.withLock(for: url) {
            try recoverCompactionIfNeeded(at: url)
            guard let snapshot = try readRegularFileTail(
                at: url,
                maxBytes: maxRetainedBytes,
                missingIsAbsent: true
            ) else {
                return Data()
            }
            // A crash between append's write and its prune can leave the persisted
            // tail oversized relative to the retention cap. Repair it on read so a
            // normal store operation restores the bounded-scrollback guarantee.
            if snapshot.fileSize > off_t(maxRetainedBytes) {
                try prune(url)
            }
            let capped = min(maxBytes, maxRetainedBytes)
            let data = snapshot.data
            guard data.count > capped else { return data }
            return Data(data.suffix(capped))
        }
    }

    func remove(for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        try operationLocks.withLock(for: url) {
            // Finish any already-durable compaction intent before publishing a
            // new clear intent. Reusing and truncating a nonempty journal would
            // otherwise destroy the only recovery copy if the clear journal
            // write were interrupted.
            try recoverCompactionIfNeeded(at: url)
            // Clearing is deliberately descriptor-bound: the validated inode is
            // truncated instead of unlinking a pathname that could be rebound
            // between validation and mutation. The caller therefore needs write
            // permission on an existing tail, and the empty storage entry remains.
            _ = try withOpenRegularFile(
                at: url,
                flags: O_WRONLY | O_NONBLOCK,
                missingIsAbsent: true
            ) { descriptor in
                let journalURL = url.appendingPathExtension("compaction")
                _ = try withOpenRegularFile(
                    at: journalURL,
                    flags: O_CREAT | O_RDWR | O_NONBLOCK,
                    mode: S_IRUSR | S_IWUSR,
                    missingIsAbsent: false
                ) { journalDescriptor in
                    try Self.syncContainingDirectory(of: journalURL)
                    // A valid empty journal is durable clear intent. If the
                    // process stops after this point, recovery completes the
                    // clear instead of resurrecting a partially compacted tail.
                    try Self.writeCompactionJournal(Data(), to: journalDescriptor)
                    guard ftruncate(descriptor, 0) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try Self.fullSync(descriptor)
                    try Self.clearCompactionJournal(journalDescriptor)
                }
            }
        }
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        return try operationLocks.withLock(for: url) {
            try recoverCompactionIfNeeded(at: url)
            // Size inspection is metadata-only. lstat both preserves the prior
            // permission contract and refuses to follow a symlinked leaf.
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                let code = errno
                if code == ENOENT { return 0 }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw StoreError.unsafeScrollbackFile(url.path)
            }
            return Int(status.st_size)
        }
    }

    /// Enumerates the persisted per-session scrollback tails in the configured
    /// directory, exposing just enough metadata for a settings or manual
    /// maintenance UI. Only valid `.scrollback` session files are reported;
    /// foreign files and malformed session names are skipped. Each valid
    /// session's metadata read shares the same deletion-stable process lock as
    /// append/read/count/remove, so GUI maintenance cannot inspect a tail while
    /// the broker is replacing it. Entry metadata failures (for example a tail
    /// deleted before its lock is acquired) remain non-fatal; lock acquisition
    /// and cleanup failures propagate so maintenance cannot report false success.
    ///
    /// `resourceValues` is a seam over the per-entry metadata read so the
    /// resilience path can be exercised deterministically in tests; callers
    /// that omit it get the real `URL.resourceValues(forKeys:)` read.
    func listStoredTails(
        resourceValues: (URL) throws -> URLResourceValues = { url in
            try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        },
        isRegularFile: (URL) throws -> Bool = { url in
            try Self.isRegularFileWithoutFollowingSymlinks(url)
        }
    ) throws -> [StoredScrollbackTail] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var tails: [StoredScrollbackTail] = []
        for url in urls {
            guard url.pathExtension == "scrollback" else { continue }
            let rawID = url.deletingPathExtension().lastPathComponent
            guard Self.isValidSessionID(rawID) else { continue }
            // Reject foreign directories and symlinks before acquiring their
            // advisory lock. The check is repeated under that lock below so a
            // concurrent leaf replacement cannot be reported as a tail.
            guard try isRegularFile(url) else { continue }
            let values: URLResourceValues?
            do {
                values = try operationLocks.withLock(for: url) {
                    guard try isRegularFile(url) else { return nil }
                    try recoverCompactionIfNeeded(at: url)
                    // `contentsOfDirectory` may vend URLs carrying prefetched
                    // metadata from before recovery rewrote the file. Rebuild
                    // the URL so the post-recovery size is read afresh.
                    let values = try resourceValues(URL(fileURLWithPath: url.path))
                    guard try isRegularFile(url) else { return nil }
                    return values
                }
            } catch let error as ScrollbackSessionOperationLocks.LockError {
                throw error
            } catch {
                // Disappearance between enumeration and inspection is expected;
                // every other failure must remain visible to maintenance UI.
                if Self.isMissingFileError(error) { continue }
                throw error
            }
            guard let values else { continue }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount > 0 else { continue }
            tails.append(StoredScrollbackTail(
                sessionID: BrokerSessionID(rawValue: rawID),
                byteCount: byteCount,
                modifiedAt: values.contentModificationDate
            ))
        }
        return tails.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    private func prune(_ url: URL) throws {
        _ = try withOpenRegularFile(
            at: url,
            flags: O_RDWR | O_NONBLOCK,
            missingIsAbsent: false
        ) { descriptor in
            try recoverCompactionIfNeeded(mainDescriptor: descriptor, at: url)
            try prune(descriptor: descriptor, at: url)
        }
    }

    private func prune(descriptor: Int32, at url: URL) throws {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard maxRetainedBytes > 0 else {
            try handle.truncate(atOffset: 0)
            try Self.fullSync(descriptor)
            return
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_size > off_t(maxRetainedBytes) else { return }

        try handle.seek(toOffset: UInt64(status.st_size - off_t(maxRetainedBytes)))
        let retained = try handle.read(upToCount: maxRetainedBytes) ?? Data()
        guard retained.count == maxRetainedBytes else {
            throw CocoaError(.fileReadUnknown)
        }

        let journalURL = url.appendingPathExtension("compaction")
        _ = try withOpenRegularFile(
            at: journalURL,
            flags: O_CREAT | O_RDWR | O_NONBLOCK,
            mode: S_IRUSR | S_IWUSR,
            missingIsAbsent: false
        ) { journalDescriptor in
            try Self.syncContainingDirectory(of: journalURL)
            try Self.writeCompactionJournal(retained, to: journalDescriptor)
            try compactionCheckpoint?(.journalSynced)

            let split = max(1, retained.count / 2)
            try Self.writeAll(Data(retained.prefix(split)), to: descriptor, at: 0)
            try compactionCheckpoint?(.mainOverwriteStarted)
            if split < retained.count {
                try Self.writeAll(Data(retained.dropFirst(split)), to: descriptor, at: off_t(split))
            }
            guard ftruncate(descriptor, off_t(retained.count)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try compactionCheckpoint?(.mainTruncated)
            try Self.fullSync(descriptor)
            try compactionCheckpoint?(.mainSynced)
            try Self.clearCompactionJournal(journalDescriptor)
        }
    }

    private func recoverCompactionIfNeeded(at url: URL) throws {
        let journalURL = url.appendingPathExtension("compaction")
        guard let retained = try readCompactionJournal(at: journalURL) else { return }
        _ = try withOpenRegularFile(
            at: url,
            flags: (retained.isEmpty ? O_WRONLY : O_RDWR) | O_NONBLOCK,
            missingIsAbsent: false
        ) { descriptor in
            try restore(retained, to: descriptor)
        }
        try clearCompactionJournalIfPresent(at: url)
    }

    private func recoverCompactionIfNeeded(mainDescriptor: Int32, at url: URL) throws {
        let journalURL = url.appendingPathExtension("compaction")
        guard let retained = try readCompactionJournal(at: journalURL) else { return }
        try restore(retained, to: mainDescriptor)
        try clearCompactionJournalIfPresent(at: url)
    }

    private func restore(_ retained: Data, to descriptor: Int32) throws {
        try Self.writeAll(retained, to: descriptor, at: 0)
        guard ftruncate(descriptor, off_t(retained.count)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Self.fullSync(descriptor)
    }

    private enum CompactionJournalObservation {
        case empty
        case valid(Data)
        case invalid
    }

    private func readCompactionJournal(at journalURL: URL) throws -> Data? {
        let observation = try withOpenRegularFile(
            at: journalURL,
            flags: O_RDONLY | O_NONBLOCK,
            missingIsAbsent: true
        ) { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard status.st_size > 0 else { return CompactionJournalObservation.empty }
            let maximumPayload = max(
                max(0, maxRetainedBytes),
                ScrollbackPersistencePolicy.maxRetainedBytesPerSession
            )
            let maximumRecord = Self.compactionJournalHeaderSize + maximumPayload
            guard status.st_size <= off_t(maximumRecord) else {
                return CompactionJournalObservation.invalid
            }
            let record = try Self.readExactly(
                from: descriptor,
                count: Int(status.st_size),
                at: 0
            )
            guard let retained = Self.decodeCompactionJournal(record) else {
                // The main file is never mutated until a complete journal has
                // been synced. An incomplete/torn record therefore belongs to a
                // pre-mutation interruption and is safe to discard.
                return CompactionJournalObservation.invalid
            }
            return CompactionJournalObservation.valid(retained)
        }
        switch observation {
        case nil, .some(.empty):
            return nil
        case .some(.valid(let retained)):
            return retained
        case .some(.invalid):
            try clearCompactionJournal(at: journalURL)
            return nil
        }
    }

    private func clearCompactionJournal(at journalURL: URL) throws {
        _ = try withOpenRegularFile(
            at: journalURL,
            flags: O_RDWR | O_NONBLOCK,
            missingIsAbsent: true
        ) { descriptor in
            try Self.clearCompactionJournal(descriptor)
        }
    }

    private func clearCompactionJournalIfPresent(at url: URL) throws {
        try clearCompactionJournal(at: url.appendingPathExtension("compaction"))
    }

    private static let compactionJournalMagic = Data("HSCMP001".utf8)
    private static let compactionJournalHeaderSize = 8 + 8 + 32

    private static func writeCompactionJournal(_ retained: Data, to descriptor: Int32) throws {
        var length = UInt64(retained.count).littleEndian
        var record = compactionJournalMagic
        withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
        record.append(contentsOf: SHA256.hash(data: retained))
        record.append(retained)
        guard ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try writeAll(record, to: descriptor, at: 0)
        guard ftruncate(descriptor, off_t(record.count)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fullSync(descriptor)
    }

    private static func decodeCompactionJournal(_ record: Data) -> Data? {
        guard record.count >= compactionJournalHeaderSize,
              record.prefix(compactionJournalMagic.count) == compactionJournalMagic else {
            return nil
        }
        let lengthOffset = compactionJournalMagic.count
        let lengthBytes = record[lengthOffset..<(lengthOffset + 8)]
        var payloadLength: UInt64 = 0
        for (index, byte) in lengthBytes.enumerated() {
            payloadLength |= UInt64(byte) << UInt64(index * 8)
        }
        let payloadStart = compactionJournalHeaderSize
        let availablePayloadBytes = record.count - payloadStart
        guard payloadLength == UInt64(availablePayloadBytes) else { return nil }
        let expectedDigest = record[(lengthOffset + 8)..<payloadStart]
        let payload = Data(record[payloadStart...])
        guard Data(SHA256.hash(data: payload)) == Data(expectedDigest) else { return nil }
        return payload
    }

    private static func clearCompactionJournal(_ descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fullSync(descriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, at offset: off_t) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.pwrite(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written,
                    offset + off_t(written)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += result
            }
        }
    }

    private static func readExactly(from descriptor: Int32, count: Int, at offset: off_t) throws -> Data {
        var data = Data(count: count)
        var bytesRead = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            while bytesRead < bytes.count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: bytesRead),
                    bytes.count - bytesRead,
                    offset + off_t(bytesRead)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else { break }
                bytesRead += result
            }
        }
        if bytesRead < data.count {
            data.removeSubrange(bytesRead..<data.count)
        }
        return data
    }

    private static func fullSync(_ descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncCode = errno
        if fullSyncCode != EINVAL && fullSyncCode != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: fullSyncCode) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func syncContainingDirectory(of url: URL) throws {
        let directoryPath = url.deletingLastPathComponent().path
        let descriptor = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let syncResult = Darwin.fsync(descriptor)
        let syncCode = errno
        let closeResult = Darwin.close(descriptor)
        let closeCode = errno
        if syncResult != 0, closeResult != 0 {
            throw StoreError.fileOperationAndCloseFailed(
                operation: String(describing: POSIXError(POSIXErrorCode(rawValue: syncCode) ?? .EIO)),
                close: String(describing: POSIXError(POSIXErrorCode(rawValue: closeCode) ?? .EIO))
            )
        }
        if syncResult != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: syncCode) ?? .EIO)
        }
        if closeResult != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: closeCode) ?? .EIO)
        }
    }

    private struct RegularFileTail {
        let data: Data
        let fileSize: off_t
    }

    private func readRegularFileTail(
        at url: URL,
        maxBytes: Int,
        missingIsAbsent: Bool
    ) throws -> RegularFileTail? {
        try withOpenRegularFile(
            at: url,
            flags: O_RDONLY | O_NONBLOCK,
            missingIsAbsent: missingIsAbsent
        ) { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let requested = min(off_t(maxBytes), max(0, status.st_size))
            let offset = max(0, status.st_size - requested)
            var data = Data(count: Int(requested))
            var bytesRead = 0
            try data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                while bytesRead < bytes.count {
                    let result = Darwin.pread(
                        descriptor,
                        baseAddress.advanced(by: bytesRead),
                        bytes.count - bytesRead,
                        offset + off_t(bytesRead)
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard result > 0 else { break }
                    bytesRead += result
                }
            }
            if bytesRead < data.count {
                data.removeSubrange(bytesRead..<data.count)
            }
            return RegularFileTail(data: data, fileSize: status.st_size)
        }
    }

    private func validateExistingLeaf(at url: URL) throws {
        _ = try withOpenRegularFile(
            at: url,
            flags: O_RDONLY | O_NONBLOCK,
            missingIsAbsent: true
        ) { _ in () }
    }

    private func withOpenRegularFile<T>(
        at url: URL,
        flags: Int32,
        mode: mode_t = 0,
        missingIsAbsent: Bool,
        _ operation: (Int32) throws -> T
    ) throws -> T? {
        let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || Self.isUnsafeExistingLeaf(url) {
                throw StoreError.unsafeScrollbackFile(url.path)
            }
            if missingIsAbsent, code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let result: Result<T, Error>
        var status = stat()
        if fstat(descriptor, &status) != 0 {
            result = .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        } else if status.st_mode & S_IFMT != S_IFREG {
            result = .failure(StoreError.unsafeScrollbackFile(url.path))
        } else {
            do {
                result = .success(try operation(descriptor))
            } catch {
                result = .failure(error)
            }
        }

        if Darwin.close(descriptor) != 0 {
            let closeCode = errno
            let closeFailure = String(cString: strerror(closeCode))
            switch result {
            case .success:
                throw POSIXError(POSIXErrorCode(rawValue: closeCode) ?? .EIO)
            case .failure(let operationFailure):
                throw StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: operationFailure),
                    close: closeFailure
                )
            }
        }
        return try result.get()
    }

    private func fileURL(for id: BrokerSessionID) throws -> URL {
        guard Self.isValidSessionID(id.rawValue) else {
            throw StoreError.invalidSessionID(id.rawValue)
        }
        return directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
    }

    static func isValidSessionID(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return rawValue.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isRegularFileWithoutFollowingSymlinks(_ url: URL) throws -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fileStatus.st_mode & S_IFMT == S_IFREG
    }

    private static func isUnsafeExistingLeaf(_ url: URL) -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else { return false }
        return fileStatus.st_mode & S_IFMT != S_IFREG
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
    }
}
