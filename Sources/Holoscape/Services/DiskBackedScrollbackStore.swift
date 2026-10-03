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
        let canonicalURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
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
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
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
        guard !data.isEmpty else { return }
        let url = try fileURL(for: id)
        try operationLocks.withLock(for: url) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                let operationError = error
                do {
                    try handle.close()
                } catch {
                    throw StoreError.fileOperationAndCloseFailed(
                        operation: String(describing: operationError),
                        close: String(describing: error)
                    )
                }
                throw operationError
            }
            try handle.close()
            try prune(url)
        }
    }

    func readTail(for id: BrokerSessionID, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        guard maxRetainedBytes > 0 else { return Data() }
        let url = try fileURL(for: id)
        return try operationLocks.withLock(for: url) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else { return Data() }
            let data = try Data(contentsOf: url)
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
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        return try operationLocks.withLock(for: url) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else { return 0 }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int ?? 0
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
            try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
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
            // Reject foreign directories and symlinks before deriving the
            // advisory-lock path. `withLock` resolves symlinks so aliases share
            // authority; invoking it for an untrusted entry could otherwise
            // create a `.lock` file beside that entry's external target.
            guard let entryType = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  entryType.isRegularFile == true,
                  entryType.isSymbolicLink != true else { continue }
            let values: URLResourceValues
            do {
                values = try operationLocks.withLock(for: url) {
                    try resourceValues(url)
                }
            } catch let error as ScrollbackSessionOperationLocks.LockError {
                throw error
            } catch {
                // A per-entry metadata/readability race must not throw out the
                // entire listing; skip the bad entry and surface the rest.
                continue
            }
            guard values.isRegularFile == true else { continue }
            tails.append(StoredScrollbackTail(
                sessionID: BrokerSessionID(rawValue: rawID),
                byteCount: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate
            ))
        }
        return tails.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    private func prune(_ url: URL) throws {
        guard maxRetainedBytes > 0 else {
            try Data().write(to: url, options: .atomic)
            return
        }
        let data = try Data(contentsOf: url)
        guard data.count > maxRetainedBytes else { return }
        try Data(data.suffix(maxRetainedBytes)).write(to: url, options: .atomic)
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
}
