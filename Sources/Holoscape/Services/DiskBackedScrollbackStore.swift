import Darwin
import Foundation

final class ScrollbackSessionOperationLocks: @unchecked Sendable {
    static let shared = ScrollbackSessionOperationLocks()

    private final class LockBox: @unchecked Sendable {
        let lock = NSLock()
    }

    private final class WeakLockBox {
        weak var value: LockBox?

        init(_ value: LockBox) {
            self.value = value
        }
    }

    private let registryLock = NSLock()
    private var locksByPath: [String: WeakLockBox] = [:]

    struct LockError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    func withLock<T>(for fileURL: URL, _ operation: () throws -> T) throws -> T {
        let standardizedURL = fileURL.standardizedFileURL
        // Canonicalize the containing directory so callers using equivalent
        // directory aliases share authority, but never resolve the session-file
        // leaf. A concurrent leaf symlink swap must not redirect the advisory
        // lock outside the scrollback directory.
        let canonicalURL = standardizedURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardizedURL.lastPathComponent)
        let key = canonicalURL.path
        let lockBox = registryLock.withLock {
            locksByPath = locksByPath.filter { $0.value.value != nil }
            if let existing = locksByPath[key]?.value {
                return existing
            }
            let created = LockBox()
            locksByPath[key] = WeakLockBox(created)
            return created
        }
        return try lockBox.lock.withLock {
            let lockURL = canonicalURL.appendingPathExtension("lock")
            do {
                try FileManager.default.createDirectory(
                    at: lockURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw LockError(
                    message: "createDirectory failed for \(lockURL.deletingLastPathComponent().path): \(error)"
                )
            }

            // The lock leaf is persistent authority, not an aliasable path.
            // Refuse symlinks atomically at open so a concurrent replacement
            // cannot redirect flock to a file outside the scrollback directory.
            let descriptor = Darwin.open(
                lockURL.path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw LockError(message: Self.posixFailure("open", path: lockURL.path, code: errno))
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let lockFailure = Self.posixFailure("flock(LOCK_EX)", path: lockURL.path, code: errno)
                if Darwin.close(descriptor) != 0 {
                    let closeFailure = Self.posixFailure("close", path: lockURL.path, code: errno)
                    throw LockError(message: "\(lockFailure); cleanup also failed: \(closeFailure)")
                }
                throw LockError(message: lockFailure)
            }

            let result: Result<T, Error>
            do {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }

            var cleanupFailures: [String] = []
            if flock(descriptor, LOCK_UN) != 0 {
                cleanupFailures.append(Self.posixFailure("flock(LOCK_UN)", path: lockURL.path, code: errno))
            }
            if Darwin.close(descriptor) != 0 {
                cleanupFailures.append(Self.posixFailure("close", path: lockURL.path, code: errno))
            }
            if !cleanupFailures.isEmpty {
                let operationFailure: String
                switch result {
                case .success:
                    operationFailure = ""
                case .failure(let error):
                    operationFailure = "operation failed: \(error); "
                }
                throw LockError(message: operationFailure + cleanupFailures.joined(separator: "; "))
            }
            return try result.get()
        }
    }

    private static func posixFailure(_ operation: String, path: String, code: Int32) -> String {
        "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// Bounded raw-byte scrollback persistence for broker-owned terminal sessions.
///
/// This store is intentionally keyed only by broker session id and stores bytes in
/// opaque `.scrollback` files. It does not serialize environment, commands, or
/// IPC frames; those remain in `BrokerSessionRegistry`. Retention is enforced on
/// every append so disk state obeys the same per-session cap as the in-memory
/// runtime ring.
struct DiskBackedScrollbackStore: Sendable {
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

    init(
        directory: URL,
        maxRetainedBytes: Int = ScrollbackPersistencePolicy.maxRetainedBytesPerSession
    ) {
        self.directory = directory
        self.maxRetainedBytes = maxRetainedBytes
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
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try prune(descriptor: descriptor)
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
            guard let data = try readRegularFile(at: url, missingIsAbsent: true) else {
                return Data()
            }
            // A crash between append's write and its prune can leave the persisted
            // tail oversized relative to the retention cap. Repair it on read so a
            // normal store operation restores the bounded-scrollback guarantee.
            if data.count > maxRetainedBytes {
                try prune(url)
            }
            let capped = min(maxBytes, maxRetainedBytes)
            guard data.count > capped else { return data }
            return Data(data.suffix(capped))
        }
    }

    func remove(for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        try operationLocks.withLock(for: url) {
            // Clearing is deliberately descriptor-bound: the validated inode is
            // truncated instead of unlinking a pathname that could be rebound
            // between validation and mutation. The caller therefore needs write
            // permission on an existing tail, and the empty storage entry remains.
            _ = try withOpenRegularFile(
                at: url,
                flags: O_WRONLY | O_NONBLOCK,
                missingIsAbsent: true
            ) { descriptor in
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                try handle.truncate(atOffset: 0)
            }
        }
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        return try operationLocks.withLock(for: url) {
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
            guard Self.isRegularFileWithoutFollowingSymlinks(url) else { continue }
            let values: URLResourceValues?
            do {
                values = try operationLocks.withLock(for: url) {
                    guard Self.isRegularFileWithoutFollowingSymlinks(url) else { return nil }
                    let values = try resourceValues(url)
                    guard Self.isRegularFileWithoutFollowingSymlinks(url) else { return nil }
                    return values
                }
            } catch let error as ScrollbackSessionOperationLocks.LockError {
                throw error
            } catch {
                // A per-entry metadata/readability race must not throw out the
                // entire listing; skip the bad entry and surface the rest.
                continue
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
            try prune(descriptor: descriptor)
        }
    }

    private func prune(descriptor: Int32) throws {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard maxRetainedBytes > 0 else {
            try handle.truncate(atOffset: 0)
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
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: retained)
        try handle.truncate(atOffset: UInt64(retained.count))
    }

    private func readRegularFile(at url: URL, missingIsAbsent: Bool) throws -> Data? {
        try withOpenRegularFile(
            at: url,
            flags: O_RDONLY | O_NONBLOCK,
            missingIsAbsent: missingIsAbsent
        ) { descriptor in
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            return try handle.readToEnd() ?? Data()
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

    private static func isRegularFileWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else { return false }
        return fileStatus.st_mode & S_IFMT == S_IFREG
    }

    private static func isUnsafeExistingLeaf(_ url: URL) -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else { return false }
        return fileStatus.st_mode & S_IFMT != S_IFREG
    }
}
