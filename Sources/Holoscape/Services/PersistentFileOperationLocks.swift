import Darwin
import Foundation

/// Coordinates file transactions both within this process and with other
/// processes that use the same persistent advisory-lock path.
final class PersistentFileOperationLocks: @unchecked Sendable {
    static let shared = PersistentFileOperationLocks()

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
    private var durabilityInitializedPaths: Set<String> = []

    struct LockError: LocalizedError {
        let message: String
        let operationError: Error?
        let operationSucceeded: Bool

        init(
            message: String,
            operationError: Error? = nil,
            operationSucceeded: Bool = false
        ) {
            self.message = message
            self.operationError = operationError
            self.operationSucceeded = operationSucceeded
        }

        var errorDescription: String? { message }
    }

    func withLock<T>(
        for fileURL: URL,
        synchronizeCreatedDirectoryEntries: ((URL) throws -> Void)? = nil,
        unlockDescriptor: (Int32) -> Int32 = { flock($0, LOCK_UN) },
        closeDescriptor: (Int32) -> Int32 = Darwin.close,
        _ operation: () throws -> T
    ) throws -> T {
        let standardizedURL = fileURL.standardizedFileURL
        // Canonicalize the containing directory so callers using equivalent
        // directory aliases share authority, but never resolve the data-file
        // leaf. A concurrent leaf symlink swap must not redirect the advisory
        // lock outside the intended directory.
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
            let lockDirectoryURL = lockURL.deletingLastPathComponent()
            let missingDirectories = Self.missingDirectories(endingAt: lockDirectoryURL)
            if !missingDirectories.isEmpty {
                // Deletion invalidates the cached proof that this directory
                // entry is durable. Clear it before recreation so a failed
                // synchronization is retried before any later operation.
                _ = registryLock.withLock {
                    durabilityInitializedPaths.remove(key)
                }
            }
            let needsDurabilityInitialization = registryLock.withLock {
                !durabilityInitializedPaths.contains(key)
            }
            do {
                try FileManager.default.createDirectory(
                    at: lockDirectoryURL,
                    withIntermediateDirectories: true
                )
                if let synchronizeCreatedDirectoryEntries {
                    let directoriesToSynchronize = needsDurabilityInitialization
                        ? Self.directoryEntryParents(endingAt: lockDirectoryURL)
                        : missingDirectories.reversed().map { $0.deletingLastPathComponent() }
                    for directory in directoriesToSynchronize {
                        try synchronizeCreatedDirectoryEntries(directory)
                    }
                    _ = registryLock.withLock {
                        durabilityInitializedPaths.insert(key)
                    }
                }
            } catch {
                throw LockError(
                    message: "createDirectory failed or synchronization failed for \(lockDirectoryURL.path): \(error)"
                )
            }

            // The lock leaf is persistent authority, not an aliasable path.
            // Refuse symlinks atomically at open so a concurrent replacement
            // cannot redirect flock outside the intended directory.
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
                if closeDescriptor(descriptor) != 0 {
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
            if unlockDescriptor(descriptor) != 0 {
                cleanupFailures.append(Self.posixFailure("flock(LOCK_UN)", path: lockURL.path, code: errno))
            }
            if closeDescriptor(descriptor) != 0 {
                cleanupFailures.append(Self.posixFailure("close", path: lockURL.path, code: errno))
            }
            if !cleanupFailures.isEmpty {
                switch result {
                case .success:
                    throw LockError(
                        message: cleanupFailures.joined(separator: "; "),
                        operationSucceeded: true
                    )
                case .failure(let error):
                    throw LockError(
                        message: "operation failed: \(error); " + cleanupFailures.joined(separator: "; "),
                        operationError: error
                    )
                }
            }
            return try result.get()
        }
    }

    private static func posixFailure(_ operation: String, path: String, code: Int32) -> String {
        "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
    }

    private static func missingDirectories(endingAt directoryURL: URL) -> [URL] {
        var result: [URL] = []
        var candidate = directoryURL.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            result.append(candidate)
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return result
    }

    /// Until the persistent lock authority exists, synchronize the full path
    /// from root to leaf. This makes retries safe after a prior directory-sync
    /// failure left an in-memory directory tree that was never durably linked.
    private static func directoryEntryParents(endingAt directoryURL: URL) -> [URL] {
        let components = directoryURL.standardizedFileURL.pathComponents
        guard components.first == "/", components.count > 1 else { return [] }

        var result = [URL(fileURLWithPath: "/", isDirectory: true)]
        var parent = result[0]
        for component in components.dropFirst().dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            result.append(parent)
        }
        return result
    }
}

// Preserve the focused scrollback-test name while sharing this generic lock.
typealias ScrollbackSessionOperationLocks = PersistentFileOperationLocks
